import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import * as z from "zod/v4";
import type { Config } from "./config.js";
import {
  MAX_MCP_BYTES,
  MAX_REMINDER_LENGTH,
  MAX_TEXT_LENGTH,
  MAX_VOICE_BYTES,
  MAX_WEBHOOK_BYTES,
  type BridgeActions,
  type InboundJob,
} from "./domain.js";
import { MediaStore } from "./media-store.js";
import { InboundQueue } from "./queue.js";
import { secretEqual, TokenBucket } from "./security.js";

interface ServerDependencies {
  config: Config;
  actions: BridgeActions;
  mediaStore: MediaStore;
  log?: (event: Record<string, unknown>) => void;
}

export interface BridgeServer {
  server: Server;
  queue: InboundQueue;
  setReady(ready: boolean): void;
}

export function createBridgeServer(dependencies: ServerDependencies): BridgeServer {
  const { config, actions, mediaStore } = dependencies;
  const log = dependencies.log ?? ((event) => process.stdout.write(`${JSON.stringify(event)}\n`));
  const queue = new InboundQueue(actions, log);
  const webhookRate = new TokenBucket(10, 10 / 60_000);
  const mcpRate = new TokenBucket(10, 10 / 60_000);
  let ready = true;

  const server = createServer(async (request, response) => {
    securityHeaders(response);
    try {
      const url = new URL(request.url ?? "/", "http://bridge.invalid");
      if (request.method === "GET" && url.pathname === "/healthz") {
        return json(response, 200, { status: "ok" });
      }
      if (request.method === "GET" && url.pathname === "/readyz") {
        return json(response, ready ? 200 : 503, { status: ready ? "ready" : "stopping" });
      }
      if ((request.method === "GET" || request.method === "HEAD") && url.pathname.startsWith("/media/")) {
        return serveMedia(request, response, url.pathname.slice("/media/".length), mediaStore);
      }
      if (request.method === "POST" && url.pathname === "/telegram/webhook") {
        return await handleWebhook(request, response, config, queue, webhookRate, log);
      }
      if (url.pathname === "/mcp") {
        return await handleMcp(request, response, config, actions, mcpRate);
      }
      return json(response, 404, { error: "not_found" });
    } catch (error) {
      if (error instanceof BodyTooLargeError) return json(response, 413, { error: "body_too_large" });
      if (error instanceof SyntaxError) return json(response, 400, { error: "invalid_json" });
      log({ level: "error", event: "request_failed" });
      if (!response.headersSent) return json(response, 500, { error: "internal_error" });
      response.end();
    }
  });
  server.headersTimeout = 10_000;
  server.requestTimeout = 15_000;
  server.keepAliveTimeout = 5_000;
  server.maxRequestsPerSocket = 100;

  return {
    server,
    queue,
    setReady(value: boolean) {
      ready = value;
    },
  };
}

async function handleWebhook(
  request: IncomingMessage,
  response: ServerResponse,
  config: Config,
  queue: InboundQueue,
  rate: TokenBucket,
  log: (event: Record<string, unknown>) => void,
): Promise<void> {
  const header = singleHeader(request, "x-telegram-bot-api-secret-token");
  if (!secretEqual(header, config.telegramWebhookSecret)) return json(response, 401, { error: "unauthorized" });
  if (!rate.take()) {
    response.setHeader("retry-after", "6");
    return json(response, 429, { error: "rate_limited" });
  }

  const body = await readJson(request, MAX_WEBHOOK_BYTES);
  const parsed = parseTelegramUpdate(body, config);
  if (parsed === "unauthorized") return json(response, 403, { error: "forbidden" });
  if (parsed === "unsupported") return json(response, 200, { status: "ignored" });
  if (parsed === "invalid") return json(response, 400, { error: "invalid_update" });

  const result = queue.enqueue(parsed);
  if (result === "full") {
    response.setHeader("retry-after", "5");
    return json(response, 503, { error: "queue_full" });
  }
  log({ level: "info", event: result === "duplicate" ? "update_duplicate" : "update_accepted", update_id: parsed.updateId });
  return json(response, 200, { status: result });
}

function parseTelegramUpdate(
  value: unknown,
  config: Config,
): InboundJob | "unauthorized" | "unsupported" | "invalid" {
  if (!isRecord(value) || !Number.isSafeInteger(value.update_id) || !isRecord(value.message)) return "invalid";
  const updateId = value.update_id as number;
  const message = value.message;
  if (!isRecord(message.from) || !isRecord(message.chat)) return "invalid";
  if (String(message.from.id) !== config.telegramAllowedUserId || String(message.chat.id) !== config.telegramAllowedChatId) {
    return "unauthorized";
  }

  if (typeof message.text === "string") {
    if (message.text.length === 0 || message.text.length > MAX_TEXT_LENGTH) return "invalid";
    return { updateId, text: message.text };
  }
  if (isRecord(message.voice)) {
    const { file_id: fileId, file_size: fileSize, mime_type: mimeType } = message.voice;
    if (
      typeof fileId !== "string" || fileId.length < 1 || fileId.length > 512 ||
      !Number.isSafeInteger(fileSize) || (fileSize as number) < 1 || (fileSize as number) > MAX_VOICE_BYTES ||
      (mimeType !== undefined && (typeof mimeType !== "string" || mimeType.length > 128))
    ) return "invalid";
    return { updateId, voice: { fileId, fileSize: fileSize as number, mimeType: mimeType ?? "audio/ogg" } };
  }
  return "unsupported";
}

async function handleMcp(
  request: IncomingMessage,
  response: ServerResponse,
  config: Config,
  actions: BridgeActions,
  rate: TokenBucket,
): Promise<void> {
  if (request.method !== "POST") {
    response.setHeader("allow", "POST");
    return json(response, 405, { error: "method_not_allowed" });
  }
  const authorization = singleHeader(request, "authorization");
  if (!secretEqual(authorization, `Bearer ${config.bridgeBearerToken}`)) {
    return json(response, 401, { error: "unauthorized" });
  }
  if (!rate.take()) {
    response.setHeader("retry-after", "6");
    return json(response, 429, { error: "rate_limited" });
  }

  const body = await readJson(request, MAX_MCP_BYTES);
  const mcp = new McpServer({ name: "clamp-telegram-bridge", version: "0.1.0" });
  mcp.registerTool(
    "send_telegram_reminder",
    {
      description: "Send a scheduled reminder to the configured owner's Telegram chat. Use only for reminders requested by that owner.",
      inputSchema: { text: z.string().min(1).max(MAX_REMINDER_LENGTH) },
    },
    async ({ text }) => {
      await actions.sendReminder(text);
      return { content: [{ type: "text" as const, text: "Reminder delivered to Telegram." }] };
    },
  );
  const transport = new StreamableHTTPServerTransport();
  response.on("close", () => {
    void transport.close();
    void mcp.close();
  });
  await mcp.connect(transport);
  await transport.handleRequest(request, response, body);
}

function serveMedia(
  request: IncomingMessage,
  response: ServerResponse,
  token: string,
  store: MediaStore,
): void {
  const media = store.get(token);
  if (!media) return json(response, 404, { error: "not_found" });
  response.writeHead(200, {
    "content-type": media.contentType,
    "content-length": media.bytes.length,
    "cache-control": "private, no-store, max-age=0",
    "x-content-type-options": "nosniff",
  });
  response.end(request.method === "HEAD" ? undefined : media.bytes);
}

class BodyTooLargeError extends Error {}

async function readJson(request: IncomingMessage, limit: number): Promise<unknown> {
  const declared = Number(request.headers["content-length"] ?? 0);
  if (Number.isFinite(declared) && declared > limit) throw new BodyTooLargeError();
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk as Uint8Array);
    size += bytes.length;
    if (size > limit) throw new BodyTooLargeError();
    chunks.push(bytes);
  }
  return JSON.parse(Buffer.concat(chunks, size).toString("utf8"));
}

function singleHeader(request: IncomingMessage, name: string): string | undefined {
  const value = request.headers[name];
  return Array.isArray(value) ? undefined : value;
}

function securityHeaders(response: ServerResponse): void {
  response.setHeader("x-content-type-options", "nosniff");
  response.setHeader("referrer-policy", "no-referrer");
  response.setHeader("content-security-policy", "default-src 'none'");
}

function json(response: ServerResponse, status: number, body: Record<string, unknown>): void {
  const bytes = Buffer.from(JSON.stringify(body));
  response.writeHead(status, {
    "content-type": "application/json",
    "content-length": bytes.length,
    "cache-control": "no-store",
  });
  response.end(bytes);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
