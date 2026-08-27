# Shrunk — release runbook

Every step below needs a human with credentials — none of it can be scripted by an
agent. Run **Steps 0–12 top to bottom** for the first deploy. For every release after
that, only **"Ship a build"** and **"Acceptance"** (below Step 12) apply — everything
before them is one-time account provisioning.

As of this writing, none of it has been done: `wrangler whoami` shows a logged-in
Cloudflare account, but the `shrunk-api` Worker does not exist yet, `wrangler.toml`
still carries the placeholder `database_id` (`00000000-0000-0000-0000-000000000000`)
and KV `id` (32 zeros), and `Shrunk/Services/ShrunkAPIClient.swift` still points at
`https://shrunk-api.REPLACE-ME.workers.dev`. Start at Step 0.

## Accounts

| Account | Used for | Where the credential lives |
|---|---|---|
| Cloudflare (Workers **Paid**, $5/mo) | Worker, D1, R2, KV, cron | `wrangler login` on this machine |
| api.data.gov | USDA FoodData Central API key | Worker secret `FDC_API_KEY` |
| developer.kroger.com | Products + Locations APIs | Worker secrets `KROGER_CLIENT_ID` / `KROGER_CLIENT_SECRET` |
| Apple Developer (team `X4VJ56X38V`) | App ID `com.shrunk.app` with Push, APNs `.p8` key, signing | `~/keys/AuthKey_*.p8`, Worker secrets `APNS_KEY_P8` / `APNS_KEY_ID` / `APNS_TEAM_ID` |
| App Store Connect | Listing, subscriptions, TestFlight, Server Notifications | ASC API key in `~/.appstoreconnect/private_keys/` |

No credential belongs in this repository. `.gitignore` blocks `*.p8`, `*.p12`,
`*.mobileprovision` and `backend/.dev.vars`.

`$API` below always means the Worker origin printed by `wrangler deploy` —
`https://shrunk-api.<account>.workers.dev`.

---

- [ ] **Step 0: Find out what is already done**

Run this before anything else — it decides which sub-steps below are no-ops.

```bash
cd /Users/drao/Projects/shrunk/backend
npx wrangler whoami
grep -n "database_id\|^id = " wrangler.toml            # zeros mean unprovisioned
npx wrangler secret list
npx wrangler deployments list | head -20
npx wrangler d1 execute shrunk --remote --command "SELECT COUNT(*) AS products FROM products;"
npx wrangler d1 execute shrunk --remote --command "SELECT source, COUNT(*) AS n FROM observations GROUP BY source;"
cd /Users/drao/Projects/shrunk
grep -n "REPLACE-ME\|workers.dev\|baseURL" Shrunk/Services/ShrunkAPIClient.swift | head
grep -n "APNs spike result" docs/superpowers/specs/2026-08-26-shrunk-v2-design.md
grep -n "Permission email sent" docs/superpowers/specs/2026-08-26-shrunk-v2-design.md
```

`secret list` should eventually show `FDC_API_KEY`, `ADMIN_SECRET`, `KROGER_CLIENT_ID`,
`KROGER_CLIENT_SECRET`, `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID` (`FCM_SERVICE_ACCOUNT_JSON`
only if the APNs spike in Step 8 fails and `PUSH_PROVIDER` flips to `"fcm"`).

---

- [ ] **Step 1: Cloudflare login, D1, R2, and the FDC key**

```bash
cd /Users/drao/Projects/shrunk/backend
npx wrangler login                       # interactive, opens a browser
npx wrangler d1 create shrunk            # copy the printed database_id into wrangler.toml's [[d1_databases]] block
npx wrangler r2 bucket create shrunk-photos
npx wrangler secret put FDC_API_KEY      # free key from https://api.data.gov/signup/
npx wrangler secret put ADMIN_SECRET     # any long random string; keep it in your password manager
```

Confirm the account is on **Workers Paid** (dashboard → Workers & Pages → Plans) —
the FDC import below exceeds the free tier's 100k D1 writes/day.

- [ ] **Step 2: Migrate and deploy**

```bash
cd /Users/drao/Projects/shrunk/backend
npm run migrate:remote && npm run deploy
curl -s "$API/health"
```
Expected: `{"ok":true}`. `npm run deploy` prints the Worker's origin — that's `$API`
for every command below and the value Step 10 needs.

- [ ] **Step 3: Import USDA FoodData Central** (~430 MB download, several minutes to load)

```bash
cd /Users/drao/Projects/shrunk
curl -L -o /tmp/fdc_branded.zip "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_branded_food_csv_2026-04-30.zip"
python3 scripts/fdc_import.py --zip /tmp/fdc_branded.zip --out scripts/out/fdc.sql \
  --report scripts/out/report.json --curated data/trending.json
cat scripts/out/report.json
cd backend && npx wrangler d1 execute shrunk --remote --file ../scripts/out/fdc.sql
```
If wrangler rejects the file for size, split it — every line is a complete statement:

```bash
cd /Users/drao/Projects/shrunk/backend
split -l 1000 -d ../scripts/out/fdc.sql ../scripts/out/fdc_part_
for f in ../scripts/out/fdc_part_*; do npx wrangler d1 execute shrunk --remote --file "$f"; done
```

- [ ] **Step 4: Load the curated catalogue** (must run *after* Step 3 — the FDC file
  has no `DELETE`, and the curated file's `DELETE` only touches `source='curated'`)

```bash
cd /Users/drao/Projects/shrunk
python3 scripts/seed_curated.py --curated data/trending.json --out scripts/out/curated.sql
cd backend && npx wrangler d1 execute shrunk --remote --file ../scripts/out/curated.sql
npx wrangler d1 execute shrunk --remote --command "SELECT source, COUNT(*) AS n FROM observations GROUP BY source;"
```
Expected: a `curated` row with roughly 70 observations alongside the `fdc` rows.

---

- [ ] **Step 5: Kroger developer account and the permission email**

1. Register at https://developer.kroger.com, create an application with the
   **Products** and **Locations** APIs, and note the Client ID and Secret.
2. Send the email drafted in spec **Appendix A**
   (`docs/superpowers/specs/2026-08-26-shrunk-v2-design.md`) to the support contact
   on developer.kroger.com/support, with the Client ID filled in.
3. Record the send date in the spec. Under spec **§9**, replace the line
   `- Permission email draft: Appendix A. Send in week 1.` with:

   ```markdown
   - Permission email draft: Appendix A. **Sent YYYY-MM-DD** from privacy@stackcurious.com to Kroger developer support (client id `<client id>`); no reply as of YYYY-MM-DD. Until it is answered, `KROGER_PERSIST` stays on and `POST /v1/admin/purge-kroger` is the one-command retraction.
   ```
   Fill both dates with the real ones — this line is the record that the spec §9
   mitigation was actually carried out.

- [ ] **Step 6: KV, Kroger secrets, redeploy**

```bash
cd /Users/drao/Projects/shrunk/backend
npx wrangler kv namespace create KROGER   # copy the printed id into the [[kv_namespaces]] block, keep binding = "KV"
npx wrangler secret put KROGER_CLIENT_ID
npx wrangler secret put KROGER_CLIENT_SECRET
npm run deploy
```

- [ ] **Step 7: Verify Kroger live against a real Cincinnati store**

Every `/v1/kroger/*` route requires an `X-Device-Id` header that parses as a UUID —
its middleware (`backend/src/routes/kroger.ts:18-22`) 400s `invalid_device_id`
before touching KV or Kroger otherwise:

```bash
API=https://shrunk-api.<account>.workers.dev
DEVICE_ID=$(uuidgen | tr A-Z a-z)
curl -s -H "X-Device-Id: $DEVICE_ID" "$API/v1/kroger/locations?zip=45044" | head -c 400
# pick a locationId from the output, then:
curl -si -H "X-Device-Id: $DEVICE_ID" "$API/v1/kroger/product/0028400642255?locationId=<locationId>" | head -20
curl -s -H "X-Device-Id: $DEVICE_ID" "$API/v1/kroger/search?term=Beverages&locationId=<locationId>" | head -c 400
```
Expected: `"attribution":"Prices from Kroger"` in every body, a `Cache-Control`
header forwarded from Kroger on the product call, and a `regular` price present.
`{"error":"kroger_upstream","status":401}` means the credentials are wrong — re-run
Step 6. `{"error":"invalid_device_id"}` (400) means the `X-Device-Id` header is
missing or isn't a UUID — fix the header, not the credentials.

Confirm persistence landed:

```bash
npx wrangler d1 execute shrunk --remote --command "SELECT gtin, location_id, regular, size_raw FROM price_snapshots ORDER BY observed_at DESC LIMIT 5;"
```

**The literal-comma multi-id check.** `KrogerClient.products()` (`backend/src/kroger/client.ts`)
builds `filter.productId=<id1>,<id2>,...` for the six-hourly sweep cron
(`runKrogerSweep`, `0 */6 * * *`) — Kroger requires that separator to stay a literal
comma on the wire, not the `%2C` a naive `encodeURIComponent(ids.join(","))` would
produce, so the client encodes each id individually and joins with a literal comma
(see the `T4` comment at `backend/src/kroger/client.ts:102`). There is no public
`/v1/kroger/*` route that takes multiple ids — this path only runs inside the sweep
— so it can't be curled directly. It's locked down by `backend/test/kroger-client.test.ts`
and `backend/test/sweep.test.ts` (both assert the ids param decodes to a literal
comma, not `%2C`). Once two or more `(gtin, location_id)` pairs exist in
`price_snapshots` (after a user sets a store and watches a couple of products),
confirm it live by watching the next `0 */6 * * *` firing:

```bash
cd /Users/drao/Projects/shrunk/backend && npx wrangler tail --format pretty
```
Expected: a `runKrogerSweep` log line with `filter.productId=` followed by two or
more ids separated by a literal `,`.

---

- [ ] **Step 8: The APNs spike result** (spec §6.5)

`backend/spikes/apns-probe.ts` is a **throwaway** spike — it is not in the repo
(deleted at the end of Phase 1 Task 14) and answers one question: can a Worker's
outbound `fetch` reach Apple's APNs HTTP/2 endpoint? The inlined probe below posts to
`api.sandbox.push.apple.com` (the sandbox host, matching `APNS_ENV="sandbox"` for the
TestFlight period — see Step 9); the production Worker uses `api.push.apple.com` once
`APNS_ENV` flips to `"production"` at App Store release ("Ship a build" below), same
HTTP/2 question either way. Skip this step only if spec §6.5 already has a result
line. Otherwise, recreate and run it.

Needs, ahead of time: an APNs auth key (`.p8`) from developer.apple.com → Keys → "+" →
Apple Push Notifications service (this can be the same key Step 9 below sets as a
permanent Worker secret — download it once, use it for both), its Key ID, team id
`X4VJ56X38V`, and a device token (run the app on a real device with a temporary
`UIApplication.shared.registerForRemoteNotifications()` /
`didRegisterForRemoteNotificationsWithDeviceToken` print, or any existing
APNs-enabled test app).

```bash
mkdir -p /Users/drao/Projects/shrunk/backend/spikes
cat > /Users/drao/Projects/shrunk/backend/spikes/wrangler.apns.toml <<'EOF'
name = "shrunk-apns-probe"
main = "apns-probe.ts"
compatibility_date = "2026-08-01"
compatibility_flags = ["nodejs_compat"]
EOF
cat > /Users/drao/Projects/shrunk/backend/spikes/apns-probe.ts <<'EOF'
// THROWAWAY SPIKE — proves/disproves APNs delivery from a Worker. Not shipped.
// Secrets: APNS_KEY_P8 (PEM contents), APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC (bundle id), DEVICE_TOKEN.
interface Env { APNS_KEY_P8: string; APNS_KEY_ID: string; APNS_TEAM_ID: string; APNS_TOPIC: string; DEVICE_TOKEN: string }

const b64url = (buf: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

function pemToPkcs8(pem: string): ArrayBuffer {
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0)).buffer;
}

async function apnsJWT(env: Env): Promise<string> {
  const key = await crypto.subtle.importKey("pkcs8", pemToPkcs8(env.APNS_KEY_P8), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = b64url(new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = b64url(new TextEncoder().encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) })));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`));
  return `${header}.${claims}.${b64url(sig)}`;
}

export default {
  async fetch(_req: Request, env: Env): Promise<Response> {
    const jwt = await apnsJWT(env);
    const res = await fetch(`https://api.sandbox.push.apple.com/3/device/${env.DEVICE_TOKEN}`, {
      method: "POST",
      headers: { authorization: `bearer ${jwt}`, "apns-topic": env.APNS_TOPIC, "apns-push-type": "alert", "content-type": "application/json" },
      body: JSON.stringify({ aps: { alert: { title: "Shrunk", body: "APNs from Workers works" } } }),
    });
    return new Response(`APNs status ${res.status}: ${await res.text()}`);
  },
};
EOF
cd /Users/drao/Projects/shrunk/backend/spikes
npx wrangler secret put APNS_KEY_P8 -c wrangler.apns.toml   # paste the .p8 file contents
npx wrangler secret put APNS_KEY_ID -c wrangler.apns.toml
npx wrangler secret put APNS_TEAM_ID -c wrangler.apns.toml  # X4VJ56X38V
npx wrangler secret put APNS_TOPIC -c wrangler.apns.toml    # com.shrunk.app
npx wrangler secret put DEVICE_TOKEN -c wrangler.apns.toml
npx wrangler deploy -c wrangler.apns.toml
curl -s https://shrunk-apns-probe.<account>.workers.dev
```

Outcomes:
- `APNs status 200` and the device shows the notification → **direct APNs from the
  Worker.**
- `400 BadDeviceToken` / `403 InvalidProviderToken` → credentials issue, fix and
  retry (a 4xx from Apple still proves HTTP/2 connectivity, so this doesn't change
  the outcome once corrected).
- A transport error / `421` / "HTTP/1.1 not supported" style failure → **use
  Firebase Cloud Messaging HTTP v1** behind the same `PushSender` interface.

Record the result and tear the spike down:

```markdown
APNs spike result (YYYY-MM-DD): direct APNs from Workers returns 200 — Phase 4 ships `PUSH_PROVIDER="apns"`.
```
or, if it failed:
```markdown
APNs spike result (YYYY-MM-DD): direct APNs from Workers failed (<the error>) — Phase 4 ships `PUSH_PROVIDER="fcm"` behind the same `PushSender` interface.
```
Append that line to spec §6.5, then:

```bash
npx wrangler delete -c wrangler.apns.toml
cd /Users/drao/Projects/shrunk
rm -rf backend/spikes
git add docs/superpowers/specs/2026-08-26-shrunk-v2-design.md
git commit -m "docs: record APNs spike result (spec §6.5)" -- docs/superpowers/specs/2026-08-26-shrunk-v2-design.md
```
Whichever line you wrote must match `PUSH_PROVIDER` in `backend/wrangler.toml`:
`grep -n PUSH_PROVIDER backend/wrangler.toml`.

- [ ] **Step 9: APNs key and push secrets**

1. developer.apple.com → Certificates, Identifiers & Profiles → **Keys** → **+** →
   name `Shrunk APNs`, tick **Apple Push Notifications service (APNs)** → Register →
   download `AuthKey_XXXXXXXXXX.p8` (**one download only**; store it in `~/keys/`,
   never in the repo).
2. Confirm the App ID `com.shrunk.app` has **Push Notifications** enabled.

```bash
cd /Users/drao/Projects/shrunk/backend
npx wrangler secret put APNS_KEY_P8      # paste the whole file including BEGIN/END, then Ctrl-D
npx wrangler secret put APNS_KEY_ID      # the 10 characters from the filename
npx wrangler secret put APNS_TEAM_ID     # X4VJ56X38V
# only if Step 8's spike failed and PUSH_PROVIDER = "fcm":
npx wrangler secret put FCM_SERVICE_ACCOUNT_JSON
npx wrangler deploy
```
Expected: the deploy output lists all three schedules — `*/5 * * * *`, `0 */6 * * *`,
`0 13 * * 1`. `APNS_ENV` stays `"sandbox"` in `backend/wrangler.toml` for the whole
TestFlight period — flip it to `"production"` only when the App Store build (not
TestFlight) goes live (Step 10 below).

---

- [ ] **Step 10: The app's base URL**

```bash
cd /Users/drao/Projects/shrunk
grep -n "REPLACE-ME" Shrunk/Services/ShrunkAPIClient.swift
```
If it matches, edit `Shrunk/Services/ShrunkAPIClient.swift`: `defaultBaseURL` (line 14)
returns `URL(string: "https://shrunk-api.REPLACE-ME.workers.dev")!` — replace
`REPLACE-ME` with the real account subdomain from Step 2's deploy output (the
`#if DEBUG` branch just above it already routes to `http://localhost:8787` when the
`useLocalAPI` toggle is on, so nothing else in that function changes). Then rebuild:

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -10
```
(`BabSnap iPhone 17` is this machine's simulator — substitute whatever
`xcrun simctl list devices available` shows on yours.) Expected: no `REPLACE-ME`
anywhere in `Shrunk/`, and the suite passes.

---

- [ ] **Step 11: App Store Connect subscriptions and Server Notifications**

Work through `docs/ASC_SETUP.md` **§2** in App Store Connect: the `Shrunk Pro` group,
`com.shrunk.pro.yearly` ($14.99, subscription level 1) and `com.shrunk.pro.monthly`
($2.99, level 2), the 7-day Free Trial introductory offer on the **yearly product
only**, and App Store Server Notifications **Version 2** with both the Production
and Sandbox URLs set to `$API/v1/appstore/notifications`.

Then press ASC's **Test Notification** button and confirm it returns 200:

```bash
cd /Users/drao/Projects/shrunk/backend && npx wrangler tail --format pretty
```
Expected: the tail shows the notification arriving and being verified. A
`401 invalid_signature` means the URL is right but the pinned root or the parser is
wrong — that is a Phase 5 backend bug, not a configuration one.

- [ ] **Step 12: StoreKit configuration tests — enable the local daemon**

`ShrunkTests/StoreKitConfigurationTests.swift` drives `Shrunk.storekit` through a real
local `SKTestSession`. On a fresh machine (or after a macOS update) the daemon it
needs is disabled by default and every session-backed test in that file skips with
"SKTestSession unavailable on this machine". Fix it once:

```bash
sudo DevToolsSecurity -enable
```

If tests still skip after that, run them from the **Xcode IDE** (Product → Test, or
the diamond next to the test) rather than `xcodebuild test` from the command line —
a known Apple StoreKitTest issue (Apple Feedback FB22237318) can leave the daemon
unreachable specifically for CLI-launched runs even with Developer Mode enabled,
while the IDE-launched run reaches it. The structural test in that file
(`test_storekitConfiguration_declaresTheTwoSubscriptionsWithYearlyTrialOnly`) reads
`Shrunk.storekit` directly and never skips, so it alone is not proof the daemon
works — confirm at least one `SKTestSession`-backed test (e.g.
`test_configuration_exposesBothPlansInOneGroup`) actually ran, not skipped.

---

## Ship a build

1. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`.
2. `xcodegen generate`
3. Archive, export and upload — see `scripts/acceptance.md` and the commands in the
   phase-6 plan, Task 10 (`xcodebuild archive` → `-exportArchive` with
   `ExportOptions.plist` → `xcrun altool --upload-app`).
4. **Only when the App Store build (not TestFlight) goes live:**
   - Flip `APNS_ENV` to `"production"` in `backend/wrangler.toml`. TestFlight builds
     carry the `development` `aps-environment` entitlement and talk to the APNs
     sandbox; the App Store build is re-signed to `production` automatically at
     distribution, so this Worker-side flip must land at the same time or push
     silently breaks for whichever side is out of sync.
   - Flip `APPSTORE_ALLOWED_ENVIRONMENTS` to `"Production"` in `backend/wrangler.toml`
     (it is `"Sandbox,Production"` during the TestFlight period so sandbox testers
     can exercise the paywall). Once the App Store build is live, a real customer's
     App Store environment claim is always `"Production"`, so narrowing the allowlist
     to just that closes off a free sandbox tester account ever minting a real Pro
     entitlement in production — see the comment above `APPSTORE_ALLOWED_ENVIRONMENTS`
     in `backend/wrangler.toml` and its doc comment in `backend/src/env.ts`.
   - `npx wrangler deploy` to apply both.
5. **Immediately after that flip (and again after any future `APNS_ENV` change),
   send one real push and confirm delivery — do not wait for a routine alert.**
   An `APNS_ENV` / `aps-environment` mismatch (Worker still pointed at the sandbox
   host while the build carries the `production` entitlement, or the reverse)
   makes Apple answer `400 BadDeviceToken` — indistinguishable from a genuinely
   dead token. As the code stands, `runAlertDrain` (`backend/src/alerts.ts`)
   treats that response as a dead token and runs
   `UPDATE devices SET apns_token = NULL WHERE id = ?`, so a slipped flip doesn't
   just miss one push — it silently deregisters every Pro device it touches, up
   to 40 per five-minute drain tick, and the only recovery is each user
   relaunching the app to re-register. Verify the flip landed clean before that
   can compound:
   ```bash
   cd /Users/drao/Projects/shrunk/backend
   npx wrangler d1 execute shrunk --remote --command "SELECT id, apns_token IS NOT NULL AS has_token FROM devices WHERE pro_until > unixepoch() LIMIT 5;"
   curl -X POST "$API/v1/admin/verified-case" -H "Authorization: Bearer $ADMIN_SECRET" \
     -H "Content-Type: application/json" -d '{"gtin":"<a gtin a Pro device is watching>","brand":null}'
   npx wrangler tail --format pretty   # watch the next */5 * * * * drain
   ```
   Expected: the tail shows a successful send (not a `400`/`BadDeviceToken` line)
   to the device(s) queried above, and a re-run of the same `SELECT` still shows
   `has_token = 1` for them afterward. If you see `apns_token` go to `NULL` on a
   device that should still be registered, the environments are still mismatched
   — re-check `APNS_ENV` in `backend/wrangler.toml` against the build's
   `aps-environment` before doing anything else.

## Acceptance

`scripts/acceptance.md` — 35/35 curated verdicts, ≥60% kitchen-scan history, ≥25/30
live prices. Do not submit without it filled in.

## If Kroger revokes access (spec §9)

```bash
sed -i '' 's/KROGER_PERSIST = "on"/KROGER_PERSIST = "off"/' backend/wrangler.toml
cd backend && npx wrangler deploy
curl -X POST "$API/v1/admin/purge-kroger" -H "Authorization: Bearer $ADMIN_SECRET"
```
The app degrades to verdict + history + curated alternatives; nothing breaks.

## Status of the one-time steps

Fill this table in as you go — it is the answer to "did we ever actually do that?"

| Step | Done | Evidence |
|---|---|---|
| Cloudflare Workers Paid | | |
| D1 `shrunk` created and migrated | | `database_id` in `wrangler.toml` |
| R2 `shrunk-photos` created | | |
| KV namespace created (binding `KV`) | | id in `wrangler.toml` |
| All secrets set | | `npx wrangler secret list` |
| FDC release imported | | `scripts/out/report.json` line |
| Curated catalogue seeded | | `SELECT source, COUNT(*) FROM observations` |
| Kroger account + permission email | | spec §9 date line |
| Kroger live smoke test (locations/product/search) | | attribution + regular price in response |
| APNs key created, push verified | | spec §6.5 result line |
| App base URL substituted | | no `REPLACE-ME` in `Shrunk/` |
| ASC subscriptions + Server Notifications | | Test Notification 200 |
| StoreKit config daemon enabled | | `SKTestSession`-backed test ran, not skipped |
| Branch protection on `main` | | `gh api repos/stackcurious/shrunk/branches/main/protection` |
