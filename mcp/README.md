# MCP server (experimental)

A second, portable way in: an MCP server that mirrors a prompt to Home Assistant so
you can answer it **either in the app or on your dashboard**, whichever you reach
first.

This is a **sibling** of the Copilot CLI bridge, not a replacement. It shares the
Home Assistant instance and nothing else — different entity namespace (`mcp_` vs
`copilot_`), separate process, no hooks, no daemon.

## Why it exists, and what it can't do

The CLI bridge works by intercepting `ask_user` with a hook, tailing the transcript,
and typing answers into the console. None of that exists in Claude Desktop or ChatGPT.
MCP gives one real hook — **elicitation** — and the server builds on it.

| | CLI bridge | MCP server |
|---|---|---|
| Runs on | Windows only | macOS, Linux, Windows |
| Catches every prompt | Yes, via hook | **No** — the model must choose the tool |
| Live activity + reasoning | Yes | **No** — a server never sees the transcript |
| Reply after a turn ends | Yes | **No** — a server can't start a user turn |
| Dual input | Console injection | Protocol-level race with cancellation |

So: **better plumbing, smaller feature set.** Use it where hooks don't exist.

### What about Claude Code?

Claude Code is a terminal CLI and exposes the same four primitives this project
relies on — `PreToolUse` hooks with a matcher (so `AskUserQuestion` can be
intercepted), a `Stop` hook for turn boundaries, JSONL session transcripts under
`~/.claude/projects/`, and a real console to inject into. It could therefore support
the **full** feature set rather than the MCP subset.

That port is not built yet. It needs a hook-config translation, a parser for Claude's
transcript schema, and a new session→pid lookup (Copilot's `inuse.<pid>.lock` has no
equivalent). Until then, Claude Code gets the MCP subset like any other client.

## How the race works

On a tool call the server simultaneously arms a Home Assistant card and sends
`elicitation/create` to the app, then takes the first answer and cancels the other.
Because cancellation is part of the protocol, there is no second input path to
reconcile and no OS-specific code.

## Setup

```bash
cd mcp
npm install
```

Claude Desktop — add to `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "home-assistant-bridge": {
      "command": "node",
      "args": ["C:\\path\\to\\copilot-ha-bridge\\mcp\\src\\server.js"],
      "env": {
        "HA_BASE_URL": "http://homeassistant.local:8123",
        "HA_TOKEN": "eyJ..."
      }
    }
  }
}
```

| Variable | Meaning |
|---|---|
| `HA_BASE_URL` | Home Assistant base URL (required) |
| `HA_TOKEN` | Long-lived access token (required) |
| `HA_CARD_TITLE` | Device name for the card (default `Copilot MCP`) |
| `HA_TIMEOUT_MS` | How long to wait for an answer (default 30 min) |
| `HA_DASHBOARD` | Fallback dashboard when the daemon is absent (default `copilot-mcp`; set to empty to manage cards yourself) |

## Remote clients (HTTP transport)

By default the server speaks **stdio**: the application starts it, nothing listens on
a port, and there is nothing to attack. Clients that can't start a local process —
ChatGPT being the obvious one — need HTTP instead:

```json
"env": {
  "MCP_TRANSPORT": "http",
  "MCP_HTTP_TOKEN": "a-long-random-string",
  "HA_BASE_URL": "http://homeassistant.local:8123",
  "HA_TOKEN": "eyJ..."
}
```

| Variable | Meaning |
|---|---|
| `MCP_TRANSPORT` | `stdio` (default) or `http` |
| `MCP_HTTP_HOST` | Interface to bind (default `127.0.0.1` — this machine only) |
| `MCP_HTTP_PORT` | Port (default `8808`) |
| `MCP_HTTP_TOKEN` | Bearer token required on every request |
| `MCP_HTTP_PATH` | Endpoint path (default `/mcp`) |
| `MCP_HTTP_ALLOWED_HOSTS` | Extra `Host` header values to accept, comma-separated — needed when a tunnel or reverse proxy is in front |

### Why it is locked down by default

This server holds a Home Assistant **long-lived access token**, and Home Assistant has
no way to scope one: a token that can arm a dashboard card can also unlock a door.
Reaching this endpoint therefore means full control of the Home Assistant instance,
which is a much bigger prize than the MCP tool itself suggests. So:

* it binds **`127.0.0.1`** unless told otherwise, so nothing off the machine can reach
  it;
* every request needs `Authorization: Bearer $MCP_HTTP_TOKEN`, compared in constant
  time;
* it **refuses to start** on a non-local interface with no token, rather than warning
  and carrying on — the one mistake that would expose the token is the one it will not
  let you make;
* DNS-rebinding protection is on, so a web page you visit can't drive it through your
  browser.

### Exposing it deliberately

Don't widen `MCP_HTTP_HOST` to `0.0.0.0` and forward a port. Leave the bind local and
put a tunnel in front of it, so the listener is never directly addressable:

* [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
  — `cloudflared tunnel --url http://127.0.0.1:8808`, ideally behind Cloudflare Access
* [Tailscale Funnel](https://tailscale.com/kb/1223/funnel) — `tailscale funnel 8808`

**A tunnel needs its hostname declared.** DNS-rebinding protection matches the `Host`
header exactly, so traffic arriving as `something.trycloudflare.com` is rejected with
`403 Invalid Host header` until you say otherwise:

```
MCP_HTTP_ALLOWED_HOSTS=something.trycloudflare.com
```

Keep `MCP_HTTP_TOKEN` set: the tunnel provides transport security and a stable
hostname, the token provides authentication, and you want both.

ChatGPT additionally needs **Developer Mode** on a Business, Enterprise or Edu
workspace before it will accept a custom connector.

## Installing only this

The MCP server is entirely self-contained: Node plus those environment variables, and
nothing from the PowerShell side — no `install.ps1`, no daemon, no hooks, no config
file. Everything it needs it creates:

* the per-client entities, on demand, over MQTT discovery
* its own **`copilot-mcp` dashboard**, because the rich `copilot-decisions` view is
  generated by the daemon that an MCP-only user does not have

### One dashboard when the daemon is present

If the PowerShell daemon is installed it owns `copilot-decisions` and renders every
session it can see — including MCP clients, which it discovers from their entities and
draws with a **reduced card**: status, decision and reply only, because those are all
an MCP server can publish. In that case the MCP server creates no dashboard of its
own, so there is one sidebar entry rather than two for what is one feature.

Without the daemon, the MCP server falls back to creating and maintaining
`copilot-mcp` itself, so an MCP-only install still works unchanged. Cards are merged
so several clients coexist, each is withdrawn when its client disconnects, and the
dashboard is removed once the last card goes — an empty dashboard in the sidebar looks
like a fault rather than an idle feature.

## Tests

```bash
HA_BASE_URL=http://homeassistant.local:8123 HA_TOKEN=eyJ... npm test
```

A real MCP client drives a real server against a real Home Assistant and checks both
halves of the race: the app answering, and Home Assistant answering while the app's
prompt gets cancelled. `node test/sweep.js` clears any entities left by an
interrupted run.

The HTTP transport has its own suite, which needs no Home Assistant:

```bash
npm run test:http
```

`test-http.js` asserts the security properties directly — local-bind detection, the
refusal to start unauthenticated on a public interface, and rejection of missing,
wrong and wrong-length tokens. `test-http-e2e.js` then starts `server.js` the way a
user would and drives it with a real MCP client over the network, so the transport is
proven wired in rather than merely importable.

## Notes

- **No broker credentials.** Entities are published through Home Assistant's own
  `mqtt.publish` service, exactly like the PowerShell bridge.
- **Entity ids are forced through the registry.** Home Assistant derives an MQTT
  entity id from device name + entity name and ignores `object_id`, so the server
  renames them to stay predictable.
- **Request id 0 can't be cancelled.** `@modelcontextprotocol/sdk` 1.30.0 has
  `if (!notification.params.requestId) return;` in `Protocol._oncancel`, and `0` is
  falsy — so the first server→client request is never cancellable. Elicitation is
  usually that first request, which would strand a prompt in the app on every
  dashboard answer. The server sends a `ping` at startup to burn id 0.
