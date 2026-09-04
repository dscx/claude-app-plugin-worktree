#!/bin/sh
# claude-worktree — SessionStart.
#
# Creates the state directory, writes a default config on first run, primes the
# worktree cache so the first turn does not pay for the git fork, and runs the
# garbage collector. Emits nothing.
#
# This is the only hook allowed to do housekeeping: it runs once per session,
# so a few forks here cost nothing, whereas the same forks on the turn path get
# paid on every prompt.

umask 077

IN=$(cat)

WT_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib.sh"
[ -r "$WT_LIB" ] && . "$WT_LIB"

wt_session_start_main() {
	wt_init

	json_field session_id
	wt_paths "$JF"

	[ -d "$SESS_DIR" ] || mkdir -p "$SESS_DIR" 2>/dev/null || return 0

	# Default config, written only when absent so the user's edits survive.
	if [ ! -e "$WT_CONFIG" ]; then
		{
			printf '%s\n' '# claude-worktree configuration.'
			printf '%s\n' '# Only these seven keys with these exact values are read.'
			printf '%s\n' '# Anything else on a line is ignored, not evaluated.'
			printf '%s\n' 'MODE=inline'
			printf '%s\n' 'PLACE=bottom'
			printf '%s\n' 'MARK=orange'
			printf '%s\n' 'STYLE=diff-add'
			printf '%s\n' 'FORMAT=full'
			printf '%s\n' 'SHOW_BRANCH=1'
			printf '%s\n' 'ROOT=1'
		} > "$WT_CONFIG.$$.tmp" 2>/dev/null || return 0
		mv -f "$WT_CONFIG.$$.tmp" "$WT_CONFIG" 2>/dev/null || rm -f "$WT_CONFIG.$$.tmp" 2>/dev/null
	fi

	# Prime the cache. wt_locate resolves and writes it; the first prompt of the
	# session then hits a warm cache and forks nothing.
	json_field cwd
	wt_unescape "$JF"
	wt_locate "$UN"

	# Garbage collection. Triple-constrained on purpose: depth, file type, and
	# name, plus an age test. Every state file this plugin writes ends in .jsonl
	# so this single invocation covers all of them. The state directory itself is
	# never removed, and nothing recursive ever runs here.
	if [ -d "$SESS_DIR" ]; then
		find "$SESS_DIR" -maxdepth 1 -type f -name '*.jsonl' -mtime +7 -exec rm -f {} + 2>/dev/null
	fi

	return 0
}

out=$( wt_session_start_main 2>/dev/null ) || out=""
case "$out" in
	*"$WT_G1"*|*"$WT_G2"*|*"$WT_G3"*) out="" ;;
esac
case "$out" in
	'{'*) : ;;
	*) out="" ;;
esac
[ -n "$out" ] && printf '%s\n' "$out"

exit 0
