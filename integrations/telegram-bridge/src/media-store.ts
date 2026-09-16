import { randomBytes } from "node:crypto";

const MEDIA_TTL_MS = 15 * 60 * 1_000;
const MEDIA_CAPACITY_BYTES = 64 * 1024 * 1024;

interface Media {
  bytes: Buffer;
  contentType: string;
  expiresAt: number;
}

export class MediaStore {
  private readonly entries = new Map<string, Media>();
  private size = 0;

  put(bytes: Buffer, contentType: string, now = Date.now()): string {
    this.prune(now);
    while (this.size + bytes.length > MEDIA_CAPACITY_BYTES && this.entries.size > 0) {
      const oldest = this.entries.keys().next().value as string | undefined;
      if (oldest === undefined) break;
      this.delete(oldest);
    }
    if (bytes.length > MEDIA_CAPACITY_BYTES) throw new Error("Voice note exceeds media capacity");
    const token = randomBytes(32).toString("base64url");
    this.entries.set(token, { bytes, contentType, expiresAt: now + MEDIA_TTL_MS });
    this.size += bytes.length;
    return token;
  }

  get(token: string, now = Date.now()): Media | undefined {
    if (!/^[A-Za-z0-9_-]{43}$/.test(token)) return undefined;
    const media = this.entries.get(token);
    if (!media) return undefined;
    if (media.expiresAt <= now) {
      this.delete(token);
      return undefined;
    }
    return media;
  }

  private prune(now: number): void {
    for (const [token, media] of this.entries) {
      if (media.expiresAt <= now) this.delete(token);
    }
  }

  private delete(token: string): void {
    const media = this.entries.get(token);
    if (media) this.size -= media.bytes.length;
    this.entries.delete(token);
  }
}
