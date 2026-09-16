import { execute } from "@ampcode/sdk";
import { setTimeout as sleep } from "node:timers/promises";

export class AmpClient {
  constructor(private readonly threadId: string) {}

  async send(prompt: string): Promise<void> {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 5 * 60 * 1_000);
      let sawEvent = false;
      try {
        let completed = false;
        for await (const message of execute({
          prompt,
          options: {
            continue: this.threadId,
            executor: "orb",
            logLevel: "error",
          },
          signal: controller.signal,
        })) {
          sawEvent = true;
          if (message.type === "result") {
            if (message.is_error) throw new Error("Amp execution failed");
            completed = true;
          }
        }
        if (!completed) throw new Error("Amp execution ended without a result");
        return;
      } catch {
        // Once Amp emits an event, acceptance may be ambiguous. Do not risk
        // duplicating a user message in the target thread.
        if (sawEvent || attempt === 2) throw new Error("Amp forwarding failed");
        await sleep(1_000 * 2 ** attempt);
      } finally {
        clearTimeout(timeout);
      }
    }
  }
}
