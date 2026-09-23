/**
 * Unit tests for the Home Assistant client's error handling.
 *
 * getState must treat a missing entity (404) as the normal provisioning case and
 * return null silently, while a bad or revoked token (401/403) is surfaced once to
 * stderr so a credential failure is diagnosable instead of looking forever like a
 * missing entity.
 */
import { HomeAssistant } from '../src/ha.js';

let pass = 0;
let fail = 0;
function check(name, condition) {
  if (condition) {
    console.log(`  PASS  ${name}`);
    pass++;
  } else {
    console.log(`  FAIL  ${name}`);
    fail++;
  }
}

const realFetch = globalThis.fetch;
function mockFetch(status, body = '') {
  globalThis.fetch = async () => ({
    ok: status >= 200 && status < 300,
    status,
    text: async () => body,
  });
}

let stderrText = '';
const realWrite = process.stderr.write.bind(process.stderr);
process.stderr.write = (chunk) => {
  stderrText += chunk;
  return true;
};

try {
  const ha = new HomeAssistant({ baseUrl: 'http://127.0.0.1:1', token: 'x' });

  mockFetch(200, JSON.stringify({ state: 'on' }));
  const ok = await ha.getState('select.test');
  check('a 200 returns the parsed state', ok?.state === 'on');

  mockFetch(404);
  stderrText = '';
  const missing = await ha.getState('select.missing');
  check('a 404 returns null', missing === null);
  check('a 404 does not warn on stderr', stderrText === '');

  mockFetch(403);
  stderrText = '';
  const denied = await ha.getState('select.denied');
  check('a 403 returns null', denied === null);
  check('a 403 surfaces an auth warning to stderr', /auth/i.test(stderrText));

  // The warning is emitted once, not on every call, so it cannot spam stderr.
  mockFetch(401);
  stderrText = '';
  await ha.getState('select.again');
  check('a repeat auth failure does not warn again', stderrText === '');
} finally {
  globalThis.fetch = realFetch;
  process.stderr.write = realWrite;
}

console.log('');
if (fail) {
  console.log(`${fail} check(s) failed`);
  process.exit(1);
}
console.log('All checks passed');
