import type { Env } from "./env";
import app from "./index";
import { runAlertDrain } from "./alerts";
import { runKrogerSweep } from "./sweep";

/**
 * Workers entry point. `src/index.ts` stays the Hono app so tests can keep
 * calling `app.request(...)`; this module only adds the cron surface (spec §6.2).
 */
export default {
  fetch: app.fetch,
  async scheduled(event: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    switch (event.cron) {
      case "*/5 * * * *":
        ctx.waitUntil(runAlertDrain(env));
        break;
      case "0 */6 * * *":
        ctx.waitUntil(runKrogerSweep(env));
        break;
    }
  },
} satisfies ExportedHandler<Env>;
