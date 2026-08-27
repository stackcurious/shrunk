import path from "node:path";
import { defineConfig } from "vitest/config";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";

export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            FDC_API_KEY: "test-key",
            ADMIN_SECRET: "test-secret",
            KROGER_CLIENT_ID: "test-client",
            KROGER_CLIENT_SECRET: "test-secret",
            KROGER_PERSIST: "off",
            PUSH_PROVIDER: "apns",
            APNS_ENV: "sandbox",
            APNS_KEY_P8: "",
            APNS_KEY_ID: "TESTKEYID1",
            APNS_TEAM_ID: "TESTTEAM01",
            FCM_SERVICE_ACCOUNT_JSON: "",
          },
        },
      }),
    ],
    test: {
      setupFiles: ["./test/apply-migrations.ts"],
    },
  };
});
