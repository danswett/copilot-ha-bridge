# AI coding agent ⇄ Home Assistant bridge

[![CI](https://github.com/danswett/copilot-ha-bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/danswett/copilot-ha-bridge/actions/workflows/ci.yml)
[![CodeQL](https://github.com/danswett/copilot-ha-bridge/actions/workflows/codeql.yml/badge.svg)](https://github.com/danswett/copilot-ha-bridge/actions/workflows/codeql.yml)

Answer your AI coding agent from Home Assistant — or from your terminal — whichever you
happen to be looking at. Works with **GitHub Copilot CLI**, **Claude Code**, **OpenAI
Codex CLI**, and any **MCP client**.

Every live session gets its own card on a Home Assistant dashboard showing what it's
doing, what it just said, and what it's waiting on. When the agent asks a question, the
card grows the matching controls. Whatever you pick is typed into the real terminal
prompt, so the terminal never stops working and nothing is ever answered twice.

> **Windows only** for the terminal integration. Answers are delivered into the running
> CLI with `AttachConsole` + `WriteConsoleInput`, which is Win32-specific. Everything
> else is portable — and the [MCP server](mcp/) needs no console injection at all, so
> it runs on any OS.

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
| **Launch a session** | Pick a workspace, type an opening prompt, press a button — a new CLI session opens on your desktop. |
| **No polling** | State changes arrive over a Home Assistant WebSocket subscription. |

The card glows **blue** while working, **amber** while waiting on you, and not at all
when idle.

---

## Supported clients

| Client | Support |
|---|---|
| **GitHub Copilot CLI** — the origin | The full experience: decisions, live activity, chain-of-thought, multi-field forms, and reply-after-the-turn. Set up by [`install.ps1`](#install). |
| **Claude Code** | The full stack too — the same four primitives, the same card. See [`claude/`](claude/). |
| **OpenAI Codex CLI** | Cards, live activity, command approvals, and the reasoning summary; replies are delivered back into the session. See [`codex/`](codex/). |
| **Any MCP client** — Claude Desktop, ChatGPT, … | The *ask* half only, on any OS: a Home Assistant card races the app's own prompt and cancels whichever loses. Installable from the picker (`-Clients mcp`). See [`mcp/`](mcp/). |

The Windows daemon, dashboard, and Home Assistant plumbing are shared; each client is
just a thin adapter onto them. The installer sets up the shared layer, then asks which
clients to configure — Copilot CLI, Claude Code, Codex CLI, and the MCP server
(detecting what you have). The MCP option installs the Node server and writes a
paste-ready client config (and registers Claude Desktop automatically if it's there),
since MCP clients point at a server rather than loading a hook.

---

## How it works

```
Your AI CLI ──hooks──► bridge scripts ──REST/WS──► Home Assistant
     ▲                                                   │
     └────── console injection ◄─── bridge daemon ◄───────┘
                                    (tails transcripts,
                                     watches entities)
```

The example below is the Copilot CLI path; Claude Code, Codex CLI, and the MCP server
each fill the same three roles — intercept a prompt, stream activity, deliver an answer
— through their own thin adapter.

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
* At least one supported client. The installer asks which of
  **[GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/use-copilot-agents/use-copilot-cli)**,
  **Claude Code**, **Codex CLI** and the **MCP server** to configure (detecting what
  you have). MCP additionally needs **Node.js**, and works with any MCP client
  ([`mcp/`](mcp/))
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

It then asks **which clients to configure** — Copilot CLI, Claude Code, Codex CLI, and
the MCP server — pre-selecting the ones it detects. The shared daemon, dashboard and
Home Assistant plumbing are installed either way; the choice only decides which
adapters get set up. Pick them non-interactively with `-Clients`:

```powershell
.\install.ps1 -Clients copilot,claude,mcp
```

Your selection is remembered, so a re-run or a self-update reconfigures the same set.
Choosing **mcp** installs the Node server, writes a paste-ready client config to
`~/.copilot/mcp/mcp-client-config.json`, and registers Claude Desktop automatically if
it's present; other MCP clients (Cursor, ChatGPT) use the snippet — see
[`mcp/README.md`](mcp/README.md).

It also registers in **Apps & features**, so it uninstalls like any other program. No
installer executable, no admin rights, and no SmartScreen warning.

If you already know the details, skip the prompts entirely:

```powershell
.\install.ps1 -HomeAssistantUrl http://homeassistant.local:8123 -Token 'eyJ...'
```

Then `/restart` any running Copilot sessions so they pick up the hooks, and open the
**Agent Sessions** dashboard in Home Assistant.

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
| `newSession.enabled` | Set to `false` to hide the "Start a new session" controls (default `true`) |
| `newSession.launcher` | `auto` (default: Agency when installed), `agency`, or `copilot` |
| `newSession.profiles` | Agency profiles offered on the dashboard (default `["work","home","local"]`) |
| `newSession.defaultProfile` | Profile preselected on the card (default: the first in `profiles`) |
| `newSession.defaultWorkspace` | Workspace label preselected on the card (default: the first in `workspaces`) |
| `newSession.workspaces` | Directories offered as launch targets — a path string, or `{ "label": …, "path": … }` |
| `newSession.resumeCount` | How many recent sessions the Resume dropdown offers (default `12`) |
| `newSession.model` | Model for launched sessions (default: whatever the CLI would pick) |
| `newSession.allowAllTools` | Add `--allow-all-tools` to launched sessions (default `false`) |
| `newSession.extraArgs` | Extra CLI arguments for launched sessions, e.g. `["--plan"]` |
| `newSession.copilotPath` | Full path to `copilot.exe` if it is not on the daemon's PATH |
| `newSession.agencyPath` | Full path to `agency.exe` if it is not on the daemon's PATH |
| `updates.repository` | Repository to check for releases (default `danswett/copilot-ha-bridge`) |
| `updates.checkForUpdates` | Set to `false` to disable the update check |
| `updates.checkHours` | How often to check GitHub for a release (default `6`, i.e. 4×/day) |

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
| New-session controls (`text`, `select`, `button`, `sensor`) | MQTT discovery, on the same bridge-level device as the update entity |
| `input_boolean.copilot_cli_live_verbose` | Created by the daemon at startup via the helper API |
| The **Agent Sessions** dashboard (`copilot-decisions`) | Regenerated by the daemon whenever the live session set changes |

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

## Starting a session from the dashboard

Everything else in the bridge attaches to sessions you already started at a keyboard.
The **Start a new session** card opens one — or reopens an old one.

Both selectors carry a default, so the whole thing is one button press: open the card,
press **Launch**. Nothing has to be filled in first.

| Row | What it does |
|---|---|
| **Resume** | `New session` (the default), or one of your recent resumable sessions |
| **Workspace** | Where a new session starts. Ignored for a resume, which reopens in its own folder |
| **Profile** | The Agency profile, applied to new and resumed sessions alike |
| **Launch** | Starts it |
| **Last launch** | What the previous press actually did |
| **Opening prompt** | Optional. A first instruction, if you want one |

A session opens in its own console window on the desktop, which the daemon then adopts
like any other — it gets the usual card, activity stream, reply box and decision
prompts. Because the window is real and visible, you can also walk over and take the
session over at the keyboard.

### Resuming

The list comes from `agency hub list-local-sessions`, which is the only thing that
knows about every session on the machine and which of them can actually be resumed —
desktop-app and VS Code sessions cannot. That call reads hundreds of sessions and takes
over a second, so the daemon caches it (`newSession.resumeCount` controls how many are
offered) and refreshes it on a timer rather than on every reconcile.

Sessions that are currently live are never offered, because two CLIs writing one
transcript would corrupt it. A resume reopens in the folder the session originally ran
in; the Workspace row only applies to a new session.

### Agency

On a machine with [Agency](https://aka.ms/agency), sessions launch through
`agency copilot` by default, so they match what you get launching by hand. That matters
more than it sounds: Agency's `--profile-only` makes the named profile the *whole*
configuration and ignores ambient MCP sources like `~/.copilot/mcp-config.json`, so a
session gets the curated set of MCP servers and plugins for that profile rather than
every server on the machine.

Because the same directory is routinely opened under different profiles, the profile is
its own dropdown rather than a property of the workspace. Set `newSession.launcher` to
`copilot` to bypass Agency entirely; the profile and resume rows then disappear from
the card.

Agency takes `--session-id` itself and uses that UUID for both its own session and the
underlying Copilot one, so the daemon still knows the session id before the process
starts either way.

Configure the workspace list first, or the card has nothing to offer:

```jsonc
"newSession": {
  "workspaces": [
    { "label": "Bridge", "path": "~/repos/copilot-ha-bridge" },
    "~/repos/my-app"
  ]
}
```

A few deliberate choices:

- **Only listed directories can be launched.** The dropdown sends a *label*, and the
  daemon resolves that label against this list. A path typed or injected anywhere else
  is never executed, so the config file — not Home Assistant — decides where a session
  may start.
- **Tools are not auto-approved.** Launched sessions get no `--allow-all-tools` unless
  you set `newSession.allowAllTools`. Permission prompts already route to Home
  Assistant, so an unattended session still asks before it acts.
- **Launch is a button, not the text box.** Home Assistant commits a text entity as soon
  as it loses focus, so acting on the typed value alone would spawn a session the moment
  you clicked away.
- **The opening prompt is capped at 255 characters**, the Home Assistant limit for an
  MQTT `text` entity. Launch with a short prompt and continue in the reply box.

The **Last launch** row reports what happened. It confirms success only once the new
session has actually registered itself, not merely when a process started.

---

## Updating

The daemon asks GitHub for the newest release a few times a day (every 6 hours by
default, tunable via `updates.checkHours`) and publishes the result as
a Home Assistant **update entity**, so a new version shows up on the dashboard and in
Home Assistant's own Updates list — with the release notes and a one-press **Install
now** button. Pressing it shows a spinner while the install runs and leaves a
notification when it finishes — *Bridge updated to X*, or the error if it failed —
then restarts the daemon so the new version is actually running.

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
.\tests\test-bridge-adapter.ps1   # shared adapter orchestration (entities, status, notifications)
.\tests\test-dashboard.ps1        # generated dashboard: title, view, session summary + version
.\tests\test-security.ps1         # template injection, path and topic safety, token handling
.\tests\test-reliability.ps1      # request budget, StrictMode safety, stale-state pruning
.\tests\test-update.ps1           # version comparison, release cache, failure safety
.\tests\test-update-outcome.ps1   # install spinner + updated/failed notification
.\tests\test-restart-restore.ps1  # a daemon restart restores cards instead of blanking them
.\tests\test-new-session.ps1      # launching a session: argument quoting, the workspace allowlist, press handling
.\tests\test-install-clients.ps1  # installer client selection (‑Clients, persisted, defaults)
.\tests\test-verbose-toggle.ps1   # Live Verbose helper is provisioned without ever resetting it
```

These are plain PowerShell, need no Home Assistant, and run in a couple of seconds.
The Claude adapter and the MCP server have their own suites — see their READMEs.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Cards show `unknown` after a Home Assistant restart | Self-heals within one reconcile (~15 s); the entities are optimistic and have no state to restore. |
| "Entity not found" on a card | The daemon provisions entities on its next pass; check the daemon log. |
| Live Verbose row is unavailable | Home Assistant is still starting: the toggle appears on its own once it finishes. The daemon ensures the helper exists at startup but never recreates it, so its on/off value is preserved across restarts. Restart the daemon and check the log for `verbose toggle ready`. |
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

### Codex CLI — cards, approvals, and reasoning

[`codex/`](codex/) gives OpenAI Codex CLI a card per session showing the prompt, each
command as it runs, and the final reply. Codex's hooks carry all of that directly, so
no transcript reading is needed for activity, and it is the only front end that fires
an explicit `SessionEnd` — cards retire because the session ended, not because a
process vanished. With **Live Verbose** on and `model_reasoning_effort` set, the
rollout is also read for the model's reasoning summary.

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

The installer's picker can set it up for you (`-Clients mcp`): it installs the server
under `~/.copilot/mcp`, runs `npm install`, writes a paste-ready client config, and
registers Claude Desktop automatically if present. Or run
[`mcp/install-mcp.ps1`](mcp/install-mcp.ps1) directly.

It speaks stdio by default, and can also serve over HTTP for clients that can't start
a local process — ChatGPT among them. That listener binds to localhost and requires a
bearer token, and refuses to start on a public interface without one, because the
server holds an unscopable Home Assistant token; reach it remotely through a tunnel
rather than by opening a port.

It is a sibling, not a replacement: an MCP server never sees the transcript and can't
start a turn, so there is no activity streaming and no reply-after-the-turn. See
[`mcp/README.md`](mcp/README.md).

---

## License

MIT — see [LICENSE](LICENSE).
