# Claude Code adapter

Brings the bridge to **Claude Code**, so a Claude session gets the same Home Assistant
card a Copilot CLI session does: live activity, chain-of-thought, a reply box that
types into the real terminal, and a card when it needs you.

Unlike the [MCP server](../mcp/README.md), which only covers asking, this is the
**full** stack — because Claude Code exposes the same four primitives the Copilot
bridge is built on:

| Need | Copilot CLI | Claude Code |
|---|---|---|
| Intercept a prompt | `preToolUse` hook | `PreToolUse` hook with a matcher |
| Turn boundary | `agentStop` | `Stop` hook |
| Live transcript | `events.jsonl` | JSONL under `~/.claude/projects/` |
| Deliver an answer | console injection | console injection |

## Install

```powershell
.\install.ps1              # the main bridge first, if not already installed
cd claude
.\install-claude.ps1
```

The adapter reuses the main bridge's Home Assistant layer, its daemon and its
dashboard, so that must be installed first. `install-claude.ps1` copies the adapter to
`~/.claude/ha-bridge` and merges three hooks into `~/.claude/settings.json`:

| Hook | Matcher | Purpose |
|---|---|---|
| `PreToolUse` | `AskUserQuestion` | Mirror a multiple-choice question to the dashboard |
| `Notification` | all | Surface "Claude is waiting", including permission prompts |
| `Stop` | all | Mark the turn idle and push the response |

Existing settings and any hooks you added yourself are preserved; re-running is safe,
and `-Uninstall` removes only this bridge's entries. Restart Claude sessions
afterwards; the daemon picks them up on its own.

## What is verified, and what is not

This matters, so it is spelled out rather than implied. Verified against a real,
signed-in Claude Code 2.1.272 on Windows:

| Verified | How |
|---|---|
| Hook payload contract | Captured live: `session_id`, `transcript_path`, `cwd`, `tool_name`, `tool_input`, `permission_mode`, plus `prompt_id`, `effort`, `tool_use_id`, and on `Stop` a `last_assistant_message` |
| `Stop` hook end to end | Fired on real sessions, read the response, marked the card idle |
| Transcript parsing | The reducer was run against a real transcript and produced the right summary, history and `thinking` |
| Console injection | A prompt was typed into a live Claude session and it ran (`ok:298`) |
| Daemon discovery and streaming | A live session was published as its own card and streamed `Running: Grep`, then retired when the process exited |
| Settings schema | `claude doctor` validates hooks; it accepts what the installer writes and rejects a deliberately broken version |

**Not verified:** the `AskUserQuestion` path, because **that tool is not exposed in this
build**. Asked to use it, Claude searched `select:AskUserQuestion` three times and
replied "There's no AskUserQuestion tool available in this environment", and it is
absent from the tool list Claude advertises at startup. It is compiled in — the tool's
description and `CLAUDE_CODE_QUESTION_PREVIEW_FORMAT` are both present in the binary —
just not offered, exactly like `EnterPlanMode`. The handling is built to the contract
embedded in that binary and covered by unit tests, but it has never run against a real
question. `Notification` is what carries attention-needed events in this build, which
is why it is hooked too.

To close that gap the moment the tool appears:

```powershell
.\tests\verify-askuserquestion.ps1
```

It asks Claude which tools it advertises and stops with an explanation if
`AskUserQuestion` is missing (exit 3). If it is present, it drives a real interactive
session, captures the `PreToolUse` payload Claude actually emits, checks every field
against the assumed contract, and runs it through the parser — so a drift in field
names is caught rather than guessed at. Re-run it after any Claude Code upgrade.

**Best-effort:** answering a permission prompt from the reply box. The text is injected
into Claude's own prompt; whether that prompt accepts typed input depends on the prompt.
Knowing a session has stopped, and why, works regardless.

## Tests

```powershell
.\tests\test-claude-ask-parser.ps1     # AskUserQuestion parsing; no Claude or HA needed
.\tests\test-claude-transcript.ps1     # transcript reducer and tailing reader
.\tests\test-claude-integration.ps1    # drives the hooks against a real Home Assistant
.\tests\verify-askuserquestion.ps1     # live AskUserQuestion check, when the tool exists
```

The fixtures in `fixtures/` mirror shapes taken from the shipping tool, including
`transcript-real-shape.jsonl`, whose envelope and noise entry types
(`queue-operation`, `attachment`, `atis-latch`, `last-prompt`, `ai-title`, `system`)
came from a live session.

## Notes

- **Session to pid.** Claude has no `inuse.<pid>.lock`. A hook runs as a descendant of
  its session, so the owning process is found by walking the hook's parent chain to the
  `claude` process — correct even with several sessions open. The result is recorded
  under `%TEMP%\agent-bridge-claude` and is how the daemon knows where to inject.
- **Liveness.** A session is live while its recorded pid is still a running `claude`
  process, which is what retires its entities promptly on exit.
- **Idle.** Claude writes no turn-end transcript entry, so the `Stop` hook is the
  authoritative idle signal; freshness is used only when adopting an already-running
  session.
- **Cards are prefixed `Claude:`** so they are distinguishable from Copilot's on a
  shared dashboard.
- All three hooks write nothing to stdout and always exit 0, so a bridge fault can
  never change how Claude behaves.
