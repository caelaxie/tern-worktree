# tern-worktree

A [Tern](https://docs.stencil.so/tern/) plugin for managing Git worktrees from the command palette. It uses Git directly to list, open, create, and remove worktrees.

This is a fork of [nibblebot/tern-worktree](https://github.com/nibblebot/tern-worktree) by Joshua Hanson.

![Opening existing Git worktrees and creating new Git worktrees from Tern's command palette](assets/worktree-demo.gif)

## Requirements

- Tern 0.9.8 or later
- `git` and `jq`
- a POSIX `sh`
- `git-lfs`, only for repositories that use Git LFS

## Install

Install from GitHub:

```sh
tern plugin install github.com/caelaxie/tern-worktree
tern plugin list
```

The plugin is registered as `worktree` and should report `ready`. Installing reloads plugins automatically. To update, run the install command again with `--force`.

To develop against a local checkout instead, link it. A linked plugin reloads when its files change:

```sh
git clone https://github.com/caelaxie/tern-worktree
cd tern-worktree
tern plugin link "$PWD"
```

## Keys

| Key | Action |
| --- | --- |
| type | filter (fuzzy, over name and path or commit) |
| ↑ ↓, Ctrl+P / Ctrl+N, Tab / Shift+Tab | move the selection |
| Enter | open, check out or create the selected entry |
| Cmd+Backspace, Cmd+Delete, Delete | remove the selected linked worktree or branch, after confirm |
| Esc | clear the filter; with an empty filter, close. On the confirm sheet, return to the list |
| Ctrl+U, Ctrl+W | clear the filter, delete the last word |
| Ctrl+R | reload the list |

## Keybinding

Optionally bind the picker to a key. Add this to `keybinds` in Tern's `settings.json` (`~/.config/tern/settings.json` on Linux, or `$TERN_CONFIG_DIR/settings.json` when set), merging it with your existing settings:

```json
{
  "keybinds": {
    "alt+shift+z": ["plugin.worktree.open_worktrees"]
  }
}
```

Save the settings and reopen the Tern window to load the binding.

## License

MIT. See [LICENSE](LICENSE).
