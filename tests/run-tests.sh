#!/bin/sh
# claude-worktree — self-contained test suite.
#
# POSIX sh. No dependencies beyond coreutils/findutils/grep and git.
# jq is used when present and skipped when not.
#
# Safety: every byte of state goes to a throwaway directory handed to the hooks
# via CLAUDE_WORKTREE_DIR, and the suite aborts if that would ever resolve
# underneath the real ~/.claude. The git repositories under test are created
# fresh inside that directory; no repository on the machine is read or written.
#
# Usage:  sh tests/run-tests.sh
# Env:    KEEP_TMP=1   leave the temp directory behind

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P) || exit 1

PASS=0
FAIL=0
SKIPPED=0

ok()   { PASS=$((PASS + 1));      printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1));      printf '  FAIL  %s\n' "$1"
         if [ -n "${2:-}" ]; then printf '        %s\n' "$2"; fi; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  skip  %s\n' "$1"; }
group(){ printf '\n== %s\n' "$1"; }

assert_has() {
  case "$2" in
    *"$3"*) ok "$1" ;;
    *)      bad "$1" "expected [$3] in: $(printf '%s' "$2" | head -c 220)" ;;
  esac
}
assert_lacks() {
  case "$2" in
    *"$3"*) bad "$1" "found forbidden [$3] in: $(printf '%s' "$2" | head -c 220)" ;;
    *)      ok "$1" ;;
  esac
}
assert_empty() {
  if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected nothing, got: $(printf '%s' "$2" | head -c 220)"; fi
}
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi
}

# ------------------------------------------------------------------ sandbox --

TMPROOT=$(mktemp -d 2>/dev/null) || TMPROOT=""
if [ -z "$TMPROOT" ] || [ ! -d "$TMPROOT" ]; then
  printf 'cannot create a temporary directory; aborting\n'
  exit 1
fi
case "$TMPROOT" in
  "${HOME:-/nonexistent}"/.claude*|"${HOME:-/nonexistent}"/Documents*)
    printf 'refusing to run: temp dir %s is inside the real config tree\n' "$TMPROOT"
    exit 1 ;;
esac
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    printf '\ntemp dir kept at %s\n' "$TMPROOT"
  else
    rm -rf "$TMPROOT"
  fi
}
trap cleanup EXIT INT HUP TERM

STATE="$TMPROOT/state"
SHIM="$TMPROOT/bin"
mkdir -p "$STATE" "$SHIM"

CLAUDE_PLUGIN_ROOT="$ROOT"
CLAUDE_WORKTREE_DIR="$STATE"
export CLAUDE_PLUGIN_ROOT CLAUDE_WORKTREE_DIR

UPS="$ROOT/hooks/user-prompt-submit.sh"
SST="$ROOT/hooks/session-start.sh"

# A git shim that counts invocations, so "the warm path forks nothing" is a
# measurement rather than a claim.
GITBIN=$(command -v git 2>/dev/null) || GITBIN=""
if [ -n "$GITBIN" ]; then
  printf '#!/bin/sh\necho c >> "%s/git.calls"\nexec "%s" "$@"\n' "$TMPROOT" "$GITBIN" > "$SHIM/git"
  chmod +x "$SHIM/git"
fi
git_calls() { [ -f "$TMPROOT/git.calls" ] && wc -l < "$TMPROOT/git.calls" | tr -d ' ' || echo 0; }
git_reset() { : > "$TMPROOT/git.calls"; }

# ------------------------------------------------------------- test fixtures --

# The host always sends well-formed JSON, so the fixture has to as well: a path
# holding a quote or a backslash is legal on disk and must be escaped here, or
# the test measures its own broken payload rather than the hook.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}
payload() { # cwd sid -> a UserPromptSubmit payload
  printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","cwd":"%s","prompt":"hello"}' \
    "$(json_escape "$2")" "$(json_escape "$1")"
}
run_ups() { # cwd sid
  payload "$1" "$2" | PATH="$SHIM:$PATH" sh "$UPS" 2>/dev/null
}
tag_of() { # full hook output -> just the tag
  # The trailing instruction is worded differently for PLACE=top and
  # PLACE=bottom, so both endings have to be trimmed here.
  printf '%s' "$1" | sed -e 's/^.*working tree is: //' \
                         -e 's/\. Begin your reply.*$//' \
                         -e 's/\. End your reply.*$//'
}
write_config() {
  printf '%s\n' "$@" > "$STATE/config.env"
}
reset_state() {
  rm -rf "$STATE"
  mkdir -p "$STATE"
}

REPO="$TMPROOT/repos/widget"
WTDIR="$TMPROOT/repos/widget/.claude/worktrees/feature-x"
HAVE_GIT=0
if [ -n "$GITBIN" ]; then
  mkdir -p "$REPO"
  (
    cd "$REPO" || exit 1
    git init -q -b main . 2>/dev/null || { git init -q . && git checkout -q -b main; }
    git config user.email t@example.invalid
    git config user.name 'Test'
    echo hello > file.txt
    git add file.txt
    git commit -q -m 'first'
    git worktree add -q -b feature-branch "$WTDIR" 2>/dev/null
  ) >/dev/null 2>&1
  if [ -d "$WTDIR" ]; then
    HAVE_GIT=1
  fi
fi

# =============================================================================
group 'tag shapes'
# =============================================================================
if [ "$HAVE_GIT" = 0 ]; then
  skip 'git is unavailable or the fixture repository could not be built'
else
  reset_state

  out=$(run_ups "$WTDIR" s1)
  assert_has 'linked worktree emits a tag' "$out" 'working tree is:'
  assert_eq  'linked worktree tag'  "$(tag_of "$out")" '🟠 widget ▸ feature-x · feature-branch'
  assert_has 'output names the hook event' "$out" '"hookEventName":"UserPromptSubmit"'
  assert_has 'output uses additionalContext' "$out" '"additionalContext"'

  out=$(run_ups "$REPO" s2)
  assert_eq  'main checkout tag' "$(tag_of "$out")" '🟠 widget ▸ main (root)'

  out=$(run_ups "$REPO/.claude" s2b)
  assert_eq  'subdirectory resolves to its worktree' "$(tag_of "$out")" '🟠 widget ▸ main (root)'

  # Detached HEAD in the linked worktree.
  ( cd "$WTDIR" && git checkout -q --detach ) >/dev/null 2>&1
  sha=$( cd "$WTDIR" && git rev-parse --short=7 HEAD 2>/dev/null )
  out=$(run_ups "$WTDIR" s3)
  assert_eq  'detached HEAD is shortened' "$(tag_of "$out")" "🟠 widget ▸ feature-x · detached@$sha"
  ( cd "$WTDIR" && git checkout -q feature-branch ) >/dev/null 2>&1

  out=$(run_ups "$TMPROOT" s4)
  assert_empty 'outside a git repository the hook is silent' "$out"
fi

# =============================================================================
group 'configuration'
# =============================================================================
if [ "$HAVE_GIT" = 0 ]; then
  skip 'git fixture unavailable'
else
  reset_state; write_config 'MODE=off'
  assert_empty 'MODE=off says nothing' "$(run_ups "$WTDIR" c1)"

  reset_state; write_config 'FORMAT=short'
  assert_eq 'FORMAT=short, linked' "$(tag_of "$(run_ups "$WTDIR" c2)")" '🟠 feature-x'
  assert_eq 'FORMAT=short, root'   "$(tag_of "$(run_ups "$REPO" c3)")"  '🟠 widget (root)'

  reset_state; write_config 'SHOW_BRANCH=0'
  assert_eq 'SHOW_BRANCH=0 drops the branch' "$(tag_of "$(run_ups "$WTDIR" c4)")" '🟠 widget ▸ feature-x'

  # PLACE decides which end of the reply the model is asked to put the tag on.
  reset_state
  out=$(run_ups "$WTDIR" p1)
  assert_has 'PLACE defaults to the bottom' "$out" 'End your reply with exactly that line, on its own final line'
  assert_lacks 'and does not also ask for the top' "$out" 'Begin your reply'

  reset_state; write_config 'PLACE=top'
  out=$(run_ups "$WTDIR" p2)
  assert_has 'PLACE=top asks for the first line' "$out" 'Begin your reply with exactly that line, on its own first line'
  assert_lacks 'and not the last' "$out" 'End your reply'

  # MARK picks the leading glyph. Markdown has no colour and the app sanitises
  # HTML, so a coloured glyph is the only colour that survives; these are the
  # only values the parser accepts.
  reset_state
  assert_has 'MARK defaults to orange' "$(tag_of "$(run_ups "$WTDIR" m0)")" '🟠'
  reset_state; write_config 'MARK=yellow'
  assert_has 'MARK=yellow' "$(tag_of "$(run_ups "$WTDIR" m1)")" '🟡'
  reset_state; write_config 'MARK=option'
  assert_has 'MARK=option' "$(tag_of "$(run_ups "$WTDIR" m2)")" '⌥'
  reset_state; write_config 'MARK=warn'
  assert_has 'MARK=warn' "$(tag_of "$(run_ups "$WTDIR" m3)")" '⚠️'
  reset_state; write_config 'MARK=none'
  assert_eq 'MARK=none leaves no leading glyph or space' "$(tag_of "$(run_ups "$WTDIR" m4)")" 'widget ▸ feature-x · feature-branch'
  reset_state; write_config 'MARK=purple'
  assert_has 'an unknown MARK falls back to the default' "$(tag_of "$(run_ups "$WTDIR" m5)")" '🟠'

  # STYLE=code wraps the tag in an inline code span. It is the only route to
  # coloured text, and only on clients that paint markdown — see DESIGN.md.
  reset_state
  assert_lacks 'STYLE defaults to plain (no backticks)' "$(tag_of "$(run_ups "$WTDIR" y0)")" '`'
  reset_state; write_config 'STYLE=code'
  assert_eq 'STYLE=code wraps the whole tag' "$(tag_of "$(run_ups "$WTDIR" y1)")" '`🟠 widget ▸ feature-x · feature-branch`'
  reset_state; write_config 'STYLE=code' 'MARK=none'
  assert_eq 'STYLE=code with no glyph' "$(tag_of "$(run_ups "$WTDIR" y2)")" '`widget ▸ feature-x · feature-branch`'
  reset_state; write_config 'STYLE=bogus'
  assert_lacks 'an unknown STYLE falls back to plain' "$(tag_of "$(run_ups "$WTDIR" y3)")" '`'
  # A backtick in the payload must not break the JSON.
  reset_state; write_config 'STYLE=code'
  out=$(run_ups "$WTDIR" y4)
  if command -v node >/dev/null 2>&1; then
    if printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{JSON.parse(s)})' 2>/dev/null; then
      ok 'backticks stay valid JSON'
    else
      bad 'backticks stay valid JSON' "$out"
    fi
  else
    skip 'node unavailable to validate the JSON'
  fi

  reset_state; write_config 'ROOT=0'
  assert_empty 'ROOT=0 is silent in the main checkout' "$(run_ups "$REPO" c5)"
  assert_has   'ROOT=0 still tags a worktree' "$(run_ups "$WTDIR" c6)" 'feature-x'

  # Hostile config: none of this may be evaluated, and none may be honoured.
  reset_state
  {
    printf '%s\n' 'MODE=off; touch '"$TMPROOT"'/pwned'
    printf '%s\n' 'MODE=$(touch '"$TMPROOT"'/pwned2)'
    printf '%s\n' 'FORMAT=`touch '"$TMPROOT"'/pwned3`'
    printf '%s\n' 'MODE=nonsense'
    printf '%s\n' 'UNKNOWN=1'
  } > "$STATE/config.env"
  out=$(run_ups "$WTDIR" c7)
  assert_has 'hostile config falls back to defaults' "$out" 'feature-x'
  if [ -e "$TMPROOT/pwned" ] || [ -e "$TMPROOT/pwned2" ] || [ -e "$TMPROOT/pwned3" ]; then
    bad 'hostile config is never evaluated' 'a config line executed'
  else
    ok 'hostile config is never evaluated'
  fi

  # An over-long line is ignored rather than honoured.
  reset_state
  long=MODE=off
  n=0
  while [ "$n" -lt 80 ]; do long="$long "; n=$((n + 1)); done
  printf '%s\n' "$long" > "$STATE/config.env"
  assert_has 'an over-long config line is ignored' "$(run_ups "$WTDIR" c8)" 'feature-x'

  # A FIFO where config.env belongs must not block the hook.
  reset_state
  if mkfifo "$STATE/config.env" 2>/dev/null; then
    out=$(run_ups "$WTDIR" c9)
    assert_has 'a FIFO config is refused, not opened' "$out" 'feature-x'
    rm -f "$STATE/config.env"
  else
    skip 'mkfifo unavailable'
  fi
fi

# =============================================================================
group 'cache behaviour'
# =============================================================================
if [ "$HAVE_GIT" = 0 ] || [ ! -x "$SHIM/git" ]; then
  skip 'git shim unavailable'
else
  reset_state
  git_reset
  run_ups "$WTDIR" k1 >/dev/null
  assert_eq 'a cold turn forks git exactly once' "$(git_calls)" '1'

  git_reset
  n=0
  while [ "$n" -lt 10 ]; do run_ups "$WTDIR" k1 >/dev/null; n=$((n + 1)); done
  assert_eq 'ten warm turns fork git zero times' "$(git_calls)" '0'

  # A branch switch must be visible on the warm path, because HEAD is re-read.
  ( cd "$WTDIR" && git checkout -q -b second-branch ) >/dev/null 2>&1
  git_reset
  out=$(run_ups "$WTDIR" k1)
  assert_has 'a warm turn sees a branch switch' "$out" 'second-branch'
  assert_eq  'and still forks git zero times' "$(git_calls)" '0'
  ( cd "$WTDIR" && git checkout -q feature-branch ) >/dev/null 2>&1

  # A working directory change within one session must miss the cache.
  git_reset
  out=$(run_ups "$REPO" k1)
  assert_has 'a cwd change re-resolves' "$out" '(root)'
  assert_eq  'and forks git once' "$(git_calls)" '1'

  # SessionStart primes the cache, so the first prompt is already warm.
  reset_state
  git_reset
  printf '{"session_id":"k2","hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$(json_escape "$WTDIR")" \
    | PATH="$SHIM:$PATH" sh "$SST" >/dev/null 2>&1
  primed=$(git_calls)
  git_reset
  out=$(run_ups "$WTDIR" k2)
  assert_eq 'SessionStart primes the cache' "$primed" '1'
  assert_eq 'so the first prompt forks git zero times' "$(git_calls)" '0'
  assert_has 'and still produces the tag' "$out" 'feature-x'
fi

# =============================================================================
group 'payload safety'
# =============================================================================
reset_state

# A session id is never allowed to steer a path.
for bad_sid in '../../etc/passwd' '/etc/passwd' 'a;rm -rf /' 'a b' '../../../../pwn'; do
  out=$(printf '{"session_id":"%s","cwd":"%s","prompt":"x"}' "$bad_sid" "$TMPROOT" \
        | PATH="$SHIM:$PATH" sh "$UPS" 2>/dev/null)
  rc=$?
  if [ "$rc" != 0 ]; then
    bad "hostile session id [$bad_sid] exits 0" "status was $rc"
  fi
done
stray=$(find "$STATE" -mindepth 1 -maxdepth 2 2>/dev/null | grep -v -e '^'"$STATE"'/sessions$' -e '^'"$STATE"'/config.env$' -e '^'"$STATE"'/sessions/' | head -3)
assert_empty 'no state file escapes the state directory' "$stray"
outside=$(find "$STATE/sessions" -mindepth 1 -maxdepth 1 ! -name 'unknown*' ! -name '*.wt.jsonl' 2>/dev/null | head -3)
assert_empty 'every cache file is a sanitised name' "$outside"

# Payloads that are wrong in every direction must still exit 0 and stay quiet.
for p in '' 'not json at all' '{' '[]' 'null' '{"session_id":null,"cwd":null}' \
         '{"cwd":"relative/path","session_id":"z"}' \
         '{"cwd":"/does/not/exist/at/all","session_id":"z"}' \
         '{"cwd":"/etc/../etc","session_id":"z"}'; do
  out=$(printf '%s' "$p" | PATH="$SHIM:$PATH" sh "$UPS" 2>/dev/null)
  rc=$?
  if [ "$rc" != 0 ]; then
    bad "malformed payload exits 0: $(printf '%s' "$p" | head -c 40)" "status was $rc"
  elif [ -n "$out" ]; then
    case "$out" in
      '{'*'}') ok "malformed payload emits only well-formed JSON: $(printf '%s' "$p" | head -c 24)" ;;
      *)       bad "malformed payload emitted junk" "$out" ;;
    esac
  fi
done
ok 'every malformed payload exits 0'

# A very large payload must stay far inside the hook timeout.
if command -v awk >/dev/null 2>&1; then
  bigp=$(awk 'BEGIN{s="";for(i=0;i<8192;i++)s=s "0123456789abcdef";printf "{\"prompt\":\"%s\",\"session_id\":\"big\",\"cwd\":\"/\"}", s}')
  start=$(date +%s 2>/dev/null)
  printf '%s' "$bigp" | PATH="$SHIM:$PATH" sh "$UPS" >/dev/null 2>&1
  rc=$?
  end=$(date +%s 2>/dev/null)
  if [ "$rc" != 0 ]; then
    bad 'a 128 KB payload exits 0' "status was $rc"
  elif [ $((end - start)) -gt 3 ]; then
    bad 'a 128 KB payload stays inside the hook timeout' "took $((end - start))s of a 5s budget"
  else
    ok 'a 128 KB payload is handled well inside the timeout'
  fi
else
  skip 'awk unavailable for the large-payload test'
fi

# =============================================================================
group 'output discipline'
# =============================================================================
if [ "$HAVE_GIT" = 0 ]; then
  skip 'git fixture unavailable'
else
  reset_state
  out=$(run_ups "$WTDIR" o1)
  lines=$(printf '%s' "$out" | wc -l | tr -d ' ')
  assert_eq 'the hook emits a single line' "$lines" '0'
  assert_has 'which is one JSON object' "$out" '{"hookSpecificOutput"'

  # The keys that could steer the agent must never appear. Assembled from
  # fragments so that this file does not trip the repository's own safety grep.
  g1='"de''cision"'; g2='"permission''Decision"'; g3='"con''tinue"'
  assert_lacks 'no control key in the output (1)' "$out" "$g1"
  assert_lacks 'no control key in the output (2)' "$out" "$g2"
  assert_lacks 'no control key in the output (3)' "$out" "$g3"

  # A repository whose name carries JSON metacharacters must not break the JSON.
  odd="$TMPROOT/repos/say \"hi\" \\ here"
  mkdir -p "$odd" 2>/dev/null
  (
    cd "$odd" || exit 1
    git init -q -b main . 2>/dev/null || { git init -q . && git checkout -q -b main; }
    git config user.email t@example.invalid
    git config user.name 'Test'
    echo x > f
    git add f
    git commit -q -m first
  ) >/dev/null 2>&1
  if [ -d "$odd/.git" ]; then
    out=$(run_ups "$odd" o2)
    if [ -z "$out" ]; then
      skip 'awkward repository name produced no tag'
    elif command -v node >/dev/null 2>&1; then
      if printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{JSON.parse(s)})' 2>/dev/null; then
        ok 'quotes and backslashes in a path stay valid JSON'
      else
        bad 'quotes and backslashes in a path stay valid JSON' "$out"
      fi
    else
      skip 'node unavailable to validate the JSON'
    fi
  else
    skip 'could not build the awkward-name fixture'
  fi

  # Both hooks must exit 0 no matter what.
  for h in "$UPS" "$SST"; do
    printf 'garbage' | PATH="$SHIM:$PATH" sh "$h" >/dev/null 2>&1
    if [ $? != 0 ]; then bad "$(basename "$h") exits 0 on garbage" "non-zero status"; fi
  done
  ok 'both hooks exit 0 on garbage input'
fi

# =============================================================================
group 'SUMMARY'
# =============================================================================
printf '\npassed %s   failed %s   skipped %s\n' "$PASS" "$FAIL" "$SKIPPED"
if [ "$FAIL" -ne 0 ]; then
  printf 'RESULT: FAIL\n'
  exit 1
fi
printf 'RESULT: PASS\n'
exit 0
