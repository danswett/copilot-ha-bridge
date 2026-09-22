#!/usr/bin/env node
/**
 * MCP server that mirrors a prompt to Home Assistant and lets you answer it from
 * either place.
 *
 * The interesting part is the race in askViaHomeAssistant(): the server arms a Home
 * Assistant card and issues an `elicitation/create` to the host application at the
 * same time, then takes whichever answer arrives first and cancels the other. Because
 * cancellation is part of the protocol, this is a cleaner form of dual input than the
 * Copilot CLI bridge's console injection - there is no second input path to reconcile,
 * and no operating system specific code.
 *
 * What it deliberately does NOT do: stream activity or reasoning, or continue a
 * finished turn. An MCP server is blind between its own invocations - it never sees
 * the transcript - and it cannot originate a user turn. Those remain exclusive to the
 * hook-based Copilot CLI bridge.
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';

import { HomeAssistant } from './ha.js';
import {
  IDLE,
  armDecision,
  clearDecision,
  entityIds,
  nodeIdFor,
  publishEntities,
  reconcileEntityIds,
  removeEntities,
  setStatus,
} from './entities.js';
import { describeSchema, outlineFor, valueForLabel } from './schema.js';
import { DEFAULT_URL_PATH, ensureDashboard, removeFromDashboard } from './dashboard.js';

const DEFAULT_TIMEOUT_MS = 30 * 60 * 1000;

function loadConfig() {
  const baseUrl = process.env.HA_BASE_URL;
  const token = process.env.HA_TOKEN;
  if (!baseUrl || !token) {
    throw new Error(
      'Set HA_BASE_URL and HA_TOKEN. In Claude Desktop these go in the server\'s "env" block.',
    );
  }
  return {
    baseUrl,
    token,
    title: process.env.HA_CARD_TITLE || 'Copilot MCP',
    timeoutMs: Number(process.env.HA_TIMEOUT_MS) || DEFAULT_TIMEOUT_MS,
    // Set HA_DASHBOARD='' to manage cards yourself.
    dashboard:
      process.env.HA_DASHBOARD === undefined ? DEFAULT_URL_PATH : process.env.HA_DASHBOARD,
  };
}

/**
 * Resolves when the user answers on the dashboard, or when `signal` aborts because the
 * application won the race.
 */
function waitForHomeAssistant(socket, ids, signal) {
  return new Promise((resolve, reject) => {
    let unsubscribe;
    const finish = (result) => {
      unsubscribe?.();
      resolve(result);
    };

    socket
      .subscribeToEntities([ids.decision, ids.reply], (event) => {
        const entityId = event?.variables?.trigger?.entity_id;
        const value = event?.variables?.trigger?.to_state?.state;
        if (!value || value === IDLE || value === 'unknown' || !value.trim()) return;
        if (entityId === ids.decision) finish({ source: 'home_assistant', label: value });
        if (entityId === ids.reply) finish({ source: 'home_assistant', text: value });
      })
      .then((off) => {
        unsubscribe = off;
        if (signal.aborted) finish(null);
      })
      .catch(reject);

    signal.addEventListener('abort', () => finish(null), { once: true });
  });
}

async function main() {
  const config = loadConfig();
  const ha = new HomeAssistant(config);

  const server = new Server(
    { name: 'copilot-ha-bridge', version: '0.1.0' },
    { capabilities: { tools: {} } },
  );

  const node = nodeIdFor(String(process.pid) + Date.now().toString(36));
  const ids = entityIds(node);
  let provisioned = false;

  const ensureProvisioned = async (options) => {
    if (provisioned) return false;
    // Publishing with the real options up front saves a round trip and removes an
    // ordering hazard: the card is never briefly live with a stale option list.
    await publishEntities(ha, node, config.title, options);
    // Home Assistant needs a moment to register newly discovered entities before they
    // can be renamed.
    await new Promise((resolve) => setTimeout(resolve, 2000));
    await reconcileEntityIds(ha, node);
    // An MCP-only install has no daemon to build a dashboard, so the server makes a
    // small one of its own. Never fatal: the entities are useful regardless.
    if (config.dashboard) {
      await ensureDashboard(ha, node, config.title, config.dashboard).catch((error) => {
        process.stderr.write(`[dashboard] ${error.message}\n`);
      });
    }
    provisioned = true;
    return true;
  };

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [
      {
        name: 'ask_via_home_assistant',
        description:
          'Ask the user a question they can answer either here or on their Home Assistant ' +
          'dashboard. Use this instead of asking in plain text whenever you need a decision ' +
          'and the user may be away from this app.',
        inputSchema: {
          type: 'object',
          properties: {
            message: { type: 'string', description: 'The question to ask.' },
            requestedSchema: {
              type: 'object',
              description:
                'JSON Schema describing the answer, in elicitation form. A single field ' +
                'with an enum/oneOf/boolean becomes a dropdown; anything else becomes a ' +
                'free-text reply box.',
            },
          },
          required: ['message'],
        },
      },
    ],
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    if (request.params.name !== 'ask_via_home_assistant') {
      throw new Error(`Unknown tool: ${request.params.name}`);
    }

    const { message, requestedSchema } = request.params.arguments ?? {};
    const schema = requestedSchema ?? { type: 'object', properties: {} };
    const description = describeSchema(schema);
    const outline = outlineFor(description);
    const question = outline ? `${message}\n\n${outline}` : message;

    const options =
      description.kind === 'choice' ? description.options.map((o) => o.title) : [IDLE];

    const freshlyPublished = await ensureProvisioned(options);
    await setStatus(ha, node, 'Waiting for an answer');

    // Already-live entities keep their config from an earlier question, so they need
    // re-arming; freshly published ones already carry the right options.
    if (!freshlyPublished && description.kind === 'choice') {
      await armDecision(ha, node, config.title, options);
    }

    const socket = await ha.connectSocket();
    const controller = new AbortController();

    // Both sides are started before either is awaited, so neither can be missed.
    const fromHomeAssistant = waitForHomeAssistant(socket, ids, controller.signal);
    const fromApplication = server
      .elicitInput(
        { message: question, requestedSchema: schema },
        { signal: controller.signal, timeout: config.timeoutMs },
      )
      .then((result) => ({ source: 'application', result }))
      .catch(() => null);

    let winner;
    try {
      winner = await Promise.race([
        fromHomeAssistant,
        fromApplication,
        new Promise((resolve) => setTimeout(() => resolve({ source: 'timeout' }), config.timeoutMs)),
      ]);
    } finally {
      // Cancels the losing elicitation via notifications/cancelled, and stops the
      // Home Assistant watcher, so nothing is left waiting on an answered question.
      controller.abort();
      await clearDecision(ha, node, config.title).catch(() => {});
      await setStatus(ha, node, IDLE).catch(() => {});
      socket.close();
    }

    if (!winner || winner.source === 'timeout') {
      return {
        content: [{ type: 'text', text: 'No answer was given before the question timed out.' }],
        isError: true,
      };
    }

    if (winner.source === 'home_assistant') {
      const answer =
        winner.label !== undefined
          ? { [description.field ?? 'answer']: valueForLabel(description, winner.label) }
          : { answer: winner.text };
      return {
        content: [
          {
            type: 'text',
            text: `Answered from Home Assistant: ${JSON.stringify(answer)}`,
          },
        ],
        structuredContent: answer,
      };
    }

    const { action, content } = winner.result ?? {};
    if (action !== 'accept') {
      return {
        content: [{ type: 'text', text: `The user ${action ?? 'dismissed'} the question.` }],
        isError: true,
      };
    }
    return {
      content: [{ type: 'text', text: `Answered here: ${JSON.stringify(content)}` }],
      structuredContent: content ?? {},
    };
  });

  const shutdown = async () => {
    if (provisioned) {
      if (config.dashboard) await removeFromDashboard(ha, node, config.dashboard).catch(() => {});
      await removeEntities(ha, node).catch(() => {});
    }
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
  // A host closing the stdio pipe is the normal way this server ends, so cleanup must
  // hang off that too - otherwise every run leaks a retained discovery config.
  process.stdin.on('close', shutdown);

  await server.connect(new StdioServerTransport());

  // Burn outbound request id 0.
  //
  // @modelcontextprotocol/sdk 1.30.0 drops cancellations for it: Protocol._oncancel
  // starts with `if (!notification.params.requestId) return;`, and id 0 is falsy, so
  // the very first server->client request can never be cancelled. Elicitation is
  // usually that first request, which would leave a stale prompt open in the
  // application every time Home Assistant won the race. A ping costs nothing and
  // moves elicitation to id 1 or higher, where cancellation works - verified against
  // the SDK directly.
  await server.ping().catch(() => {});
}

main().catch((error) => {
  process.stderr.write(`${error.stack ?? error.message}\n`);
  process.exit(1);
});
