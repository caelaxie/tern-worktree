--!strict

local fuzzy = require("./fuzzy")
local configuration = require("./configuration")

local ui = tern.ui

type Attached = { kind: "attached", name: string }
type Detached = { kind: "detached", sha: string }
type Head = Attached | Detached

type Main = { kind: "main", path: string, head: Head }
type Linked = { kind: "linked", path: string, head: Head }
type Branch = { kind: "branch", name: string, sha: string, subject: string }
type NewBranch = { kind: "new", name: string }
type Row = Main | Linked | Branch | NewBranch

type OpenCmd = { kind: "open", path: string }
type CheckoutCmd = { kind: "checkout", branch: string }
type CreateCmd = { kind: "create", branch: string }
type Primary = OpenCmd | CheckoutCmd | CreateCmd
type RemoveCmd = { kind: "remove", path: string }
type Command = Primary | RemoveCmd

type Inflight = { command: Command, row: Row }
type Mode =
	{ kind: "list" }
	| { kind: "confirm", row: Linked }
	| { kind: "running", inflight: Inflight }
	| { kind: "outcome", inflight: Inflight, status: number, output: string, timed_out: boolean }

type Listed = { kind: "listed", at: number, row: Row, label_hits: { number }, detail_hits: { number } }
type CreateShown = { kind: "create", row: NewBranch, label_hits: { number }, detail_hits: { number } }
type Shown = Listed | CreateShown

type State = {
	cx: BlockCx,
	mode: Mode,
	rows: { Row },
	loading: boolean,
	list_finished: boolean,
	load_error: string?,
	query_problem: string?,
	input_note: string?,
	note_timer: TimerHandle?,
	query: string,
	shown: { Shown },
	sel: number, -- index into `shown`
	closed: boolean,
}

local NOTE_MS = 2500 -- how long a refused-character note stays
local LIST_TIMEOUT_MS = 15000

local HOME = tern.getenv("HOME") or "/"
local SCRIPT = tern.plugin.dir .. "/worktree.sh"
local UNGROUPED = ""

-- A leftover variant has to be `never`. error() alone still typechecks if a case was skipped.
local function unreachable(x: never): never
	error("unreachable")
end

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

local function show_note(s: State, text: string)
	s.input_note = text
	if s.note_timer then
		s.note_timer:cancel()
	end
	s.note_timer = tern.timer(NOTE_MS, function()
		s.input_note, s.note_timer = nil, nil
		render(s)
	end)
end

local function head_label(head: Head): string
	if head.kind == "attached" then
		return head.name
	elseif head.kind == "detached" then
		return `(detached {head.sha:sub(1, 7)})`
	else
		return unreachable(head)
	end
end

local function attached_name(head: Head): string?
	if head.kind == "attached" then
		return head.name
	elseif head.kind == "detached" then
		return nil
	else
		return unreachable(head)
	end
end

local function label_of(row: Row): string
	if row.kind == "main" then
		return head_label(row.head)
	elseif row.kind == "linked" then
		return head_label(row.head)
	elseif row.kind == "branch" then
		return row.name
	elseif row.kind == "new" then
		return `Create '{row.name}' worktree`
	else
		return unreachable(row)
	end
end

local function detail_of(row: Row): string
	if row.kind == "main" then
		return row.path
	elseif row.kind == "linked" then
		return row.path
	elseif row.kind == "branch" then
		if row.subject == "" then
			return row.sha
		end
		return `{row.sha} {row.subject}`
	elseif row.kind == "new" then
		return "Create a Git branch and worktree"
	else
		return unreachable(row)
	end
end

local function group_of(row: Row): string?
	if row.kind == "main" then
		return "Worktrees"
	elseif row.kind == "linked" then
		return "Worktrees"
	elseif row.kind == "branch" then
		return "Branches"
	elseif row.kind == "new" then
		return nil
	else
		return unreachable(row)
	end
end

local function freed_branch(row: Row): string?
	if row.kind == "linked" then
		return attached_name(row.head)
	elseif row.kind == "main" then
		return nil
	elseif row.kind == "branch" then
		return nil
	elseif row.kind == "new" then
		return nil
	else
		return unreachable(row)
	end
end

local function label_text(row: Row): string
	return valid_utf8(show_home(label_of(row)))
end

local function detail_text(row: Row): string
	return valid_utf8(show_home(detail_of(row)))
end

local function command_of(row: Row): Primary
	if row.kind == "main" then
		return { kind = "open", path = row.path }
	elseif row.kind == "linked" then
		return { kind = "open", path = row.path }
	elseif row.kind == "branch" then
		return { kind = "checkout", branch = row.name }
	elseif row.kind == "new" then
		return { kind = "create", branch = row.name }
	else
		return unreachable(row)
	end
end

local function remove_command(row: Linked): RemoveCmd
	return { kind = "remove", path = row.path }
end

local function remove_refusal(row: Main | Branch | NewBranch): string
	if row.kind == "main" then
		return "The main checkout stays."
	elseif row.kind == "branch" then
		return "This branch has no worktree to remove."
	elseif row.kind == "new" then
		return "Nothing to remove yet."
	else
		return unreachable(row)
	end
end

local function argv_of(cmd: Command): { string }
	if cmd.kind == "open" then
		return { "sh", SCRIPT, "open", cmd.path }
	elseif cmd.kind == "checkout" then
		local argv = { "sh", SCRIPT, "checkout", cmd.branch }
		local directory = configuration.directory()
		if directory ~= "" then
			table.insert(argv, directory)
		end
		return argv
	elseif cmd.kind == "create" then
		local argv = { "sh", SCRIPT, "create", cmd.branch }
		local directory = configuration.directory()
		if directory ~= "" then
			table.insert(argv, directory)
		end
		return argv
	elseif cmd.kind == "remove" then
		return { "sh", SCRIPT, "remove", cmd.path }
	else
		return unreachable(cmd)
	end
end

local function refilter(s: State, prefer: string?)
	local matched: { Listed } = {}
	local scores: { [number]: number } = {}
	for i, row in s.rows do
		-- One haystack so a query may span label and detail; the label leads,
		-- so fzy's leading-gap charge prefers label hits.
		local label = label_text(row)
		local label_len = #fuzzy.chars(label)
		local score, positions = fuzzy.match(s.query, label .. "  " .. detail_text(row))
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
			table.insert(matched, { kind = "listed", at = i, row = row, label_hits = lh, detail_hits = dh })
		end
	end
	if s.query ~= "" then
		table.sort(matched, function(a: Listed, b: Listed): boolean
			if scores[a.at] ~= scores[b.at] then
				return scores[a.at] > scores[b.at]
			end
			return a.at < b.at
		end)
	end
	local rank: { [string]: number } = {}
	local ngroups = 0
	for _, row in s.rows do
		local g = group_of(row) or UNGROUPED
		if not rank[g] then
			ngroups += 1
			rank[g] = ngroups
		end
	end
	local bucket: { [number]: { Listed } } = {}
	for _, m in matched do
		local r = rank[group_of(m.row) or UNGROUPED] :: number
		bucket[r] = bucket[r] or {}
		table.insert(bucket[r], m)
	end
	local shown: { Shown } = {}
	for r = 1, ngroups do
		local items: { Listed } = bucket[r] or {}
		for _, m in items do
			table.insert(shown, m)
		end
	end
	s.query_problem = nil
	local q = s.query:match("^%s*(.-)%s*$") or ""
	if q ~= "" then
		local exact = false
		for _, row in s.rows do
			exact = exact or label_of(row) == q
		end
		local problem = git_branch_problem(q)
		if not exact and problem then
			s.query_problem = `“{q}” isn't a valid branch name: {problem}`
		elseif not exact then
			local row: NewBranch = { kind = "new", name = q }
			local named = false
			for _, m in shown do
				if fuzzy.match(s.query, label_text(m.row)) then
					named = true
					break
				end
			end
			local created: CreateShown = {
				kind = "create",
				row = row,
				label_hits = {},
				detail_hits = {},
			}
			table.insert(shown, if named then #shown + 1 else 1, created)
		end
	end
	local sel = 1
	if prefer then
		for i, m in shown do
			if m.row.kind == "branch" and m.row.name == prefer then
				sel = i
				break
			end
		end
	end
	s.shown, s.sel = shown, sel
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

local function parse_head(raw: any, at: string): Head
	if type(raw) ~= "table" then
		error(`{at} must be an object`, 0)
	end
	if raw.kind == "attached" then
		if type(raw.name) ~= "string" or raw.name == "" then
			error(`{at}.name must be a nonempty string`, 0)
		end
		return { kind = "attached", name = raw.name }
	elseif raw.kind == "detached" then
		if type(raw.sha) ~= "string" or raw.sha == "" then
			error(`{at}.sha must be a nonempty string`, 0)
		end
		return { kind = "detached", sha = raw.sha }
	else
		error(`{at}.kind must be attached or detached`, 0)
	end
end

local function parse_row(raw: any, at: string): Row
	if type(raw) ~= "table" then
		error(`{at} must be an object`, 0)
	end
	if raw.kind == "main" then
		if type(raw.path) ~= "string" or raw.path == "" then
			error(`{at}.path must be a nonempty string`, 0)
		end
		return { kind = "main", path = raw.path, head = parse_head(raw.head, `{at}.head`) }
	elseif raw.kind == "linked" then
		if type(raw.path) ~= "string" or raw.path == "" then
			error(`{at}.path must be a nonempty string`, 0)
		end
		return { kind = "linked", path = raw.path, head = parse_head(raw.head, `{at}.head`) }
	elseif raw.kind == "branch" then
		if type(raw.name) ~= "string" or raw.name == "" then
			error(`{at}.name must be a nonempty string`, 0)
		end
		if type(raw.sha) ~= "string" or raw.sha == "" then
			error(`{at}.sha must be a nonempty string`, 0)
		end
		if type(raw.subject) ~= "string" then
			error(`{at}.subject must be a string`, 0)
		end
		return { kind = "branch", name = raw.name, sha = raw.sha, subject = raw.subject }
	else
		error(`{at}.kind must be main, linked, or branch`, 0)
	end
end

local function parse_decoded(decoded: any): ({ Row }, string?)
	if not is_array(decoded) then
		error("its output isn't a JSON array", 0)
	end
	local items: { any } = decoded
	local out: { Row } = {}
	local bad, why = 0, nil :: string?
	for k = 1, #items do
		local valid, row = pcall(parse_row, items[k], `item {k}`)
		if valid then
			table.insert(out, row)
		else
			bad += 1
			why = why or tostring(row)
		end
	end
	local skipped = if bad > 0 then `skipped {bad} of {#items} items: {why}` else nil
	return out, skipped
end

local function parse_list(stdout: string): ({ Row }, string?)
	local ok, decoded = pcall(tern.json.decode, stdout)
	if not ok then
		error("its output isn't a JSON array", 0)
	end
	return parse_decoded(decoded)
end

local function path_inside(path: string, root: string): boolean
	if path == root then
		return true
	end
	local prefix = if root:sub(-1) == "/" then root else root .. "/"
	return path:sub(1, #prefix) == prefix
end

-- spawn reports ENOENT when cwd is gone, which reads as "sh" missing.
local function list_cwd(s: State, removed: string): string
	local cwd = s.cx.cwd or HOME
	if not path_inside(cwd, removed) then
		return cwd
	end
	for _, row in s.rows do
		if row.kind == "main" then
			return row.path
		end
	end
	for _, row in s.rows do
		if row.kind == "linked" and not path_inside(row.path, removed) then
			return row.path
		end
	end
	return HOME
end

local function load_options(s: State, prefer: string?, cwd: string?)
	s.loading, s.list_finished, s.load_error = true, false, nil
	refilter(s)
	local argv = { "sh", SCRIPT, "list" }
	local opts: ProcessOptions = { cwd = cwd or s.cx.cwd or HOME, timeout_ms = LIST_TIMEOUT_MS }
	local function done(err: string?, rows: { Row }?)
		s.loading, s.list_finished = false, true
		if s.closed then
			return
		end
		s.load_error = err
		s.rows = rows or {}
		refilter(s, prefer)
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
			local parsed, rows, skipped = pcall(parse_list, res.stdout)
			if parsed then
				done(if skipped then `worktree.sh list: {skipped}` else nil, rows)
			else
				done(`worktree.sh list: {rows}`)
			end
		end)
	end)
	if not ok then
		s.loading, s.list_finished = false, true
		s.load_error = `can't run {argv[1]}: {err}`
		s.rows = {}
		refilter(s)
	end
end

local function sh_single(path: string): string
	return "'" .. (path:gsub("'", "'\\''")) .. "'"
end

local function shell_program(program: string?): boolean
	local base = (program or ""):match("[^/]+$") or ""
	return base == "zsh" or base == "bash" or base == "fish" or base == "sh"
end

--- Pane the picker was opened from. Kv is set by the window command; the cwd
--- match covers a picker that was already open before that was recorded.
local function shell_pane(s: State): number?
	local panes = tern.pane.list()
	local saved = tern.kv.get("shell_pane")
	if type(saved) == "number" then
		for _, info in panes do
			if info.pane == saved then
				return saved
			end
		end
	end
	local cwd = s.cx.cwd
	local found: number? = nil
	for _, info in panes do
		if info.pane ~= s.cx.pane and info.cwd == cwd and shell_program(info.program) then
			if found ~= nil then
				return found
			end
			found = info.pane
		end
	end
	return found
end

local function stdout_path(stdout: string): string?
	local path: string? = nil
	for line in (stdout .. "\n"):gmatch("(.-)\n") do
		if line ~= "" then
			path = line
		end
	end
	return path
end

--- cd the current tab's terminal into `path`. Returns false and a reason when
--- there is no pane to write to.
local function switch_shell(s: State, path: string): (boolean, string?)
	local pane = shell_pane(s)
	if pane == nil then
		return false, "No terminal in this tab to switch into the worktree."
	end
	local ok, err = pcall(function()
		tern.pane.write(pane, "cd -- " .. sh_single(path) .. "\r")
	end)
	if not ok then
		return false, tostring(err)
	end
	return true, nil
end

local function finish(s: State, inflight: Inflight, status: number, output: string, timed_out: boolean, stdout: string?)
	if s.closed then
		return
	end
	if status == 0 and inflight.command.kind == "remove" then
		s.cx:toast("success", label_text(inflight.row), "exit 0")
		s.mode = { kind = "list" }
		load_options(s, freed_branch(inflight.row), list_cwd(s, inflight.command.path))
		render(s)
		return
	end
	if status == 0 and (inflight.command.kind == "create" or inflight.command.kind == "checkout") then
		local path = stdout_path(stdout or "")
		local switched, why = false, "worktree.sh did not report a path"
		if path ~= nil then
			switched, why = switch_shell(s, path)
		end
		if not switched then
			s.mode = {
				kind = "outcome",
				inflight = inflight,
				status = 1,
				output = why or "could not switch to the worktree",
				timed_out = false,
			}
			render(s)
			return
		end
		s.cx:toast("success", label_text(inflight.row), path or "")
		close(s)
		return
	end
	if status == 0 then
		s.cx:toast("success", label_text(inflight.row), "exit 0")
		close(s)
		return
	end
	s.mode = { kind = "outcome", inflight = inflight, status = status, output = output, timed_out = timed_out }
	render(s)
end

local function begin(s: State, cmd: Command, row: Row)
	if s.mode.kind == "running" then
		return
	end
	local inflight: Inflight = { command = cmd, row = row }
	s.mode = { kind = "running", inflight = inflight }
	local argv = { "sh", SCRIPT }
	local opts: ProcessOptions = { cwd = s.cx.cwd or HOME }
	local ok, err = pcall(function()
		argv = argv_of(cmd)
		tern.process.run(argv, opts, function(res: ProcessResult)
			local out = res.stdout
			if res.stderr ~= "" then
				out = if out == "" or out:sub(-1) == "\n" then out .. res.stderr else out .. "\n" .. res.stderr
			end
			finish(s, inflight, res.status, out, res.timed_out, res.stdout)
		end)
	end)
	if not ok then
		finish(s, inflight, -1, `can't run {argv[1]}: {err}`, false)
	end
end

local function choose(s: State, row: Row)
	local cmd = command_of(row)
	if cmd.kind == "open" then
		local switched, why = switch_shell(s, cmd.path)
		if not switched then
			s.mode = {
				kind = "outcome",
				inflight = { command = cmd, row = row },
				status = 1,
				output = why or "could not switch to the worktree",
				timed_out = false,
			}
			render(s)
			return
		end
		s.cx:toast("success", label_text(row), cmd.path)
		close(s)
		return
	end
	begin(s, cmd, row)
end

local function accept_confirm(s: State)
	if s.mode.kind ~= "confirm" then
		return
	end
	local row = s.mode.row
	begin(s, remove_command(row), row)
end

local function request_remove(s: State, row: Row)
	if s.mode.kind ~= "list" then
		return
	end
	if row.kind == "linked" then
		s.mode = { kind = "confirm", row = row }
	elseif row.kind == "main" then
		return
	elseif row.kind == "branch" then
		show_note(s, remove_refusal(row))
	elseif row.kind == "new" then
		show_note(s, remove_refusal(row))
	else
		unreachable(row)
	end
end

local function restore_rows(s: State, saved: any): boolean
	if type(saved) ~= "table" or not is_array(saved.options) then
		return false
	end
	local items: { any } = saved.options
	local ok, rows = pcall(function(): { Row }
		local out: { Row } = {}
		for k = 1, #items do
			table.insert(out, parse_row(items[k], `item {k}`))
		end
		return out
	end)
	if not ok or not rows then
		return false
	end
	s.rows = rows
	s.list_finished = true
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
	local create = false
	for _, m in s.shown do
		if m.row.kind == "new" then
			create = true
			break
		end
	end
	return ui.el("div", { class = "wt-filter", key = "filter" }, {
		ui.node("input", { text = s.query, placeholder = "Type to filter…" }),
		ui.el("span", { class = "wt-count", text = `{#s.shown - (if create then 1 else 0)}/{#s.rows}` }),
	})
end

local function options_view(s: State): Node
	local rows: { Node } = {}
	if #s.shown == 0 then
		if s.loading then
			table.insert(rows, ui.progress(nil, "loading worktrees…"))
		elseif not s.query_problem then
			table.insert(rows, ui.el("div", { class = "wt-none", key = "none", text = if #s.rows == 0 then "no worktrees or branches" else `nothing matches “{s.query}”` }))
		end
	end
	-- Headings show only when a shown row has a group. A group's rows are
	-- contiguous (see refilter), so its heading goes before the first one.
	local grouped, last = false, nil :: string?
	for _, m in s.shown do
		grouped = grouped or group_of(m.row) ~= nil
	end
	local mode = s.mode
	for row, m in s.shown do
		local g = group_of(m.row)
		if grouped and g and g ~= last then
			table.insert(rows, ui.el("div", { class = "wt-group", key = `g{g}`, text = valid_utf8(show_home(g)) }))
		end
		last = g
		local class = "wt-opt"
		if row == s.sel then
			class ..= " sel"
		end
		if mode.kind == "running" then
			if mode.inflight.row == m.row then
				class ..= " running"
			end
		end
		if m.kind == "create" then
			class ..= " create"
		end
		local pick = if m.kind == "listed" then `pick={m.at}` else "pick=new"
		local key = if m.kind == "listed" then `o{m.at}` else "onew"
		table.insert(rows, ui.el("button", { class = class, key = key, actions = { click = pick } }, {
			highlighted(label_text(m.row), m.label_hits, "wt-label"),
			highlighted(detail_text(m.row), m.detail_hits, "wt-detail"),
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

local function confirm_text(row: Linked): string
	local path = show_home(row.path)
	local head = row.head
	if head.kind == "attached" then
		return `Remove the worktree at {path}. The branch {head.name} stays.`
	elseif head.kind == "detached" then
		return `Remove the detached worktree at {path}. No branch is deleted.`
	else
		return unreachable(head)
	end
end

local function layer_view(s: State): Node?
	local mode = s.mode
	if mode.kind == "outcome" then
		local inflight = mode.inflight
		local verdict = if mode.timed_out then "timed out"
			elseif mode.status == 0 then "exit 0"
			elseif mode.status == -1 then "failed"
			else `exit {mode.status}`
		return sheet("outcome", label_text(inflight.row), {
			ui.row({ ui.badge(verdict, if mode.status == 0 then "success" else "error") }),
			if mode.output == "" then ui.text(ui.span("no output", "muted")) else ui.ansi(show_home(mode.output)),
		}, {
			button("Back", "back"),
			button("Close", "close", "primary"),
		})
	elseif mode.kind == "confirm" then
		return sheet("confirm", "Remove worktree", {
			ui.el("div", { text = confirm_text(mode.row) }),
		}, {
			button("Cancel", "cancel"),
			button("Remove", "remove", "danger"),
		})
	elseif mode.kind == "list" then
		return nil
	elseif mode.kind == "running" then
		return nil
	else
		return unreachable(mode)
	end
end

local function remove_hint(row: Row): { Span }?
	if row.kind == "linked" then
		return { ui.span("del", "key"), ui.span(" remove  ", "muted") }
	elseif row.kind == "main" then
		return { ui.span("main checkout stays", "muted") }
	elseif row.kind == "branch" then
		return nil
	elseif row.kind == "new" then
		return nil
	else
		return unreachable(row)
	end
end

local function hints(s: State): Node
	local mode = s.mode
	if mode.kind == "running" then
		return ui.progress(nil, `running {label_text(mode.inflight.row)}…`)
	end
	local function k(key: string, what: string): { Span }
		return { ui.span(key, "key"), ui.span(` {what}  `, "muted") }
	end
	local groups: { { Span } }
	if mode.kind == "outcome" then
		groups = { k("⏎", "close"), k("esc", "back") }
	elseif mode.kind == "confirm" then
		groups = { k("⏎", "remove"), k("esc", "cancel") }
	elseif mode.kind == "list" then
		groups = { k("↑↓", "select"), k("⏎", "run"), k("esc", if s.query ~= "" then "clear" else "close"), k("^R", "reload") }
		local m = s.shown[s.sel]
		if m then
			local extra = remove_hint(m.row)
			if extra then
				table.insert(groups, extra)
			end
		end
	else
		return unreachable(mode)
	end
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
		show_note(s, `a branch name can't contain {what}`)
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
		choose(s, m.row)
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
	elseif name == "delete" then
		if key.ctrl or key.alt or key.meta or key.shift then
			return false
		end
		local m = s.shown[s.sel]
		if not m then
			return false
		end
		request_remove(s, m.row)
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
		local s: State = {
			cx = cx,
			mode = { kind = "list" },
			rows = {},
			loading = false,
			list_finished = false,
			query = "",
			shown = {},
			sel = 1,
			closed = false,
		}
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
			if restore_rows(s, saved) then
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
				ui.md("Pick a worktree, a branch, or a new branch name. Each one cds this tab's terminal into that worktree."),
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
			local mode = s.mode
			if mode.kind ~= "list" and mode.kind ~= "running" then
				return
			end
			local function take(row: number, picked: Row)
				s.sel = row
				if mode.kind == "list" then
					choose(s, picked)
				end
			end
			if ev.value == "new" then
				for row, m in s.shown do
					if m.kind == "create" then
						take(row, m.row)
						return
					end
				end
				return
			end
			local at = tonumber(ev.value)
			if not at then
				return
			end
			for row, m in s.shown do
				if m.kind == "listed" and m.at == at then
					take(row, m.row)
					return
				end
			end
		elseif ev.act == "back" then
			if s.mode.kind == "outcome" then
				s.mode = { kind = "list" }
			end
		elseif ev.act == "cancel" then
			if s.mode.kind == "confirm" then
				s.mode = { kind = "list" }
			end
		elseif ev.act == "remove" then
			accept_confirm(s)
		elseif ev.act == "close" then
			close(s)
		end
	end,

	key = function(s: State, key: Key, _cx: BlockCx): boolean?
		local name = key.name
		local esc = name == "escape" or name == "esc"
		local mode = s.mode
		if mode.kind == "running" then
			-- esc leaves; a running command keeps going without the block.
			if esc then
				close(s)
				return nil
			end
			return false
		elseif mode.kind == "outcome" then
			if name == "enter" then
				close(s)
			elseif esc then
				s.mode = { kind = "list" }
			else
				return false
			end
			return nil
		elseif mode.kind == "confirm" then
			if name == "enter" then
				accept_confirm(s)
			elseif esc then
				s.mode = { kind = "list" }
			else
				return false
			end
			return nil
		elseif mode.kind == "list" then
			return list_key(s, key)
		else
			return unreachable(mode)
		end
	end,

	save = function(s: State): any
		local options = nil
		if s.list_finished then
			options = tern.json.array()
			for _, row in s.rows do
				if row.kind == "main" or row.kind == "linked" then
					local head = if row.head.kind == "attached"
						then { kind = "attached", name = row.head.name }
						else { kind = "detached", sha = row.head.sha }
					table.insert(options, { kind = row.kind, path = row.path, head = head })
				elseif row.kind == "branch" then
					table.insert(options, {
						kind = "branch",
						name = row.name,
						sha = row.sha,
						subject = row.subject,
					})
				else
					unreachable(row)
				end
			end
		end
		return {
			query = s.query,
			options = options,
			load_error = if s.list_finished then s.load_error else nil,
		}
	end,
})
