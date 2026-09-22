/**
 * HTTP transport for the MCP server.
 *
 * stdio is the right default: the client starts the server, nothing listens, and
 * there is nothing to secure. This exists for the cases stdio cannot serve - another
 * machine on your network, a container, or ChatGPT, whose backend connects inward and
 * therefore needs a reachable endpoint.
 *
 * The defaults are deliberately timid, because this process holds a Home Assistant
 * long-lived access token and Home Assistant cannot scope one. A leak is control of
 * the whole instance, so:
 *
 *   - it binds to 127.0.0.1 unless told otherwise;
 *   - it refuses to bind anywhere else without an auth token;
 *   - every request must present that token;
 *   - DNS rebinding protection is on, so a browser on your network cannot be tricked
 *     into driving it from a hostile page.
 *
 * Exposing this to the internet is a deliberate act, not a default. Prefer an
 * outbound tunnel (Cloudflare Tunnel, Tailscale Funnel) over opening a port: the
 * tunnel authenticates the pipe, and the token below authenticates the caller.
 */

import { createServer } from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';

const LOCAL_HOSTS = new Set(['127.0.0.1', '::1', 'localhost']);

export function isLocalBind(host) {
  return LOCAL_HOSTS.has(host);
}

/** Compares without leaking length or position through timing. */
function tokensMatch(presented, expected) {
  const a = Buffer.from(presented ?? '', 'utf8');
  const b = Buffer.from(expected ?? '', 'utf8');
  if (a.length !== b.length || a.length === 0) return false;
  return timingSafeEqual(a, b);
}

function readBearer(request) {
  const header = request.headers.authorization ?? '';
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  return match ? match[1].trim() : '';
}

/**
 * Starts the HTTP listener and returns the transport the server should connect to.
 *
 * Throws rather than starting insecurely: a non-local bind with no token is the one
 * configuration that could hand a stranger your Home Assistant, so it is refused
 * outright instead of warned about.
 */
export async function startHttpTransport({ host, port, token, path = '/mcp', allowedHosts = [] }) {
  if (!isLocalBind(host) && !token) {
    throw new Error(
      `Refusing to bind ${host}:${port} without an auth token. Set MCP_HTTP_TOKEN, ` +
        'or bind 127.0.0.1. This process holds a Home Assistant token and Home ' +
        'Assistant cannot scope one, so an unauthenticated listener is a full ' +
        'instance compromise.',
    );
  }

  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: () => crypto.randomUUID(),
    enableDnsRebindingProtection: true,
    // Matched exactly against the Host header, so anything fronting this server -
    // a tunnel, a reverse proxy - has to be named here or its traffic is a 403.
    allowedHosts: [
      `${host}:${port}`,
      `localhost:${port}`,
      `127.0.0.1:${port}`,
      ...allowedHosts,
    ],
  });

  const httpServer = createServer(async (request, response) => {
    // Exact path only: a prefix test would also accept /mcp-anything.
    const requestPath = (request.url ?? '').split('?')[0];
    if (requestPath !== path) {
      response.writeHead(404).end();
      return;
    }

    if (token && !tokensMatch(readBearer(request), token)) {
      // No detail in the body: a 401 should not help someone probe for the reason.
      response.writeHead(401, { 'WWW-Authenticate': 'Bearer' }).end();
      return;
    }

    try {
      await transport.handleRequest(request, response);
    } catch (error) {
      process.stderr.write(`[http] ${error.message}\n`);
      if (!response.headersSent) response.writeHead(500).end();
    }
  });

  await new Promise((resolve, reject) => {
    httpServer.once('error', reject);
    httpServer.listen(port, host, resolve);
  });

  const scope = isLocalBind(host) ? 'this machine only' : 'REACHABLE FROM YOUR NETWORK';
  process.stderr.write(
    `[http] listening on http://${host}:${port}${path} (${scope}; auth ${token ? 'required' : 'DISABLED'})\n`,
  );

  return { transport, httpServer };
}
