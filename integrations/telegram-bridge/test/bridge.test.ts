import assert from "node:assert/strict";
import test from "node:test";
import type { Config } from "../src/config.js";
import { ProductionBridgeActions } from "../src/bridge.js";
import { MediaStore } from "../src/media-store.js";

const config = {
  publicBaseUrl: "https://bridge.example.test",
} as Config;

test("voice notes are relayed through an expiring unguessable media URL", async () => {
  const prompts: string[] = [];
  const media = new MediaStore();
  const actions = new ProductionBridgeActions(
    config,
    { send: async (prompt) => { prompts.push(prompt); } },
    {
      sendMessage: async () => {},
      downloadVoice: async () => ({ bytes: Buffer.from("voice-bytes"), contentType: "audio/ogg" }),
    },
    media,
  );

  await actions.forwardVoice(42, { fileId: "telegram-file", fileSize: 11, mimeType: "audio/ogg" });
  assert.equal(prompts.length, 1);
  const match = prompts[0]?.match(/https:\/\/bridge\.example\.test\/media\/([A-Za-z0-9_-]{43})/);
  assert.ok(match);
  assert.equal(media.get(match[1]!)?.bytes.toString(), "voice-bytes");
  assert.match(prompts[0]!, /expires after 15 minutes/);
});
