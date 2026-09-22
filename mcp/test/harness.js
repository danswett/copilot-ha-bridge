/**
 * End-to-end harness: a real MCP client driving the server against a real Home
 * Assistant.
 *
 * Proves the part that matters, the dual-input race:
 *   1. the application answering wins, and
 *   2. Home Assistant answering wins and the application's prompt is cancelled.
 *
 * Needs HA_BASE_URL and HA_TOKEN, and creates and removes its own entities.
 */

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { ElicitRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const serverPath = path.join(here, '..', 'src', 'server.js');

const baseUrl = process.env.HA_BASE_URL;
const token = process.env.HA_TOKEN;
if (!baseUrl || !token) {
  console.error('Set HA_BASE_URL and HA_TOKEN to run the harness.');
  process.exit(2);
}

let failures = 0;
const check = (name, ok, detail = '') => {
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` - ${detail}` : ''}`);
  if (!ok) failures++;
};

async function haFetch(pathname, init = {}) {
  const response = await fetch(`${baseUrl.replace(/\/+$/, '')}${pathname}`, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  });
  if (!response.ok) throw new Error(`${pathname} -> ${response.status}`);
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

async function connect({ onElicit }) {
  const client = new Client(
    { name: 'harness', version: '0.1.0' },
    { capabilities: { elicitation: {} } },
  );
  client.setRequestHandler(ElicitRequestSchema, onElicit);
  await client.connect(
    new StdioClientTransport({
      command: process.execPath,
      args: [serverPath],
      env: { ...process.env, HA_BASE_URL: baseUrl, HA_TOKEN: token, HA_CARD_TITLE: 'Copilot MCP Test' },
      stderr: 'inherit',
    }),
  );
  return client;
}

const QUESTION = {
  message: 'Deploy to production?',
  requestedSchema: {
    type: 'object',
    properties: {
      confirm: { type: 'string', title: 'Confirm', enum: ['ship', 'hold'] },
    },
    required: ['confirm'],
  },
};

async function testToolIsAdvertised() {
  console.log('--- tool discovery ---');
  const client = await connect({ onElicit: async () => ({ action: 'decline' }) });
  try {
    const { tools } = await client.listTools();
    check('ask_via_home_assistant is advertised', tools.some((t) => t.name === 'ask_via_home_assistant'));
  } finally {
    await client.close();
  }
}

async function testApplicationWins() {
  console.log('--- the application answers first ---');
  let sawPrompt = false;
  const client = await connect({
    onElicit: async (request) => {
      sawPrompt = request.params.message.includes('Deploy to production?');
      return { action: 'accept', content: { confirm: 'ship' } };
    },
  });
  try {
    const result = await client.callTool({ name: 'ask_via_home_assistant', arguments: QUESTION });
    check('the server elicited from the application', sawPrompt);
    check('the answer came back', result.structuredContent?.confirm === 'ship',
      JSON.stringify(result.structuredContent));
    check('not reported as an error', result.isError !== true);
  } finally {
    await client.close();
  }
}

async function testHomeAssistantWins() {
  console.log('--- Home Assistant answers first ---');
  let cancelled = false;
  const client = await connect({
    // Stands in for the user being away from the app: never answers, but honours
    // cancellation so we can observe the server withdrawing the prompt.
    onElicit: async (_request, extra) =>
      new Promise((_resolve, reject) => {
        extra.signal.addEventListener(
          'abort',
          () => {
            cancelled = true;
            reject(new Error('cancelled'));
          },
          { once: true },
        );
      }),
  });

  try {
    const pending = client.callTool({ name: 'ask_via_home_assistant', arguments: QUESTION });

    // Poll rather than sleep: publishing, renaming and arming take a variable amount
    // of time on a large Home Assistant instance.
    let decision = null;
    for (let attempt = 0; attempt < 30; attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      const states = await haFetch('/api/states');
      // Every matching entity must be considered, not just the first: a retained
      // config from an earlier run can linger and would otherwise mask the live one.
      const candidates = states.filter(
        (s) => s.entity_id.startsWith('select.mcp_') && s.entity_id.endsWith('_decision'),
      );
      const armed = candidates.find((s) => s.attributes?.options?.includes('ship'));
      if (armed) {
        decision = armed;
        break;
      }
      decision = decision ?? candidates[0] ?? null;
    }

    check('a decision entity exists on the deterministic id', Boolean(decision), decision?.entity_id);
    check('it is armed with the question options',
      Boolean(decision?.attributes?.options?.includes('ship')),
      JSON.stringify(decision?.attributes?.options));
    if (!decision?.attributes?.options?.includes('ship')) {
      throw new Error('the card never armed, so the rest of the race cannot be tested');
    }

    await haFetch('/api/services/select/select_option', {
      method: 'POST',
      body: JSON.stringify({ entity_id: decision.entity_id, option: 'ship' }),
    });

    const result = await pending;
    check('the Home Assistant answer won', result.structuredContent?.confirm === 'ship',
      JSON.stringify(result.structuredContent));

    // The cancellation notification travels after the tool result, so allow it to land.
    await new Promise((resolve) => setTimeout(resolve, 2000));
    check("the application's prompt was cancelled", cancelled);

    const after = await haFetch(`/api/states/${decision.entity_id}`);
    check('the card was cleared afterwards', after.state === 'Idle', after.state);
  } finally {
    await client.close();
  }
}

async function main() {
  console.log(`Running against ${baseUrl}`);
  await testToolIsAdvertised();
  await testApplicationWins();
  await testHomeAssistantWins();

  console.log('');
  console.log(failures ? `${failures} check(s) failed` : 'All checks passed');
  process.exit(failures ? 1 : 0);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
