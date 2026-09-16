import { setTimeout as sleep } from "node:timers/promises";
import { MAX_VOICE_BYTES, type VoiceInput } from "./domain.js";

type Fetch = typeof globalThis.fetch;

interface TelegramEnvelope {
  ok?: boolean;
  result?: unknown;
  parameters?: { retry_after?: number };
}

async function boundedBody(response: Response, limit: number): Promise<Buffer> {
  if (!response.body) return Buffer.alloc(0);
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel();
      throw new Error("Response exceeds size limit");
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks, size);
}

export class TelegramClient {
  constructor(
    private readonly token: string,
    private readonly chatId: string,
    private readonly fetchImpl: Fetch = fetch,
  ) {}

  async sendMessage(text: string): Promise<void> {
    const characters = Array.from(text);
    for (let offset = 0; offset < characters.length; offset += 4_096) {
      await this.call("sendMessage", {
        chat_id: this.chatId,
        text: characters.slice(offset, offset + 4_096).join(""),
      });
    }
  }

  async downloadVoice(voice: VoiceInput): Promise<{ bytes: Buffer; contentType: string }> {
    if (voice.fileSize > MAX_VOICE_BYTES) throw new Error("Voice note exceeds size limit");
    const result = await this.call("getFile", { file_id: voice.fileId });
    if (!isRecord(result) || typeof result.file_path !== "string") {
      throw new Error("Telegram getFile returned an invalid result");
    }
    const filePath = result.file_path;
    if (!/^[A-Za-z0-9_./-]{1,512}$/.test(filePath) || filePath.includes("..")) {
      throw new Error("Telegram returned an invalid file path");
    }

    const response = await this.fetchImpl(
      `https://api.telegram.org/file/bot${this.token}/${filePath}`,
      { signal: AbortSignal.timeout(30_000) },
    );
    if (!response.ok) throw new Error("Telegram voice download failed");
    const bytes = await boundedBody(response, MAX_VOICE_BYTES);
    const contentType = /^audio\/[A-Za-z0-9.+-]+$/.test(voice.mimeType) ? voice.mimeType : "audio/ogg";
    return { bytes, contentType };
  }

  private async call(method: string, body: Record<string, unknown>): Promise<unknown> {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      let response: Response;
      try {
        response = await this.fetchImpl(`https://api.telegram.org/bot${this.token}/${method}`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(15_000),
        });
      } catch {
        if (attempt === 2) throw new Error("Telegram request failed");
        await sleep(500 * 2 ** attempt);
        continue;
      }

      const raw = await boundedBody(response, 64 * 1024);
      let envelope: TelegramEnvelope = {};
      try {
        envelope = JSON.parse(raw.toString("utf8")) as TelegramEnvelope;
      } catch {
        // The fixed error below deliberately excludes Telegram's response body.
      }
      if (response.ok && envelope.ok === true) return envelope.result;
      const retryAfter = envelope.parameters?.retry_after;
      if (attempt < 2 && (response.status === 429 || response.status >= 500)) {
        await sleep(Math.min(5_000, Math.max(500, (retryAfter ?? 2 ** attempt) * 1_000)));
        continue;
      }
      throw new Error("Telegram API rejected the request");
    }
    throw new Error("Telegram retry limit reached");
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
