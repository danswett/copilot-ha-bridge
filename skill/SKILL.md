# Decision Notifier

Use this skill whenever work cannot continue without user input.

## Required workflow

1. Complete all independent work before interrupting the user.
2. Form one concise question with explicit choices when possible.
3. Use `ask_user` for the actual response. Never ask the question only in normal
   response text.
4. The bridge handles delivery automatically — there is nothing extra to call. Do
   **not** send a separate Home Assistant notification for the same question.

## What the bridge does

Every live CLI session gets its own set of Home Assistant entities, published through
MQTT discovery as one per-session device: a `select` for a decision, a `text` for a
reply, `sensor`s for status and activity, and a `button` to submit. Entities are
created on demand and cleared when the session exits. There is no fixed slot pool.

**When you call `ask_user`,** the `preToolUse` hook (`route-ask-user-v3.ps1`) arms this
session's card with the question and its choices, then returns immediately. The native
terminal prompt stays live, so the user can answer in **either** place:

- **Terminal** — answer normally. The card clears on its own.
- **Home Assistant** — pick the options and press Send. The daemon types the answer
  into the session's console, and the terminal prompt resolves exactly as if the user
  had typed it.

The transcript is the authority on which happened: a `tool.execution_start` for
`ask_user` paired with its `tool.execution_complete` is the definitive "answered"
signal, whichever input produced it. The two paths therefore cannot both fire.

**Between questions,** the daemon streams each session's activity to its card, and the
**Reply** box is always available — so the user can continue a conversation from the
dashboard even after a turn has finished.

## Question shapes

Two `ask_user` argument shapes are supported. Current builds pass **`message`** plus a
**`requestedSchema`** JSON-Schema form; older builds passed `question` plus a flat
`choices` array. The option list is derived from `requestedSchema.properties`,
handling `enum` (with optional `enumNames`), `oneOf: [{const, title}]`, multi-select
`items.enum` / `items.anyOf`, and `type: boolean` (Yes/No).

- A **single-field** form becomes one dropdown.
- A **multi-field** form (up to 4 fields) becomes one dropdown per field plus a Send
  button, so every combination stays reachable without a combinatorial option list.
- Larger forms fall back to freeform, with the question carrying a numbered outline of
  every field and its options, marking any default.

A malformed `ask_user` call is repaired before publishing. When the model fails to
close the tool-call markup, the closing tag and later parameters get swallowed into the
question string; the hook splits at the leak and parses the trailing payload — for both
a leaked `choices` array and a leaked `requestedSchema`, including when either is cut
off mid-write. Real arguments always win over recovered ones.

## Message quality

- Include only the context needed to decide, the exact question, and all choices.
- Put the recommended choice first and label it `(Recommended)`.
- Keep secrets, credentials, raw logs, source code, and unrelated output out of
  notifications.
- Use a title that distinguishes a decision from an informational update.
- Do not notify for routine progress that does not require user action.
- Decision questions are carried in full up to 6,000 characters and each choice up to
  600; anything longer is truncated and the card says so.
- A reply typed into the **Reply** box is capped at 255 characters, because it travels
  through an MQTT `text` entity. Use a decision, or answer in the terminal, for
  anything longer.

## Failure behavior

- A notification failure must not be treated as the user's answer.
- Surface the notification failure in the CLI, then continue with `ask_user`.
- Never silently choose an option solely because the user did not respond.

## Architecture

```
Copilot CLI ──hooks──► bridge scripts ──REST/WS──► Home Assistant
     ▲                                                   │
     └────── console injection ◄─── bridge daemon ◄───────┘
```

All Home Assistant traffic uses a long-lived token. **No MQTT broker credentials are
needed** — entities are published through Home Assistant's own `mqtt.publish` service.

| File | Role |
|---|---|
| `decision-bridge-common.ps1` | Config loader, `ask_user` argument parsing and repair, REST helpers with retry/backoff |
| `decision-mqtt.ps1` | Per-session MQTT discovery: publish, arm/clear a decision, set status and activity, tear down |
| `decision-ha-websocket.ps1` | Entity-registry reads and renames, scoped `subscribe_trigger` waits, dashboard generation |
| `decision-inject.ps1` | `AttachConsole` + `WriteConsoleInput` delivery, with session→pid lookup from `inuse.<pid>.lock` |
| `copilot-bridge-daemon.ps1` | The loop: reconcile sessions, stream activity, sweep orphans, deliver answers |
| `copilot-bridge-supervisor.ps1` | Keeps one daemon alive with backoff; named mutex prevents a second instance |
| `route-ask-user-v3.ps1` | The non-blocking `ask_user` router |
| `notify-agent-response.ps1` | Non-blocking response mirror + card |

Logs: `%TEMP%\copilot-decision-bridge.log` (hooks), `%TEMP%\copilot-bridge-daemon.log`,
`%TEMP%\copilot-bridge-supervisor.log`.

Hook config changes reach a running CLI only after `/restart`. The daemon is shared and
picks up new sessions on its own reconcile — no restart needed for streaming or replies.

### Implementation notes

- The decision `select` and reply `text` are **optimistic** (no state topic) so a tap or
  typed value sticks without a device echo. The cost is that they read `unknown` after a
  Home Assistant restart; the daemon repairs them on its next reconcile.
- Home Assistant derives an MQTT entity id from device name + entity name and ignores
  `object_id`, so the bridge forces deterministic ids with
  `config/entity_registry/update` → `new_entity_id`.
- Waits use a scoped `subscribe_trigger`, **not** a broad `state_changed` subscription —
  the latter floods the CPU.
- The daemon must keep a **real** console for `AttachConsole` to work. It is launched
  hidden via `copilot-bridge-launch.vbs` (`WScript.Shell.Run(..., 0, …)`). Do not switch
  it to `conhost --headless`, which gives a pseudoconsole and breaks injection.

## Tests

- `tests/test-decision-args.ps1` — `ask_user` argument parsing: both argument shapes,
  every `requestedSchema` field type, the multi-field outline, and malformed-markup
  recovery for leaked `choices` and leaked `requestedSchema`.
- `tests/test-decision-retry.ps1` — the HTTP resilience layer: transient-versus-permanent
  classification, retry, fail-fast, retry budget.

Both are plain PowerShell, need no Home Assistant, and run in a couple of seconds. Run
them after any change to `decision-bridge-common.ps1`.
