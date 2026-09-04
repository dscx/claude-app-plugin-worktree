# claude-worktree

A Claude Code conversation never says which tree it is editing. If you keep several
worktrees per repository — one per feature, one per agent, one per half-finished idea —
then two chats look identical while pointing at completely different working copies, and
the only way to tell them apart is to ask.

This plugin puts the answer on the last line of every reply:

```
🟠 atlas ▸ search-rewrite · worktree-search-rewrite
```

Repository, worktree, branch. In the main checkout it says so instead:

```
🟠 atlas ▸ main (root)
```

## Install

From inside Claude Code:

```
/plugin marketplace add dscx/claude-app-plugin-worktree
/plugin install claude-worktree@claude-worktree
```

Or from a shell:

```
claude plugin marketplace add dscx/claude-app-plugin-worktree
claude plugin install claude-worktree@claude-worktree
```

The repository is `claude-app-plugin-worktree` but the plugin and its marketplace are both
named `claude-worktree`, which is why the second command does not repeat the repository
name. To work on the plugin instead, point the marketplace at a local checkout:
`claude plugin marketplace add /path/to/claude-app-plugin-worktree`.

Restart Claude Code afterwards. Hook definitions are read when a session starts, so an
already-running session will not pick up the plugin until it is restarted.

### Updating

The install cache is keyed by the `version` in `.claude-plugin/plugin.json`:
`claude plugin marketplace update claude-worktree` reports success but leaves the installed
copy alone unless that version changed. If you are editing the plugin locally,
`claude plugin uninstall` followed by `claude plugin install` is the only reliable way to
pick your changes up.

## What you'll actually see

The tag is typed by the model, into the body of its own reply, because that is the only
channel that renders everywhere. A `UserPromptSubmit` hook works out the worktree and asks
for the line; the model writes it.

That makes the tag **advisory**. It is a request, and models do not always comply: on a
long turn the model can forget it, reword it, or drop it, and nothing detects that. What
the tag says is exact — it comes from `git`, not from the model's guess — but *whether* it
appears is best-effort.

The alternative was worse. A hook's only deterministic channel for putting text in front of
you is a `Stop` hook's `systemMessage`, and the desktop app collapses that behind a
"Claude Code notice" dropdown. A worktree indicator you have to expand a dropdown to read
is not an indicator. See [DESIGN.md](DESIGN.md) for why the status line, which would be the
obvious home for this, is not available either.

## Configuration

Config lives in a plain `KEY=value` file, one key per line, no quoting or JSON:

```
${CLAUDE_WORKTREE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/claude-worktree}/config.env
```

By default that is `~/.claude/claude-worktree/config.env`, written on first run.

| Key | Values | Default | Meaning |
| --- | --- | --- | --- |
| `MODE` | `inline`, `off` | `inline` | `off` disables the tag entirely without uninstalling the plugin. |
| `PLACE` | `bottom`, `top` | `bottom` | Which end of the reply the tag goes on. |
| `MARK` | `orange`, `yellow`, `warn`, `option`, `none` | `orange` | The leading glyph: 🟠, 🟡, ⚠️, ⌥, or none at all. |
| `FORMAT` | `full`, `short` | `full` | `full` is `🟠 repo ▸ worktree · branch`; `short` is just `🟠 worktree`. |
| `SHOW_BRANCH` | `1`, `0` | `1` | Include the branch. Worth turning off when your worktree names already encode the branch. |
| `ROOT` | `1`, `0` | `1` | Tag the main checkout too. Set `0` and the tag appears **only** when you are in a linked worktree, so its presence is itself the signal. |

Two environment variables matter:

- `CLAUDE_WORKTREE_DIR` — override the whole state directory (config and cache).
- `CLAUDE_CONFIG_DIR` — respected if you have moved your Claude Code config elsewhere.

## What it reports

| Situation | Tag |
| --- | --- |
| Linked worktree | `🟠 atlas ▸ search-rewrite · worktree-search-rewrite` |
| Main checkout | `🟠 atlas ▸ main (root)` |
| Detached HEAD | `🟠 atlas ▸ search-rewrite · detached@b30d649` |
| Not a git repository | nothing at all |

Both kinds of worktree are covered: the ones Claude Code creates under
`<repo>/.claude/worktrees/`, and the ones you made yourself with `git worktree add`
anywhere on disk. The plugin does not care which — it asks git.

It also follows the session. `cd` somewhere else, or enter or leave a worktree mid-session,
and the next turn reports the new tree. Switch branches from another terminal and the next
turn reports the new branch, without re-running git.

## Cost

The steady-state turn forks nothing beyond the `cat` that reads the hook payload —
about 6 ms per turn on the development machine, against a 5-second hook timeout. `git` is
forked exactly once per session, and again only if the working directory changes; the
branch is read straight out of `HEAD`, which is one short line. A 256 KB prompt costs about
16 ms, because the payload is projected down before it is parsed.

## Limitations

- **The tag is model-typed.** See "What you'll actually see". Exact in content, best-effort
  in appearance. Do not build anything on its presence.
- **One tag per turn.** `UserPromptSubmit` fires once per prompt. If the assistant sends
  several messages in a turn, only one is asked to carry the tag.
- **The colour is a glyph, not text.** Markdown has no colour and the desktop app
  sanitises HTML, so `MARK` selects a coloured *character*. There is no way for a hook to
  set the colour of the surrounding text.
- **`PLACE=bottom` competes with anything else that wants the last line.** If you also run
  `claude-timestamps` in `MODE=inline`, it asks for a stamp on the final line too, and the
  two instructions will fight. Put one of them on `top`.
- **Submodules report the submodule.** git's answer for a submodule working tree is the
  submodule, so that is what you get. That is usually what you wanted.
- **Nothing is logged.** The plugin stores one cache line per session — four absolute
  paths, no prompt text, no history — and deletes it after seven days. It never reads the
  transcript.
- **A worktree pruned underneath you** loses its `HEAD` file, and the tag then drops the
  branch rather than inventing one.

## Uninstall

```
/plugin uninstall claude-worktree@claude-worktree
/plugin marketplace remove claude-worktree
```

Then restart Claude Code. State and config are left in place; remove them yourself if you
want them gone:

```
rm -rf ~/.claude/claude-worktree
```

## Licence

MIT. See [LICENSE](LICENSE). Contributor-facing notes on why the plugin is built the way it
is are in [DESIGN.md](DESIGN.md).
