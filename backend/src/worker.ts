import type { Env } from "./env";
import app from "./index";
import { runAlertDrain } from "./alerts";
import { runWeeklyDigest } from "./digest";
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
        // C1 — per-device and per-job failures are already contained inside
        // runAlertDrain; this catches anything above that (e.g. the initial
        // job-scan query itself failing) so an unhandled rejection never
        // surfaces from ctx.waitUntil.
        ctx.waitUntil(runAlertDrain(env).catch(() => {}));
        break;
      case "0 */6 * * *":
        // I2 — per-pair failures are already contained inside runKrogerSweep;
        // this catches anything above that (e.g. the initial pair-selection
        // query itself failing) so an unhandled rejection never surfaces from
        // ctx.waitUntil.
        ctx.waitUntil(runKrogerSweep(env).catch(() => {}));
        break;
      case "0 1 * * 1":
        // C1 — per-device failures are already contained inside
        // runWeeklyDigest; this catches anything above that (e.g. the
        // weeklyCounts/device-list query itself failing).
        ctx.waitUntil(runWeeklyDigest(env).catch(() => {}));
        break;
    }
  },
} satisfies ExportedHandler<Env>;
