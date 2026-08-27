export interface Env {
  DB: D1Database;
  /** Label photos for submissions awaiting review. Deleted on accept/reject (spec §6.3). */
  PHOTOS: R2Bucket;
  KV: KVNamespace;
  FDC_API_KEY: string;
  /** Bearer secret for every /v1/admin/* route. */
  ADMIN_SECRET: string;
  KROGER_CLIENT_ID: string;
  KROGER_CLIENT_SECRET: string;
  KROGER_PERSIST: "on" | "off";
  /** "apns" (default) | "fcm" — spec §6.5. */
  PUSH_PROVIDER: string;
  /** "sandbox" (default) | "production". */
  APNS_ENV: string;
  /** Contents of the AuthKey_XXXXXXXXXX.p8 file, PEM including the BEGIN/END lines. */
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  /** Firebase service-account JSON, used only when PUSH_PROVIDER = "fcm". */
  FCM_SERVICE_ACCOUNT_JSON: string;
  ENV: string;
  /**
   * Test-only trust anchor: base64 DER of a root certificate that replaces
   * Apple Root CA - G3. Never set in `wrangler.toml`, so production always
   * verifies against Apple.
   */
  APPSTORE_ROOT_CA_B64?: string;
  /**
   * I3 (final review) — comma-separated allowlist of App Store `environment`
   * claims ("Sandbox" | "Production") this Worker accepts, checked against
   * both a device-posted transaction JWS and a Server Notifications V2
   * payload. Defaults to `"Production"` when unset — see
   * `appstore/entitlement.ts`'s `allowedAppstoreEnvironments`. Set to
   * `"Sandbox,Production"` for a TestFlight/dev environment; production stays
   * `"Production"`-only so a free sandbox tester account can never mint real
   * Pro entitlements.
   */
  APPSTORE_ALLOWED_ENVIRONMENTS?: string;
}
