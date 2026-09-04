# Design notes

This file is for contributors. The README says what the plugin does; this says why it is
built the way it is. Most of what follows is a constraint we hit and worked around, not a
preference.

It shares a great deal of its shape with `claude-timestamps`, deliberately: the hook
safety rules, the payload-shrinking parser and the per-session state layout are the same,
because the reasons for them are the same. The parts that differ are below.

## Why not the status line, which is where this obviously belongs

Claude Code's status line already receives everything this plugin computes, and more:
`worktree.name`, `worktree.path`, `worktree.branch`, `worktree.original_cwd`,
`worktree.original_branch`, and `workspace.git_worktree` for any linked worktree whether or
not the session entered it through Claude Code. A five-line `jq` script in
`settings.json` would do the whole job with no plugin at all.

It renders in the terminal only. The desktop app ships the CLI, and therefore its settings
schema — `statusLine` appears in `app.asar` seven times, all of them in schema validation
and in the description of `disableAllHooks` — but nothing in the bundle draws one. There
are no renderer symbols for it at all, against 985 occurrences of `worktree`. The app knows
everything about worktrees and nothing about painting a status line.

So on the client this plugin is for, the status line is a dead channel. If you work mainly
in the terminal, you do not need this plugin; configure `statusLine` and read
`worktree.name` out of its stdin.

## Why the colour is a glyph

`MARK` picks between 🟠, 🟡, ⚠️, ⌥ and nothing. It does not pick a colour, because there is
no colour to pick.

This was measured rather than assumed, twice, on 2026-09-04, by rendering candidates in a
desktop-app assistant message and reading the result off the screen.

**Round one — author-supplied HTML.** All stripped:

| Candidate | Result |
| --- | --- |
| `<span style="color:orange">` | stripped |
| `<span style="color:#f59e0b">` | stripped |
| `<font color="orange">` | stripped |
| 🟠 | renders orange |

The app carries `sanitizeHtml` with a tag allowlist, and inline style does not survive it.

**Round two — markdown-native colour, and it depends on the client.** Round one only proved
that *our* markup is removed, not that the renderer paints nothing. It does paint — but not
everywhere. Same message, read on two clients:

| Candidate | Desktop app | Mobile |
| --- | --- | --- |
| inline code span | **coloured** | no colour |
| ` ```diff ` `-` / `+` / `!` lines | **coloured** | no colour |
| link | **coloured** | no colour |
| blockquote | no colour | no colour |
| `<span style>` / `<font color>` | stripped | stripped |
| 🟠 glyph | orange | orange |

Two conclusions follow, and they set the defaults:

1. **The glyph is the only colour that survives everywhere**, because it is carried by the
   font rather than by the renderer. That is why `MARK` is the default mechanism and
   `STYLE=plain` is the default style. A reader on mobile still gets a coloured marker.
2. **`STYLE=code` is opt-in**, and it buys colour only on clients that paint markdown.

`STYLE=code` uses an inline code span rather than a fenced ` ```diff ` block, even though a
fence colours more strongly. A fence is a block element: it wraps a one-line footer in a
box, on every client. On desktop you would at least be paying that for colour; on mobile you
would pay it and get nothing. An inline code span stays a single inline line everywhere and
degrades to a monospace pill, which is a much cheaper failure.

The wider trap this whole exercise is a monument to: **a rendering result is a property of a
client, not of "markdown".** Round one tested one client and concluded something about the
format. Round two tested six constructs on that same client and concluded something about
the product. Only round three — the same message on a second client — was actually
measuring the thing that varies. Test the surfaces your users read on, and say which surface
a result came from.

Do not add a `COLOR` setting. You cannot choose the colour, only the construct; the theme
decides what that construct is painted.

ANSI escapes are a terminal mechanism and would render as literal noise. So the colour has
to live in the font, which is what a coloured glyph is — and it degrades honestly, since a
terminal without emoji fonts shows a box rather than a broken escape sequence. `MARK=option`
exists for exactly that case.



A coloured glyph is the one thing guaranteed to survive, because the colour is in the font
rather than in any markup. It also degrades honestly: in a terminal without emoji fonts it
is a box, not a broken escape sequence, and `MARK=option` gives an ASCII-adjacent
alternative for exactly that case.

## Why the tag is typed by the model

A hook has exactly two ways to affect what a user sees:

1. A `Stop` hook's `systemMessage`. Deterministic, but the desktop app collapses it behind
   a "Claude Code notice" dropdown. An indicator that requires a click is not an indicator.
2. `UserPromptSubmit`'s `additionalContext`, which reaches the model, which can then type
   whatever it was asked to type into the body of its reply — where every client renders it.

Neither is good. The first is exact and unreadable; the second is readable and advisory.
For an indicator whose entire value is being *glanceable*, readable wins, and the README
says plainly that the model can drop it.

`MessageDisplay` is not a third option: its output is discarded by the host, in every
client, in every form.

## Why `git` is forked once per session and not once per turn

The per-turn budget is small — the two `bash` startups of a two-hook plugin already cost
about 4.4 ms — and `git rev-parse` is not free. But the answer it gives is almost entirely
static: the repository root, the git directory and the common git directory do not change
while the working directory stays put.

So they are cached, keyed by the working directory the payload reports:

- **Cache hit** — reuse the three paths. Zero forks.
- **Cache miss** — one `git rev-parse` asking for all three paths at once, then rewrite the
  cache. Happens on the first turn of a session, and again when `cd`, `EnterWorktree` or
  `ExitWorktree` changes the directory.

`SessionStart` primes the cache, so even the first prompt of a session is a hit.

The branch is deliberately **not** cached, because it is the one part that changes under
you — you switch branches, or another session in another worktree does. It is read on every
turn straight out of `<git dir>/HEAD`, with the shell, no fork: that file is one short line,
git rewrites it on every checkout, and for a linked worktree it lives at
`<common>/worktrees/<name>/HEAD`, which is exactly the git directory git reports for that
worktree. A branch switch made anywhere shows up on the very next turn at no cost.

Detached HEAD is shortened by trimming the object id in the shell rather than by forking
`git rev-parse --short`, for the same reason.

Measured: about 6 ms per warm turn, one `git` fork per session, and the test suite asserts
the fork counts rather than trusting them.

## Why `cwd` is checked before it is used

`cwd` is the only payload field in this plugin that reaches a filesystem call, and the
whole per-turn path is built on it. It is required to be absolute, free of newline, tab and
carriage return, free of any `..` component, no longer than 512 bytes, and an existing
directory. Anything else leaves it empty and the hook goes quiet.

The session id is sanitised separately and far more harshly — anything outside
`[A-Za-z0-9._-]` makes the whole id `unknown` — because it is used to build a path in the
state directory, and a path is not a place to discover that a value contained a slash.

Paths are not, however, sanitised for *display*. A repository directory may legitimately
hold a quote or a backslash, so the tag is JSON-escaped rather than filtered, and the test
suite builds a repository called `say "hi" \ here` to prove the output stays parseable.
Splitting git's three-line answer therefore runs with globbing disabled: a path containing
`*` would otherwise be replaced by whatever it matched.

## Why a status of 2 is forbidden

Inherited wholesale from `claude-timestamps`, and worth restating because the failure is
invisible. On `Stop`, a hook exiting with status 2 means "do not stop", and the session
loops without a user in it. This plugin ships no `Stop` hook, but a shell syntax error
exits 2 on its own, and the rules that prevent it cost nothing:

- Every hook script ends with a literal `exit 0` and has no other exit path.
- No `set -e`.
- Real work runs in a subshell whose failure is swallowed:
  `out=$( real_work 2>/dev/null ) || out=""`.
- The captured output is checked for blocking control keys before it is printed, and
  `emit_context` checks the **raw** text before escaping — after escaping, every `"` has
  become `\"` and a guard written with literal quotes can never fire.
- CI greps the tree for those control-key strings and for a literal status-2 exit. This is
  why the docs describe them in prose rather than quoting them: a code fence would fail CI.

## Why one hooks file, where `claude-timestamps` has two

That plugin splits its hooks across two files because an unrecognised event key disables
**every** hook in the file that contains it, and it depends on `MessageDisplay`, which is
accepted by the CLI but undocumented. The split is a blast radius.

This plugin uses `UserPromptSubmit` and `SessionStart` only. Both are documented and
supported everywhere, so there is nothing to quarantine. If you ever add an undocumented
event here, give it its own file — and read that plugin's DESIGN.md first.

There is a second reason not to name `hooks/hooks.json` in `plugin.json`: **the CLI loads
`hooks/hooks.json` automatically**, and a manifest that also references it is rejected —
"Duplicate hooks file detected", and the plugin's status becomes "failed to load". The
`hooks` array is for *additional* hook files only, so a plugin with exactly one hooks file
omits the key entirely. Verified on CLI 2.1.239 and on the CLI bundled in the desktop app,
both of which carry the check.

That error is louder than its consequences. Measured on 2026-09-04 against the sibling
`claude-timestamps` plugin, hooks in a "failed to load" plugin still fired normally — both
the auto-loaded file and the manifest-referenced one — and its slash command stayed
available. So this is a correctness and hygiene fix, not an outage: do not diagnose a
silent plugin by assuming this error caused it.

`claude plugin list` is the only place it shows up; `claude plugin validate --strict`
passes either way, so validation is not enough on its own.

## Why the payload is shrunk before it is parsed

`${var#*pat}` and `${var%%pat*}` are quadratic in the length of the subject string. The
`UserPromptSubmit` payload carries the entire user prompt, and JSON key order is not
guaranteed, so `cwd` may well sit behind it. Above 1 KB the payload is therefore projected
down to the four short fields the hooks read — with `jq` when it is installed, by truncation
when it is not — before any parameter expansion touches it. A 256 KB prompt costs about
16 ms against a 5-second timeout; without the projection it runs past the timeout, and a
hook the host kills produces no tag and no error.

## Validating the manifests

Both manifests live in `.claude-plugin/`, so the obvious command validates the wrong one:

```
claude plugin validate . --strict                           # marketplace.json only
claude plugin validate .claude-plugin/plugin.json --strict   # plugin.json
```

The directory form resolves to `marketplace.json` and prints "Validating marketplace
manifest"; it never opens `plugin.json`. The two invocations are not redundant. CI runs
both.
