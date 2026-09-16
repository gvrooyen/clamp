export interface Config {
  port: number;
  telegramBotToken: string;
  telegramWebhookSecret: string;
  telegramAllowedUserId: string;
  telegramAllowedChatId: string;
  ampThreadId: string;
  bridgeBearerToken: string;
  publicBaseUrl: string;
}

function required(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name];
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function decimalId(value: string, name: string): string {
  if (!/^-?[0-9]{1,20}$/.test(value)) {
    throw new Error(`${name} must be a decimal Telegram ID`);
  }
  return value;
}

function secret(value: string, name: string, pattern: RegExp, min: number, max: number): string {
  if (value.length < min || value.length > max || !pattern.test(value)) {
    throw new Error(`${name} has an invalid format`);
  }
  return value;
}

export function loadConfig(env: NodeJS.ProcessEnv): Config {
  const rawPort = env.PORT ?? "8080";
  const port = Number(rawPort);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error("PORT must be an integer from 1 to 65535");
  }

  const publicBaseUrl = new URL(required(env, "PUBLIC_BASE_URL"));
  if (publicBaseUrl.protocol !== "https:" && env.NODE_ENV === "production") {
    throw new Error("PUBLIC_BASE_URL must use HTTPS in production");
  }
  if (publicBaseUrl.username || publicBaseUrl.password || publicBaseUrl.search || publicBaseUrl.hash) {
    throw new Error("PUBLIC_BASE_URL must not contain credentials, a query, or a fragment");
  }
  if (publicBaseUrl.pathname !== "/") {
    throw new Error("PUBLIC_BASE_URL must be an origin without a path");
  }

  const ampThreadId = required(env, "AMP_THREAD_ID");
  if (!/^T-[0-9a-f-]{36}$/.test(ampThreadId)) {
    throw new Error("AMP_THREAD_ID must be an Amp thread ID");
  }

  required(env, "AMP_API_KEY");

  return {
    port,
    telegramBotToken: secret(
      required(env, "TELEGRAM_BOT_TOKEN"),
      "TELEGRAM_BOT_TOKEN",
      /^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$/,
      32,
      128,
    ),
    telegramWebhookSecret: secret(
      required(env, "TELEGRAM_WEBHOOK_SECRET"),
      "TELEGRAM_WEBHOOK_SECRET",
      /^[A-Za-z0-9_-]+$/,
      32,
      256,
    ),
    telegramAllowedUserId: decimalId(
      required(env, "TELEGRAM_ALLOWED_USER_ID"),
      "TELEGRAM_ALLOWED_USER_ID",
    ),
    telegramAllowedChatId: decimalId(
      required(env, "TELEGRAM_ALLOWED_CHAT_ID"),
      "TELEGRAM_ALLOWED_CHAT_ID",
    ),
    ampThreadId,
    bridgeBearerToken: secret(
      required(env, "BRIDGE_BEARER_TOKEN"),
      "BRIDGE_BEARER_TOKEN",
      /^[A-Za-z0-9._~-]+$/,
      32,
      512,
    ),
    publicBaseUrl: publicBaseUrl.origin,
  };
}
