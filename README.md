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
| **Start a conversation** | A session appears as soon as it opens, so you can send it its first prompt from the dashboard. |
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

The one-liner:

```powershell
irm https://raw.githubusercontent.com/danswett/copilot-ha-bridge/main/bootstrap.ps1 | iex
```

Or from a clone:

```powershell
git clone https://github.com/danswett/copilot-ha-bridge.git
cd copilot-ha-bridge
.\install.ps1
```

With no arguments the installer finds Home Assistant for you: it probes
`homeassistant.local:8123` (the hostname Home Assistant publishes over mDNS, which
Windows resolves natively) and confirms the product from its unauthenticated
`manifest.json`. You confirm or correct the URL, then it walks you through creating a
long-lived token and pastes straight into the config.

It also registers in **Apps & features**, so it uninstalls like any other program. No
installer executable, no admin rights, and no SmartScreen warning.

If you already know the details, skip the prompts entirely:

```powershell
.\install.ps1 -HomeAssistantUrl http://homeassistant.local:8123 -Token 'eyJ...'
```

Then `/restart` any running Copilot sessions so they pick up the hooks, and open the
**Copilot Decisions** dashboard in Home Assistant.

Optional out-of-band push when a session needs you:

```powershell
.\install.ps1 -NotifyService notify.mobile_app_pixel
```

The installer is idempotent — re-run it to upgrade in place. Re-running with only
some arguments keeps the rest of your settings, and the previous config is backed up
to `copilot-ha-bridge.config.json.bak` first.

It is **not interactive** when you pass `-NonInteractive`, which is what you want in a
script; otherwise it prompts for anything missing. Before finishing it verifies the URL
and token against `/api/` and checks that `mqtt.publish` exists, so a misconfigured
install fails immediately instead of silently doing nothing later. Use `-SkipVerify`
for an offline install, or when the token comes from an environment variable that isn't
set yet.

To try a build without touching a working install, point it at a sandbox:

```powershell
.\install.ps1 -HomeAssistantUrl http://ha.example:8123 -Token test `
              -TargetHome $env:TEMP\bridge-sandbox -SkipTask -SkipVerify
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
| `updates.repository` | Repository to check for releases (default `danswett/copilot-ha-bridge`) |
| `updates.checkForUpdates` | Set to `false` to disable the daily update check |

Prefer keeping the token out of a file? Leave `token` empty and set `COPILOT_HA_TOKEN`
in your environment.

---

## Home Assistant setup

There is **no config flow** — the bridge is a set of Windows-side scripts, not a Home
Assistant integration, so it never appears under *Settings → Devices & Services*. It
authenticates with a long-lived token and provisions everything itself:

| Object | How it appears |
|---|---|
| Per-session entities (`select`, `text`, `sensor`, `button`) | MQTT discovery, created on demand and removed when the session exits |
| `sensor.copilot_cli_sessions` | MQTT discovery, published by the daemon |
| `input_boolean.copilot_cli_live_verbose` | Created by the daemon at startup via the helper API |
| The `copilot-decisions` dashboard | Regenerated by the daemon whenever the live session set changes |

### There is no MQTT broker to configure

The bridge **never connects to your broker** — no host, port, or credentials anywhere.
It has no MQTT client at all. Every entity is published by calling Home Assistant's own
`mqtt.publish` service over the REST API, so Home Assistant owns the broker connection
and the bridge only ever needs its token.

That means the MQTT integration is the one prerequisite it cannot provision itself. The
installer checks for it and warns if `mqtt.publish` is missing. Nothing goes in
`configuration.yaml`.

`uninstall.ps1 -ClearEntities` reverses all of it, including the helper and the
dashboard view.

---

## Updating

The daemon asks GitHub for the newest release once a day and publishes the result as
a Home Assistant **update entity**, so a new version shows up on the dashboard and in
Home Assistant's own Updates list — with the release notes and a one-press **Install
now** button.

From a terminal:

```powershell
.\update.ps1 -Check     # report what's available
.\update.ps1            # install it, after confirming
```

Either way your configuration is preserved: the installer reads the existing config,
backs it up, and keeps your URL, token and settings.

**Nothing updates itself.** The check is passive and installing is always a deliberate
action, because this software types into terminals and registers scheduled tasks. Set
`updates.checkForUpdates` to `false` to turn the check off entirely, or point
`updates.repository` at your own fork.

---

## Uninstall

From **Settings → Apps → Installed apps**, or:

```powershell
.\uninstall.ps1 -ClearEntities
```

`-ClearEntities` clears the retained MQTT discovery topics, the Live Verbose helper and
the dashboard view, so Home Assistant is left clean; without it they linger.
`-KeepConfig` preserves your settings.

---

## Tests

```powershell
.\tests\test-decision-args.ps1    # ask_user argument parsing and recovery
.\tests\test-decision-retry.ps1   # HTTP retry / transient-failure classification
.\tests\test-security.ps1         # template injection, path and topic safety, token handling
.\tests\test-reliability.ps1      # request budget, StrictMode safety, stale-state pruning
.\tests\test-update.ps1           # version comparison, release cache, failure safety
```

Both are plain PowerShell, need no Home Assistant, and run in a couple of seconds.
The Claude adapter and the MCP server have their own suites — see their READMEs.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Cards show `unknown` after a Home Assistant restart | Self-heals within one reconcile (~15 s); the entities are optimistic and have no state to restore. |
| "Entity not found" on a card | The daemon provisions entities on its next pass; check the daemon log. |
| Live Verbose row is unavailable | The daemon creates `input_boolean.copilot_cli_live_verbose` at startup and repairs it if it loses its state. Restart the daemon and check the log for `verbose toggle ready`. |
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
* **Hooks never wait on a missing Home Assistant.** Each one probes first and skips its
  Home Assistant work if the host doesn't answer within about a second, so an outage
  costs a moment rather than the tens of seconds the retry layer would otherwise spend.
  The question is still recorded locally and the daemon arms the card once Home
  Assistant is reachable again.
* **Session names are treated as untrusted.** A Copilot session is named after its task
  and a Claude session after its working directory, so template syntax in either is
  neutralised before it reaches a card — otherwise a folder called `{{ ... }}` would be
  evaluated by Home Assistant.
* **Use HTTPS if you can.** A long-lived token is sent on every request, so over plain
  HTTP it crosses your network in the clear. The installer warns about this.
* The daemon idles at a few percent of one core and reconciles every ~15 s, with
  WebSocket pushes for anything latency-sensitive.

---

## Other clients

### Claude Code — full support

[`claude/`](claude/) adds the same experience to Claude Code: live activity,
chain-of-thought, a reply box that types into the real terminal, and a card when it
needs you. Claude Code exposes the same four primitives this bridge is built on —
`PreToolUse` with a matcher, a `Stop` hook, JSONL transcripts, and a real console — so
it gets the full stack rather than a subset.

```powershell
cd claude
.\install-claude.ps1
```

See [`claude/README.md`](claude/README.md), which states exactly what is verified
against a live session and what is not.

### Codex CLI — session cards and live activity

[`codex/`](codex/) gives OpenAI Codex CLI a card per session showing the prompt, each
command as it runs, and the final reply. Codex's hooks carry all of that directly, so
no transcript reading is needed, and it is the only front end that fires an explicit
`SessionEnd` — cards retire because the session ended, not because a process vanished.

```powershell
cd codex
.\install-codex.ps1
```

Commands awaiting approval appear on the card and can be approved or denied from
Home Assistant, while the terminal prompt stays usable. See
[`codex/README.md`](codex/README.md) — and note the hooks must be **trusted once** in
Codex or they are skipped silently.

### Anything else, via MCP (experimental)

[`mcp/`](mcp/) holds a separate MCP server that brings the *ask* half of this to
Claude Desktop and other MCP clients, on any OS. It races a Home Assistant card
against the app's own elicitation prompt and cancels whichever loses.

It is a sibling, not a replacement: an MCP server never sees the transcript and can't
start a turn, so there is no activity streaming and no reply-after-the-turn. See
[`mcp/README.md`](mcp/README.md).

---

## License

MIT — see [LICENSE](LICENSE).
