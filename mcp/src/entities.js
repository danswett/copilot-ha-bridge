/**
 * Per-conversation Home Assistant entities for the MCP server.
 *
 * The payload shapes mirror the PowerShell bridge, which is already proven against a
 * real instance. In particular the decision `select` and reply `text` deliberately
 * omit `state_topic`: that puts them in optimistic mode, so a tap or a typed value
 * sticks without a device echoing it back. With a state_topic the selection would
 * never hold, because nothing is subscribed on the device side.
 *
 * The node id is namespaced `mcp_`, distinct from the CLI bridge's `copilot_`, so the
 * two can share one Home Assistant instance without ever colliding.
 */

const DISCOVERY_PREFIX = 'homeassistant';
const COMMAND_PREFIX = 'copilot_mcp';

export const IDLE = 'Idle';

export function nodeIdFor(sessionId) {
  return `mcp_${sessionId.replace(/[^a-zA-Z0-9]/g, '').slice(0, 12).toLowerCase()}`;
}

export function entityIds(node) {
  return {
    decision: `select.${node}_decision`,
    reply: `text.${node}_reply`,
    status: `sensor.${node}_status`,
  };
}

function topics(node) {
  return {
    decisionCommand: `${COMMAND_PREFIX}/${node}/decision/set`,
    replyCommand: `${COMMAND_PREFIX}/${node}/reply/set`,
    statusState: `${COMMAND_PREFIX}/${node}/status`,
  };
}

function device(node, title) {
  return {
    identifiers: [node],
    name: title,
    manufacturer: 'copilot-ha-bridge',
    model: 'MCP client',
  };
}

/**
 * Publishes the discovery configs. Home Assistant derives an MQTT entity_id from the
 * device name plus the entity name, so the device title must stay stable for
 * entityIds() to keep resolving.
 */
export async function publishEntities(ha, node, title, options = [IDLE]) {
  const t = topics(node);
  const dev = device(node, title);

  await ha.publishMqtt(`${DISCOVERY_PREFIX}/select/${node}/decision/config`, {
    name: 'Decision',
    unique_id: `${node}_decision`,
    command_topic: t.decisionCommand,
    options: options.length ? options : [IDLE],
    device: dev,
  });

  await ha.publishMqtt(`${DISCOVERY_PREFIX}/text/${node}/reply/config`, {
    name: 'Reply',
    unique_id: `${node}_reply`,
    command_topic: t.replyCommand,
    max: 255,
    device: dev,
  });

  await ha.publishMqtt(`${DISCOVERY_PREFIX}/sensor/${node}/status/config`, {
    name: 'Status',
    unique_id: `${node}_status`,
    state_topic: t.statusState,
    device: dev,
  });

  await ha.publishMqtt(t.statusState, IDLE, true);
}

export async function setStatus(ha, node, status) {
  await ha.publishMqtt(topics(node).statusState, status.slice(0, 255), true);
}

/**
 * Arms the decision selector with the question's options, or clears it back to Idle.
 * Options are re-published as a new discovery config because an MQTT select's option
 * list is part of its config, not its state.
 */
export async function armDecision(ha, node, title, options) {
  const t = topics(node);
  // IDLE is always kept in the list so the card can be returned to it later. An MQTT
  // select rejects select_option for a value outside its configured options, so
  // without this, clearing an armed card silently fails.
  const full = [IDLE, ...options.filter((option) => option !== IDLE)];
  await ha.publishMqtt(`${DISCOVERY_PREFIX}/select/${node}/decision/config`, {
    name: 'Decision',
    unique_id: `${node}_decision`,
    command_topic: t.decisionCommand,
    options: full,
    device: device(node, title),
  });
}

export async function clearDecision(ha, node, title) {
  await armDecision(ha, node, title, []);
  // The option list is applied asynchronously, so give it a beat before selecting.
  for (let attempt = 0; attempt < 5; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 600));
    try {
      await ha.callService('select', 'select_option', {
        entity_id: entityIds(node).decision,
        option: IDLE,
      });
      return;
    } catch {
      /* option list not applied yet */
    }
  }
}

/** Empty retained payloads remove the entities cleanly, leaving no orphans behind. */
export async function removeEntities(ha, node) {
  for (const [component, object] of [
    ['select', 'decision'],
    ['text', 'reply'],
    ['sensor', 'status'],
  ]) {
    await ha.publishMqtt(`${DISCOVERY_PREFIX}/${component}/${node}/${object}/config`, '', true);
  }
}

/**
 * Forces the entities onto their deterministic ids.
 *
 * Home Assistant builds an MQTT entity_id from the device name plus the entity name
 * and ignores `object_id` entirely, so a device titled "Copilot MCP" yields
 * select.copilot_mcp_decision rather than anything derived from unique_id. Renaming
 * through the entity registry is the only way to make entityIds() reliable, and it has
 * to happen before anything tries to read or write those entities.
 */
export async function reconcileEntityIds(ha, node) {
  const socket = await ha.connectSocket();
  try {
    const registry = await socket.send({ type: 'config/entity_registry/list' });
    const wanted = entityIds(node);
    const byUniqueId = new Map(
      (registry.result ?? []).map((entry) => [entry.unique_id, entry]),
    );

    for (const [object, target] of Object.entries(wanted)) {
      const entry = byUniqueId.get(`${node}_${object}`);
      if (!entry || entry.entity_id === target) continue;
      await socket.send({
        type: 'config/entity_registry/update',
        entity_id: entry.entity_id,
        new_entity_id: target,
      });
    }
  } finally {
    socket.close();
  }
}
