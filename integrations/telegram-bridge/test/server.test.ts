import assert from "node:assert/strict";
import type { AddressInfo } from "node:net";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { Config } from "../src/config.js";
import type { BridgeActions, VoiceInput } from "../src/domain.js";
import { MediaStore } from "../src/media-store.js";
import { createBridgeServer } from "../src/server.js";

const config: Config = {
  port: 8080,
  publicBaseUrl: "https://bridge.example.test",
  ampThreadId: "T-12345678-1234-1234-1234-123456789abc",
  telegramBotToken: `123456:${"a".repeat(35)}`,
  telegramWebhookSecret: "w".repeat(32),
  telegramAllowedUserId: "123456789",
  telegramAllowedChatId: "-1001234567890",
  bridgeBearerToken: "b".repeat(32),
};

class FakeActions implements BridgeActions {
  readonly texts: Array<{ updateId: number; text: string }> = [];
  readonly reminders: string[] = [];
  confirmations = 0;
  failures = 0;
  releaseForward: (() => void) | undefined;

  async forwardText(updateId: number, text: string): Promise<void> {
    this.texts.push({ updateId, text });
    if (this.releaseForward) await new Promise<void>((resolve) => {
      const release = this.releaseForward;
      this.releaseForward = () => {
        release?.();
        resolve();
      };
    });
  }

  async forwardVoice(_updateId: number, _voice: VoiceInput): Promise<void> {}
  async confirmForwarded(): Promise<void> { this.confirmations += 1; }
  async confirmFailed(): Promise<void> { this.failures += 1; }
  async sendReminder(text: string): Promise<void> { this.reminders.push(text); }
}

async function start(actions = new FakeActions()) {
  const logs: Array<Record<string, unknown>> = [];
  const application = createBridgeServer({
    config,
    actions,
    mediaStore: new MediaStore(),
    log: (event) => logs.push(event),
  });
  await new Promise<void>((resolve) => application.server.listen(0, "127.0.0.1", resolve));
  const address = application.server.address() as AddressInfo;
  const baseUrl = `http://127.0.0.1:${address.port}`;
  return {
    actions,
    application,
    baseUrl,
    close: async () => new Promise<void>((resolve, reject) => {
      application.server.close((error) => error ? reject(error) : resolve());
    }),
  };
}

function telegramUpdate(updateId: number, overrides: Record<string, unknown> = {}) {
  return {
    update_id: updateId,
    message: {
      from: { id: 123456789 },
      chat: { id: -1001234567890 },
      text: "Remember the asymmetric boundary",
      ...overrides,
    },
  };
}

test("health endpoints expose readiness without credentials", async (t) => {
  const running = await start();
  t.after(running.close);
  assert.deepEqual(await (await fetch(`${running.baseUrl}/healthz`)).json(), { status: "ok" });
  running.application.setReady(false);
  const response = await fetch(`${running.baseUrl}/readyz`);
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { status: "stopping" });
});

test("webhook authenticates, allowlists, acknowledges promptly, and deduplicates", async (t) => {
  const actions = new FakeActions();
  actions.releaseForward = () => {};
  const running = await start(actions);
  t.after(running.close);
  const post = (body: unknown, secret = config.telegramWebhookSecret) => fetch(`${running.baseUrl}/telegram/webhook`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-telegram-bot-api-secret-token": secret,
    },
    body: JSON.stringify(body),
  });

  assert.equal((await post(telegramUpdate(1), "wrong")).status, 401);
  assert.equal((await post(telegramUpdate(2, { from: { id: 987654321 } }))).status, 403);

  const accepted = await post(telegramUpdate(3));
  assert.equal(accepted.status, 200);
  assert.deepEqual(await accepted.json(), { status: "accepted" });
  assert.deepEqual(actions.texts, [{ updateId: 3, text: "Remember the asymmetric boundary" }]);
  assert.equal(actions.confirmations, 0, "the HTTP acknowledgement does not wait for Amp");

  const duplicate = await post(telegramUpdate(3));
  assert.deepEqual(await duplicate.json(), { status: "duplicate" });
  assert.equal(actions.texts.length, 1);
  actions.releaseForward?.();
});

test("webhook rejects bounded-input violations before enqueue", async (t) => {
  const running = await start();
  t.after(running.close);
  const response = await fetch(`${running.baseUrl}/telegram/webhook`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-telegram-bot-api-secret-token": config.telegramWebhookSecret,
    },
    body: JSON.stringify(telegramUpdate(4, { text: "x".repeat(8_001) })),
  });
  assert.equal(response.status, 400);
  assert.equal(running.actions.texts.length, 0);
});

test("authenticated MCP tool delivers reminders and rejects the wrong bearer", async (t) => {
  const running = await start();
  t.after(running.close);
  const unauthorized = await fetch(`${running.baseUrl}/mcp`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer wrong" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }),
  });
  assert.equal(unauthorized.status, 401);

  const transport = new StreamableHTTPClientTransport(new URL(`${running.baseUrl}/mcp`), {
    requestInit: { headers: { authorization: `Bearer ${config.bridgeBearerToken}` } },
  });
  const client = new Client({ name: "bridge-test", version: "1.0.0" });
  await client.connect(transport);
  t.after(async () => client.close());
  const tools = await client.listTools();
  assert.deepEqual(tools.tools.map((tool) => tool.name), ["send_telegram_reminder"]);
  const result = await client.callTool({
    name: "send_telegram_reminder",
    arguments: { text: "Take the bread out of the oven." },
  });
  assert.equal(result.isError, undefined);
  assert.deepEqual(running.actions.reminders, ["Take the bread out of the oven."]);
});
