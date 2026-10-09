--!strict
-- Worktree, host half: the `picker` block, a fuzzy picker of the repository's
-- Git worktrees and branches, backed by Git through worktree.sh.
--
-- Opening it runs `sh worktree.sh list` in the block's cwd (the focused pane's
-- when opened from the palette), whose stdout is a JSON array of
--
--   { "group": "Worktrees", "label": "main", "detail": "/repo/path",
--     "action": "open", "target": "/repo/path" }
--
-- `action` is `open` (target: a worktree path) or `checkout` (target: a branch
-- without a worktree). A row that isn't valid is skipped, and a note says how
-- many and why. Rows sharing a group sit under one heading, in order of first
-- appearance. Picking a row runs `sh worktree.sh <action> <target>`.
--
-- Typing filters the rows fuzzily (fuzzy.luau) over label and detail. The
-- filter takes only the characters a branch name is made of (A-Za-z0-9._/-);
-- others are dropped as typed, with a note. A text that is a valid git branch
-- name and no row's label exactly gets a "Create '<name>' worktree" row
-- (`sh worktree.sh create <name>`): first when no label matches the text (so
-- Enter creates it), else last. An invalid name shows why in its place.
-- ↑↓ (Ctrl+P/N/K/J, Tab) pick, Enter runs, Esc clears the filter, then
-- closes; Ctrl+R lists again.
--
-- A zero exit toasts the row's label and closes the block; a nonzero exit, a
-- timeout or a spawn failure shows the output in a sheet (Enter closes, Esc
-- goes back to the list). Esc while a command runs closes the block; the
-- command keeps going. Commands run detached from any terminal, in the
-- block's cwd.
--
-- A restart keeps the list's last finished result and the filter text rather
-- than listing again: Tern restarts plugin blocks when any file under a linked
-- plugin's directory changes. Ctrl+R lists on demand.
--
-- Displayed text (labels, details, output) shows the home directory as $HOME;
-- commands still run with the real paths.

local fuzzy = require("./fuzzy")
local configuration = require("./configuration")

local ui = tern.ui

--- A pickable row. `target` is a worktree path (open), a branch name
--- (checkout, create).
type Option = {
	label: string,
	detail: string,
	group: string?,
	action: string,
	target: string,
}

type Outcome = { option: Option, status: number, output: string, timed_out: boolean }

--- A visible row: its option, an id for click events (its index in
--- `State.options`; 0 for the create row), and the matched codepoints.
type Shown = { i: number, option: Option, label_hits: { number }, detail_hits: { number }, create: boolean? }

type State = {
	cx: BlockCx,
	options: { Option }, -- the last finished `list`
	loading: boolean,
	loaded: boolean, -- `list` has finished (it may have failed: no options then)
	load_error: string?, -- why `list` failed, or what it skipped
	create_option: Option?, -- the create row for the current query
	query_problem: string?, -- why the query can't be a branch name
	input_note: string?, -- the last character the filter refused
	note_timer: TimerHandle?, -- clears `input_note`
	query: string,
	shown: { Shown },
	sel: number, -- index into `shown`
	running: Option?, -- the picked option whose command runs; held itself, not an index, since the list can change under it
	outcome: Outcome?,
	closed: boolean,
}

local NOTE_MS = 2500 -- how long a refused-character note stays
local LIST_TIMEOUT_MS = 15000
local ACTIONS = { open = true, checkout = true }

local HOME = tern.getenv("HOME") or "/"
local SCRIPT = tern.plugin.dir .. "/worktree.sh"

--- `s` as displayed: the home directory reads `$HOME` wherever it ends a
--- path component (`/home/me/x`, `/home/me`, not `/home/meg`).
local function show_home(s: string): string
	local home = HOME:gsub("/+$", "")
	if home == "" then
		return s
	end
	local out: { string } = {}
	local from = 1
	while true do
		local a, b = s:find(home, from, true)
		if not a or not b then
			break
		end
		local after = s:sub(b + 1, b + 1)
		table.insert(out, s:sub(from, a - 1))
		table.insert(out, if after:match("^[%w_%.%-]$") then home else "$HOME")
		from = b + 1
	end
	table.insert(out, s:sub(from))
	return table.concat(out)
end

--- `s` with each invalid UTF-8 byte replaced by U+FFFD, so codepoint
--- positions (fuzzy matches, highlights) agree with what is drawn.
local function valid_utf8(s: string): string
	if utf8.len(s) ~= nil then
		return s
	end
	local out: { string } = {}
	local pos = 1
	while true do
		local n, bad = utf8.len(s, pos)
		if n ~= nil or bad == nil then
			table.insert(out, s:sub(pos))
			break
		end
		table.insert(out, s:sub(pos, bad - 1))
		table.insert(out, "\u{FFFD}")
		pos = bad + 1
	end
	return table.concat(out)
end

--- Why `name` can't be a git branch (what `git branch` refuses), or nil.
--- Characters the filter refuses never reach here.
local function git_branch_problem(name: string): string?
	if name:sub(1, 1) == "-" then
		return "it can't start with -"
	elseif name == "HEAD" then
		return "HEAD is reserved"
	elseif name:find("..", 1, true) then
		return "it can't contain .."
	elseif name:sub(1, 1) == "/" or name:sub(-1) == "/" or name:find("//", 1, true) then
		return "/ must sit between two names"
	elseif name:sub(-1) == "." then
		return "it can't end with ."
	elseif name:find("@{", 1, true) then
		return "it can't contain @{"
	end
	for part in name:gmatch("[^/]+") do
		if part:sub(1, 1) == "." then
			return "a part can't start with ."
		elseif part:sub(-5) == ".lock" then
			return "a part can't end with .lock"
		end
	end
	return nil
end

--- Whether the filter takes character `c` (one UTF-8 character): A-Za-z0-9._/-
local function filter_takes(c: string): boolean
	return c:match("^[A-Za-z0-9%._/%-]$") ~= nil
end

local function render(s: State)
	if not s.closed then
		pcall(function()
			s.cx:render()
		end)
	end
end

local function close(s: State)
	s.closed = true
	s.cx:exit(0)
end

--- What a row shows (and the filter matches): label and detail, $HOME-ified.
local function label_text(o: Option): string
	return valid_utf8(show_home(o.label))
end

local function detail_text(o: Option): string
	return valid_utf8(show_home(o.detail))
end

local function finish(s: State, o: Option, status: number, output: string, timed_out: boolean)
	s.running = nil
	if s.closed then
		return
	end
	if status == 0 then
		s.cx:toast("success", label_text(o), "exit 0")
		close(s)
		return
	end
	s.outcome = { option = o, status = status, output = output, timed_out = timed_out }
	render(s)
end

--- Runs `o`'s command: `sh worktree.sh <action> <target>`.
local function start(s: State, o: Option)
	s.outcome, s.running = nil, o
	local argv = { "sh", SCRIPT, o.action, o.target }
	local opts: ProcessOptions = { cwd = s.cx.cwd or HOME }
	local ok, err = pcall(function()
		if o.action == "checkout" or o.action == "create" then
			local directory = configuration.directory()
			if directory ~= "" then
				table.insert(argv, directory)
			end
		end
		tern.process.run(argv, opts, function(res: ProcessResult)
			local out = res.stdout
			if res.stderr ~= "" then
				out = if out == "" or out:sub(-1) == "\n" then out .. res.stderr else out .. "\n" .. res.stderr
			end
			finish(s, o, res.status, out, res.timed_out)
		end)
	end)
	if not ok then
		finish(s, o, -1, `can't run {argv[1]}: {err}`, false)
	end
end

local function choose(s: State, o: Option)
	if not s.running then
		start(s, o)
	end
end

--- Recomputes the visible rows for `s.query`: every option on an empty query,
--- in list order within each group; else the fuzzy matches, best first (each
--- group's rows together), plus the create row unless the query is exactly an
--- option's label. That row leads when the query matches no option's label on
--- its own (matches only in details, e.g. a path, don't count), else it
--- trails. Selects the first.
local function refilter(s: State)
	local shown: { Shown } = {}
	local scores: { [number]: number } = {}
	for i, o in s.options do
		-- One haystack so a query may span label and detail; the label leads,
		-- so fzy's leading-gap charge prefers label hits.
		local label = label_text(o)
		local label_len = #fuzzy.chars(label)
		local score, positions = fuzzy.match(s.query, label .. "  " .. detail_text(o))
		if score then
			local lh, dh = {}, {}
			for _, p in positions do
				if p <= label_len then
					table.insert(lh, p)
				elseif p > label_len + 2 then
					table.insert(dh, p - label_len - 2)
				end
			end
			scores[i] = score
			table.insert(shown, { i = i, option = o, label_hits = lh, detail_hits = dh })
		end
	end
	if s.query ~= "" then
		table.sort(shown, function(a: Shown, b: Shown): boolean
			if scores[a.i] ~= scores[b.i] then
				return scores[a.i] > scores[b.i]
			end
			return a.i < b.i
		end)
	end
	-- Groups in first-appearance order over s.options ("" is ungrouped), so each
	-- group's rows stay together, in the order above.
	local rank: { [string]: number } = {}
	local ngroups = 0
	for _, o in s.options do
		local g = o.group or ""
		if not rank[g] then
			ngroups += 1
			rank[g] = ngroups
		end
	end
	local bucket: { [number]: { Shown } } = {}
	for _, m in shown do
		local r = rank[m.option.group or ""] :: number
		bucket[r] = bucket[r] or {}
		table.insert(bucket[r], m)
	end
	shown = {}
	for r = 1, ngroups do
		local items: { Shown } = bucket[r] or {}
		for _, m in items do
			table.insert(shown, m)
		end
	end
	s.create_option, s.query_problem = nil, nil
	local q = s.query:match("^%s*(.-)%s*$") or ""
	if q ~= "" then
		local exact = false
		for _, o in s.options do
			exact = exact or o.label == q
		end
		local problem = git_branch_problem(q)
		if exact then
			-- An existing option already is this name.
		elseif problem then
			s.query_problem = `“{q}” isn't a valid branch name: {problem}`
		else
			local o: Option = { label = `Create '{q}' worktree`, detail = "Create a Git branch and worktree", action = "create", target = q }
			s.create_option = o
			-- Typing a name that no label matches means a new one: Enter creates it.
			local named = false
			for _, m in shown do
				if fuzzy.match(s.query, label_text(m.option)) then
					named = true
					break
				end
			end
			local row: Shown = { i = 0, option = o, label_hits = {}, detail_hits = {}, create = true }
			table.insert(shown, if named then #shown + 1 else 1, row)
		end
	end
	s.shown, s.sel = shown, 1
end

--- Whether decoded JSON `v` is an array: its keys are exactly 1..n.
local function is_array(v: any): boolean
	if type(v) ~= "table" then
		return false
	end
	local n = 0
	for k, _ in v do
		if type(k) ~= "number" then
			return false
		end
		n += 1
	end
	return n == #v
end

--- A `list` row (or a saved option) as an Option, or raises with why not.
local function parse_option(raw: any, at: string): Option
	if type(raw) ~= "table" then
		error(`{at} must be an object`, 0)
	end
	if type(raw.label) ~= "string" or raw.label == "" then
		error(`{at}.label must be a nonempty string`, 0)
	end
	if type(raw.target) ~= "string" or raw.target == "" then
		error(`{at}.target must be a nonempty string`, 0)
	end
	if type(raw.action) ~= "string" or not ACTIONS[raw.action] then
		error(`{at}.action must be open or checkout`, 0)
	end
	if raw.detail ~= nil and type(raw.detail) ~= "string" then
		error(`{at}.detail must be a string`, 0)
	end
	if raw.group ~= nil and type(raw.group) ~= "string" then
		error(`{at}.group must be a string`, 0)
	end
	return { label = raw.label, detail = raw.detail or "", group = raw.group, action = raw.action, target = raw.target }
end

--- The options from `stdout` of `worktree.sh list`, or raises with why not.
--- A row that isn't valid is skipped; the second result says how many were
--- and why the first was.
local function parse_list(stdout: string): ({ Option }, string?)
	local ok, decoded = pcall(tern.json.decode, stdout)
	if not ok or not is_array(decoded) then
		error("its output isn't a JSON array", 0)
	end
	local items: { any } = decoded
	local out: { Option } = {}
	local bad, why = 0, nil :: string?
	for k = 1, #items do
		local valid, opt = pcall(parse_option, items[k], `item {k}`)
		if valid then
			table.insert(out, opt)
		else
			bad += 1
			why = why or tostring(opt)
		end
	end
	local skipped = if bad > 0 then `skipped {bad} of {#items} items: {why}` else nil
	return out, skipped
end

--- Runs `worktree.sh list` for the options; those already shown stay usable
--- while it runs, and a failure shows above them.
local function load_options(s: State)
	s.loading, s.loaded, s.load_error = true, false, nil
	refilter(s)
	local argv = { "sh", SCRIPT, "list" }
	local opts: ProcessOptions = { cwd = s.cx.cwd or HOME, timeout_ms = LIST_TIMEOUT_MS }
	local function done(err: string?, options: { Option }?)
		s.loading, s.loaded = false, true
		if s.closed then
			return
		end
		s.load_error = err
		s.options = options or {}
		refilter(s)
		render(s)
		-- Kept now, not at the next key: a restart may come before any.
		pcall(function()
			s.cx:save()
		end)
	end
	local ok, err = pcall(function()
		tern.process.run(argv, opts, function(res: ProcessResult)
			if res.status ~= 0 then
				local why = res.stderr:gsub("%s+$", "")
				done(`worktree.sh list {if res.timed_out then "timed out" else `exited {res.status}`}`
					.. (if why ~= "" then `: {why}` else ""))
				return
			end
			local parsed, result, skipped = pcall(parse_list, res.stdout)
			if parsed then
				done(if skipped then `worktree.sh list: {skipped}` else nil, result)
			else
				done(`worktree.sh list: {result}`)
			end
		end)
	end)
	if not ok then
		s.loading, s.loaded = false, true
		s.load_error = `can't run {argv[1]}: {err}`
		s.options = {}
		refilter(s)
	end
end

--- Takes back the finished `list` result kept by `save` (see the header);
--- false when there is none to take, so `list` runs.
local function restore_options(s: State, saved: any): boolean
	if type(saved.options) ~= "table" then
		return false
	end
	local ok, options = pcall(function(): { Option }
		local out: { Option } = {}
		for k, o in ipairs(saved.options) do
			table.insert(out, parse_option(o, `item {k}`))
		end
		return out
	end)
	if not ok then
		return false
	end
	s.options, s.loaded = options, true
	s.load_error = if type(saved.load_error) == "string" then saved.load_error else nil
	refilter(s)
	return true
end

local function set_query(s: State, q: string)
	if q ~= s.query then
		s.query = q
		refilter(s)
	end
end

local function drop_last_char(q: string): string
	local at = utf8.offset(q, -1)
	return if at then q:sub(1, at - 1) else q:sub(1, -2)
end

local function button(text: string, act: string, class: string?): Node
	return ui.el("button", { class = "wt-btn" .. (if class then " " .. class else ""), text = text, actions = { click = act } })
end

local function sheet(key: string, title: string, body: { Node }, buttons: { Node }): Node
	return ui.col({ ui.el("div", { class = "wt-scrim", key = "scrim" }, {
		ui.el("div", { class = "wt-sheet", key = key }, {
			ui.el("div", { class = "wt-shead", text = title }),
			ui.el("div", { class = "wt-sbody" }, body),
			ui.el("div", { class = "wt-sfoot" }, buttons),
		}),
	}) })
end

--- `text` as a span whose matched codepoints (`hits`) are wrapped in `.wt-hit`.
local function highlighted(text: string, hits: { number }, class: string): Node
	if #hits == 0 then
		return ui.el("span", { class = class, text = text })
	end
	local hit: { [number]: boolean } = {}
	for _, p in hits do
		hit[p] = true
	end
	local parts: { Node } = {}
	local run: { string } = {}
	local run_hit = false
	local function flush()
		if #run > 0 then
			table.insert(parts, ui.el("span", { class = if run_hit then "wt-hit" else nil, text = table.concat(run) }))
			run = {}
		end
	end
	for p, c in fuzzy.chars(text) do
		local h = hit[p] == true
		if h ~= run_hit then
			flush()
			run_hit = h
		end
		table.insert(run, c)
	end
	flush()
	return ui.el("span", { class = class }, parts)
end

local function filter_view(s: State): Node
	return ui.el("div", { class = "wt-filter", key = "filter" }, {
		ui.node("input", { text = s.query, placeholder = "Type to filter…" }),
		ui.el("span", { class = "wt-count", text = `{#s.shown - (if s.create_option then 1 else 0)}/{#s.options}` }),
	})
end

--- The group a shown row sits under: nil for ungrouped rows and the create
--- row, which sits outside every group.
local function group_of(m: Shown): string?
	if m.create then
		return nil
	end
	local g = m.option.group
	return if g and g ~= "" then g else nil
end

local function options_view(s: State): Node
	local rows: { Node } = {}
	if #s.shown == 0 then
		if s.loading then
			table.insert(rows, ui.progress(nil, "loading worktrees…"))
		elseif not s.query_problem then
			table.insert(rows, ui.el("div", { class = "wt-none", key = "none", text = if #s.options == 0 then "no worktrees or branches" else `nothing matches “{s.query}”` }))
		end
	end
	-- Headings show only when a shown row has a group. A group's rows are
	-- contiguous (see refilter), so its heading goes before the first one.
	local grouped, last = false, nil :: string?
	for _, m in s.shown do
		grouped = grouped or group_of(m) ~= nil
	end
	for row, m in s.shown do
		local g = group_of(m)
		if grouped and g and g ~= last then
			table.insert(rows, ui.el("div", { class = "wt-group", key = `g{g}`, text = valid_utf8(show_home(g)) }))
		end
		last = g
		local class = "wt-opt"
		if row == s.sel then
			class ..= " sel"
		end
		if s.running == m.option then
			class ..= " running"
		end
		if m.create then
			class ..= " create"
		end
		table.insert(rows, ui.el("button", { class = class, key = `o{m.i}`, actions = { click = `pick={m.i}` } }, {
			highlighted(label_text(m.option), m.label_hits, "wt-label"),
			highlighted(detail_text(m.option), m.detail_hits, "wt-detail"),
		}))
	end
	if s.loading and #s.shown > 0 then
		table.insert(rows, ui.progress(nil, "loading more worktrees…"))
	end
	if s.query_problem then
		table.insert(rows, ui.el("div", { class = "wt-note bad", key = "problem", text = s.query_problem }))
	end
	if s.input_note then
		table.insert(rows, ui.el("div", { class = "wt-note", key = "refused", text = s.input_note }))
	end
	return ui.el("div", { class = "wt-opts", key = "opts" }, rows)
end

local function layer_view(s: State): Node?
	local r = s.outcome
	if r then
		local verdict = if r.timed_out then "timed out"
			elseif r.status == 0 then "exit 0"
			elseif r.status == -1 then "failed"
			else `exit {r.status}`
		return sheet("outcome", label_text(r.option), {
			ui.row({ ui.badge(verdict, if r.status == 0 then "success" else "error") }),
			if r.output == "" then ui.text(ui.span("no output", "muted")) else ui.ansi(show_home(r.output)),
		}, {
			button("Back", "back"),
			button("Close", "close", "primary"),
		})
	end
	return nil
end

local function hints(s: State): Node
	local running = s.running
	if running then
		return ui.progress(nil, `running {label_text(running)}…`)
	end
	local function k(key: string, what: string): { Span }
		return { ui.span(key, "key"), ui.span(` {what}  `, "muted") }
	end
	local groups: { { Span } } = if s.outcome then { k("⏎", "close"), k("esc", "back") }
		else { k("↑↓", "select"), k("⏎", "run"), k("esc", if s.query ~= "" then "clear" else "close"), k("^R", "reload") }
	local spans: { Span } = {}
	for _, g in groups do
		for _, sp in g do
			table.insert(spans, sp)
		end
	end
	return ui.text(spans)
end

--- Appends typed or pasted `text` to the query, minus the characters the
--- filter refuses; notes the first refused one.
local function type_text(s: State, text: string)
	local kept: { string } = {}
	local refused: string? = nil
	for _, c in fuzzy.chars(valid_utf8(text)) do
		if filter_takes(c) then
			table.insert(kept, c)
		else
			refused = refused or c
		end
	end
	if refused then
		local what = if refused == " " then "spaces" else `“{refused}”`
		s.input_note = `a branch name can't contain {what}`
		-- Shown for a moment, however fast the next keys come.
		if s.note_timer then
			s.note_timer:cancel()
		end
		s.note_timer = tern.timer(NOTE_MS, function()
			s.input_note, s.note_timer = nil, nil
			render(s)
		end)
	end
	if #kept > 0 then
		set_query(s, s.query .. table.concat(kept))
	end
end

--- List-mode keys: the filter takes text; arrows and Ctrl+P/N/K/J move.
local function list_key(s: State, key: Key): boolean?
	local name = key.name
	local n = #s.shown
	local function move(by: number)
		if n > 0 then
			s.sel = (s.sel - 1 + by) % n + 1
		end
	end
	if name == "up" or (key.ctrl and (name == "p" or name == "k")) or (name == "tab" and key.shift) then
		move(-1)
	elseif name == "down" or (key.ctrl and (name == "n" or name == "j")) or name == "tab" then
		move(1)
	elseif name == "home" then
		s.sel = 1
	elseif name == "end" then
		s.sel = math.max(n, 1)
	elseif name == "enter" then
		local m = s.shown[s.sel]
		if not m then
			return false
		end
		choose(s, m.option)
	elseif name == "escape" or name == "esc" then
		if s.query == "" then
			close(s)
		else
			set_query(s, "")
		end
	elseif name == "backspace" then
		if s.query == "" then
			return false
		end
		set_query(s, if key.ctrl or key.alt then "" else drop_last_char(s.query))
	elseif key.ctrl and name == "u" then
		set_query(s, "")
	elseif key.ctrl and name == "w" then
		set_query(s, (s.query:gsub("%s*[^%s]*$", "")))
	elseif key.ctrl and name == "r" then
		if s.loading then
			return false
		end
		load_options(s)
	elseif name == "paste" then
		type_text(s, ((key.text or ""):gsub("[\r\n\t]+", " ")))
	elseif not (key.ctrl or key.meta or key.alt) and key.text and key.text ~= "" then
		type_text(s, key.text)
	elseif name == "space" and not (key.ctrl or key.meta or key.alt) then
		type_text(s, " ")
	else
		return false
	end
	return nil
end

tern.block.define("picker", {
	init = function(cx: BlockCx, _args: { string }, saved: any): State
		local s: State = { cx = cx, options = {}, loading = false, loaded = false, query = "", shown = {}, sel = 1, closed = false }
		if type(saved) == "table" then
			-- A restart: the filter text as it was, and the list as it last finished.
			if type(saved.query) == "string" then
				local kept: { string } = {}
				for _, c in fuzzy.chars(valid_utf8(saved.query)) do
					if filter_takes(c) then
						table.insert(kept, c)
					end
				end
				s.query = table.concat(kept)
			end
			if restore_options(s, saved) then
				return s
			end
		end
		load_options(s)
		return s
	end,

	title = function(_s: State): string?
		return "Worktrees"
	end,

	view = function(s: State, _cx: BlockCx): BlockView
		local body: { Node } = {
			ui.el("div", { class = "wt-title", text = "Worktrees" }),
			ui.el("div", { class = "wt-msg" }, {
				ui.md("Pick a worktree to open it in a tab, pick a branch to create its worktree, or type a new branch name to create it."),
			}),
			filter_view(s),
		}
		if s.load_error then
			table.insert(body, ui.diagnostic({ severity = "error", message = show_home(s.load_error) }))
		end
		table.insert(body, options_view(s))
		return {
			main = ui.col({ ui.el("div", { class = "wt", key = "wt" }, body) }),
			dock = ui.col({ hints(s) }),
			layer = layer_view(s),
		}
	end,

	event = function(s: State, ev: UiEvent, _cx: BlockCx)
		if ev.ev ~= "action" then
			return
		end
		if ev.act == "pick" then
			local i = tonumber(ev.value)
			if i and not s.outcome then
				for row, m in s.shown do
					if m.i == i then
						s.sel = row
						choose(s, m.option)
						break
					end
				end
			end
		elseif ev.act == "back" then
			s.outcome = nil
		elseif ev.act == "close" then
			close(s)
		end
	end,

	key = function(s: State, key: Key, _cx: BlockCx): boolean?
		local name = key.name
		local esc = name == "escape" or name == "esc"
		if s.running then
			-- esc leaves; a running command keeps going without the block.
			if esc then
				close(s)
				return nil
			end
			return false
		end
		if s.outcome then
			if name == "enter" then
				close(s)
			elseif esc then
				s.outcome = nil
			else
				return false
			end
			return nil
		end
		return list_key(s, key)
	end,

	save = function(s: State): any
		return {
			query = s.query,
			options = if s.loaded then s.options else nil,
			load_error = if s.loaded then s.load_error else nil,
		}
	end,
})
