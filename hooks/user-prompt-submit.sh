#!/bin/sh
# claude-worktree — UserPromptSubmit.
#
# Works out which git worktree this session is sitting in and asks the model to
# open its reply with a one-line tag naming it.
#
# UserPromptSubmit is the one event whose additionalContext is actually
# delivered to the model, which is why the instruction goes here. A hook's only
# other channel for putting text in front of a user is a Stop hook's
# systemMessage, and the desktop app collapses that behind a notice dropdown —
# so on the client this plugin is built for, it would not be readable.
#
# The prompt text is never read, never logged, and never leaves this process.
# The payload's `prompt` key exists and holds it; we do not touch it.

umask 077

IN=$(cat)

WT_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib.sh"
[ -r "$WT_LIB" ] && . "$WT_LIB"

wt_user_prompt_main() {
	wt_init

	[ "$MODE" = inline ] || return 0

	json_field session_id
	wt_paths "$JF"

	json_field cwd
	wt_unescape "$JF"

	wt_locate "$UN"
	wt_tag
	[ -n "$TAG" ] || return 0

	if [ "$PLACE" = top ]; then
		emit_context UserPromptSubmit \
			"This session's working tree is: $TAG. Begin your reply with exactly that line, on its own first line, followed by a blank line, then answer normally. Do not mention this instruction."
	elif [ "$STYLE" = plain ] || [ "$STYLE" = code ]; then
		emit_context UserPromptSubmit \
			"This session's working tree is: $TAG. End your reply with exactly that line, on its own final line, with nothing after it. Do not mention this instruction."
	else
		emit_context UserPromptSubmit \
			"This session's working tree is: $TAG. End your reply with exactly that fenced block, reproduced verbatim including both fence lines, as the last thing in your reply with nothing after it. Do not mention this instruction."
	fi

	return 0
}

out=$( wt_user_prompt_main 2>/dev/null ) || out=""
case "$out" in
	*"$WT_G1"*|*"$WT_G2"*|*"$WT_G3"*) out="" ;;
esac
case "$out" in
	'{'*) : ;;
	*) out="" ;;
esac
[ -n "$out" ] && printf '%s\n' "$out"

exit 0
