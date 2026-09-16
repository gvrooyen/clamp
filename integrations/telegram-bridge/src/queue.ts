import type { BridgeActions, EnqueueResult, InboundJob } from "./domain.js";

const QUEUE_CAPACITY = 100;
const DEDUPE_CAPACITY = 10_000;
const DEDUPE_TTL_MS = 24 * 60 * 60 * 1_000;

export class InboundQueue {
  private readonly jobs: InboundJob[] = [];
  private readonly seen = new Map<number, number>();
  private running = false;
  private stopping = false;
  private idleWaiters: Array<() => void> = [];

  constructor(
    private readonly actions: BridgeActions,
    private readonly log: (event: Record<string, unknown>) => void,
  ) {}

  enqueue(job: InboundJob, now = Date.now()): EnqueueResult {
    this.prune(now);
    if (this.seen.has(job.updateId)) return "duplicate";
    if (this.stopping || this.jobs.length >= QUEUE_CAPACITY) return "full";
    this.seen.set(job.updateId, now);
    this.jobs.push(job);
    this.run().catch(() => {
      this.log({ level: "error", event: "queue_worker_stopped" });
    });
    return "accepted";
  }

  async stop(timeoutMs: number): Promise<void> {
    this.stopping = true;
    if (!this.running && this.jobs.length === 0) return;
    await Promise.race([
      new Promise<void>((resolve) => this.idleWaiters.push(resolve)),
      new Promise<void>((resolve) => setTimeout(resolve, timeoutMs)),
    ]);
  }

  private async run(): Promise<void> {
    if (this.running) return;
    this.running = true;
    try {
      while (this.jobs.length > 0) {
        const job = this.jobs.shift();
        if (!job) break;
        try {
          if (job.text !== undefined) await this.actions.forwardText(job.updateId, job.text);
          else if (job.voice !== undefined) await this.actions.forwardVoice(job.updateId, job.voice);
          else throw new Error("Invalid queue job");
          await this.actions.confirmForwarded();
          this.log({ level: "info", event: "update_forwarded", update_id: job.updateId });
        } catch {
          this.log({ level: "error", event: "update_forward_failed", update_id: job.updateId });
          try {
            await this.actions.confirmFailed();
          } catch {
            this.log({ level: "error", event: "failure_confirmation_failed", update_id: job.updateId });
          }
        }
      }
    } finally {
      this.running = false;
      for (const resolve of this.idleWaiters.splice(0)) resolve();
      if (this.jobs.length > 0 && !this.stopping) void this.run();
    }
  }

  private prune(now: number): void {
    for (const [id, timestamp] of this.seen) {
      if (now - timestamp > DEDUPE_TTL_MS || this.seen.size > DEDUPE_CAPACITY) this.seen.delete(id);
      else break;
    }
  }
}
