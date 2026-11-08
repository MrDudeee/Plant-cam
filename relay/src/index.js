// Plant Cam relay.
// Claude connects to /mcp. The Plant Cam app connects to /phone and keeps that
// connection open while it is on screen. The relay passes each request from
// Claude to the app and the app's answer back. Nothing is stored: photos only
// pass through memory on their way to Claude.

const REQUEST_TIMEOUT_MS = 45000;

const TOOLS = [
  {
    name: "phone_status",
    description: "Check whether the Plant Cam app is open and connected right now.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "list_photos",
    description:
      "List photos on the user's iPhone taken on or after the plant's sprout date, oldest first. Each line is: id | date taken | width x height | views it is filed under.",
    inputSchema: {
      type: "object",
      properties: {
        since: { type: "string", description: "Earliest date taken, YYYY-MM-DD" },
        until: { type: "string", description: "Latest date taken, YYYY-MM-DD" },
        view: { type: "string", enum: ["side", "overhead", "nodes", "unsorted"], description: "Only photos filed under this view, or not filed yet" },
        limit: { type: "number", description: "Maximum photos to list (default 100, max 500)" },
        offset: { type: "number", description: "Skip this many photos, for paging" },
      },
    },
  },
  {
    name: "view_photos",
    description: "Show up to 10 photos by id so you can look at them.",
    inputSchema: {
      type: "object",
      properties: {
        ids: { type: "array", items: { type: "string" }, description: "Photo ids from list_photos" },
        size: { type: "string", enum: ["small", "medium", "large"], description: "Defaults to the size chosen in the app" },
      },
      required: ["ids"],
    },
  },
  {
    name: "file_photos",
    description:
      "File photos under a view (side, overhead, or nodes). This adds them to that view's album in the user's Photos app, which drives the timelapse. Set remove to take them out instead.",
    inputSchema: {
      type: "object",
      properties: {
        ids: { type: "array", items: { type: "string" } },
        view: { type: "string", enum: ["side", "overhead", "nodes"] },
        remove: { type: "boolean" },
      },
      required: ["ids", "view"],
    },
  },
  {
    name: "list_notes",
    description: "List the dated notes shown on the timelapse timeline.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "add_note",
    description: "Add a dated note to the timelapse timeline, for example a pre-flower sighting or a lighting change.",
    inputSchema: {
      type: "object",
      properties: {
        date: { type: "string", description: "YYYY-MM-DD" },
        text: { type: "string", description: "Short note, under 80 characters" },
      },
      required: ["date", "text"],
    },
  },
];

const PHONE_TOOLS = new Set(TOOLS.map((t) => t.name).filter((n) => n !== "phone_status"));

// ---------- helpers ----------

function text(body, status = 200) {
  return new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8" } });
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function safeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function authorized(req, env) {
  if (!env.RELAY_TOKEN) return false;
  return safeEqual(req.headers.get("Authorization") || "", `Bearer ${env.RELAY_TOKEN}`);
}

function toolError(message) {
  return { isError: true, content: [{ type: "text", text: message }] };
}

const NOT_OPEN = "Plant Cam isn't connected. Ask the user to open the app and tap Start connection.";

// ---------- entry point ----------

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (url.pathname === "/") return text("Plant Cam relay is running.");
    if (url.pathname !== "/mcp" && url.pathname !== "/phone") return text("Not found", 404);
    if (!authorized(req, env)) return text("Unauthorized", 401);
    const hub = env.HUB.get(env.HUB.idFromName("main"));
    return hub.fetch(req);
  },
};

// ---------- the hub: one instance holds the phone's connection ----------

export class Hub {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.pending = new Map();
    // Answer the app's keep-alive pings without waking the hub.
    if (typeof WebSocketRequestResponsePair !== "undefined" && state.setWebSocketAutoResponse) {
      state.setWebSocketAutoResponse(new WebSocketRequestResponsePair('{"type":"ping"}', '{"type":"pong"}'));
    }
  }

  async fetch(req) {
    const path = new URL(req.url).pathname;
    if (path === "/phone") return this.connectPhone(req);
    if (path === "/mcp") return this.mcp(req);
    return text("Not found", 404);
  }

  phone() {
    const sockets = this.state.getWebSockets("phone");
    return sockets.length ? sockets[sockets.length - 1] : null;
  }

  connectPhone(req) {
    if (req.headers.get("Upgrade") !== "websocket") return text("Expected a WebSocket upgrade", 426);
    for (const old of this.state.getWebSockets("phone")) {
      try {
        old.close(4000, "Replaced by a newer connection");
      } catch (_) {}
    }
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.state.acceptWebSocket(server, ["phone"]);
    return new Response(null, { status: 101, webSocket: client });
  }

  // Messages from the app: {type:"part"|"done"|"error", id, content?, isError?, message?}
  async webSocketMessage(ws, message) {
    let msg;
    try {
      msg = JSON.parse(typeof message === "string" ? message : new TextDecoder().decode(message));
    } catch (_) {
      return;
    }
    if (msg.type === "ping") {
      ws.send('{"type":"pong"}');
      return;
    }
    const p = this.pending.get(msg.id);
    if (!p) return;
    if (msg.type === "part") {
      if (Array.isArray(msg.content)) p.content.push(...msg.content);
    } else if (msg.type === "done") {
      if (Array.isArray(msg.content)) p.content.push(...msg.content);
      this.finish(msg.id, { content: p.content, isError: msg.isError === true });
    } else if (msg.type === "error") {
      this.finish(msg.id, toolError(msg.message || "The app reported an error."));
    }
  }

  async webSocketClose(ws) {
    this.failRequestsOn(ws);
  }

  async webSocketError(ws) {
    this.failRequestsOn(ws);
  }

  failRequestsOn(ws) {
    for (const [id, p] of this.pending) {
      if (p.ws === ws) this.finish(id, toolError("Plant Cam disconnected before answering. " + NOT_OPEN));
    }
  }

  finish(id, result) {
    const p = this.pending.get(id);
    if (!p) return;
    clearTimeout(p.timer);
    this.pending.delete(id);
    p.resolve(result);
  }

  ask(tool, args) {
    const ws = this.phone();
    if (!ws) return Promise.resolve(toolError(NOT_OPEN));
    const id = crypto.randomUUID();
    return new Promise((resolve) => {
      const timer = setTimeout(
        () => this.finish(id, toolError("Plant Cam took too long to answer. It may have gone to the background.")),
        REQUEST_TIMEOUT_MS
      );
      this.pending.set(id, { resolve, timer, ws, content: [] });
      try {
        ws.send(JSON.stringify({ type: "request", id, tool, args }));
      } catch (_) {
        this.finish(id, toolError(NOT_OPEN));
      }
    });
  }

  // ---------- MCP over HTTP for Claude ----------

  async mcp(req) {
    if (req.method !== "POST") return text("Method not allowed", 405);
    let msg;
    try {
      msg = await req.json();
    } catch (_) {
      return json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }, 400);
    }
    if (Array.isArray(msg)) {
      const results = (await Promise.all(msg.map((m) => this.handle(m)))).filter(Boolean);
      return results.length ? json(results) : new Response(null, { status: 202 });
    }
    const result = await this.handle(msg);
    return result ? json(result) : new Response(null, { status: 202 });
  }

  async handle(msg) {
    const { id, method, params } = msg || {};
    if (id === undefined || id === null) return null; // notifications get no reply
    const ok = (result) => ({ jsonrpc: "2.0", id, result });
    const fail = (code, message) => ({ jsonrpc: "2.0", id, error: { code, message } });

    switch (method) {
      case "initialize":
        return ok({
          protocolVersion: params?.protocolVersion || "2025-06-18",
          capabilities: { tools: {} },
          serverInfo: { name: "plant-cam", version: "1.0.0" },
        });
      case "ping":
        return ok({});
      case "tools/list":
        return ok({ tools: TOOLS });
      case "tools/call": {
        const name = params?.name;
        const args = params?.arguments || {};
        if (name === "phone_status") {
          const connected = this.phone() !== null;
          return ok({
            content: [{ type: "text", text: connected ? "Plant Cam is open and connected." : NOT_OPEN }],
          });
        }
        if (!PHONE_TOOLS.has(name)) return fail(-32602, `Unknown tool: ${name}`);
        return ok(await this.ask(name, args));
      }
      default:
        return fail(-32601, `Method not found: ${method}`);
    }
  }
}
