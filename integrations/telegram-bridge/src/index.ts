import { AmpClient } from "./amp.js";
import { ProductionBridgeActions } from "./bridge.js";
import { loadConfig } from "./config.js";
import { MediaStore } from "./media-store.js";
import { createBridgeServer } from "./server.js";
import { TelegramClient } from "./telegram.js";

function log(event: Record<string, unknown>): void {
  process.stdout.write(`${JSON.stringify({ timestamp: new Date().toISOString(), ...event })}\n`);
}

const config = loadConfig(process.env);
const mediaStore = new MediaStore();
const telegram = new TelegramClient(config.telegramBotToken, config.telegramAllowedChatId);
const amp = new AmpClient(config.ampThreadId);
const actions = new ProductionBridgeActions(config, amp, telegram, mediaStore);
const application = createBridgeServer({ config, actions, mediaStore, log });

application.server.listen(config.port, "0.0.0.0", () => {
  log({ level: "info", event: "server_ready", port: config.port });
});

let shuttingDown = false;
async function shutdown(signal: string): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  application.setReady(false);
  log({ level: "info", event: "shutdown_started", signal });
  application.server.close();
  await application.queue.stop(20_000);
  application.server.closeAllConnections();
  log({ level: "info", event: "shutdown_complete" });
}

process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));
