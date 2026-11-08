// Runs the hub with stand-ins for Cloudflare's pieces: node relay/test/hub.test.mjs
import assert from "node:assert/strict";
import worker, { Hub } from "../src/index.js";

class FakeSocket {
  constructor() { this.sent = []; this.closed = false; }
  send(s) { this.sent.push(JSON.parse(s)); }
  close() { this.closed = true; }
}
function makeState(sockets) {
  return { getWebSockets: () => sockets, acceptWebSocket() {} };
}
const rpc = (hub, body) =>
  hub.mcp(new Request("https://relay.test/mcp", { method: "POST", body: JSON.stringify(body) })).then((r) => r.json());

// 1. Auth at the front door
{
  const env = { RELAY_TOKEN: "s3cret", HUB: { idFromName: () => "x", get: () => ({ fetch: () => new Response("hub") }) } };
  let r = await worker.fetch(new Request("https://relay.test/mcp", { method: "POST" }), env);
  assert.equal(r.status, 401);
  r = await worker.fetch(new Request("https://relay.test/mcp", { method: "POST", headers: { Authorization: "Bearer wrong!" } }), env);
  assert.equal(r.status, 401);
  r = await worker.fetch(new Request("https://relay.test/mcp", { method: "POST", headers: { Authorization: "Bearer s3cret" } }), env);
  assert.equal(await r.text(), "hub");
  r = await worker.fetch(new Request("https://relay.test/"), env);
  assert.equal(r.status, 200);
  r = await worker.fetch(new Request("https://relay.test/mcp"), { HUB: env.HUB });
  assert.equal(r.status, 401, "no token configured means locked");
}

// 2. MCP basics with no phone connected
{
  const hub = new Hub(makeState([]), {});
  const init = await rpc(hub, { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } });
  assert.equal(init.result.serverInfo.name, "plant-cam");
  const list = await rpc(hub, { jsonrpc: "2.0", id: 2, method: "tools/list" });
  assert.deepEqual(list.result.tools.map((t) => t.name), ["phone_status", "list_photos", "view_photos", "file_photos", "list_notes", "add_note"]);
  const status = await rpc(hub, { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "phone_status" } });
  assert.match(status.result.content[0].text, /isn't connected/);
  const offline = await rpc(hub, { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "list_photos", arguments: {} } });
  assert.equal(offline.result.isError, true);
  const unknown = await rpc(hub, { jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "delete_everything" } });
  assert.equal(unknown.error.code, -32602);
  const note = await hub.mcp(new Request("https://relay.test/mcp", { method: "POST", body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) }));
  assert.equal(note.status, 202);
}

// 3. A request goes to the phone, comes back in parts, and resolves
{
  const phone = new FakeSocket();
  const hub = new Hub(makeState([phone]), {});
  const pending = rpc(hub, { jsonrpc: "2.0", id: 7, method: "tools/call", params: { name: "view_photos", arguments: { ids: ["a", "b"] } } });
  await new Promise((r) => setTimeout(r, 10));
  const req = phone.sent[0];
  assert.equal(req.type, "request");
  assert.equal(req.tool, "view_photos");
  assert.deepEqual(req.args.ids, ["a", "b"]);
  await hub.webSocketMessage(phone, JSON.stringify({ type: "part", id: req.id, content: [{ type: "image", data: "AAA", mimeType: "image/jpeg" }] }));
  await hub.webSocketMessage(phone, JSON.stringify({ type: "done", id: req.id, content: [{ type: "image", data: "BBB", mimeType: "image/jpeg" }] }));
  const res = await pending;
  assert.equal(res.result.content.length, 2);
  assert.equal(res.result.content[1].data, "BBB");
  assert.equal(hub.pending.size, 0);
}

// 4. The app reports an error, or disconnects mid-request
{
  const phone = new FakeSocket();
  const hub = new Hub(makeState([phone]), {});
  const a = rpc(hub, { jsonrpc: "2.0", id: 8, method: "tools/call", params: { name: "list_notes" } });
  await new Promise((r) => setTimeout(r, 10));
  await hub.webSocketMessage(phone, JSON.stringify({ type: "error", id: phone.sent[0].id, message: "Photos access is off" }));
  assert.equal((await a).result.content[0].text, "Photos access is off");

  const b = rpc(hub, { jsonrpc: "2.0", id: 9, method: "tools/call", params: { name: "list_notes" } });
  await new Promise((r) => setTimeout(r, 10));
  await hub.webSocketClose(phone);
  const rb = await b;
  assert.equal(rb.result.isError, true);
  assert.match(rb.result.content[0].text, /disconnected/);
}

// 5. Pings are answered and junk is ignored
{
  const phone = new FakeSocket();
  const hub = new Hub(makeState([phone]), {});
  await hub.webSocketMessage(phone, '{"type":"ping"}');
  assert.equal(phone.sent[0].type, "pong");
  await hub.webSocketMessage(phone, "not json");
  await hub.webSocketMessage(phone, JSON.stringify({ type: "done", id: "nobody" }));
}

console.log("All relay tests passed");
