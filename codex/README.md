# Codex CLI adapter

Brings the bridge to **OpenAI Codex CLI**: each session gets a Home Assistant card
showing what it is doing — the prompt you gave it, the command it is running, the
reply it finished with — and retires itself when the session exits.

## Why Codex is the easiest of the three

Its hooks carry almost everything outright, so unlike the Claude adapter this one
never reads a transcript to know what is happening:

| Event | Payload |
|---|---|
| `SessionStart` | `session_id`, `transcript_path`, `cwd`, `model`, `permission_mode`, `source` |
| `UserPromptSubmit` | + `turn_id`, `prompt` |
| `PreToolUse` | + `tool_name`, `tool_input`, `tool_use_id` |
| `Stop` | + `stop_hook_active`, `last_assistant_message` |
| `SessionEnd` | + `reason` |

Those were captured from real sessions on Codex 0.155.0-alpha.6, not taken from
documentation, and they are saved as fixtures in [`fixtures/`](fixtures/).

Codex is also the only front end that says goodbye. `SessionEnd` means a card retires
because the session ended, not because the daemon noticed a dead process.

## Install

```powershell
.\install.ps1              # the main bridge first, if not already installed
cd codex
.\install-codex.ps1
```

Codex loads third-party hooks from plugins, so the adapter is packaged as one and
registered through a local marketplace — the supported route for a plugin that does
not come from a catalogue. The installer writes the plugin, registers the marketplace,
and installs it.

### Then trust the hooks — this step is not optional

Start Codex once and approve the trust prompt.

**Until you do, Codex skips these hooks in complete silence.** No error, no warning, no
log line. It is indistinguishable from a broken install, and it cost hours to diagnose
the first time. If the bridge seems to do nothing at all, this is the first thing to
check:

```powershell
# Trusted hooks appear here, one per event.
Select-String -Path $env:USERPROFILE\.codex\config.toml -Pattern 'hooks.state."copilot-ha-bridge'
```

Re-running the installer preserves trust, because the hash covers the hook command
rather than the script contents — so you can update the adapter without re-approving.

## Gotchas worth knowing

- **Hook commands must not be shell-quoted.** A quoted executable path fails with
  `hook exited with code 1`; the same command unquoted runs fine. The installer
  resolves `pwsh` from `PATH` for exactly this reason, and warns if the install path
  contains a space.
- **`SessionEnd` is clamped to three seconds.** Codex says so on every run
  (`warning: clamping SessionEnd hook timeout to 3s`). That is not enough time to
  retire a session's Home Assistant entities, and a teardown cut off halfway leaves a
  card behind — which is what happened before the work was moved. `SessionEnd` now
  only marks the registration locally, and the daemon retires the entities on its next
  reconcile, where there is time to do it properly.
- **A session killed outright never fires `SessionEnd`.** The daemon retires it when
  its process disappears, and the registration is pruned on the same basis.
- **Approval markers share the state directory with registrations** and also end in
  `.json`, so the registration reader skips them explicitly. Without that they were
  parsed as registrations and the missing fields threw under StrictMode, which took
  down the daemon's entire reconcile rather than just this adapter.

## What works, and what does not yet

Verified live against Home Assistant: the card appears on `SessionStart`, tracks the
prompt and each tool call through the turn, shows the final reply, and is retired
when the session ends — confirmed in the daemon log as `dashboard rebuilt for 3
session(s)` followed by `retired session`.

**Approving commands from Home Assistant works.** Codex runs `PermissionRequest`
before showing its own approval UI, and a hook that writes nothing to stdout reads as
"no decision", so the terminal prompt still appears. The dashboard is therefore a
second way to answer rather than a replacement, and whichever is used first wins —
the same arrangement Copilot's `ask_user` uses.

Verified end to end: Codex asked to run a command outside its sandbox, the card armed
showing that exact command, approving on the dashboard delivered the answer into the
session, and the command ran.

Note that `PermissionRequest` only fires in an interactive session. `codex exec`
reports `approval: never` regardless of `approval_policy`, because it has no way to
ask.

**Chain-of-thought is wired but unproven.** The reducer reads the rollout transcript
for `Reasoning` items, gated on the same **Live Verbose** toggle as the other
adapters. It is written to the contract in codex-rs — `ThreadItemDetails` declares a
`Reasoning` variant holding `{ text }` — and covered by tests.

It has never produced anything, because no model has been observed emitting one:
across 26 real rollouts, including runs with `model_reasoning_effort=high` and
`model_reasoning_summary=detailed`, only `AgentMessage`, `UserMessage` and
`CommandExecution` ever appeared. If reasoning starts being emitted it will show up;
until then the card is unchanged. The distinction between *implemented* and
*observed* is deliberate, and the test suite says so too.

## Tests

```powershell
.\tests\test-codex.ps1
```

Covers hook parsing against the real captured payloads, session naming, path safety,
approval markers, and the rollout reducer. Needs no Home Assistant and no Codex
session.

## Uninstall

```powershell
.\install-codex.ps1 -Uninstall
```

Removes the plugin, the marketplace registration and the adapter. Trust entries under
`[hooks.state]` are left alone; they are harmless and Codex prunes them itself.
