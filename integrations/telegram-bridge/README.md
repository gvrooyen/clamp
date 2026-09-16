# Clamp Telegram bridge

This optional companion service connects one allowlisted Telegram user and chat
to one existing Amp orb thread. It is intentionally a limited bridge:

- Telegram text and voice notes become user messages in the Amp thread.
- Telegram receives only a delivery confirmation, not the agent's full reply.
- A bearer-authenticated MCP tool lets that thread send scheduled reminders to
  the configured Telegram chat.
- The Fly app and Amp project own configuration. The container build contains
  no credentials or private Clamp knowledge.

The bridge does not change Clamp's knowledge, publication, or indexing model.
The Amp thread remains the conversation owner and Git remains the durable
knowledge authority.

## Runtime model

```text
Telegram webhook ──▶ Fly bridge ──▶ Amp SDK ──▶ configured Amp thread
                            ▲                         │
                            └──── reminder MCP tool ◀─┘
```

Webhook requests are authenticated and acknowledged after admission to a
bounded in-memory queue. One worker forwards admitted updates in order. Update
IDs are deduplicated in memory for 24 hours (up to 10,000 IDs). The queue holds
at most 100 updates. These structures are deliberately **best effort**: a
restart can lose admitted work and deduplication state. There is no Fly volume,
database, or external queue.

Voice notes are downloaded from Telegram, bounded to 20 MiB, and held in memory
behind a random 256-bit URL for 15 minutes. The Amp thread receives that URL so
it can inspect the audio. The URL remains in the thread after it expires, but
the audio does not. Text is bounded to 8,000 characters; reminder tool input is
bounded to 16,000 characters and split at Telegram's 4,096-character limit.

The webhook and MCP endpoint each allow a burst of 10 requests and refill at
10 requests per minute. Logs contain fixed event names, update IDs, and status;
they do not contain message bodies, audio, tokens, Telegram API responses, or
Amp results.

## Configuration

Every value below is supplied at runtime. Do not add a `.env` file to source.

| Variable | Purpose |
| --- | --- |
| `AMP_API_KEY` | Long-lived Amp access token (`sgamp_…`) with access to the target thread. |
| `AMP_THREAD_ID` | Existing orb thread to continue (`T-…`). |
| `TELEGRAM_BOT_TOKEN` | Token issued by BotFather. |
| `TELEGRAM_WEBHOOK_SECRET` | 32–256 character random `A-Za-z0-9_-` value also given to Telegram's `setWebhook`. |
| `TELEGRAM_ALLOWED_USER_ID` | Sole allowed numeric Telegram user ID. |
| `TELEGRAM_ALLOWED_CHAT_ID` | Sole allowed numeric Telegram chat ID. |
| `BRIDGE_BEARER_TOKEN` | Random token, at least 32 characters, used by the reminder MCP endpoint. |
| `PUBLIC_BASE_URL` | Exact HTTPS Fly app origin, without credentials or a query, such as `https://my-bridge.fly.dev`. |
| `PORT` | Listener port; defaults to `8080`. |

`GET /healthz` reports process liveness and `GET /readyz` reports admission
readiness. `POST /telegram/webhook` requires Telegram's
`X-Telegram-Bot-Api-Secret-Token`. `POST /mcp` requires
`Authorization: Bearer <BRIDGE_BEARER_TOKEN>`.

## Local verification

Node.js 22 or later is required. Tests use fakes and require no credentials or
network services:

```bash
cd integrations/telegram-bridge
npm ci
npm test
docker build -t clamp-telegram-bridge:test .
```

The lockfile pins all npm packages. The multi-stage Dockerfile pins its Debian
Node base image by digest, installs the Amp CLI required by `@ampcode/sdk`, and
runs as the unprivileged `node` user.

## Fly.io reference deployment

No command in this guide should be run until the owner has approved creating or
changing the external Fly app, secrets, and Telegram webhook.

1. Check out the intended Clamp release or commit. Work in this directory and
   create app-specific configuration without committing it:

   ```bash
   cd integrations/telegram-bridge
   cp fly.example.toml fly.toml
   fly launch --no-deploy
   ```

   Set the app name and preferred region in `fly.toml`. Keep one Machine
   running: stopping the only Machine can interrupt work after Telegram has
   already received its webhook acknowledgement.

2. Generate independent webhook and MCP secrets. Add all eight configuration
   values with `fly secrets`; prefer `fly secrets import` or interactive input
   so values do not enter shell history or process arguments. Do not make the
   Telegram and MCP secrets equal. Confirm names only with `fly secrets list`.

3. With explicit deployment approval, deploy from this directory:

   ```bash
   fly deploy
   fly checks list
   ```

4. Register exactly this webhook URL with Telegram:
   `https://<app>.fly.dev/telegram/webhook`. Supply
   `TELEGRAM_WEBHOOK_SECRET` as Telegram's `secret_token` and restrict
   `allowed_updates` to `message`. Keep the bot token out of command arguments,
   shell history, output, and artifacts. Registration is an external mutation
   and requires separate owner approval.

5. Add `BRIDGE_BEARER_TOKEN` to the target Amp project's **Secrets & Env
   Vars** as `CLAMP_TELEGRAM_BRIDGE_TOKEN`. Add the non-secret endpoint as
   `CLAMP_TELEGRAM_BRIDGE_URL`. Configure the project's Amp settings:

   ```json
   {
     "amp.mcpServers": {
       "clamp-telegram": {
         "url": "${CLAMP_TELEGRAM_BRIDGE_URL}/mcp",
         "headers": {
           "Authorization": "Bearer ${CLAMP_TELEGRAM_BRIDGE_TOKEN}"
         },
         "includeTools": ["send_telegram_reminder"]
       }
     }
   }
   ```

   Keep this MCP server available to the designated thread so an automation
   can use it after waking the orb. Tell every scheduled reminder explicitly to
   call `send_telegram_reminder` with the reminder text. A result written only
   to the Amp thread is not automatically mirrored to Telegram.

6. After both integrations are configured, test one harmless text message, one
   short voice note, and one explicit reminder-tool call. Check only redacted
   event metadata in Fly logs. Do not use private knowledge as test content.

## Failure behavior

- Invalid webhook secrets and non-allowlisted users/chats are rejected before
  enqueueing. Duplicate update IDs receive success without being forwarded.
- Queue saturation returns `503` with `Retry-After`, allowing Telegram to retry.
- Telegram network, rate-limit, and server failures receive bounded retries.
  Amp startup failures are retried only before any SDK event is observed; after
  that point acceptance is ambiguous, so the bridge fails rather than risk a
  duplicate thread message.
- Forwarding success produces `Forwarded to Amp. Continue the conversation
  there.` Forwarding failure produces a short retry-later notice when Telegram
  itself remains reachable.
- MCP delivery reports an error to Amp if Telegram rejects the reminder. The
  automation can then surface that failure in the thread; it must not claim the
  reminder was delivered.

Because persistence is best effort, this service does not promise delivery
across process crashes, deploys, Fly Machine replacement, or an ambiguous Amp
acceptance boundary. Add a durable queue and durable idempotency ledger before
offering stronger guarantees.
