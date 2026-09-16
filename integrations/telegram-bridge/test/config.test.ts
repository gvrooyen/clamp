import assert from "node:assert/strict";
import test from "node:test";
import { loadConfig } from "../src/config.js";

const validEnvironment: NodeJS.ProcessEnv = {
  NODE_ENV: "production",
  PORT: "8080",
  PUBLIC_BASE_URL: "https://bridge.example.test/",
  AMP_API_KEY: "not-a-real-key",
  AMP_THREAD_ID: "T-12345678-1234-1234-1234-123456789abc",
  TELEGRAM_BOT_TOKEN: `123456:${"a".repeat(35)}`,
  TELEGRAM_WEBHOOK_SECRET: "w".repeat(32),
  TELEGRAM_ALLOWED_USER_ID: "123456789",
  TELEGRAM_ALLOWED_CHAT_ID: "-1001234567890",
  BRIDGE_BEARER_TOKEN: "b".repeat(32),
};

test("loads a complete production configuration without retaining a trailing slash", () => {
  const config = loadConfig(validEnvironment);
  assert.equal(config.port, 8080);
  assert.equal(config.publicBaseUrl, "https://bridge.example.test");
  assert.equal(config.telegramAllowedChatId, "-1001234567890");
});

test("rejects insecure production media URLs and short secrets", () => {
  assert.throws(
    () => loadConfig({ ...validEnvironment, PUBLIC_BASE_URL: "http://bridge.example.test" }),
    /HTTPS/,
  );
  assert.throws(
    () => loadConfig({ ...validEnvironment, BRIDGE_BEARER_TOKEN: "short" }),
    /invalid format/,
  );
  assert.throws(
    () => loadConfig({ ...validEnvironment, PUBLIC_BASE_URL: "https://bridge.example.test/prefix" }),
    /without a path/,
  );
});
