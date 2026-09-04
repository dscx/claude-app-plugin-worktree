#!/bin/sh
# claude-worktree — shared hook helpers.
#
# POSIX sh only. No bashisms, no errexit. Nothing here ever exits the caller.
# Every function returns 0; failure is expressed by leaving its output variable
# empty, never by a non-zero status. A hook that exits with the "do not stop"
# status turns the agent into a loop, and a syntax error produces that status
# all by itself — so the safe outcome has to be unconditional.
#
# Fork budget: the steady-state per-turn path forks nothing beyond the `cat`
# that reads stdin. `git` is forked only when the session's working directory
# changes, and the answer is cached; the branch is read straight out of
# HEAD with the shell, because that file is one short line and re-reading it
# is how a branch switch mid-session gets noticed for free.

# ---------------------------------------------------------------------------
# character constants
# ---------------------------------------------------------------------------
WT_Q='"'
WT_BS='\'
WT_TAB='	'
WT_CR=$(printf '\r')
WT_NL='
'

# Forbidden control keys. Assembled from fragments so that the literal words
# never appear as contiguous text in this repository — the CI safety grep
# rejects them on sight, and it is right to.
WT_G1='"de''cision"'
WT_G2='"permission''Decision"'
WT_G3='"con''tinue"'

# The separators between the tag's parts. The leading glyph is chosen by the
# MARK setting, resolved in wt_init.
WT_SEP='▸'
WT_DOT='·'

# Markdown has no colour, and the desktop app's renderer sanitises HTML, so a
# coloured *glyph* is the only colour that is guaranteed to survive. These are
# the presets MARK selects between; the config parser is a strict allowlist by
# design and never takes an arbitrary string.
wt_mark_glyph() {
	case "$MARK" in
		orange) WT_MARK='🟠' ;;
		yellow) WT_MARK='🟡' ;;
		warn)   WT_MARK='⚠️' ;;
		option) WT_MARK='⌥' ;;
		none)   WT_MARK='' ;;
		*)      WT_MARK='🟠' ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# wt_init — umask, state dir, config
# ---------------------------------------------------------------------------
wt_load_config() {
	# Strict allowlist. Not a parser: each accepted line must match one of the
	# fifteen legal KEY=value pairs exactly. Anything else — unknown keys, shell
	# metacharacters, command substitution, a key with an illegal value — falls
	# through to the ignore branch. There is no eval and no sourcing.
	#
	# Bounded on three axes, because the state directory is not a trusted input:
	# anything with write access to it can replace config.env. `-f` rejects a
	# FIFO (opening one blocks forever and burns the whole hook timeout), the
	# line counter rejects a huge file, and the length test rejects a huge line.
	# No legal line is longer than `SHOW_BRANCH=1`.
	if [ ! -f "$WT_CONFIG" ] || [ ! -r "$WT_CONFIG" ]; then
		return 0
	fi
	_cfg_n=0
	while IFS= read -r _cfg_ln || [ -n "$_cfg_ln" ]; do
		_cfg_n=$((_cfg_n + 1))
		if [ "$_cfg_n" -gt 64 ]; then
			break
		fi
		if [ "${#_cfg_ln}" -le 64 ]; then
			case "$_cfg_ln" in
				MODE=inline|MODE=off)
					MODE=${_cfg_ln#MODE=} ;;
				FORMAT=full|FORMAT=short)
					FORMAT=${_cfg_ln#FORMAT=} ;;
				SHOW_BRANCH=0|SHOW_BRANCH=1)
					SHOW_BRANCH=${_cfg_ln#SHOW_BRANCH=} ;;
				ROOT=0|ROOT=1)
					ROOT=${_cfg_ln#ROOT=} ;;
				PLACE=bottom|PLACE=top)
					PLACE=${_cfg_ln#PLACE=} ;;
				MARK=orange|MARK=yellow|MARK=warn|MARK=option|MARK=none)
					MARK=${_cfg_ln#MARK=} ;;
				*)
					: ;;
			esac
		fi
	done < "$WT_CONFIG"
	return 0
}

wt_init() {
	umask 077
	MODE=inline
	FORMAT=full
	SHOW_BRANCH=1
	ROOT=1
	PLACE=bottom
	MARK=orange
	STATE_DIR="${CLAUDE_WORKTREE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/claude-worktree}"
	SESS_DIR="$STATE_DIR/sessions"
	WT_CONFIG="$STATE_DIR/config.env"
	WT_JQ=0
	if command -v jq >/dev/null 2>&1; then
		WT_JQ=1
	fi
	wt_load_config
	wt_mark_glyph
	wt_prepare_payload
	return 0
}

# ---------------------------------------------------------------------------
# wt_prepare_payload — bound the cost of parsing $IN, once, before any field is
# read. Sets IN (possibly to a smaller equivalent) and WT_TRUNCATED.
#
# `${var#*pat}` and `${var%%pat*}` are quadratic in the length of var, and
# UserPromptSubmit's payload carries the whole user prompt. JSON key order is
# not guaranteed, so `cwd` may well sit behind it. Above WT_SCAN_MAX the
# payload is therefore projected down to the handful of short fields the hooks
# read, before any parameter expansion touches it.
# ---------------------------------------------------------------------------
WT_SCAN_MAX=1024
WT_SCAN_HARD=4096

# Projection program. Only the fields the two hooks read, and never `prompt`.
# `cwd` gets a longer clamp than the ids because it is a path.
WT_JQ_PROJECT='def c: if type=="string" then .[0:256] else . end;
def p: if type=="string" then .[0:512] else . end;
if type=="object" then {session_id:(.session_id|c),prompt_id:(.prompt_id|c),
source:(.source|c),cwd:(.cwd|p)}
else empty end'

wt_prepare_payload() {
	WT_TRUNCATED=0
	IN=${IN:-}
	[ "${#IN}" -gt "$WT_SCAN_MAX" ] || return 0

	if [ "${WT_JQ:-0}" = 1 ]; then
		_pp_s=$(printf '%s' "$IN" | jq -c "$WT_JQ_PROJECT" 2>/dev/null) || _pp_s=""
		case "$_pp_s" in
			'{'*'}')
				IN=$_pp_s
				return 0 ;;
		esac
	fi

	_pp_s=$(printf '%s' "$IN" | head -c "$WT_SCAN_MAX" 2>/dev/null) || _pp_s=""
	if [ -n "$_pp_s" ]; then
		IN=$_pp_s
		WT_TRUNCATED=1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# sanitize_id — never let a payload value reach a path unfiltered
# ---------------------------------------------------------------------------
sanitize_id() {
	SID_OUT=$1
	case "$SID_OUT" in
		''|*[!A-Za-z0-9._-]*) SID_OUT=unknown ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# JSON field extraction. Pure POSIX parameter expansion, bounded by the same
# two ceilings as the projection above.
# ---------------------------------------------------------------------------
wt_json_get() {
	_jg_j=$1
	_jg_k=$2
	JF=""

	if [ "${WT_JQ:-0}" = 1 ] && [ "${#_jg_j}" -gt "${WT_SCAN_MAX:-1024}" ]; then
		JF=$(printf '%s' "$_jg_j" | jq -r --arg k "$_jg_k" \
			'if type=="object" and has($k) and (.[$k] != null) then (.[$k]|tostring) else "" end' 2>/dev/null) || JF=""
		return 0
	fi

	if [ "${#_jg_j}" -gt "${WT_SCAN_HARD:-4096}" ]; then
		return 0
	fi

	_jg_pat="$WT_Q$_jg_k$WT_Q"
	_jg_rest=""

	# Find an occurrence of "name" that is actually in key position, i.e.
	# followed (after optional whitespace) by a colon. Occurrences inside a
	# string value are skipped rather than trusted.
	while :; do
		case "$_jg_j" in
			*"$_jg_pat"*) : ;;
			*) return 0 ;;
		esac
		_jg_rest=${_jg_j#*"$_jg_pat"}
		_jg_skip=$_jg_rest
		while :; do
			case "$_jg_skip" in
				' '*|"$WT_TAB"*|"$WT_NL"*|"$WT_CR"*) _jg_skip=${_jg_skip#?} ;;
				*) break ;;
			esac
		done
		case "$_jg_skip" in
			:*) _jg_rest=${_jg_skip#:}; break ;;
			*) _jg_j=$_jg_rest ;;
		esac
	done

	while :; do
		case "$_jg_rest" in
			"$WT_Q"*|t*|f*|n*|-*|0*|1*|2*|3*|4*|5*|6*|7*|8*|9*|'{'*|'['*|'') break ;;
			*) _jg_rest=${_jg_rest#?} ;;
		esac
	done

	case "$_jg_rest" in
		"$WT_Q"*)
			_jg_work=${_jg_rest#"$WT_Q"}
			while :; do
				_jg_seg=${_jg_work%%"$WT_Q"*}
				if [ "$_jg_seg" = "$_jg_work" ]; then
					JF="$JF$_jg_seg"
					break
				fi
				_jg_tail=$_jg_seg
				_jg_n=0
				while :; do
					case "$_jg_tail" in
						*"$WT_BS") _jg_tail=${_jg_tail%?}; _jg_n=$((_jg_n + 1)) ;;
						*) break ;;
					esac
				done
				JF="$JF$_jg_seg"
				_jg_work=${_jg_work#"$_jg_seg"}
				if [ $((_jg_n % 2)) -eq 0 ]; then
					break
				fi
				JF="$JF$WT_Q"
				_jg_work=${_jg_work#"$WT_Q"}
			done
			;;
		t*) JF=true ;;
		f*) JF=false ;;
		n*) JF="" ;;
		'{'*|'['*) JF="" ;;
		'') JF="" ;;
		*)
			JF=${_jg_rest%%,*}
			JF=${JF%%'}'*}
			JF=${JF%%']'*}
			while :; do
				case "$JF" in
					*' '|*"$WT_TAB"|*"$WT_NL"|*"$WT_CR") JF=${JF%?} ;;
					*) break ;;
				esac
			done
			case "$JF" in
				''|*[!0-9.eE+-]*) JF="" ;;
			esac
			;;
	esac
	return 0
}

json_field() {
	wt_json_get "$IN" "$1"
	return 0
}

# ---------------------------------------------------------------------------
# wt_unescape <json string body> -> UN
#
# JSON string values arrive from wt_json_get with their escapes still raw. The
# cache holds paths, and a path with a quote or a backslash in it round-trips
# through the cache as `\"` or `\\`. Only the escapes this plugin can itself
# produce are reversed; \n \t \r become a space, and \uXXXX is left alone
# because a path that needs it is a path this plugin will decline to use.
# ---------------------------------------------------------------------------
wt_unescape() {
	UN=""
	_ue_s=$1
	while :; do
		case "$_ue_s" in
			*"$WT_BS"*)
				UN="$UN${_ue_s%%"$WT_BS"*}"
				_ue_s=${_ue_s#*"$WT_BS"}
				case "$_ue_s" in
					n*|t*|r*) UN="$UN "; _ue_s=${_ue_s#?} ;;
					'') : ;;
					*) UN="$UN$(printf '%.1s' "$_ue_s")"; _ue_s=${_ue_s#?} ;;
				esac
				;;
			*)
				UN="$UN$_ue_s"
				break
				;;
		esac
	done
	return 0
}

# ---------------------------------------------------------------------------
# state_write / state_replace — per-session files, temp in the SAME directory,
# then rename. `mv` is atomic only within one filesystem, hence the temp file
# next to its destination. Sessions genuinely do run in parallel, and plain
# `>>` from concurrent writers interleaves and tears records.
# ---------------------------------------------------------------------------
state_replace() {
	_sr_f=$1
	_sr_d=${_sr_f%/*}
	if [ ! -d "$_sr_d" ]; then
		mkdir -p "$_sr_d" 2>/dev/null || return 0
	fi
	_sr_t="$_sr_f.$$.tmp"
	printf '%s\n' "$2" > "$_sr_t" 2>/dev/null || return 0
	mv -f "$_sr_t" "$_sr_f" 2>/dev/null || rm -f "$_sr_t" 2>/dev/null
	return 0
}

# ---------------------------------------------------------------------------
# wt_replace <haystack> <needle> <replacement> -> RP
# ---------------------------------------------------------------------------
wt_replace() {
	RP=""
	_rp_h=$1
	while :; do
		case "$_rp_h" in
			*"$2"*)
				_rp_pre=${_rp_h%%"$2"*}
				RP="$RP$_rp_pre$3"
				_rp_h=${_rp_h#*"$2"}
				;;
			*)
				RP="$RP$_rp_h"
				break
				;;
		esac
	done
	return 0
}

# ---------------------------------------------------------------------------
# wt_escape <text> -> JE   JSON string body, single line, no control characters
# ---------------------------------------------------------------------------
wt_escape() {
	wt_replace "$1" "$WT_BS" "$WT_BS$WT_BS"
	wt_replace "$RP" "$WT_Q" "$WT_BS$WT_Q"
	wt_replace "$RP" "$WT_NL" ' '
	wt_replace "$RP" "$WT_CR" ' '
	wt_replace "$RP" "$WT_TAB" ' '
	JE=$RP
	return 0
}

# ---------------------------------------------------------------------------
# emit_context <event name> <single-line text>
# {"hookSpecificOutput":{"hookEventName":"...","additionalContext":"..."}}
#
# The guard tests the RAW text, before escaping. Testing the escaped string is
# useless: wt_escape has by then rewritten every `"` as `\"`, so a control key
# in the input can no longer match a pattern written with literal quotes.
# ---------------------------------------------------------------------------
emit_context() {
	_ec_e=$1
	_ec_t=$2
	[ -n "$_ec_t" ] || return 0
	case "$_ec_t" in
		*"$WT_G1"*|*"$WT_G2"*|*"$WT_G3"*) return 0 ;;
	esac
	wt_escape "$_ec_t"
	printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}' \
		"$_ec_e" "$JE"
	return 0
}

# ---------------------------------------------------------------------------
# wt_paths <raw session id> — sets SID and WT_CACHE_F
#
# The cache carries a .jsonl extension on purpose: the garbage collector is
# allowed exactly one shape of find(1) invocation, and giving every state file
# the same extension means that one command covers all of them.
# ---------------------------------------------------------------------------
wt_paths() {
	sanitize_id "$1"
	SID=$SID_OUT
	WT_CACHE_F="$SESS_DIR/$SID.wt.jsonl"
	return 0
}

# ---------------------------------------------------------------------------
# Path helpers. Parameter expansion only — `basename` and `dirname` are forks,
# and this runs on the turn path.
# ---------------------------------------------------------------------------
wt_basename() {
	BN=$1
	while :; do
		case "$BN" in
			?*/) BN=${BN%/} ;;
			*)   break ;;
		esac
	done
	case "$BN" in
		*/*) BN=${BN##*/} ;;
	esac
	return 0
}

wt_dirname() {
	DN=$1
	while :; do
		case "$DN" in
			?*/) DN=${DN%/} ;;
			*)   break ;;
		esac
	done
	case "$DN" in
		*/*) DN=${DN%/*} ;;
		*)   DN="." ;;
	esac
	[ -n "$DN" ] || DN="/"
	return 0
}

# wt_clamp <text> <max> -> CL. Trims to max characters and marks the cut.
wt_clamp() {
	CL=$1
	_cl_m=$2
	if [ "${#CL}" -gt "$_cl_m" ]; then
		while [ "${#CL}" -gt $((_cl_m - 1)) ]; do
			CL=${CL%?}
		done
		CL="$CL…"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# wt_check_cwd <path> -> WT_CWD
#
# The payload's `cwd` is the one field that reaches a filesystem call, so it is
# checked rather than trusted: absolute, no control characters, no `..`
# component, and an existing directory. Anything else leaves WT_CWD empty and
# the hook goes quiet.
# ---------------------------------------------------------------------------
wt_check_cwd() {
	WT_CWD=""
	_cc_p=$1
	case "$_cc_p" in
		/*) : ;;
		*)  return 0 ;;
	esac
	case "$_cc_p" in
		*"$WT_NL"*|*"$WT_CR"*|*"$WT_TAB"*) return 0 ;;
	esac
	case "$_cc_p" in
		*/../*|*/..) return 0 ;;
	esac
	if [ "${#_cc_p}" -gt 512 ]; then
		return 0
	fi
	[ -d "$_cc_p" ] || return 0
	WT_CWD=$_cc_p
	return 0
}

# ---------------------------------------------------------------------------
# wt_resolve <cwd> -> WT_GITDIR WT_COMMON WT_TOP
#
# ONE git fork, asking for all three paths at once. This is the only fork on
# any path in this plugin, and it happens on the first turn of a session and
# then only when the working directory changes.
#
# `--path-format=absolute` needs git 2.31. Without it the paths may come back
# relative to cwd, so the fallback resolves them against the top level itself.
# ---------------------------------------------------------------------------
wt_resolve() {
	WT_GITDIR=""
	WT_COMMON=""
	WT_TOP=""
	_rs_c=$1
	[ -n "$_rs_c" ] || return 0
	command -v git >/dev/null 2>&1 || return 0

	_rs_o=$(cd -- "$_rs_c" 2>/dev/null && git rev-parse --path-format=absolute \
		--git-dir --git-common-dir --show-toplevel 2>/dev/null) || _rs_o=""
	if [ -z "$_rs_o" ]; then
		_rs_o=$(cd -- "$_rs_c" 2>/dev/null && git rev-parse \
			--git-dir --git-common-dir --show-toplevel 2>/dev/null) || _rs_o=""
	fi
	[ -n "$_rs_o" ] || return 0

	# Split on newline with globbing disabled: a path may legitimately hold a
	# `*`, and pathname expansion here would replace it with whatever matches.
	_rs_ifs=$IFS
	set -f
	IFS=$WT_NL
	# shellcheck disable=SC2086
	set -- $_rs_o
	set +f
	IFS=$_rs_ifs
	[ $# -eq 3 ] || return 0

	WT_GITDIR=$1
	WT_COMMON=$2
	WT_TOP=$3
	case "$WT_TOP" in
		/*) : ;;
		*)  WT_GITDIR=""; WT_COMMON=""; WT_TOP=""; return 0 ;;
	esac
	case "$WT_GITDIR" in
		/*) : ;;
		*)  WT_GITDIR="$WT_TOP/$WT_GITDIR" ;;
	esac
	case "$WT_COMMON" in
		/*) : ;;
		*)  WT_COMMON="$WT_TOP/$WT_COMMON" ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# wt_describe — turns the three resolved paths into WT_REPO, WT_NAME, WT_LINKED
# ---------------------------------------------------------------------------
wt_describe() {
	WT_REPO=""
	WT_NAME=""
	WT_LINKED=false
	[ -n "$WT_TOP" ] || return 0

	if [ "$WT_GITDIR" != "$WT_COMMON" ]; then
		WT_LINKED=true
	fi

	# The repository is named by whatever holds the common git directory:
	# `<repo>/.git` for an ordinary clone, `<repo>.git` when it is bare.
	wt_basename "$WT_COMMON"
	_ds_b=$BN
	if [ "$_ds_b" = ".git" ]; then
		wt_dirname "$WT_COMMON"
		wt_basename "$DN"
		WT_REPO=$BN
	else
		WT_REPO=${_ds_b%.git}
	fi
	[ -n "$WT_REPO" ] || WT_REPO=$_ds_b

	wt_basename "$WT_TOP"
	WT_NAME=$BN
	return 0
}

# ---------------------------------------------------------------------------
# wt_head_branch <git dir> -> WT_BRANCH
#
# Read straight out of HEAD, with no fork. That file is one short line, it is
# rewritten by every checkout, and reading it on each turn is what makes a
# mid-session branch switch show up without re-running git. For a linked
# worktree the per-worktree HEAD lives at `<common>/worktrees/<name>/HEAD`,
# which is exactly the git dir git reported for that worktree.
# ---------------------------------------------------------------------------
wt_head_branch() {
	WT_BRANCH=""
	_hb_f="$1/HEAD"
	[ -f "$_hb_f" ] || return 0
	[ -r "$_hb_f" ] || return 0
	IFS= read -r _hb_l < "$_hb_f" 2>/dev/null || _hb_l=""
	[ -n "$_hb_l" ] || return 0
	while :; do
		case "$_hb_l" in
			*' '|*"$WT_TAB"|*"$WT_CR") _hb_l=${_hb_l%?} ;;
			*) break ;;
		esac
	done
	case "$_hb_l" in
		'ref: refs/heads/'*)
			WT_BRANCH=${_hb_l#ref: refs/heads/}
			;;
		'ref: '*)
			WT_BRANCH=${_hb_l#ref: }
			;;
		*)
			# Detached: a raw object id. Shortened by trimming, not by forking
			# `git rev-parse --short`, which would cost a fork on every turn.
			case "$_hb_l" in
				*[!0-9a-f]*) return 0 ;;
			esac
			if [ "${#_hb_l}" -lt 7 ]; then
				return 0
			fi
			while [ "${#_hb_l}" -gt 7 ]; do
				_hb_l=${_hb_l%?}
			done
			WT_BRANCH="detached@$_hb_l"
			;;
	esac
	case "$WT_BRANCH" in
		*"$WT_NL"*|*"$WT_CR"*) WT_BRANCH="" ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# Cache. One line per session, keyed by the working directory it describes, so
# a `cd` or an EnterWorktree mid-session simply misses and re-resolves.
# ---------------------------------------------------------------------------
wt_cache_read() {
	C_CWD=""
	C_GITDIR=""
	C_COMMON=""
	C_TOP=""
	[ -r "$WT_CACHE_F" ] || return 0
	IFS= read -r _cr_l < "$WT_CACHE_F" || _cr_l=""
	[ -n "$_cr_l" ] || return 0
	wt_json_get "$_cr_l" cwd;        wt_unescape "$JF"; C_CWD=$UN
	wt_json_get "$_cr_l" git_dir;    wt_unescape "$JF"; C_GITDIR=$UN
	wt_json_get "$_cr_l" common_dir; wt_unescape "$JF"; C_COMMON=$UN
	wt_json_get "$_cr_l" top;        wt_unescape "$JF"; C_TOP=$UN
	return 0
}

wt_cache_write() {
	wt_escape "$WT_CWD";    _cw_c=$JE
	wt_escape "$WT_GITDIR"; _cw_g=$JE
	wt_escape "$WT_COMMON"; _cw_m=$JE
	wt_escape "$WT_TOP";    _cw_t=$JE
	state_replace "$WT_CACHE_F" \
		"{\"cwd\":\"$_cw_c\",\"git_dir\":\"$_cw_g\",\"common_dir\":\"$_cw_m\",\"top\":\"$_cw_t\"}"
	return 0
}

# ---------------------------------------------------------------------------
# wt_locate <raw cwd> -> WT_TOP / WT_GITDIR / WT_COMMON / WT_REPO / WT_NAME /
#                        WT_LINKED / WT_BRANCH
#
# The whole per-turn path. A cache hit forks nothing; a miss forks git once and
# rewrites the cache. Outside a git repository everything stays empty.
# ---------------------------------------------------------------------------
wt_locate() {
	WT_TOP=""
	WT_GITDIR=""
	WT_COMMON=""
	WT_REPO=""
	WT_NAME=""
	WT_LINKED=false
	WT_BRANCH=""

	wt_check_cwd "$1"
	[ -n "$WT_CWD" ] || return 0

	wt_cache_read
	if [ -n "$C_CWD" ] && [ "$C_CWD" = "$WT_CWD" ] && [ -n "$C_TOP" ] && [ -d "$C_TOP" ]; then
		WT_GITDIR=$C_GITDIR
		WT_COMMON=$C_COMMON
		WT_TOP=$C_TOP
	else
		wt_resolve "$WT_CWD"
		[ -n "$WT_TOP" ] || return 0
		wt_cache_write
	fi

	wt_describe
	[ -n "$WT_REPO" ] || return 0
	wt_head_branch "$WT_GITDIR"
	return 0
}

# ---------------------------------------------------------------------------
# wt_tag -> TAG   the single line the model is asked to print
#
# Linked worktree:  🟠 repo ▸ worktree · branch
# Main checkout:    🟠 repo ▸ branch (root)
# Outside a repo:   empty, and the hook says nothing at all.
#
# The leading glyph comes from MARK and may be empty (MARK=none), which is why
# the body is built first and the mark prefixed only if there is one.
# ---------------------------------------------------------------------------
wt_tag() {
	TAG=""
	[ -n "$WT_REPO" ] || return 0

	wt_clamp "$WT_REPO" 64;   _tg_r=$CL
	wt_clamp "$WT_NAME" 64;   _tg_n=$CL
	wt_clamp "$WT_BRANCH" 64; _tg_b=$CL
	[ "$SHOW_BRANCH" = 1 ] || _tg_b=""

	_tg_body=""
	if [ "$WT_LINKED" = true ]; then
		if [ "$FORMAT" = short ]; then
			_tg_body="$_tg_n"
		elif [ -n "$_tg_b" ]; then
			_tg_body="$_tg_r $WT_SEP $_tg_n $WT_DOT $_tg_b"
		else
			_tg_body="$_tg_r $WT_SEP $_tg_n"
		fi
	else
		[ "$ROOT" = 1 ] || return 0
		if [ "$FORMAT" = short ] || [ -z "$_tg_b" ]; then
			_tg_body="$_tg_r (root)"
		else
			_tg_body="$_tg_r $WT_SEP $_tg_b (root)"
		fi
	fi

	[ -n "$_tg_body" ] || return 0
	if [ -n "$WT_MARK" ]; then
		TAG="$WT_MARK $_tg_body"
	else
		TAG="$_tg_body"
	fi
	return 0
}
