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

ChatGPT needs Developer Mode on a Business/Enterprise/Edu workspace and a reachable
HTTP endpoint; this server speaks stdio, so it would need an HTTP transport first.

## Tests

```bash
HA_BASE_URL=http://homeassistant.local:8123 HA_TOKEN=eyJ... npm test
```

A real MCP client drives a real server against a real Home Assistant and checks both
halves of the race: the app answering, and Home Assistant answering while the app's
prompt gets cancelled. `node test/sweep.js` clears any entities left by an
interrupted run.

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
