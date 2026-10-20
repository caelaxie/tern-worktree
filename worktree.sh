#!/bin/sh
# Helper for the worktree plugin's Worktrees picker.
#   worktree.sh list              JSON rows for worktrees and branch-only branches
#   worktree.sh open PATH         open PATH in a new Tern tab and focus it
#   worktree.sh checkout BRANCH [DIRECTORY]   create an existing branch's worktree, open it
#   worktree.sh create BRANCH [DIRECTORY]     create BRANCH (or reuse it), open it
# Default worktrees use <main checkout name>.<branch>, with "/" replaced by "-".
# A nonempty native directory setting uses DIRECTORY/<main checkout name>/<branch>.
# Missing/empty uses the main checkout's parent; relative paths use the main checkout.
# Absolute paths are used as-is; "~" and "~/" expand using HOME, without evaluation.
set -eu

die() {
	printf 'worktree: %s\n' "$*" >&2
	exit 1
}

usage() {
	printf 'usage: worktree.sh list | open PATH | checkout BRANCH [DIRECTORY] | create BRANCH [DIRECTORY] | remove PATH\n' >&2
	exit 2
}

need() {
	command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH"
}

open_tab() {
	[ -d "$1" ] || die "not a directory: $1"
	need tern
	need jq
	tab=$(tern new tab --cwd "$1" --json) || die "tern new tab failed"
	block=$(printf '%s' "$tab" | jq -r '.block // empty' 2>/dev/null) || block=
	[ -n "$block" ] || die "tern did not report a block for the new tab"
	tern focus "$block"
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
		open_tab "$path"
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
	else
		safe_branch=$(printf '%s' "$branch" | jq -Rr 'gsub("/"; "-")')
		path="${main%/*}/${main##*/}.$safe_branch"
	fi
	if [ -e "$path" ] || [ -L "$path" ] ||
		printf '%s' "$worktrees" | jq -e --arg path "$path" 'any(.[]; .path == $path)' >/dev/null; then
		die "worktree path already exists or is registered: $path"
	fi

	if git show-ref --verify --quiet "refs/heads/$branch"; then
		git worktree add -- "$path" "$branch" || exit 1
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
		git worktree add -b "$branch" -- "$path" "$base" || exit 1
	fi
	open_tab "$path"
}

remove_path() {
	path=$1
	[ -n "$path" ] || die "path is empty"
	need git
	need jq
	git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
	worktrees=$(worktrees_json) || exit 1
	set_main_path "$worktrees" || exit 1
	[ -n "$main" ] || die "main repository has no worktree"
	class=$(printf '%s' "$worktrees" | jq -r --arg path "$path" '
		if any(.[]; .path == $path and .bare == true) then "bare"
		elif (.[0] | select(.bare != true) | .path) == $path then "main"
		elif any(.[]; .path == $path and .bare != true) then "linked"
		else "absent"
		end') || exit 1
	case $class in
	absent)
		return 0
		;;
	main)
		die "refusing to remove the main worktree: $path"
		;;
	bare)
		die "refusing to remove a bare worktree: $path"
		;;
	linked)
		status=0
		git -C "$main" worktree remove -- "$path" || status=$?
		if [ "$status" -ne 0 ]; then
			worktrees=$(worktrees_json) || exit "$status"
			if printf '%s' "$worktrees" | jq -e --arg path "$path" 'any(.[]; .path == $path)' >/dev/null; then
				exit "$status"
			fi
		fi
		return 0
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
	[ $# -eq 1 ] || usage
	remove_path "$1"
	;;
*)
	usage
	;;
esac
