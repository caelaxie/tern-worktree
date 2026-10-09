--!strict
-- Machine-wide plugin setting, shared by the picker and the configuration block.
local ui = tern.ui
local INPUT = "main.config.directory"

local function directory(): string
	local value = tern.kv.get("directory")
	if value == nil then
		return ""
	end
	if type(value) ~= "string" then
		error("worktree directory setting must be a string", 0)
	end
	return value
end

type State = {
	cx: BlockCx,
	draft: string,
	cursor: number, -- UTF-8 bytes before the caret; view/events use UTF-16 instead.
	anchor: number?,
	dirty: boolean,
	read_ok: boolean,
	problem: string?,
}

local function units(text: string): number
	local n = 0
	for _, cp in utf8.codes(text) do
		n += if cp > 0xFFFF then 2 else 1
	end
	return n
end

local function bytes(text: string, offset: number): number
	local n = 0
	for pos, cp in utf8.codes(text) do
		local width = if cp > 0xFFFF then 2 else 1
		if n + width > offset then
			return pos - 1
		end
		n += width
	end
	return #text
end

local function focus(cx: BlockCx)
	cx:frame({ { "focus", INPUT } })
end

local function load(s: State)
	local ok, value = pcall(directory)
	if not ok then
		s.read_ok = false
		s.problem = `Can't read worktree directory: {value}`
		return
	end
	s.problem = nil
	s.read_ok = true
	if not s.dirty then
		s.draft = value
		s.cursor = #s.draft
		s.anchor = nil
	end
end

local function save_directory(s: State, use_default: boolean?)
	if not s.read_ok then
		s.problem = "Can't save worktree directory: retry reading the setting first."
		return
	end
	-- Revalidate before writing; retain the draft on read and write failures,
	-- including a failed Use default action.
	local ok, err = pcall(function()
		directory()
		local value = if use_default then "" else s.draft
		tern.kv.set("directory", if value == "" then nil else value)
	end)
	if not ok then
		s.problem = `Can't save worktree directory: {err}`
		return
	end
	s.cx:exit(0)
end

local function replace(s: State, first: number, last: number, text: string)
	s.draft = s.draft:sub(1, first) .. text .. s.draft:sub(last + 1)
	s.cursor = first + #text
	s.anchor = nil
	s.dirty = true
end

local function insert(s: State, text: string)
	local anchor = s.anchor or s.cursor
	replace(s, math.min(anchor, s.cursor), math.max(anchor, s.cursor), text)
end

local function move(s: State, pos: number, shift: boolean)
	if shift then
		s.anchor = s.anchor or s.cursor
	else
		s.anchor = nil
	end
	s.cursor = pos
end

local function button(label: string, action: string, primary: boolean?): Node
	return ui.el("button", {
		class = if primary then "wt-btn primary" else "wt-btn",
		text = label,
		actions = { click = action },
	})
end

tern.block.define("configure", {
	features = { "edit" } :: { "edit" | "undo" },

	init = function(cx: BlockCx, _args: { string }, saved: any): State
		local s: State = { cx = cx, draft = "", cursor = 0, dirty = false, read_ok = false }
		if type(saved) == "table" and type(saved.draft) == "string" then
			s.draft = saved.draft
			s.cursor = if type(saved.cursor) == "number" then bytes(s.draft, saved.cursor) else #s.draft
			s.anchor = if type(saved.anchor) == "number" then bytes(s.draft, saved.anchor) else nil
			s.dirty = saved.dirty == true
			s.read_ok = saved.read_ok == true
			s.problem = if type(saved.problem) == "string" then saved.problem else nil
		else
			load(s)
		end
		return s
	end,

	title = function(_s: State): string
		return "Configure worktree directory"
	end,

	view = function(s: State, _cx: BlockCx): BlockView
		local body: { Node } = {
			ui.el("div", { class = "wt-title", text = "Worktree directory" }),
			ui.el("div", { class = "wt-msg", text = "Shared across repositories on this machine. Empty uses sibling <repo>.<branch> worktrees, replacing branch / with -. A custom directory uses <directory>/<repo>/<branch>, preserving branch /. Existing worktrees are not moved. Absolute paths, ~/ paths and paths relative to the main checkout are supported; no shell quoting is needed." }),
			ui.node("input", {
				key = "directory",
				text = s.draft,
				cursor = units(s.draft:sub(1, s.cursor)),
				anchor = if s.anchor then units(s.draft:sub(1, s.anchor)) else nil,
				placeholder = "Default: beside the main checkout",
				aria = "Worktree directory",
			}),
			ui.row({ button("Save", "save", true), button("Cancel", "cancel"), button("Use default", "default"), button("Clear", "clear") }),
		}
		if s.problem then
			table.insert(body, ui.diagnostic({ severity = "error", message = s.problem }))
			table.insert(body, button("Retry read", "reload"))
		end
		return {
			main = ui.col({ ui.el("div", { class = "wt", key = "config" }, body) }),
			dock = ui.col({ ui.text("Enter Save · Esc Cancel · Ctrl/Cmd+A Select all · Ctrl/Cmd+U Clear · Use default resets and saves") }),
		}
	end,

	-- The first resize arrives after the surface is drawn, when the input exists.
	resize = function(_s: State, _cols: number, _rows: number, cx: BlockCx)
		focus(cx)
	end,

	event = function(s: State, ev: UiEvent, cx: BlockCx)
		if ev.ev == "focus" and ev.id == INPUT then
			focus(cx)
		elseif ev.ev == "edit" and ev.id == INPUT then
			-- Native offsets are UTF-16 [from,to), not Lua byte indexes. Ignore
			-- stale edits computed against an older text length (keys in flight).
			if type(ev.from) ~= "number" or type(ev.to) ~= "number" or type(ev.text) ~= "string"
				or type(ev.cursor) ~= "number" or ev.len ~= units(s.draft) then
				return
			end
			local first, last = bytes(s.draft, ev.from), bytes(s.draft, ev.to)
			if first ~= last or ev.text ~= "" then
				replace(s, first, last, ev.text)
			end
			s.cursor = bytes(s.draft, ev.cursor)
			s.anchor = nil
		elseif ev.ev == "action" then
			if ev.act == "save" then
				save_directory(s)
			elseif ev.act == "cancel" then
				cx:exit(0)
			elseif ev.act == "default" then
				save_directory(s, true)
			elseif ev.act == "clear" then
				replace(s, 0, #s.draft, "")
				focus(cx)
			elseif ev.act == "reload" then
				load(s)
			end
		end
	end,

	key = function(s: State, key: Key, cx: BlockCx): boolean?
		local name = key.name
		if name == "enter" then
			save_directory(s)
		elseif name == "escape" or name == "esc" then
			cx:exit(0)
		elseif (key.ctrl or key.meta) and name == "a" then
			s.anchor, s.cursor = 0, #s.draft
		elseif (key.ctrl or key.meta) and name == "u" then
			replace(s, 0, #s.draft, "")
		elseif name == "home" or name == "end" then
			move(s, if name == "home" then 0 else #s.draft, key.shift)
		elseif name == "left" then
			local prev = if s.cursor > 0 then (utf8.offset(s.draft, -1, s.cursor + 1) or 1) - 1 else 0
			move(s, if key.ctrl or key.meta then 0 else prev, key.shift)
		elseif name == "right" then
			local next_pos = if s.cursor < #s.draft then (utf8.offset(s.draft, 2, s.cursor + 1) or (#s.draft + 1)) - 1 else #s.draft
			move(s, if key.ctrl or key.meta then #s.draft else next_pos, key.shift)
		elseif name == "backspace" or name == "delete" then
			if s.anchor and s.anchor ~= s.cursor then
				insert(s, "")
			elseif name == "backspace" and s.cursor > 0 then
				local prev = (utf8.offset(s.draft, -1, s.cursor + 1) or 1) - 1
				replace(s, if key.ctrl or key.alt then 0 else prev, s.cursor, "")
			elseif name == "delete" and s.cursor < #s.draft then
				local next_pos = (utf8.offset(s.draft, 2, s.cursor + 1) or (#s.draft + 1)) - 1
				replace(s, s.cursor, if key.ctrl or key.alt then #s.draft else next_pos, "")
			else
				return false
			end
		elseif name == "paste" then
			insert(s, ((key.text or ""):gsub("[\r\n\t]+", " ")))
		elseif not (key.ctrl or key.meta or key.alt) and key.text and key.text ~= "" then
			insert(s, key.text)
		elseif name == "space" and not (key.ctrl or key.meta or key.alt) then
			insert(s, " ")
		else
			return false
		end
		return nil
	end,

	save = function(s: State): any
		return {
			draft = s.draft,
			cursor = units(s.draft:sub(1, s.cursor)),
			anchor = if s.anchor then units(s.draft:sub(1, s.anchor)) else nil,
			dirty = s.dirty,
			read_ok = s.read_ok,
			problem = s.problem,
		}
	end,
})

return { directory = directory }
