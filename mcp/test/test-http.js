/**
 * Security tests for the HTTP transport.
 *
 * The properties that matter are the ones that stop this process's Home Assistant
 * token reaching a stranger, so they are asserted rather than assumed:
 *
 *   - a non-local bind without a token is refused outright, not warned about;
 *   - requests without the token are rejected;
 *   - requests with a wrong token are rejected;
 *   - the correct token is accepted.
 *
 * No Home Assistant is needed: the listener is started directly.
 */

import http from 'node:http';
import { startHttpTransport, isLocalBind } from '../src/http.js';

let failures = 0;
const check = (name, ok, detail = '') => {
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` - ${detail}` : ''}`);
  if (!ok) failures++;
};

console.log('--- local bind detection ---');
for (const host of ['127.0.0.1', '::1', 'localhost']) {
  check(`${host} is local`, isLocalBind(host));
}
for (const host of ['0.0.0.0', '192.168.1.50', '::']) {
  check(`${host} is not local`, !isLocalBind(host));
}

console.log('--- refuses an unauthenticated public bind ---');
let refused = false;
let message = '';
try {
  await startHttpTransport({ host: '0.0.0.0', port: 48081, token: '' });
}
catch (error) {
  refused = true;
  message = error.message;
}
check('binding 0.0.0.0 with no token throws', refused);
check('the reason names the Home Assistant token', /Home Assistant token/.test(message));

console.log('--- authentication ---');
const port = 48082;
const token = 'test-token-do-not-use';
const { httpServer } = await startHttpTransport({ host: '127.0.0.1', port, token });

async function probe(headers) {
  const response = await fetch(`http://127.0.0.1:${port}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream', ...headers },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping' }),
  });
  return response.status;
}

try {
  check('no credentials are rejected', (await probe({})) === 401);
  check('a wrong token is rejected', (await probe({ authorization: 'Bearer wrong' })) === 401);
  check('a token of the wrong length is rejected', (await probe({ authorization: 'Bearer test-token' })) === 401);
  const ok = await probe({ authorization: `Bearer ${token}` });
  check('the correct token passes authentication', ok !== 401, `status ${ok}`);

  const wrongPath = await fetch(`http://127.0.0.1:${port}/not-mcp`, { method: 'POST' });
  check('an unknown path is a 404', wrongPath.status === 404, `status ${wrongPath.status}`);
}
finally {
  httpServer.close();
}

console.log('--- DNS rebinding protection ---');
const dnsPort = 48084;
const dnsToken = 'dns-probe-token';
const dns = await startHttpTransport({
  host: '127.0.0.1',
  port: dnsPort,
  token: dnsToken,
  allowedHosts: ['tunnel.example.com'],
});

// The SDK matches the Host header exactly, so anything fronting this server has to
// be declared. undici's fetch refuses to override Host, hence raw node:http. A
// successful initialize opens an SSE stream that never ends, so this resolves on
// the status code rather than waiting for the body.
function hostProbe(hostHeader) {
  return new Promise((resolve) => {
    const body = JSON.stringify({
      jsonrpc: '2.0', id: 1, method: 'initialize',
      params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'p', version: '0' } },
    });
    const req = http.request({
      host: '127.0.0.1', port: dnsPort, path: '/mcp', method: 'POST',
      headers: {
        'content-type': 'application/json',
        accept: 'application/json, text/event-stream',
        authorization: `Bearer ${dnsToken}`,
        'content-length': Buffer.byteLength(body),
        Host: hostHeader,
      },
    }, (res) => {
      const done = () => { resolve(res.statusCode); req.destroy(); };
      res.on('data', done);
      res.on('end', () => resolve(res.statusCode));
      setTimeout(done, 1500);
    });
    req.on('error', () => resolve(0));
    req.end(body);
  });
}

try {
  // Host validation runs before session handling, so the meaningful distinction is
  // 403 versus anything else. The transport is stateful, so only the first
  // initialize gets a 200 - a later one is a protocol-level 400, which still proves
  // the Host header was accepted.
  const bound = await hostProbe(`127.0.0.1:${dnsPort}`);
  check('the bound host is accepted', bound !== 403, `status ${bound}`);
  const evil = await hostProbe('evil.example.com');
  check('an unknown Host header is rejected', evil === 403, `status ${evil}`);
  const tunnel = await hostProbe('tunnel.example.com');
  check('a declared tunnel hostname is accepted', tunnel !== 403, `status ${tunnel}`);
}
finally {
  dns.httpServer.close();
}

console.log('');
if (failures) {
  console.log(`${failures} check(s) failed`);
}
else {
  console.log('All checks passed');
}
process.exitCode = failures ? 1 : 0;
