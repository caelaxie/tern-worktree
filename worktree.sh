#!/bin/sh
# Helper for the worktree plugin's Worktrees picker.
#   worktree.sh list              JSON rows for worktrees and branch-only branches
#   worktree.sh open PATH         open PATH in a new Tern tab and focus it
#   worktree.sh checkout BRANCH [DIRECTORY]   create an existing branch's worktree, print its path
#   worktree.sh create BRANCH [DIRECTORY]     create BRANCH (or reuse it), print its path
# A nonempty native directory setting uses DIRECTORY/<main checkout name>/<branch>.
# With no directory setting, the worktrunk user config's worktree-path is used
# (~/.config/worktrunk/config.toml, or $XDG_CONFIG_HOME/worktrunk/config.toml).
# If that is unset, worktrees are siblings: <main checkout name>.<branch>, "/" → "-".
# Absolute paths are used as-is; "~" and "~/" expand using HOME, without evaluation.
# A relative worktree-path is relative to the main checkout.
set -eu

# Plugin processes inherit the Tern daemon's PATH, which is only
# /usr/bin:/bin:/usr/sbin:/sbin. Global LFS filters invoke `git-lfs filter-process`,
# so a checkout dies with "git-lfs: command not found" unless the prefix that
# holds git-lfs is visible. ~/.local/bin is first so a user tern or git wins.
for dir in \
	/home/linuxbrew/.linuxbrew/bin \
	/usr/local/bin \
	/opt/homebrew/bin \
	"${HOME:-}/.local/bin"
do
	if [ -n "$dir" ] && [ -d "$dir" ]; then
		PATH="$dir:$PATH"
	fi
done
export PATH

die() {
	printf 'worktree: %s\n' "$*" >&2
	exit 1
}

usage() {
	printf 'usage: worktree.sh list | open PATH | checkout BRANCH [DIRECTORY] | create BRANCH [DIRECTORY] | remove [PATH] [--force] [--branch NAME]\n' >&2
	exit 2
}

need() {
	command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH"
}

# PATH above already includes ~/.local/bin. This still finds the app bundle
# when tern was not installed onto PATH, so create can focus the new tab.
find_tern() {
	if command -v tern >/dev/null 2>&1; then
		command -v tern
		return
	fi
	for cand in \
		"${HOME:-}/.local/bin/tern" \
		/opt/homebrew/bin/tern \
		/usr/local/bin/tern \
		/Applications/Tern.app/Contents/MacOS/tern \
		"${HOME:-}/Applications/Tern.app/Contents/MacOS/tern"
	do
		if [ -x "$cand" ]; then
			printf '%s\n' "$cand"
			return
		fi
	done
	die "tern not found on PATH"
}

open_tab() {
	[ -d "$1" ] || die "not a directory: $1"
	tern_bin=$(find_tern)
	need jq
	tab=$("$tern_bin" new tab --cwd "$1" --json) || die "tern new tab failed"
	block=$(printf '%s' "$tab" | jq -r '.block // empty' 2>/dev/null) || block=
	[ -n "$block" ] || die "tern did not report a block for the new tab"
	"$tern_bin" focus "$block"
}

# The trailing dot stays through command substitution, which would drop a path's
# trailing newlines. Callers read $main. Do not recapture with main=$(set_main_path ...).
set_main_path() {
	main=$(printf '%s' "$1" | jq -j '.[0] | select(.bare != true) | .path // empty' &&
		printf '.') || return 1
	main=${main%.}
}

# NUL-delimited porcelain keeps paths literal, including whitespace and escapes.
worktrees_json() {
	git worktree list --porcelain -z | jq -Rs '
		split("\u0000\u0000") | map(select(length > 0)
			| split("\u0000") | reduce .[] as $field ({};
				if $field | startswith("worktree ") then .path = $field[9:]
				elif $field | startswith("HEAD ") then .head = $field[5:]
				elif $field | startswith("branch refs/heads/") then .branch = $field[18:]
				elif $field == "bare" then .bare = true
				else . end))'
}

list() {
	need git
	need jq
	git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
	worktrees=$(worktrees_json) || exit 1
	set_main_path "$worktrees" || exit 1
	branches=$(git for-each-ref --format='%(refname:strip=2)%00%(objectname:short)%00%(subject)' refs/heads |
		jq -Rs 'split("\n") | map(select(length > 0) | split("\u0000")
			| {branch: .[0], sha: .[1], subject: .[2]})') || exit 1
	printf '%s' "$worktrees" | jq --argjson branches "$branches" --arg main "$main" '
		[.[] | select(.bare != true)] as $worktrees
		| [$worktrees[] | {
			kind: (if $main != "" and .path == $main then "main" else "linked" end),
			path: .path,
			head: (if .branch then {kind: "attached", name: .branch}
				else {kind: "detached", sha: (.head // "")} end)
		}]
		+ [$branches[] | select(.branch as $branch |
			any($worktrees[]; .branch == $branch) | not) | {
			kind: "branch",
			name: .branch,
			sha: .sha,
			subject: (.subject // "")
		}]'
}

# Top-level worktree-path only. A later [projects.*] table is not the global value.
wt_template() {
	if [ -n "${XDG_CONFIG_HOME:-}" ]; then
		file=$XDG_CONFIG_HOME/worktrunk/config.toml
	elif [ -n "${HOME:-}" ]; then
		file=$HOME/.config/worktrunk/config.toml
	else
		return 0
	fi
	[ -f "$file" ] || return 0
	raw=$(awk '
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		/^[[:space:]]*\[/ { exit }
		/^[[:space:]]*worktree-path[[:space:]]*=/ {
			sub(/^[[:space:]]*worktree-path[[:space:]]*=[[:space:]]*/, "")
			sub(/[[:space:]]+$/, "")
			print
			exit
		}
	' "$file") || return 1
	case $raw in
	\"*\")
		raw=${raw#\"}
		raw=${raw%\"}
		;;
	\'*\')
		raw=${raw#\'}
		raw=${raw%\'}
		;;
	esac
	printf '%s' "$raw"
}

# {{ repo }}, {{ repo_path }}, {{ branch }}, and {{ branch | sanitize }}.
# sanitize replaces / and \ with -. Anything else is refused.
expand_wt_template() {
	repo=${main##*/}
	jq -Rr --arg repo "$repo" --arg repo_path "$main" --arg branch "$branch" '
		def sanitize: gsub("[/\\\\]"; "-");
		gsub("\\{\\{\\s*repo_path\\s*\\}\\}"; $repo_path)
		| gsub("\\{\\{\\s*branch\\s*\\|\\s*sanitize\\s*\\}\\}"; ($branch | sanitize))
		| gsub("\\{\\{\\s*repo\\s*\\}\\}"; $repo)
		| gsub("\\{\\{\\s*branch\\s*\\}\\}"; $branch)
	' <<EOF
$1
EOF
}

# Sets $path from the user worktree-path. Returns 1 when the config has none.
wt_path() {
	template=$(wt_template) || return 1
	[ -n "$template" ] || return 1
	expanded=$(expand_wt_template "$template") || die "can't read worktree-path"
	case $expanded in
	*'{''{'*)
		die "unsupported worktree-path template: $template"
		;;
	\~ | \~/*)
		[ -n "${HOME:-}" ] || die "HOME is empty; cannot expand worktree-path"
		expanded=$HOME${expanded#\~}
		;;
	/*) ;;
	*) expanded=$main/$expanded ;;
	esac
	path=$expanded
}

switch_open() {
	need git
	need jq
	branch=$1
	case $branch in
	'' | -*) die "invalid branch name: '$branch'" ;;
	esac
	git check-ref-format --branch "$branch" >/dev/null 2>&1 ||
		die "invalid branch name: '$branch'"
	git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
	worktrees=$(worktrees_json) || exit 1
	path=$(printf '%s' "$worktrees" | jq -j --arg branch "$branch" '
		first(.[] | select(.bare != true and .branch == $branch) | .path) // empty' &&
		printf '.') || exit 1
	path=${path%.}
	if [ -n "$path" ]; then
		printf '%s\n' "$path"
		return
	fi

	set_main_path "$worktrees" || exit 1
	[ -n "$main" ] || die "main repository has no worktree"
	directory=${3:-}
	if [ -n "$directory" ]; then
		case $directory in
		\~ | \~/*)
			[ -n "${HOME:-}" ] || die "HOME is empty; cannot expand worktree directory"
			directory=$HOME${directory#\~}
			;;
		/*) ;;
		*) directory=$main/$directory ;;
		esac
		path="$directory/${main##*/}/$branch"
	elif wt_path; then
		:
	else
		safe_branch=$(printf '%s' "$branch" | jq -Rr 'gsub("/"; "-")')
		path="${main%/*}/${main##*/}.$safe_branch"
	fi
	if [ -e "$path" ] || [ -L "$path" ] ||
		printf '%s' "$worktrees" | jq -e --arg path "$path" 'any(.[]; .path == $path)' >/dev/null; then
		die "worktree path already exists or is registered: $path"
	fi
	parent=${path%/*}
	if [ -n "$parent" ] && [ "$parent" != "$path" ]; then
		mkdir -p -- "$parent" || die "cannot create worktree parent: $parent"
	fi

	if git show-ref --verify --quiet "refs/heads/$branch"; then
		git worktree add -- "$path" "$branch" >&2 || exit 1
	else
		[ "$2" = create ] || die "branch does not exist: '$branch'"
		base=$(git symbolic-ref -q refs/remotes/origin/HEAD) || base=
		if [ -n "$base" ] && git rev-parse --verify "$base^{commit}" >/dev/null 2>&1; then
			:
		elif git show-ref --verify --quiet refs/heads/main; then
			base=refs/heads/main
		elif git show-ref --verify --quiet refs/heads/master; then
			base=refs/heads/master
		else
			base=HEAD
		fi
		git worktree add -b "$branch" -- "$path" "$base" >&2 || exit 1
	fi
	# The host cds the terminal that opened the picker. A new tab would leave that block put.
	printf '%s\n' "$path"
}

# A confirmed removal deletes the branch too, including when it is unmerged.
# Missing refs are already gone.
delete_branch() {
	[ -n "$branch" ] || return 0
	if git -C "$main" show-ref --verify --quiet "refs/heads/$branch"; then
		git -C "$main" branch -D -- "$branch" || exit $?
	fi
}

remove_path() {
	path=$1
	force=${2:-}
	branch=${3:-}
	[ -n "$path" ] || [ -n "$branch" ] || die "path is empty"
	need git
	need jq
	git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
	worktrees=$(worktrees_json) || exit 1
	set_main_path "$worktrees" || exit 1
	[ -n "$main" ] || die "main repository has no worktree"
	if [ -z "$path" ]; then
		delete_branch
		return
	fi
	if [ -z "$branch" ]; then
		branch=$(printf '%s' "$worktrees" | jq -r --arg path "$path" '
			first(.[] | select(.path == $path and .branch != null) | .branch) // empty') || exit 1
	fi
	class=$(printf '%s' "$worktrees" | jq -r --arg path "$path" '
		if any(.[]; .path == $path and .bare == true) then "bare"
		elif (.[0] | select(.bare != true) | .path) == $path then "main"
		elif any(.[]; .path == $path and .bare != true) then "linked"
		else "absent"
		end') || exit 1
	case $class in
	absent)
		delete_branch
		return
		;;
	main)
		die "refusing to remove the main worktree: $path"
		;;
	bare)
		die "refusing to remove a bare worktree: $path"
		;;
	linked)
		status=0
		if [ "$force" = force ]; then
			# Once overrides a dirty tree. Twice also overrides a lock.
			git -C "$main" worktree remove --force --force -- "$path" || status=$?
		else
			git -C "$main" worktree remove -- "$path" || status=$?
		fi
		if [ "$status" -ne 0 ]; then
			worktrees=$(worktrees_json) || exit "$status"
			if printf '%s' "$worktrees" | jq -e --arg path "$path" 'any(.[]; .path == $path)' >/dev/null; then
				exit "$status"
			fi
		fi
		delete_branch
		return
		;;
	*)
		die "cannot classify worktree path"
		;;
	esac
}

[ $# -ge 1 ] || usage
cmd=$1
shift

case $cmd in
list)
	[ $# -eq 0 ] || usage
	list
	;;
open)
	[ $# -eq 1 ] || usage
	open_tab "$1"
	;;
checkout)
	[ $# -eq 1 ] || [ $# -eq 2 ] || usage
	switch_open "$1" checkout "${2:-}"
	;;
create)
	[ $# -eq 1 ] || [ $# -eq 2 ] || usage
	switch_open "$1" create "${2:-}"
	;;
remove)
	force=
	path=
	branch=
	while [ $# -gt 0 ]; do
		case $1 in
		--force)
			force=force
			;;
		--branch)
			shift
			[ $# -ge 1 ] || usage
			branch=$1
			;;
		--)
			shift
			[ $# -ge 1 ] && [ -z "$path" ] || usage
			path=$1
			;;
		-*)
			usage
			;;
		*)
			[ -z "$path" ] || usage
			path=$1
			;;
		esac
		shift
	done
	[ $# -eq 0 ] || usage
	[ -n "$path" ] || [ -n "$branch" ] || usage
	remove_path "$path" "$force" "$branch"
	;;
*)
	usage
	;;
esac
