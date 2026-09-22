# Copilot CLI ⇄ Home Assistant bridge

Answer GitHub Copilot CLI prompts from Home Assistant — or from your terminal —
whichever you happen to be looking at.

Every live CLI session gets its own card on a Home Assistant dashboard showing what
it's doing, what it just said, and what it's waiting on. When Copilot asks a question,
the card grows the matching controls. Whatever you pick is typed into the real
terminal prompt, so the terminal never stops working and nothing is ever answered
twice.

> **Windows only.** Answers are delivered into the running CLI with `AttachConsole` +
> `WriteConsoleInput`, which is Win32-specific. Everything else is portable, but that
> part is the point of the project.

---

## What you get

| | |
|---|---|
| **Dual input** | Answer in the terminal *or* Home Assistant. First one wins; the other clears. |
| **Live activity** | Each session streams its status, current tool, and last response to its card. |
| **Chain-of-thought** | A dashboard toggle streams the model's reasoning into an expander. |
| **Real forms** | Multi-field questions become one dropdown per field plus a Send button. |
| **Continuation** | Reply to a finished turn from your phone; it's typed into the session. |
| **No polling** | State changes arrive over a Home Assistant WebSocket subscription. |

The card glows **blue** while working, **amber** while waiting on you, and not at all
when idle.

---

## How it works

```
Copilot CLI ──hooks──► bridge scripts ──REST/WS──► Home Assistant
     ▲                                                   │
     └────── console injection ◄─── bridge daemon ◄───────┘
                                    (tails transcripts,
                                     watches entities)
```

* **`route-ask-user-v3.ps1`** (`preToolUse`) arms the session's card when Copilot calls
  `ask_user`, then returns immediately. It does **not** block, so the native terminal
  prompt stays live.
* **The daemon** tails every session's transcript for activity, publishes it to Home
  Assistant, and watches the cards. When you answer on a card, it types that answer
  into the session's console.
* **The transcript is the source of truth.** A `tool.execution_start` for `ask_user`
  paired with its matching `tool.execution_complete` is the authoritative "answered"
  signal, whichever input produced it — so the two paths can't collide.

Entities are created on demand per session through **MQTT discovery**, published via
Home Assistant's own `mqtt.publish` service. **No MQTT broker credentials are needed** —
only a Home Assistant token.

---

## Requirements

* Windows 10/11 and **PowerShell 7+**
* [GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/use-copilot-agents/use-copilot-cli)
* Home Assistant with the **MQTT integration** configured (any broker)
* A Home Assistant **long-lived access token**
* These HACS frontend cards:
  [`card-mod`](https://github.com/thomasloven/lovelace-card-mod),
  [`button-card`](https://github.com/custom-cards/button-card),
  [`layout-card`](https://github.com/thomasloven/lovelace-layout-card)

---

## Install

```powershell
git clone https://github.com/<you>/copilot-ha-bridge.git
cd copilot-ha-bridge
.\install.ps1 -HomeAssistantUrl http://homeassistant.local:8123 -Token 'eyJ...'
```

Then `/restart` any running Copilot sessions so they pick up the hooks, and open the
**Copilot Decisions** dashboard in Home Assistant.

Optional out-of-band push when a session needs you:

```powershell
.\install.ps1 -HomeAssistantUrl http://ha.lan:8123 -Token 'eyJ...' `
              -NotifyService notify.mobile_app_pixel
```

The installer is idempotent — re-run it to upgrade in place. Re-running with only
some arguments keeps the rest of your settings, and the previous config is backed up
to `copilot-ha-bridge.config.json.bak` first.

To try a build without touching a working install, point it at a sandbox:

```powershell
.\install.ps1 -HomeAssistantUrl http://ha.example:8123 -Token test `
              -TargetHome $env:TEMP\bridge-sandbox -SkipTask
```

### Configuration

Settings live in `~/.copilot/copilot-ha-bridge.config.json` (written by the installer,
never in the repo). See [`config.example.json`](config.example.json).

| Key | Meaning |
|---|---|
| `homeAssistant.baseUrl` | e.g. `http://homeassistant.local:8123` |
| `homeAssistant.token` | Long-lived access token |
| `homeAssistant.tokenEnvVar` | Read the token from this env var instead (default `COPILOT_HA_TOKEN`) |
| `dashboard.urlPath` | Lovelace dashboard slug (default `copilot-decisions`) |
| `notifications.enabled` / `.service` | Optional notify-style service |
| `copilot.sessionStateRoot` | Override session-state location if not `~/.copilot/session-state` |

Prefer keeping the token out of a file? Leave `token` empty and set `COPILOT_HA_TOKEN`
in your environment.

---

## Uninstall

```powershell
.\uninstall.ps1 -ClearEntities
```

`-ClearEntities` clears the retained MQTT discovery topics so Home Assistant drops the
bridge's entities; without it they linger. `-KeepConfig` preserves your settings.

---

## Tests

```powershell
.\tests\test-decision-args.ps1    # ask_user argument parsing and recovery
.\tests\test-decision-retry.ps1   # HTTP retry / transient-failure classification
```

Both are plain PowerShell, need no Home Assistant, and run in a couple of seconds.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Cards show `unknown` after a Home Assistant restart | Self-heals within one reconcile (~15 s); the entities are optimistic and have no state to restore. |
| "Entity not found" on a card | The daemon provisions entities on its next pass; check the daemon log. |
| Answers picked in Home Assistant do nothing | The session predates the install — `/restart` it. |
| Nothing at all happens | Check `$env:TEMP\copilot-bridge-daemon.log` and `copilot-decision-bridge.log`. |

The daemon runs as the hidden scheduled task `CopilotBridgeDaemon`:

```powershell
Get-ScheduledTask -TaskName CopilotBridgeDaemon
Get-Content $env:TEMP\copilot-bridge-daemon.log -Tail 20
```

---

## Notes and limitations

* **Enter doesn't send a reply.** Home Assistant commits a text entity on the `change`
  event, which fires identically for Enter and for clicking away — they can't be told
  apart, so replies are sent with the Send button instead.
* **Reply length is capped at 255 characters** by Home Assistant's `text` entity.
  Use the terminal for longer answers.
* **Multi-field questions cap at 4 fields**; larger forms fall back to a text outline.
* The daemon idles at a few percent of one core and reconciles every ~15 s, with
  WebSocket pushes for anything latency-sensitive.

---

## License

MIT — see [LICENSE](LICENSE).
