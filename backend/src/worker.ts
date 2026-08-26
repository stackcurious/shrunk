import type { Env } from "./env";
import app from "./index";
import { runKrogerSweep } from "./sweep";

/**
 * Workers entry point. `src/index.ts` stays the Hono app so tests can keep
 * calling `app.request(...)`; this module only adds the cron surface.
 */
export default {
  fetch: app.fetch,
  async scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    if (controller.cron === "0 */6 * * *") {
      ctx.waitUntil(runKrogerSweep(env)); // spec §6.2 — Kroger sweep
    }
  },
} satisfies ExportedHandler<Env>;
