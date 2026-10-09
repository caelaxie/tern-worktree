--!strict
-- Worktree, window half: the stylesheet and palette commands. Each command
-- focuses its existing dialog pane or opens a split below the focused pane.
-- The picker lists the repository's worktrees and branches (host.luau);
-- nothing is read from the plugin's files here.

local function open_dialog(cx: WindowCx, kind: string)
	for _, pane in cx.session:panes() do
		if pane.block == kind then
			cx.layout:focus(pane.pane)
			return
		end
	end
	cx:new_block(kind, {}, "below")
end

tern.command({
	id = "open_worktrees",
	title = "Worktree: Worktrees",
	icon = "puzzle",
	run = function(cx: WindowCx)
		open_dialog(cx, "worktree.picker")
	end,
})

tern.command({
	id = "configure_directory",
	title = "Worktree: Configure directory",
	icon = "puzzle",
	run = function(cx: WindowCx)
		open_dialog(cx, "worktree.configure")
	end,
})

-- Colors come from Tern's theme variables (text --t1..--t4, lines --l1..--l4,
-- --accent, --bad, opaque --card; --pop-bg is translucent glass), so the
-- picker follows light and dark themes.
tern.css("picker", table.concat({
	".wt{display:flex;flex-direction:column;gap:10px;padding:16px 18px}",
	".wt-title{font-size:16px;font-weight:700;color:var(--t1)}",
	".wt-msg{color:var(--t2)}",
	".wt-opts{display:flex;flex-direction:column;gap:4px}",
	".wt-filter{display:flex;align-items:center;gap:10px}",
	".wt-filter > :first-child{flex:1}",
	".wt-count{color:var(--t4);font-variant-numeric:tabular-nums}",
	".wt-none{padding:7px 10px;color:var(--t3)}",
	".wt-opt{display:flex;align-items:baseline;gap:10px;width:100%;padding:7px 10px;text-align:left;"
		.. "border:1px solid var(--l2);border-radius:7px;background-color:transparent;color:var(--t1);cursor:pointer}",
	".wt-opt:hover{border-color:var(--l3)}",
	".wt-opt.sel{border-color:var(--accent);box-shadow:inset 3px 0 0 var(--accent)}",
	".wt-opt.running{opacity:0.6}",
	".wt-opt.create{border-style:dashed}",
	".wt-opt.create .wt-label{color:var(--accent)}",
	".wt-group{padding:8px 10px 0;font-size:11px;font-weight:700;letter-spacing:0.06em;text-transform:uppercase;color:var(--t3)}",
	".wt-note{padding:2px 10px;color:var(--t3)}",
	".wt-note.bad{color:var(--bad)}",
	".wt-hit{color:var(--accent);text-decoration:underline}",
	".wt-label{font-weight:600;white-space:nowrap}",
	".wt-detail{color:var(--t3);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-family:var(--mono)}",
	-- The layer covers the pane and lets clicks through; the scrim takes them.
	".wt-scrim{position:absolute;left:0;top:0;right:0;bottom:0;box-sizing:border-box;pointer-events:auto;"
		.. "background-color:rgba(0,0,0,0.35);overflow:auto;padding:16px}",
	".wt-sheet{max-width:720px;margin:0 auto;background:var(--card);color:var(--t1);border-radius:10px;"
		.. "box-shadow:0 0 0 1px var(--l2),0 20px 50px rgba(0,0,0,0.35);overflow:hidden}",
	".wt-shead{padding:10px 14px;font-weight:700;border-bottom:1px solid var(--l1)}",
	".wt-sbody{display:flex;flex-direction:column;gap:8px;padding:12px 14px;max-height:60vh;overflow:auto}",
	".wt-sfoot{display:flex;justify-content:flex-end;gap:8px;padding:10px 14px;border-top:1px solid var(--l1)}",
	".wt-btn{padding:5px 14px;border:1px solid var(--l2);border-radius:6px;background-color:transparent;color:var(--t1);cursor:pointer}",
	".wt-btn:hover{border-color:var(--l3)}",
	".wt-btn.primary{border-color:var(--accent);background:var(--accent-fill);color:#ffffff}",
}, "\n"))
