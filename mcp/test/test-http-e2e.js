/**
 * End-to-end check of the HTTP transport against the real server entry point.
 *
 * test-http.js asserts the security properties of the listener in isolation. This
 * starts server.js exactly as a user would (MCP_TRANSPORT=http) and drives it with
 * a real MCP client over the network, which is the only way to know the transport
 * is actually wired into the server rather than merely importable.
 */

import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const serverPath = path.join(here, '..', 'src', 'server.js');

const PORT = 48083;
const TOKEN = 'e2e-token-not-a-secret';

let failures = 0;
const check = (name, ok, detail = '') => {
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` - ${detail}` : ''}`);
  if (!ok) failures++;
};

const child = spawn(process.execPath, [serverPath], {
  env: {
    ...process.env,
    MCP_TRANSPORT: 'http',
    MCP_HTTP_PORT: String(PORT),
    MCP_HTTP_TOKEN: TOKEN,
    // The tool is never called here, so Home Assistant is not contacted; these only
    // have to satisfy the startup configuration check.
    HA_BASE_URL: process.env.HA_BASE_URL || 'http://127.0.0.1:8123',
    HA_TOKEN: process.env.HA_TOKEN || 'unused-in-this-test',
    HA_DASHBOARD: '',
  },
  stdio: ['ignore', 'pipe', 'pipe'],
});

let stderr = '';
child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });

async function waitForListener() {
  for (let i = 0; i < 100; i++) {
    if (/listening on http/.test(stderr)) return true;
    if (child.exitCode !== null) return false;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return false;
}

try {
  check('the server starts and listens', await waitForListener(), stderr.trim().split('\n').pop() || '');
  check('startup says it is local-only', /this machine only/.test(stderr));

  const url = new URL(`http://127.0.0.1:${PORT}/mcp`);

  console.log('--- a client without the token cannot connect ---');
  let rejected = false;
  try {
    const anon = new Client({ name: 'anon', version: '0' }, { capabilities: {} });
    await anon.connect(new StreamableHTTPClientTransport(url));
  }
  catch {
    rejected = true;
  }
  check('an unauthenticated MCP client is refused', rejected);

  console.log('--- an authenticated client works end to end ---');
  const client = new Client({ name: 'e2e', version: '0' }, { capabilities: { elicitation: {} } });
  await client.connect(new StreamableHTTPClientTransport(url, {
    requestInit: { headers: { authorization: `Bearer ${TOKEN}` } },
  }));
  check('an authenticated MCP client connects', true);

  const tools = await client.listTools();
  const names = tools.tools.map((tool) => tool.name);
  check('the tool is advertised over HTTP', names.includes('ask_via_home_assistant'), names.join(', '));

  const tool = tools.tools.find((entry) => entry.name === 'ask_via_home_assistant');
  check(
    'its input schema survives the transport',
    Boolean(tool?.inputSchema?.properties?.message),
    Object.keys(tool?.inputSchema?.properties || {}).join(', '),
  );

  await client.close();
}
finally {
  child.kill();
}

console.log('');
if (failures) {
  console.log(`${failures} check(s) failed`);
}
else {
  console.log('All checks passed');
}

// Set the code and let Node drain rather than calling process.exit(): a hard exit
// while the HTTP transport's handles are still closing trips a libuv assertion on
// Windows, which would turn a reported test failure into an unreadable crash.
process.exitCode = failures ? 1 : 0;
