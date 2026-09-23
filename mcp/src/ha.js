/**
 * Minimal Home Assistant client.
 *
 * Deliberately dependency-free: Node 22+ ships both fetch and WebSocket, and the
 * whole point of the MCP server is to run on macOS and Linux too, so it must not
 * reach for the PowerShell layer the Copilot CLI bridge uses.
 */

export class HomeAssistant {
  #authWarned = false;

  constructor({ baseUrl, token }) {
    if (!baseUrl) throw new Error('Home Assistant base URL is required.');
    if (!token) throw new Error('Home Assistant token is required.');
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.token = token;
  }

  get #headers() {
    return { Authorization: `Bearer ${this.token}`, 'Content-Type': 'application/json' };
  }

  async #request(path, init = {}) {
    const response = await fetch(`${this.baseUrl}${path}`, { ...init, headers: this.#headers });
    if (!response.ok) {
      const error = new Error(`Home Assistant ${init.method ?? 'GET'} ${path} failed: ${response.status}`);
      error.status = response.status;
      throw error;
    }
    const text = await response.text();
    return text ? JSON.parse(text) : null;
  }

  async verify() {
    const info = await this.#request('/api/');
    return info?.message === 'API running.';
  }

  callService(domain, service, data) {
    return this.#request(`/api/services/${domain}/${service}`, {
      method: 'POST',
      body: JSON.stringify(data ?? {}),
    });
  }

  async getState(entityId) {
    try {
      return await this.#request(`/api/states/${entityId}`);
    } catch (error) {
      // A 404 is the normal "entity does not exist yet" case while provisioning. A
      // 401/403 means the token is bad or revoked - surface that once to stderr so it
      // is diagnosable, instead of looking forever like a missing entity.
      if ((error?.status === 401 || error?.status === 403) && !this.#authWarned) {
        this.#authWarned = true;
        process.stderr.write(`[ha] authentication failed (${error.status}); check the Home Assistant token\n`);
      }
      return null;
    }
  }

  /**
   * Publishes a retained MQTT message through Home Assistant itself.
   *
   * This is why the bridge needs no broker credentials and no MQTT client: Home
   * Assistant already owns the broker connection, so discovery configs travel over
   * the same authenticated REST call as everything else.
   */
  publishMqtt(topic, payload, retain = true) {
    return this.callService('mqtt', 'publish', {
      topic,
      payload: typeof payload === 'string' ? payload : JSON.stringify(payload),
      retain,
    });
  }

  /**
   * Opens an authenticated WebSocket and resolves once it is ready to take commands.
   */
  async connectSocket() {
    const url = `${this.baseUrl.replace(/^http/, 'ws')}/api/websocket`;
    const socket = new WebSocket(url);
    let nextId = 1;
    const pending = new Map();
    const triggerHandlers = new Map();

    await new Promise((resolve, reject) => {
      const fail = (error) => reject(error instanceof Error ? error : new Error('WebSocket failed'));
      socket.addEventListener('error', fail, { once: true });
      socket.addEventListener('message', (event) => {
        const message = JSON.parse(event.data);
        if (message.type === 'auth_required') {
          socket.send(JSON.stringify({ type: 'auth', access_token: this.token }));
          return;
        }
        if (message.type === 'auth_ok') {
          resolve();
          return;
        }
        if (message.type === 'auth_invalid') {
          reject(new Error('Home Assistant rejected the token.'));
          return;
        }
        if (message.type === 'result') {
          pending.get(message.id)?.(message);
          pending.delete(message.id);
          return;
        }
        if (message.type === 'event') {
          triggerHandlers.get(message.id)?.(message.event);
        }
      });
    });

    const send = (payload) =>
      new Promise((resolve) => {
        const id = nextId++;
        pending.set(id, resolve);
        socket.send(JSON.stringify({ ...payload, id }));
      });

    return {
      raw: socket,
      send,
      /** Subscribes to state changes for specific entities. Scoped on purpose: a broad
       *  state_changed subscription is enough traffic to burn real CPU. */
      async subscribeToEntities(entityIds, handler) {
        const id = nextId++;
        triggerHandlers.set(id, handler);
        const ready = new Promise((resolve) => pending.set(id, resolve));
        socket.send(
          JSON.stringify({
            id,
            type: 'subscribe_trigger',
            trigger: { platform: 'state', entity_id: entityIds },
          }),
        );
        await ready;
        return () => triggerHandlers.delete(id);
      },
      close() {
        try {
          socket.close();
        } catch {
          /* already closing */
        }
      },
    };
  }
}
