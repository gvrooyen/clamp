export const MAX_WEBHOOK_BYTES = 64 * 1024;
export const MAX_MCP_BYTES = 32 * 1024;
export const MAX_TEXT_LENGTH = 8_000;
export const MAX_REMINDER_LENGTH = 16_000;
export const MAX_VOICE_BYTES = 20 * 1024 * 1024;

export interface VoiceInput {
  fileId: string;
  fileSize: number;
  mimeType: string;
}

export interface InboundJob {
  updateId: number;
  text?: string;
  voice?: VoiceInput;
}

export type EnqueueResult = "accepted" | "duplicate" | "full";

export interface BridgeActions {
  forwardText(updateId: number, text: string): Promise<void>;
  forwardVoice(updateId: number, voice: VoiceInput): Promise<void>;
  confirmForwarded(): Promise<void>;
  confirmFailed(): Promise<void>;
  sendReminder(text: string): Promise<void>;
}
