import type { Config } from "./config.js";
import type { BridgeActions, VoiceInput } from "./domain.js";
import type { MediaStore } from "./media-store.js";

interface AmpSender {
  send(prompt: string): Promise<void>;
}

interface TelegramGateway {
  sendMessage(text: string): Promise<void>;
  downloadVoice(voice: VoiceInput): Promise<{ bytes: Buffer; contentType: string }>;
}

export class ProductionBridgeActions implements BridgeActions {
  constructor(
    private readonly config: Config,
    private readonly amp: AmpSender,
    private readonly telegram: TelegramGateway,
    private readonly media: MediaStore,
  ) {}

  async forwardText(updateId: number, text: string): Promise<void> {
    await this.amp.send([
      `Authorized Telegram message (update ${updateId}) from the owner:`,
      "",
      text,
      "",
      "Treat the message above as a user message to this existing thread. Keep the full response in Amp; Telegram only receives a delivery confirmation.",
    ].join("\n"));
  }

  async forwardVoice(updateId: number, voice: VoiceInput): Promise<void> {
    const downloaded = await this.telegram.downloadVoice(voice);
    const token = this.media.put(downloaded.bytes, downloaded.contentType);
    const mediaUrl = `${this.config.publicBaseUrl}/media/${token}`;
    await this.amp.send([
      `Authorized Telegram voice note (update ${updateId}) from the owner:`,
      mediaUrl,
      "",
      "The unguessable media URL expires after 15 minutes. Inspect the audio and treat its spoken content as a user message to this existing thread. Keep the full response in Amp; Telegram only receives a delivery confirmation.",
    ].join("\n"));
  }

  async confirmForwarded(): Promise<void> {
    await this.telegram.sendMessage("Forwarded to Amp. Continue the conversation there.");
  }

  async confirmFailed(): Promise<void> {
    await this.telegram.sendMessage("I could not forward that message to Amp. Please retry later or use Amp directly.");
  }

  async sendReminder(text: string): Promise<void> {
    await this.telegram.sendMessage(text);
  }
}
