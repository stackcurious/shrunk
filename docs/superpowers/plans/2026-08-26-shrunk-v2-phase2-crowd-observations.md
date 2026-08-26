# Shrunk v2 — Phase 2: Label Capture & Crowd Observations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a shopper photograph a product's net-content line so the parsed size becomes a real observation in the database — auto-accepted when the on-device OCR gate clears 0.8, otherwise queued with its photo for a one-page admin review.

**Architecture:** On device, Vision OCR reads the label, a Swift port of the shared package-weight normalizer picks and parses the net-content line, and a confirm sheet lets the shopper fix the quantity before `POST /v1/observations` uploads it as multipart. The Worker recomputes the §6.3 confidence gate server-side (the client is never trusted with the verdict), writes a `submissions` row plus an `observations` row with `source='crowd'`, stores the photo in R2 only when the row lands `pending`, and queues an `alert_jobs(kind='size_drop')` row whenever an accepted crowd observation is smaller than the previous accepted same-kind one. A bearer-protected single-page admin app flips pending rows and deletes their photos.

**Tech Stack:** TypeScript, Hono 4, Wrangler 4, Cloudflare D1 + R2, Vitest with `@cloudflare/vitest-pool-workers` · Swift 5.9 / SwiftUI / AVFoundation / Vision / XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-26-shrunk-v2-design.md` (§5 `submissions` + `alert_jobs`, §5.1 normalization, §5.2 crowd trust, §6.1 `POST /v1/observations` and `GET|POST /v1/admin/review`, §6.3 crowd submission gate, §7 Label capture + ResultView, §8 error handling, §10 OCR parser & gate testing, §11 Week 2).

## Global Constraints

- Barcodes are stored and exchanged as **13-digit zero-padded GTINs** (spec §2). The Worker runs every inbound barcode through `normalizeGTIN` before touching the database.
- Quantities are normalized to **grams (mass), millilitres (volume), or count** with `unit_kind ∈ {mass, volume, count}`; observations of different kinds are never compared (spec §5.1).
- Two observations that normalize **within 1%** are the same size (spec §5.1). A crowd observation must clear that band before it counts as a size drop.
- Multi-segment package weights whose same-kind segments disagree by more than **2%** are discarded as malformed (spec §5.1).
- Crowd confidence is **0.5 (parsed) + 0.2 (kind matches the product's dominant kind) + 0.2 (within 0.5×–1.5× of the latest accepted observation) + 0.1 (OCR confidence ≥ 0.9)**; **≥ 0.8 → `accepted`**, otherwise `pending` (spec §5.2, §6.3). The gate is recomputed on the server; the client's own score is never read.
- Photos exist only to adjudicate a `pending` row. They are written to R2 **only** when the gate returns `pending`, and **deleted on accept or reject** (spec §6.3).
- Every `/v1/admin/*` route requires `Authorization: Bearer <ADMIN_SECRET>`.
- Copy that must appear verbatim: **"Not in our database yet — snap the label to add it"** (spec §8), **"Confirm with a label photo"** (spec §7), **"Couldn't reach Shrunk — check connection."** (spec §8).
- Cloudflare **Workers Paid**. No Kroger in this phase — no proxy routes, no `price_snapshots` writes, no `KROGER_PERSIST`.
- iOS 17+, Swift 5.9, `project.yml` is the source of truth. New Swift files under `Shrunk/` are picked up automatically by `xcodegen generate`; **test resources need an explicit `resources:` entry**.
- iOS tests: `xcodegen generate && xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17'`. Worker tests: `cd backend && npx vitest run`.
- Assume Phase 1 (`docs/superpowers/plans/2026-08-26-shrunk-v2-week1-data-backbone.md`) is complete: `backend/` exists with `src/index.ts`, `src/env.ts`, `src/db.ts`, `src/normalize.ts`, `src/gtin.ts`, `src/routes/product.ts`, `migrations/0001_init.sql`; `fixtures/package_weights.json` exists; `Shrunk/Services/ShrunkAPIClient.swift` exists with `fetchProduct(barcode:locationId:)` and `ProductDTO`.
- Commit after every task. Never commit `backend/node_modules`, `backend/.wrangler`, or `.dev.vars`.

## File Structure

```
backend/
  migrations/0002_submissions.sql      submissions + alert_jobs (spec §5)
  wrangler.toml                        + [[r2_buckets]] PHOTOS
  vitest.config.ts                     + ADMIN_SECRET test binding
  src/env.ts                           + PHOTOS: R2Bucket, ADMIN_SECRET: string
  src/db.ts                            + submission / observation-write / alert_jobs helpers
  src/gate.ts                          scoreSubmission — the §6.3 formula, pure
  src/crowd.ts                         finalizeAcceptance — unit_kind backfill + size_drop queueing
  src/routes/observations.ts           POST /v1/observations
  src/routes/admin.ts                  auth + review page + photo + decision
  src/index.ts                         mounts the two new routers
  test/db-submissions.test.ts
  test/gate.test.ts
  test/observations.test.ts
  test/admin.test.ts
Shrunk/
  Features/Contribute/NetContentParser.swift        Swift port of the normalizer + line picker
  Features/Contribute/LabelOCRService.swift         Vision text recognition
  Features/Contribute/ContributeViewModel.swift     capture → OCR → confirm → submit
  Features/Contribute/LabelCaptureController.swift  AVCaptureSession + still capture
  Features/Contribute/LabelCaptureView.swift        camera screen
  Features/Contribute/ContributeConfirmSheet.swift  editable quantity + unit
  Services/DeviceIdentity.swift                     stable per-install UUID in @AppStorage
  Services/ShrunkAPIClient.swift                    + submitObservation(...)
  Models/ShrunkProduct.swift                        + needsConfirmation
  Features/Result/ResultView.swift                  two entry points + toast
  Features/Result/ResultViewModel.swift             + reload(barcode:)
  Resources/Info.plist                              camera usage string covers label photos
ShrunkTests/
  NetContentParserTests.swift
  LabelOCRServiceTests.swift
  ContributeViewModelTests.swift
  ShrunkAPIClientTests.swift                        + multipart + submitObservation tests
project.yml                                         fixtures/package_weights.json → test resources
```

---

### Task 1: `submissions` + `alert_jobs` schema, R2 binding, D1 helpers

**Files:**
- Create: `backend/migrations/0002_submissions.sql`
- Modify: `backend/src/env.ts`
- Modify: `backend/src/db.ts`
- Modify: `backend/wrangler.toml`
- Modify: `backend/vitest.config.ts`
- Test: `backend/test/db-submissions.test.ts`

**Interfaces:**
- Consumes: `ProductRow`, `getProduct`, `insertProduct` from Phase 1 `src/db.ts`.
- Produces: `Env { DB: D1Database; PHOTOS: R2Bucket; FDC_API_KEY: string; ADMIN_SECRET: string; ENV: string }`.
- Produces (`src/db.ts`):
  - `SubmissionRow { id: string; device_id: string; gtin: string; photo_key: string | null; ocr_text: string | null; parsed_quantity: number; parsed_kind: string; status: string; created_at: number; reviewed_at: number | null }`
  - `PendingSubmissionRow extends SubmissionRow { name: string; brand: string }`
  - `NewObservation { gtin; quantity; unit_kind; raw_text: string | null; observed_at; source; source_ref: string | null; confidence; status }`
  - `NewAlertJob { kind: string; gtin: string; brand: string | null; location_id: string | null; payload: string; created_at: number }`
  - `insertObservation(db, row: NewObservation): Promise<number>` — returns the new observation id
  - `setObservationStatus(db, id: number, status: string): Promise<void>`
  - `getLatestAcceptedObservation(db, gtin: string, unitKind: string): Promise<{ id: number; quantity: number } | null>`
  - `getObservationBySubmission(db, submissionId: string): Promise<{ id: number; gtin: string; quantity: number; unit_kind: string; status: string } | null>`
  - `insertSubmission(db, row: Omit<SubmissionRow, "reviewed_at">): Promise<void>`
  - `getSubmission(db, id: string): Promise<SubmissionRow | null>`
  - `listPendingSubmissions(db, limit?: number): Promise<PendingSubmissionRow[]>`
  - `markSubmissionReviewed(db, id: string, status: string, reviewedAt: number): Promise<void>`
  - `insertAlertJob(db, job: NewAlertJob): Promise<void>`
  - `setProductUnitKindIfMissing(db, gtin: string, unitKind: string, now: number): Promise<void>`

- [ ] **Step 1: Create the R2 bucket and set the admin secret**

```bash
cd backend
npx wrangler r2 bucket create shrunk-photos
npx wrangler secret put ADMIN_SECRET      # paste a long random string, e.g. `openssl rand -hex 24`
```

Add the same secret to the git-ignored `backend/.dev.vars` so `wrangler dev` works locally:

```
ADMIN_SECRET=dev-secret
```

- [ ] **Step 2: Add the bindings**

Append to `backend/wrangler.toml`:

```toml
[[r2_buckets]]
binding = "PHOTOS"
bucket_name = "shrunk-photos"
```

Replace `backend/src/env.ts` entirely:

```ts
export interface Env {
  DB: D1Database;
  /** Label photos for submissions awaiting review. Deleted on accept/reject (spec §6.3). */
  PHOTOS: R2Bucket;
  FDC_API_KEY: string;
  /** Bearer secret for every /v1/admin/* route. */
  ADMIN_SECRET: string;
  ENV: string;
}
```

In `backend/vitest.config.ts`, add `ADMIN_SECRET` to the miniflare bindings (the R2 bucket comes from `wrangler.toml` and is simulated locally):

```ts
          miniflare: {
            bindings: { TEST_MIGRATIONS: migrations, FDC_API_KEY: "test-key", ADMIN_SECRET: "test-secret" },
          },
```

- [ ] **Step 3: Write the migration**

`backend/migrations/0002_submissions.sql`:

```sql
-- Crowd label submissions (spec §5). `id` is the UUID also written to
-- observations.source_ref, which is how a submission finds its observation.
CREATE TABLE submissions (
  id              TEXT PRIMARY KEY,
  device_id       TEXT NOT NULL,
  gtin            TEXT NOT NULL,
  photo_key       TEXT,
  ocr_text        TEXT,
  parsed_quantity REAL NOT NULL,
  parsed_kind     TEXT NOT NULL CHECK (parsed_kind IN ('mass','volume','count')),
  status          TEXT NOT NULL CHECK (status IN ('accepted','pending','rejected')),
  created_at      INTEGER NOT NULL,
  reviewed_at     INTEGER
);
CREATE INDEX sub_status ON submissions(status, created_at);

-- Queued pushes (spec §5). The cron that drains this arrives in Phase 4; this
-- phase only ever writes kind='size_drop'. No CHECK on `kind` — Phase 4 adds
-- 'price_hike', 'verified_case' and 'digest'.
CREATE TABLE alert_jobs (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  kind        TEXT NOT NULL,
  gtin        TEXT,
  brand       TEXT,
  location_id TEXT,
  payload     TEXT,
  created_at  INTEGER NOT NULL,
  sent_at     INTEGER
);
CREATE INDEX aj_unsent ON alert_jobs(sent_at, created_at);
```

- [ ] **Step 4: Write the failing tests**

`backend/test/db-submissions.test.ts`:

```ts
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import {
  getLatestAcceptedObservation,
  getObservationBySubmission,
  getSubmission,
  insertAlertJob,
  insertObservation,
  insertSubmission,
  listPendingSubmissions,
  markSubmissionReviewed,
  setObservationStatus,
  setProductUnitKindIfMissing,
} from "../src/db";

const GTIN = "0028400642255";

async function seedProduct(unitKind: string | null) {
  await env.DB.prepare(
    "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'Gatorade', 'Gatorade', 'Beverages', NULL, ?, 1, 1)"
  ).bind(GTIN, unitKind).run();
}

function submission(id: string, status: string, photoKey: string | null = null) {
  return {
    id, device_id: "device-1", gtin: GTIN, photo_key: photoKey,
    ocr_text: "NET WT 28 OZ (794g)", parsed_quantity: 793.786, parsed_kind: "mass",
    status, created_at: 1700000000,
  };
}

describe("submission and alert_jobs helpers", () => {
  beforeEach(async () => {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM alert_jobs"),
      env.DB.prepare("DELETE FROM submissions"),
      env.DB.prepare("DELETE FROM observations"),
      env.DB.prepare("DELETE FROM products"),
    ]);
  });

  it("round-trips a submission", async () => {
    await seedProduct("mass");
    await insertSubmission(env.DB, submission("sub-1", "pending", "submissions/sub-1.jpg"));
    const row = await getSubmission(env.DB, "sub-1");
    expect(row).toMatchObject({
      id: "sub-1", device_id: "device-1", gtin: GTIN, photo_key: "submissions/sub-1.jpg",
      ocr_text: "NET WT 28 OZ (794g)", parsed_quantity: 793.786, parsed_kind: "mass",
      status: "pending", created_at: 1700000000, reviewed_at: null,
    });
    expect(await getSubmission(env.DB, "nope")).toBeNull();
  });

  it("lists only pending submissions and joins the product name", async () => {
    await seedProduct("mass");
    await insertSubmission(env.DB, submission("sub-1", "pending"));
    await insertSubmission(env.DB, submission("sub-2", "accepted"));
    const rows = await listPendingSubmissions(env.DB);
    expect(rows.map((r) => r.id)).toEqual(["sub-1"]);
    expect(rows[0].name).toBe("Gatorade");
    expect(rows[0].brand).toBe("Gatorade");
  });

  it("lists a submission for a product that does not exist yet", async () => {
    await insertSubmission(env.DB, submission("sub-1", "pending"));
    const rows = await listPendingSubmissions(env.DB);
    expect(rows).toHaveLength(1);
    expect(rows[0].name).toBe("");
  });

  it("marks a submission reviewed and drops its photo key", async () => {
    await seedProduct("mass");
    await insertSubmission(env.DB, submission("sub-1", "pending", "submissions/sub-1.jpg"));
    await markSubmissionReviewed(env.DB, "sub-1", "rejected", 1700000900);
    const row = await getSubmission(env.DB, "sub-1");
    expect(row).toMatchObject({ status: "rejected", reviewed_at: 1700000900, photo_key: null });
  });

  it("inserts an observation, returns its id, and flips its status", async () => {
    await seedProduct("mass");
    const id = await insertObservation(env.DB, {
      gtin: GTIN, quantity: 793.786, unit_kind: "mass", raw_text: "NET WT 28 OZ (794g)",
      observed_at: 1700000000, source: "crowd", source_ref: "sub-1", confidence: 0.7, status: "pending",
    });
    expect(id).toBeGreaterThan(0);

    const found = await getObservationBySubmission(env.DB, "sub-1");
    expect(found).toMatchObject({ id, gtin: GTIN, quantity: 793.786, unit_kind: "mass", status: "pending" });

    await setObservationStatus(env.DB, id, "accepted");
    expect((await getObservationBySubmission(env.DB, "sub-1"))?.status).toBe("accepted");
  });

  it("finds the newest accepted observation of the requested kind only", async () => {
    await seedProduct("mass");
    await insertObservation(env.DB, { gtin: GTIN, quantity: 907.184, unit_kind: "mass", raw_text: null, observed_at: 1517443200, source: "fdc", source_ref: "1", confidence: 0.9, status: "accepted" });
    await insertObservation(env.DB, { gtin: GTIN, quantity: 850, unit_kind: "mass", raw_text: null, observed_at: 1625097600, source: "fdc", source_ref: "2", confidence: 0.9, status: "accepted" });
    await insertObservation(env.DB, { gtin: GTIN, quantity: 500, unit_kind: "mass", raw_text: null, observed_at: 1700000000, source: "crowd", source_ref: "sub-1", confidence: 0.5, status: "pending" });
    await insertObservation(env.DB, { gtin: GTIN, quantity: 828.058, unit_kind: "volume", raw_text: null, observed_at: 1700000000, source: "fdc", source_ref: "3", confidence: 0.9, status: "accepted" });

    expect((await getLatestAcceptedObservation(env.DB, GTIN, "mass"))?.quantity).toBe(850);
    expect((await getLatestAcceptedObservation(env.DB, GTIN, "volume"))?.quantity).toBe(828.058);
    expect(await getLatestAcceptedObservation(env.DB, GTIN, "count")).toBeNull();
  });

  it("fills a missing dominant kind but never overwrites one", async () => {
    await seedProduct(null);
    await setProductUnitKindIfMissing(env.DB, GTIN, "mass", 1700000000);
    let row = await env.DB.prepare("SELECT unit_kind, updated_at FROM products WHERE gtin = ?").bind(GTIN).first<{ unit_kind: string; updated_at: number }>();
    expect(row).toMatchObject({ unit_kind: "mass", updated_at: 1700000000 });

    await setProductUnitKindIfMissing(env.DB, GTIN, "volume", 1700009999);
    row = await env.DB.prepare("SELECT unit_kind, updated_at FROM products WHERE gtin = ?").bind(GTIN).first<{ unit_kind: string; updated_at: number }>();
    expect(row).toMatchObject({ unit_kind: "mass", updated_at: 1700000000 });
  });

  it("round-trips an alert job", async () => {
    await insertAlertJob(env.DB, {
      kind: "size_drop", gtin: GTIN, brand: "Gatorade", location_id: null,
      payload: JSON.stringify({ percent_change: -12.5 }), created_at: 1700000000,
    });
    const row = await env.DB.prepare("SELECT kind, gtin, brand, location_id, payload, created_at, sent_at FROM alert_jobs").first<any>();
    expect(row).toMatchObject({ kind: "size_drop", gtin: GTIN, brand: "Gatorade", location_id: null, created_at: 1700000000, sent_at: null });
    expect(JSON.parse(row.payload).percent_change).toBe(-12.5);
  });
});
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `cd backend && npx vitest run test/db-submissions.test.ts`
Expected: FAIL — `does not provide an export named 'insertSubmission'` (and siblings).

- [ ] **Step 6: Implement the helpers**

Append to `backend/src/db.ts`:

```ts
export interface SubmissionRow {
  id: string;
  device_id: string;
  gtin: string;
  photo_key: string | null;
  ocr_text: string | null;
  parsed_quantity: number;
  parsed_kind: string;
  status: string;
  created_at: number;
  reviewed_at: number | null;
}

export interface PendingSubmissionRow extends SubmissionRow {
  name: string;
  brand: string;
}

export interface NewObservation {
  gtin: string;
  quantity: number;
  unit_kind: string;
  raw_text: string | null;
  observed_at: number;
  source: string;
  source_ref: string | null;
  confidence: number;
  status: string;
}

export interface NewAlertJob {
  kind: string;
  gtin: string;
  brand: string | null;
  location_id: string | null;
  payload: string;
  created_at: number;
}

export async function insertObservation(db: D1Database, row: NewObservation): Promise<number> {
  const result = await db
    .prepare(
      "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    )
    .bind(
      row.gtin, row.quantity, row.unit_kind, row.raw_text, row.observed_at,
      row.source, row.source_ref, row.confidence, row.status, Math.floor(Date.now() / 1000)
    )
    .run();
  return Number(result.meta.last_row_id);
}

export async function setObservationStatus(db: D1Database, id: number, status: string): Promise<void> {
  await db.prepare("UPDATE observations SET status = ? WHERE id = ?").bind(status, id).run();
}

export async function getLatestAcceptedObservation(
  db: D1Database, gtin: string, unitKind: string
): Promise<{ id: number; quantity: number } | null> {
  return db
    .prepare(
      "SELECT id, quantity FROM observations WHERE gtin = ? AND unit_kind = ? AND status = 'accepted' ORDER BY observed_at DESC, id DESC LIMIT 1"
    )
    .bind(gtin, unitKind)
    .first<{ id: number; quantity: number }>();
}

export async function getObservationBySubmission(
  db: D1Database, submissionId: string
): Promise<{ id: number; gtin: string; quantity: number; unit_kind: string; status: string } | null> {
  return db
    .prepare(
      "SELECT id, gtin, quantity, unit_kind, status FROM observations WHERE source = 'crowd' AND source_ref = ? LIMIT 1"
    )
    .bind(submissionId)
    .first<{ id: number; gtin: string; quantity: number; unit_kind: string; status: string }>();
}

export async function insertSubmission(db: D1Database, row: Omit<SubmissionRow, "reviewed_at">): Promise<void> {
  await db
    .prepare(
      "INSERT INTO submissions (id, device_id, gtin, photo_key, ocr_text, parsed_quantity, parsed_kind, status, created_at, reviewed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)"
    )
    .bind(
      row.id, row.device_id, row.gtin, row.photo_key, row.ocr_text,
      row.parsed_quantity, row.parsed_kind, row.status, row.created_at
    )
    .run();
}

export async function getSubmission(db: D1Database, id: string): Promise<SubmissionRow | null> {
  return db
    .prepare(
      "SELECT id, device_id, gtin, photo_key, ocr_text, parsed_quantity, parsed_kind, status, created_at, reviewed_at FROM submissions WHERE id = ?"
    )
    .bind(id)
    .first<SubmissionRow>();
}

export async function listPendingSubmissions(db: D1Database, limit = 100): Promise<PendingSubmissionRow[]> {
  const { results } = await db
    .prepare(
      `SELECT s.id, s.device_id, s.gtin, s.photo_key, s.ocr_text, s.parsed_quantity, s.parsed_kind,
              s.status, s.created_at, s.reviewed_at,
              COALESCE(p.name, '') AS name, COALESCE(p.brand, '') AS brand
       FROM submissions s LEFT JOIN products p ON p.gtin = s.gtin
       WHERE s.status = 'pending'
       ORDER BY s.created_at ASC
       LIMIT ?`
    )
    .bind(limit)
    .all<PendingSubmissionRow>();
  return results;
}

export async function markSubmissionReviewed(
  db: D1Database, id: string, status: string, reviewedAt: number
): Promise<void> {
  // photo_key is cleared alongside the R2 delete so the row can never point at
  // an object that no longer exists.
  await db
    .prepare("UPDATE submissions SET status = ?, reviewed_at = ?, photo_key = NULL WHERE id = ?")
    .bind(status, reviewedAt, id)
    .run();
}

export async function insertAlertJob(db: D1Database, job: NewAlertJob): Promise<void> {
  await db
    .prepare(
      "INSERT INTO alert_jobs (kind, gtin, brand, location_id, payload, created_at, sent_at) VALUES (?, ?, ?, ?, ?, ?, NULL)"
    )
    .bind(job.kind, job.gtin, job.brand, job.location_id, job.payload, job.created_at)
    .run();
}

export async function setProductUnitKindIfMissing(
  db: D1Database, gtin: string, unitKind: string, now: number
): Promise<void> {
  await db
    .prepare("UPDATE products SET unit_kind = ?, updated_at = ? WHERE gtin = ? AND unit_kind IS NULL")
    .bind(unitKind, now, gtin)
    .run();
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd backend && npx vitest run && npx tsc --noEmit`
Expected: the 8 new tests pass alongside every Phase 1 test; typecheck clean.

- [ ] **Step 8: Commit**

```bash
git add backend/migrations/0002_submissions.sql backend/src/env.ts backend/src/db.ts \
        backend/wrangler.toml backend/vitest.config.ts backend/test/db-submissions.test.ts
git commit -m "feat(backend): submissions + alert_jobs schema, R2 binding, D1 helpers"
```

---

### Task 2: Crowd submission gate (spec §6.3)

**Files:**
- Create: `backend/src/gate.ts`
- Test: `backend/test/gate.test.ts`

**Interfaces:**
- Consumes: `UnitKind` from Phase 1 `src/normalize.ts`.
- Produces: `ACCEPT_THRESHOLD = 0.8`
- Produces: `GateInput { quantity: number; unitKind: string; ocrConfidence: number; productUnitKind: string | null; latestAcceptedQuantity: number | null }`
- Produces: `GateResult { confidence: number; status: "accepted" | "pending"; components: { parsed: number; kindMatch: number; range: number; ocr: number } }`
- Produces: `scoreSubmission(input: GateInput): GateResult` — pure, no I/O.

- [ ] **Step 1: Write the failing tests**

`backend/test/gate.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { scoreSubmission } from "../src/gate";

const base = {
  quantity: 793.786,
  unitKind: "mass",
  ocrConfidence: 0,
  productUnitKind: null as string | null,
  latestAcceptedQuantity: null as number | null,
};

describe("scoreSubmission components", () => {
  it("gives 0.5 for a parsed quantity alone and holds it pending", () => {
    const result = scoreSubmission(base);
    expect(result.components).toEqual({ parsed: 0.5, kindMatch: 0, range: 0, ocr: 0 });
    expect(result.confidence).toBe(0.5);
    expect(result.status).toBe("pending");
  });

  it("gives 0 for parsed when the quantity is not a positive number", () => {
    expect(scoreSubmission({ ...base, quantity: 0 }).components.parsed).toBe(0);
    expect(scoreSubmission({ ...base, quantity: -5 }).components.parsed).toBe(0);
    expect(scoreSubmission({ ...base, quantity: Number.NaN }).components.parsed).toBe(0);
  });

  it("gives 0 for parsed when the unit kind is not one of mass/volume/count", () => {
    expect(scoreSubmission({ ...base, unitKind: "grams" }).components.parsed).toBe(0);
    expect(scoreSubmission({ ...base, unitKind: "" }).components.parsed).toBe(0);
  });

  it("adds 0.2 only when the kind matches the product's dominant kind", () => {
    expect(scoreSubmission({ ...base, productUnitKind: "mass" }).components.kindMatch).toBe(0.2);
    expect(scoreSubmission({ ...base, productUnitKind: "volume" }).components.kindMatch).toBe(0);
    expect(scoreSubmission({ ...base, productUnitKind: null }).components.kindMatch).toBe(0);
  });

  it("adds 0.2 only inside 0.5x-1.5x of the latest accepted observation", () => {
    const at = (quantity: number) => scoreSubmission({ ...base, quantity, latestAcceptedQuantity: 1000 }).components.range;
    expect(at(500)).toBe(0.2);    // exactly 0.5x
    expect(at(1500)).toBe(0.2);   // exactly 1.5x
    expect(at(1000)).toBe(0.2);
    expect(at(499)).toBe(0);
    expect(at(1501)).toBe(0);
    expect(scoreSubmission({ ...base, latestAcceptedQuantity: null }).components.range).toBe(0);
    expect(scoreSubmission({ ...base, latestAcceptedQuantity: 0 }).components.range).toBe(0);
  });

  it("adds 0.1 only when OCR confidence reaches 0.9", () => {
    expect(scoreSubmission({ ...base, ocrConfidence: 0.9 }).components.ocr).toBe(0.1);
    expect(scoreSubmission({ ...base, ocrConfidence: 1 }).components.ocr).toBe(0.1);
    expect(scoreSubmission({ ...base, ocrConfidence: 0.89 }).components.ocr).toBe(0);
  });
});

describe("scoreSubmission threshold", () => {
  it("accepts at exactly 0.8 despite floating-point addition", () => {
    // 0.5 + 0.2 + 0.1 is 0.7999999999999999 in IEEE-754. It must still accept.
    const result = scoreSubmission({ ...base, productUnitKind: "mass", ocrConfidence: 0.95 });
    expect(result.confidence).toBe(0.8);
    expect(result.status).toBe("accepted");
  });

  it("accepts at 0.8 from parsed + range + ocr when the product has no dominant kind", () => {
    const result = scoreSubmission({ ...base, latestAcceptedQuantity: 907.184, ocrConfidence: 0.95 });
    expect(result.confidence).toBe(0.8);
    expect(result.status).toBe("accepted");
  });

  it("holds 0.7 pending", () => {
    const result = scoreSubmission({ ...base, productUnitKind: "mass" });
    expect(result.confidence).toBe(0.7);
    expect(result.status).toBe("pending");
  });

  it("scores a perfect submission 1.0", () => {
    const result = scoreSubmission({
      ...base, productUnitKind: "mass", latestAcceptedQuantity: 907.184, ocrConfidence: 0.97,
    });
    expect(result.confidence).toBe(1);
    expect(result.status).toBe("accepted");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && npx vitest run test/gate.test.ts`
Expected: FAIL — `Cannot find module '../src/gate'`.

- [ ] **Step 3: Implement the gate**

`backend/src/gate.ts`:

```ts
import type { UnitKind } from "./normalize";

const VALID_KINDS: string[] = ["mass", "volume", "count"] satisfies UnitKind[];

/** Spec §5.2: crowd rows at or above this land `accepted`, the rest `pending`. */
export const ACCEPT_THRESHOLD = 0.8;

export interface GateInput {
  /** Normalized quantity the device parsed (grams / millilitres / count). */
  quantity: number;
  unitKind: string;
  /** Vision's confidence for the line the quantity came from, 0..1. */
  ocrConfidence: number;
  /** The product's dominant kind, or null when we have never established one. */
  productUnitKind: string | null;
  /** Latest accepted observation of the same kind, or null when there is none. */
  latestAcceptedQuantity: number | null;
}

export interface GateResult {
  confidence: number;
  status: "accepted" | "pending";
  components: { parsed: number; kindMatch: number; range: number; ocr: number };
}

/**
 * Spec §6.3:
 *   0.5 parsed + 0.2 kind matches dominant + 0.2 within 0.5x-1.5x of the latest
 *   accepted observation + 0.1 OCR confidence >= 0.9.
 *
 * Always recomputed server-side — the device's own score is advisory only.
 */
export function scoreSubmission(input: GateInput): GateResult {
  const parsed =
    Number.isFinite(input.quantity) && input.quantity > 0 && VALID_KINDS.includes(input.unitKind)
      ? 0.5
      : 0;

  const kindMatch = input.productUnitKind !== null && input.productUnitKind === input.unitKind ? 0.2 : 0;

  const latest = input.latestAcceptedQuantity;
  const range =
    latest !== null && latest > 0 && input.quantity >= latest * 0.5 && input.quantity <= latest * 1.5
      ? 0.2
      : 0;

  const ocr = Number.isFinite(input.ocrConfidence) && input.ocrConfidence >= 0.9 ? 0.1 : 0;

  // 0.5 + 0.2 + 0.1 evaluates to 0.7999999999999999 in IEEE-754 doubles, which
  // would fail a bare `>= 0.8`. Round to cents before comparing or reporting.
  const confidence = Math.round((parsed + kindMatch + range + ocr) * 100) / 100;

  return {
    confidence,
    status: confidence >= ACCEPT_THRESHOLD ? "accepted" : "pending",
    components: { parsed, kindMatch, range, ocr },
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && npx vitest run test/gate.test.ts && npx tsc --noEmit`
Expected: `10 passed`.

If `satisfies UnitKind[]` is rejected by the installed TypeScript, drop the clause and write `const VALID_KINDS: string[] = ["mass", "volume", "count"];`.

- [ ] **Step 5: Commit**

```bash
git add backend/src/gate.ts backend/test/gate.test.ts
git commit -m "feat(backend): crowd submission confidence gate (spec 6.3)"
```

---

### Task 3: `POST /v1/observations`

**Files:**
- Create: `backend/src/crowd.ts`
- Create: `backend/src/routes/observations.ts`
- Modify: `backend/src/index.ts`
- Test: `backend/test/observations.test.ts`

**Interfaces:**
- Consumes: `normalizeGTIN` (Phase 1 `src/gtin.ts`); `getProduct`, `insertProduct`, `ProductRow` (Phase 1 `src/db.ts`); all Task 1 helpers; `scoreSubmission` (Task 2).
- Produces: `finalizeAcceptance(db: D1Database, input: AcceptanceInput): Promise<boolean>` in `src/crowd.ts`, where `AcceptanceInput { gtin: string; quantity: number; unitKind: string; previousQuantity: number | null; brand: string | null; now: number }`. Returns `true` when it queued a `size_drop` alert job. Reused by Task 4.
- Produces: `observationsRoute` — `POST /v1/observations`, `multipart/form-data` with fields `gtin`, `quantity`, `unit_kind`, `raw_text`, `ocr_confidence`, `device_id`, optional `photo`.
- Produces response: `200 { "status": "accepted" | "pending", "confidence": 0.8, "observation_id": 42 }`.
  Errors: `400 { "error": "invalid_multipart" | "invalid_gtin" | "missing_device_id" | "invalid_quantity" | "invalid_unit_kind" | "photo_too_large" }`.

- [ ] **Step 1: Write the failing tests**

`backend/test/observations.test.ts`:

```ts
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";

const GTIN = "0028400642255";

function body(overrides: Record<string, string> = {}, photo?: Blob): FormData {
  const fields: Record<string, string> = {
    gtin: GTIN,
    device_id: "device-1",
    quantity: "793.786",
    unit_kind: "mass",
    raw_text: "NET WT 28 OZ (794g)",
    ocr_confidence: "0.95",
    ...overrides,
  };
  const form = new FormData();
  for (const [key, value] of Object.entries(fields)) form.append(key, value);
  if (photo) form.append("photo", photo, "label.jpg");
  return form;
}

const jpeg = () => new Blob([new Uint8Array([0xff, 0xd8, 0xff, 0xd9])], { type: "image/jpeg" });

async function post(form: FormData) {
  return app.request("/v1/observations", { method: "POST", body: form }, env);
}

async function seedProduct(unitKind: string | null) {
  await env.DB.prepare(
    "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'Gatorade', 'Gatorade', 'Beverages', NULL, ?, 1, 1)"
  ).bind(GTIN, unitKind).run();
}

async function seedAccepted(quantity: number, unitKind = "mass") {
  await env.DB.prepare(
    "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, ?, '32 oz', 1517443200, 'fdc', '1', 0.9, 'accepted', 1)"
  ).bind(GTIN, quantity, unitKind).run();
}

async function photoKeys(): Promise<string[]> {
  return (await env.PHOTOS.list()).objects.map((o) => o.key);
}

describe("POST /v1/observations", () => {
  beforeEach(async () => {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM alert_jobs"),
      env.DB.prepare("DELETE FROM submissions"),
      env.DB.prepare("DELETE FROM observations"),
      env.DB.prepare("DELETE FROM products"),
    ]);
    for (const key of await photoKeys()) await env.PHOTOS.delete(key);
  });

  it("accepts a high-confidence submission, keeps no photo, and queues a size drop", async () => {
    await seedProduct("mass");
    await seedAccepted(907.184);

    const res = await post(body({}, jpeg()));
    expect(res.status).toBe(200);
    const json = await res.json<{ status: string; confidence: number; observation_id: number }>();
    expect(json.status).toBe("accepted");
    expect(json.confidence).toBe(1);
    expect(json.observation_id).toBeGreaterThan(0);

    const observation = await env.DB.prepare(
      "SELECT quantity, unit_kind, raw_text, source, source_ref, confidence, status FROM observations WHERE id = ?"
    ).bind(json.observation_id).first<any>();
    expect(observation).toMatchObject({
      quantity: 793.786, unit_kind: "mass", raw_text: "NET WT 28 OZ (794g)",
      source: "crowd", confidence: 1, status: "accepted",
    });

    const submission = await env.DB.prepare("SELECT id, status, photo_key, device_id, parsed_quantity FROM submissions").first<any>();
    expect(submission).toMatchObject({ status: "accepted", photo_key: null, device_id: "device-1", parsed_quantity: 793.786 });
    expect(observation.source_ref).toBe(submission.id);

    // Accepted rows never need a human, so the photo is never written (spec §6.3).
    expect(await photoKeys()).toEqual([]);

    const job = await env.DB.prepare("SELECT kind, gtin, brand, location_id, payload, sent_at FROM alert_jobs").first<any>();
    expect(job).toMatchObject({ kind: "size_drop", gtin: GTIN, brand: "Gatorade", location_id: null, sent_at: null });
    expect(JSON.parse(job.payload)).toEqual({
      gtin: GTIN, unit_kind: "mass", previous_quantity: 907.184, quantity: 793.786,
      percent_change: -12.5, source: "crowd",
    });
  });

  it("holds a low-confidence submission pending and stores its photo", async () => {
    await seedProduct(null);

    const res = await post(body({ ocr_confidence: "0.4" }, jpeg()));
    const json = await res.json<{ status: string; confidence: number; observation_id: number }>();
    expect(json.status).toBe("pending");
    expect(json.confidence).toBe(0.5);

    const submission = await env.DB.prepare("SELECT id, status, photo_key FROM submissions").first<any>();
    expect(submission.status).toBe("pending");
    expect(submission.photo_key).toBe(`submissions/${submission.id}.jpg`);
    expect(await photoKeys()).toEqual([submission.photo_key]);

    const stored = await env.PHOTOS.get(submission.photo_key);
    expect(stored?.httpMetadata?.contentType).toBe("image/jpeg");

    expect((await env.DB.prepare("SELECT status FROM observations WHERE id = ?").bind(json.observation_id).first<any>()).status).toBe("pending");
    expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM alert_jobs").first<{ n: number }>())!.n).toBe(0);
  });

  it("accepts a pending submission that arrives without a photo", async () => {
    await seedProduct(null);
    const res = await post(body({ ocr_confidence: "0.4" }));
    expect((await res.json<{ status: string }>()).status).toBe("pending");
    const submission = await env.DB.prepare("SELECT photo_key FROM submissions").first<any>();
    expect(submission.photo_key).toBeNull();
    expect(await photoKeys()).toEqual([]);
  });

  it("creates the product row when the barcode is unknown everywhere", async () => {
    const res = await post(body({ gtin: "0099999999999", ocr_confidence: "0.4" }));
    expect(res.status).toBe(200);
    expect((await res.json<{ status: string }>()).status).toBe("pending");
    const product = await env.DB.prepare("SELECT gtin, name, unit_kind FROM products WHERE gtin = '0099999999999'").first<any>();
    expect(product).toMatchObject({ gtin: "0099999999999", name: "", unit_kind: null });
  });

  it("backfills the product's dominant kind when a crowd row is accepted", async () => {
    await seedProduct(null);
    await seedAccepted(907.184);
    // 0.5 parsed + 0.2 range + 0.1 ocr = 0.8 -> accepted with no dominant kind.
    const res = await post(body());
    expect(await res.json<{ status: string; confidence: number }>()).toMatchObject({ status: "accepted", confidence: 0.8 });
    const product = await env.DB.prepare("SELECT unit_kind FROM products WHERE gtin = ?").bind(GTIN).first<any>();
    expect(product.unit_kind).toBe("mass");
  });

  it("does not queue a size drop for a change inside the 1% same-size band", async () => {
    await seedProduct("mass");
    await seedAccepted(907.184);
    const res = await post(body({ quantity: "900" }));
    expect((await res.json<{ status: string }>()).status).toBe("accepted");
    expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM alert_jobs").first<{ n: number }>())!.n).toBe(0);
  });

  it("does not queue a size drop when the package grew", async () => {
    await seedProduct("mass");
    await seedAccepted(793.786);
    const res = await post(body({ quantity: "907.184" }));
    expect((await res.json<{ status: string }>()).status).toBe("accepted");
    expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM alert_jobs").first<{ n: number }>())!.n).toBe(0);
  });

  it("normalizes a 12-digit UPC-A onto the existing product", async () => {
    await seedProduct("mass");
    await post(body({ gtin: "028400642255", ocr_confidence: "0.4" }));
    const submission = await env.DB.prepare("SELECT gtin FROM submissions").first<any>();
    expect(submission.gtin).toBe(GTIN);
    expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM products").first<{ n: number }>())!.n).toBe(1);
  });

  it("rejects malformed submissions", async () => {
    const cases: Array<[Record<string, string>, string]> = [
      [{ gtin: "12345" }, "invalid_gtin"],
      [{ device_id: "" }, "missing_device_id"],
      [{ quantity: "0" }, "invalid_quantity"],
      [{ quantity: "banana" }, "invalid_quantity"],
      [{ unit_kind: "grams" }, "invalid_unit_kind"],
    ];
    for (const [overrides, error] of cases) {
      const res = await post(body(overrides));
      expect(res.status, error).toBe(400);
      expect(await res.json()).toEqual({ error });
    }
  });

  it("rejects a photo larger than 5 MB before touching R2", async () => {
    const huge = new Blob([new Uint8Array(5 * 1024 * 1024 + 1)], { type: "image/jpeg" });
    const res = await post(body({ ocr_confidence: "0.4" }, huge));
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "photo_too_large" });
    expect(await photoKeys()).toEqual([]);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && npx vitest run test/observations.test.ts`
Expected: FAIL — every case returns 404 from Hono's default not-found handler (`expected 404 to be 200`).

- [ ] **Step 3: Implement the acceptance side effects**

`backend/src/crowd.ts`:

```ts
import { insertAlertJob, setProductUnitKindIfMissing } from "./db";

/**
 * Spec §5.1: two observations within 1% are the same size. A "size drop" has to
 * clear that band, otherwise OCR rounding noise would page every watcher.
 */
const SAME_SIZE_TOLERANCE = 0.01;

export interface AcceptanceInput {
  gtin: string;
  quantity: number;
  unitKind: string;
  /** Latest accepted same-kind quantity as it stood *before* this row was accepted. */
  previousQuantity: number | null;
  brand: string | null;
  now: number;
}

/**
 * Everything that must happen when a crowd observation becomes `accepted`,
 * whether it cleared the gate on arrival or a reviewer approved it later.
 * Returns true when a size_drop alert job was queued.
 */
export async function finalizeAcceptance(db: D1Database, input: AcceptanceInput): Promise<boolean> {
  // A product first seen through a contribution has no dominant kind until now;
  // without this the §6.3 kind-match component could never fire for it.
  await setProductUnitKindIfMissing(db, input.gtin, input.unitKind, input.now);

  const previous = input.previousQuantity;
  if (previous === null || previous <= 0) return false;
  if (input.quantity >= previous * (1 - SAME_SIZE_TOLERANCE)) return false;

  const percentChange = ((input.quantity - previous) / previous) * 100;
  await insertAlertJob(db, {
    kind: "size_drop",
    gtin: input.gtin,
    brand: input.brand,
    location_id: null,
    payload: JSON.stringify({
      gtin: input.gtin,
      unit_kind: input.unitKind,
      previous_quantity: previous,
      quantity: input.quantity,
      percent_change: Math.round(percentChange * 10) / 10,
      source: "crowd",
    }),
    created_at: input.now,
  });
  return true;
}
```

- [ ] **Step 4: Implement the route**

`backend/src/routes/observations.ts`:

```ts
import { Hono } from "hono";
import type { Env } from "../env";
import { normalizeGTIN } from "../gtin";
import {
  getLatestAcceptedObservation,
  getProduct,
  insertObservation,
  insertProduct,
  insertSubmission,
  type ProductRow,
} from "../db";
import { scoreSubmission } from "../gate";
import { finalizeAcceptance } from "../crowd";

export const observationsRoute = new Hono<{ Bindings: Env }>();

const MAX_PHOTO_BYTES = 5 * 1024 * 1024;
const KINDS = new Set(["mass", "volume", "count"]);
const MAX_RAW_TEXT = 500;

observationsRoute.post("/v1/observations", async (c) => {
  let form: FormData;
  try {
    form = await c.req.formData();
  } catch {
    return c.json({ error: "invalid_multipart" }, 400);
  }

  const gtin = normalizeGTIN(String(form.get("gtin") ?? ""));
  if (!gtin) return c.json({ error: "invalid_gtin" }, 400);

  const deviceId = String(form.get("device_id") ?? "").trim();
  if (!deviceId) return c.json({ error: "missing_device_id" }, 400);

  const quantity = Number(form.get("quantity"));
  if (!Number.isFinite(quantity) || quantity <= 0) return c.json({ error: "invalid_quantity" }, 400);

  const unitKind = String(form.get("unit_kind") ?? "");
  if (!KINDS.has(unitKind)) return c.json({ error: "invalid_unit_kind" }, 400);

  const rawTextField = String(form.get("raw_text") ?? "").slice(0, MAX_RAW_TEXT).trim();
  const rawText = rawTextField.length > 0 ? rawTextField : null;

  const ocrField = Number(form.get("ocr_confidence") ?? 0);
  const ocrConfidence = Number.isFinite(ocrField) ? ocrField : 0;

  const photo = form.get("photo");
  const file = photo instanceof File && photo.size > 0 ? photo : null;
  if (file && file.size > MAX_PHOTO_BYTES) return c.json({ error: "photo_too_large" }, 400);

  // Contributions are the only way non-food products enter the database at all,
  // so an unknown barcode gets a bare product row rather than a 404.
  let product = await getProduct(c.env.DB, gtin);
  if (!product) {
    product = { gtin, name: "", brand: "", category: "", image_url: null, unit_kind: null } satisfies ProductRow;
    await insertProduct(c.env.DB, product);
  }

  const latest = await getLatestAcceptedObservation(c.env.DB, gtin, unitKind);
  const gate = scoreSubmission({
    quantity,
    unitKind,
    ocrConfidence,
    productUnitKind: product.unit_kind,
    latestAcceptedQuantity: latest?.quantity ?? null,
  });

  const now = Math.floor(Date.now() / 1000);
  const submissionId = crypto.randomUUID();

  // Photos exist only so a human can adjudicate a pending row (spec §6.3).
  let photoKey: string | null = null;
  if (gate.status === "pending" && file) {
    photoKey = `submissions/${submissionId}.jpg`;
    await c.env.PHOTOS.put(photoKey, await file.arrayBuffer(), {
      httpMetadata: { contentType: file.type || "image/jpeg" },
    });
  }

  const observationId = await insertObservation(c.env.DB, {
    gtin,
    quantity,
    unit_kind: unitKind,
    raw_text: rawText,
    observed_at: now,
    source: "crowd",
    source_ref: submissionId,
    confidence: gate.confidence,
    status: gate.status,
  });

  await insertSubmission(c.env.DB, {
    id: submissionId,
    device_id: deviceId,
    gtin,
    photo_key: photoKey,
    ocr_text: rawText,
    parsed_quantity: quantity,
    parsed_kind: unitKind,
    status: gate.status,
    created_at: now,
  });

  if (gate.status === "accepted") {
    await finalizeAcceptance(c.env.DB, {
      gtin,
      quantity,
      unitKind,
      previousQuantity: latest?.quantity ?? null,
      brand: product.brand,
      now,
    });
  }

  return c.json({ status: gate.status, confidence: gate.confidence, observation_id: observationId });
});
```

Mount it in `backend/src/index.ts`:

```ts
import { Hono } from "hono";
import type { Env } from "./env";
import { productRoute } from "./routes/product";
import { observationsRoute } from "./routes/observations";

const app = new Hono<{ Bindings: Env }>();

app.get("/health", (c) => c.json({ ok: true }));
app.route("/", productRoute);
app.route("/", observationsRoute);

export default app;
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd backend && npx vitest run && npx tsc --noEmit`
Expected: `10 passed` in `observations.test.ts`, every earlier suite still green.

If the `satisfies ProductRow` clause is rejected by the installed TypeScript, drop it — the object literal already matches.

- [ ] **Step 6: Commit**

```bash
git add backend/src/crowd.ts backend/src/routes/observations.ts backend/src/index.ts backend/test/observations.test.ts
git commit -m "feat(backend): POST /v1/observations applies the crowd gate server-side"
```

---

### Task 4: Admin review page, photo route, accept/reject

**Files:**
- Create: `backend/src/routes/admin.ts`
- Modify: `backend/src/index.ts`
- Modify: `backend/README.md`
- Test: `backend/test/admin.test.ts`

**Interfaces:**
- Consumes: `getProduct`, `getSubmission`, `getObservationBySubmission`, `getLatestAcceptedObservation`, `listPendingSubmissions`, `markSubmissionReviewed`, `setObservationStatus`, `PendingSubmissionRow` (Task 1); `finalizeAcceptance` (Task 3).
- Produces: `adminRoute` with
  - `GET /v1/admin/review` → `200` full HTML page listing pending submissions. `401` JSON `{ "error": "unauthorized" }`, or `401` HTML key-entry shell when the request `Accept`s `text/html`.
  - `GET /v1/admin/photo/:id` → the R2 object for that submission, `404 { "error": "not_found" }` when there is none.
  - `POST /v1/admin/review/:id` with JSON body `{ "decision": "accept" | "reject" }` → `200 { "ok": true, "id": "...", "status": "accepted" | "rejected", "alerted": false }`. `400 { "error": "invalid_decision" }`, `404 { "error": "not_found" }` for an unknown or already-reviewed submission.
- Produces: `renderReview(rows: PendingSubmissionRow[]): string` and `renderShell(): string` (exported for tests).

**Why a shell page:** a browser cannot attach an `Authorization` header to a top-level navigation, and an `<img src>` cannot carry one either. So an unauthenticated HTML `GET` answers `401` with a data-free page that asks for the secret, keeps it in `sessionStorage`, and re-fetches every admin route with the bearer header. Every route that touches data still requires the header.

- [ ] **Step 1: Write the failing tests**

`backend/test/admin.test.ts`:

```ts
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";

const GTIN = "0028400642255";
const AUTH = { Authorization: "Bearer test-secret" };

async function photoKeys(): Promise<string[]> {
  return (await env.PHOTOS.list()).objects.map((o) => o.key);
}

/**
 * Product with no dominant kind + one accepted 907.184 g observation, then a
 * 793.786 g contribution: 0.5 parsed + 0.2 range = 0.7 -> pending, with a
 * larger incumbent still on record so accepting it must queue a size drop.
 */
async function seedPending(): Promise<{ submissionId: string; observationId: number; photoKey: string }> {
  await env.DB.prepare(
    "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'Gatorade', 'Gatorade', 'Beverages', NULL, NULL, 1, 1)"
  ).bind(GTIN).run();
  await env.DB.prepare(
    "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 907.184, 'mass', '32 oz', 1517443200, 'fdc', '1', 0.9, 'accepted', 1)"
  ).bind(GTIN).run();

  const form = new FormData();
  form.append("gtin", GTIN);
  form.append("device_id", "device-1");
  form.append("quantity", "793.786");
  form.append("unit_kind", "mass");
  form.append("raw_text", "NET WT 28 OZ (794g)");
  form.append("ocr_confidence", "0.4");
  form.append("photo", new Blob([new Uint8Array([0xff, 0xd8, 0xff, 0xd9])], { type: "image/jpeg" }), "label.jpg");

  const res = await app.request("/v1/observations", { method: "POST", body: form }, env);
  const json = await res.json<{ status: string; observation_id: number }>();
  expect(json.status).toBe("pending");

  const row = await env.DB.prepare("SELECT id, photo_key FROM submissions WHERE status = 'pending'").first<{ id: string; photo_key: string }>();
  return { submissionId: row!.id, observationId: json.observation_id, photoKey: row!.photo_key };
}

async function decide(id: string, decision: string, headers: Record<string, string> = AUTH) {
  return app.request(
    `/v1/admin/review/${id}`,
    { method: "POST", headers: { ...headers, "Content-Type": "application/json" }, body: JSON.stringify({ decision }) },
    env
  );
}

describe("admin auth", () => {
  beforeEach(async () => {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM alert_jobs"),
      env.DB.prepare("DELETE FROM submissions"),
      env.DB.prepare("DELETE FROM observations"),
      env.DB.prepare("DELETE FROM products"),
    ]);
    for (const key of await photoKeys()) await env.PHOTOS.delete(key);
  });

  it("401s every admin route without a bearer token", async () => {
    for (const path of ["/v1/admin/review", "/v1/admin/photo/sub-1"]) {
      const res = await app.request(path, { headers: { Accept: "application/json" } }, env);
      expect(res.status, path).toBe(401);
      expect(await res.json()).toEqual({ error: "unauthorized" });
    }
    const post = await decide("sub-1", "accept", {});
    expect(post.status).toBe(401);
  });

  it("401s a wrong bearer token", async () => {
    const res = await app.request("/v1/admin/review", { headers: { Authorization: "Bearer nope", Accept: "application/json" } }, env);
    expect(res.status).toBe(401);
  });

  it("serves a data-free key form to an unauthenticated browser", async () => {
    const res = await app.request("/v1/admin/review", { headers: { Accept: "text/html" } }, env);
    expect(res.status).toBe(401);
    expect(res.headers.get("content-type")).toContain("text/html");
    const html = await res.text();
    expect(html).toContain('id="keyForm"');
    expect(html).not.toContain("data-photo");
  });
});

describe("GET /v1/admin/review", () => {
  beforeEach(async () => {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM alert_jobs"),
      env.DB.prepare("DELETE FROM submissions"),
      env.DB.prepare("DELETE FROM observations"),
      env.DB.prepare("DELETE FROM products"),
    ]);
    for (const key of await photoKeys()) await env.PHOTOS.delete(key);
  });

  it("renders the pending queue", async () => {
    const { submissionId } = await seedPending();
    const res = await app.request("/v1/admin/review", { headers: AUTH }, env);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("Pending submissions (1)");
    expect(html).toContain(GTIN);
    expect(html).toContain("Gatorade");
    expect(html).toContain("793.786 g");
    expect(html).toContain("NET WT 28 OZ (794g)");
    expect(html).toContain(`data-photo="${submissionId}"`);
    expect(html).toContain(`data-decision="accept" data-id="${submissionId}"`);
    expect(html).toContain(`data-decision="reject" data-id="${submissionId}"`);
  });

  it("escapes OCR text so a crafted label cannot inject markup", async () => {
    await env.DB.prepare(
      "INSERT INTO submissions (id, device_id, gtin, photo_key, ocr_text, parsed_quantity, parsed_kind, status, created_at, reviewed_at) VALUES ('sub-x', 'd', ?, NULL, '<script>alert(1)</script>', 100, 'mass', 'pending', 1, NULL)"
    ).bind(GTIN).run();
    const html = await (await app.request("/v1/admin/review", { headers: AUTH }, env)).text();
    expect(html).not.toContain("<script>alert(1)</script>");
    expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
  });

  it("says so when nothing is waiting", async () => {
    const html = await (await app.request("/v1/admin/review", { headers: AUTH }, env)).text();
    expect(html).toContain("Nothing waiting for review.");
  });
});

describe("GET /v1/admin/photo/:id", () => {
  beforeEach(async () => {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM alert_jobs"),
      env.DB.prepare("DELETE FROM submissions"),
      env.DB.prepare("DELETE FROM observations"),
      env.DB.prepare("DELETE FROM products"),
    ]);
    for (const key of await photoKeys()) await env.PHOTOS.delete(key);
  });

  it("returns the stored bytes", async () => {
    const { submissionId } = await seedPending();
    const res = await app.request(`/v1/admin/photo/${submissionId}`, { headers: AUTH }, env);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("image/jpeg");
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(new Uint8Array([0xff, 0xd8, 0xff, 0xd9]));
  });

  it("404s an unknown submission", async () => {
    const res = await app.request("/v1/admin/photo/nope", { headers: AUTH }, env);
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "not_found" });
  });
});

describe("POST /v1/admin/review/:id", () => {
  beforeEach(async () => {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM alert_jobs"),
      env.DB.prepare("DELETE FROM submissions"),
      env.DB.prepare("DELETE FROM observations"),
      env.DB.prepare("DELETE FROM products"),
    ]);
    for (const key of await photoKeys()) await env.PHOTOS.delete(key);
  });

  it("accepts: flips the observation, deletes the photo, queues the size drop", async () => {
    const { submissionId, observationId, photoKey } = await seedPending();

    const res = await decide(submissionId, "accept");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, id: submissionId, status: "accepted", alerted: true });

    expect((await env.DB.prepare("SELECT status FROM observations WHERE id = ?").bind(observationId).first<any>()).status).toBe("accepted");

    const submission = await env.DB.prepare("SELECT status, photo_key, reviewed_at FROM submissions WHERE id = ?").bind(submissionId).first<any>();
    expect(submission.status).toBe("accepted");
    expect(submission.photo_key).toBeNull();
    expect(submission.reviewed_at).toBeGreaterThan(0);

    expect(await env.PHOTOS.get(photoKey)).toBeNull();
    expect(await photoKeys()).toEqual([]);

    const job = await env.DB.prepare("SELECT kind, gtin FROM alert_jobs").first<any>();
    expect(job).toMatchObject({ kind: "size_drop", gtin: GTIN });

    // Accepting also settles the product's dominant kind.
    expect((await env.DB.prepare("SELECT unit_kind FROM products WHERE gtin = ?").bind(GTIN).first<any>()).unit_kind).toBe("mass");
  });

  it("rejects: flips the observation, deletes the photo, queues nothing", async () => {
    const { submissionId, observationId, photoKey } = await seedPending();

    const res = await decide(submissionId, "reject");
    expect(await res.json()).toEqual({ ok: true, id: submissionId, status: "rejected", alerted: false });

    expect((await env.DB.prepare("SELECT status FROM observations WHERE id = ?").bind(observationId).first<any>()).status).toBe("rejected");
    expect((await env.DB.prepare("SELECT status, photo_key FROM submissions WHERE id = ?").bind(submissionId).first<any>()).status).toBe("rejected");
    expect(await env.PHOTOS.get(photoKey)).toBeNull();
    expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM alert_jobs").first<{ n: number }>())!.n).toBe(0);
  });

  it("a reviewed submission disappears from the queue and cannot be re-decided", async () => {
    const { submissionId } = await seedPending();
    await decide(submissionId, "accept");

    const html = await (await app.request("/v1/admin/review", { headers: AUTH }, env)).text();
    expect(html).toContain("Nothing waiting for review.");

    const again = await decide(submissionId, "accept");
    expect(again.status).toBe(404);
    expect(await again.json()).toEqual({ error: "not_found" });
  });

  it("400s an unknown decision", async () => {
    const { submissionId } = await seedPending();
    const res = await decide(submissionId, "maybe");
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_decision" });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && npx vitest run test/admin.test.ts`
Expected: FAIL — every admin request 404s (`expected 404 to be 401`).

- [ ] **Step 3: Implement the admin router**

`backend/src/routes/admin.ts`:

```ts
import { Hono } from "hono";
import type { Env } from "../env";
import {
  getLatestAcceptedObservation,
  getObservationBySubmission,
  getProduct,
  getSubmission,
  listPendingSubmissions,
  markSubmissionReviewed,
  setObservationStatus,
  type PendingSubmissionRow,
} from "../db";
import { finalizeAcceptance } from "../crowd";

export const adminRoute = new Hono<{ Bindings: Env }>();

// MARK: - Auth

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

adminRoute.use("/v1/admin/*", async (c, next) => {
  const secret = c.env.ADMIN_SECRET ?? "";
  const header = c.req.header("Authorization") ?? "";
  const prefix = "Bearer ";
  const ok = secret.length > 0 && header.startsWith(prefix) && constantTimeEqual(header.slice(prefix.length), secret);
  if (ok) return next();

  // A browser cannot attach a bearer header to a top-level navigation, so an
  // HTML GET gets a data-free page that collects the secret and re-fetches.
  if (c.req.method === "GET" && (c.req.header("Accept") ?? "").includes("text/html")) {
    return c.html(renderShell(), 401);
  }
  return c.json({ error: "unauthorized" }, 401);
});

// MARK: - Routes

adminRoute.get("/v1/admin/review", async (c) => {
  return c.html(renderReview(await listPendingSubmissions(c.env.DB)));
});

adminRoute.get("/v1/admin/photo/:id", async (c) => {
  const submission = await getSubmission(c.env.DB, c.req.param("id"));
  if (!submission?.photo_key) return c.json({ error: "not_found" }, 404);
  const object = await c.env.PHOTOS.get(submission.photo_key);
  if (!object) return c.json({ error: "not_found" }, 404);
  return new Response(object.body, {
    headers: {
      "Content-Type": object.httpMetadata?.contentType ?? "image/jpeg",
      "Cache-Control": "private, no-store",
    },
  });
});

adminRoute.post("/v1/admin/review/:id", async (c) => {
  const id = c.req.param("id");
  const parsed = await c.req.json<{ decision?: string }>().catch(() => ({}) as { decision?: string });
  const decision = parsed.decision;
  if (decision !== "accept" && decision !== "reject") return c.json({ error: "invalid_decision" }, 400);

  const submission = await getSubmission(c.env.DB, id);
  if (!submission || submission.status !== "pending") return c.json({ error: "not_found" }, 404);

  const observation = await getObservationBySubmission(c.env.DB, id);
  const status = decision === "accept" ? "accepted" : "rejected";
  const now = Math.floor(Date.now() / 1000);

  // Read the incumbent before the flip — once accepted, this row would be its
  // own "previous observation".
  const previous = observation
    ? await getLatestAcceptedObservation(c.env.DB, observation.gtin, observation.unit_kind)
    : null;

  if (observation) await setObservationStatus(c.env.DB, observation.id, status);
  await markSubmissionReviewed(c.env.DB, id, status, now);
  if (submission.photo_key) await c.env.PHOTOS.delete(submission.photo_key);

  let alerted = false;
  if (decision === "accept" && observation) {
    const product = await getProduct(c.env.DB, observation.gtin);
    alerted = await finalizeAcceptance(c.env.DB, {
      gtin: observation.gtin,
      quantity: observation.quantity,
      unitKind: observation.unit_kind,
      previousQuantity: previous?.quantity ?? null,
      brand: product?.brand ?? null,
      now,
    });
  }

  return c.json({ ok: true, id, status, alerted });
});

// MARK: - HTML

const STYLES = `
  :root { color-scheme: light; }
  body { font: 15px/1.5 -apple-system, system-ui, sans-serif; margin: 0; padding: 24px; background: #fafaf7; color: #0e0e11; }
  h1 { font-size: 20px; margin: 0 0 16px; }
  .card { background: #fff; border: 1px solid #e8e8ea; border-radius: 14px; padding: 16px; margin-bottom: 16px; max-width: 640px; }
  .meta { font: 13px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; color: #6b7280; white-space: pre-wrap; word-break: break-word; }
  .qty { font: 600 20px ui-monospace, SFMono-Regular, Menlo, monospace; margin: 8px 0; }
  img { max-width: 100%; border-radius: 10px; display: block; margin: 12px 0; background: #f4f4f5; min-height: 48px; }
  button { font: 600 15px system-ui; border: 0; border-radius: 10px; padding: 10px 18px; margin-right: 8px; cursor: pointer; }
  button[disabled] { opacity: 0.5; }
  .accept { background: #1d9e75; color: #fff; }
  .reject { background: #e24b4a; color: #fff; }
  input { font: 15px system-ui; padding: 10px; border: 1px solid #e8e8ea; border-radius: 10px; width: 320px; max-width: 100%; }
  .empty { color: #6b7280; }
`;

function escapeHtml(value: string): string {
  return value.replace(
    /[&<>"']/g,
    (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[ch]!
  );
}

function unitLabel(kind: string): string {
  if (kind === "mass") return "g";
  if (kind === "volume") return "mL";
  return "count";
}

export function renderReview(rows: PendingSubmissionRow[]): string {
  const cards = rows
    .map((row) => {
      const id = escapeHtml(row.id);
      const title = [row.gtin, row.name || "(unknown product)", row.brand].filter(Boolean).map(escapeHtml).join(" · ");
      const photo = row.photo_key
        ? `<img data-photo="${id}" alt="Label photo">`
        : `<div class="meta">(no photo)</div>`;
      return `<section class="card" data-card="${id}">
      <div class="meta">${title}</div>
      <div class="qty">${row.parsed_quantity} ${escapeHtml(unitLabel(row.parsed_kind))}</div>
      <div class="meta">${escapeHtml(row.ocr_text ?? "(no OCR text)")}</div>
      <div class="meta">device ${escapeHtml(row.device_id)} · ${new Date(row.created_at * 1000).toISOString()}</div>
      ${photo}
      <button class="accept" data-decision="accept" data-id="${id}">Accept</button>
      <button class="reject" data-decision="reject" data-id="${id}">Reject</button>
    </section>`;
    })
    .join("\n");

  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Shrunk review</title><style>${STYLES}</style></head>
<body><main>
<h1>Pending submissions (${rows.length})</h1>
${cards || '<p class="empty">Nothing waiting for review.</p>'}
</main></body></html>`;
}

export function renderShell(): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Shrunk review</title><style>${STYLES}</style></head>
<body><main id="app">
<h1>Shrunk review</h1>
<p class="empty">Paste the admin secret. It stays in this tab and is sent as a bearer token.</p>
<form id="keyForm"><input id="key" type="password" autocomplete="off" placeholder="ADMIN_SECRET">
<button class="accept" type="submit">Open</button></form>
</main>
<script>
const STORE = "shrunkAdminKey";
const app = document.getElementById("app");
const auth = () => ({ Authorization: "Bearer " + sessionStorage.getItem(STORE) });

function wire() {
  for (const img of app.querySelectorAll("img[data-photo]")) {
    fetch("/v1/admin/photo/" + img.dataset.photo, { headers: auth() })
      .then((r) => (r.ok ? r.blob() : null))
      .then((b) => { if (b) img.src = URL.createObjectURL(b); });
  }
  for (const button of app.querySelectorAll("button[data-decision]")) {
    button.addEventListener("click", async () => {
      button.disabled = true;
      const res = await fetch("/v1/admin/review/" + button.dataset.id, {
        method: "POST",
        headers: Object.assign({ "Content-Type": "application/json" }, auth()),
        body: JSON.stringify({ decision: button.dataset.decision })
      });
      if (res.ok) app.querySelector('[data-card="' + button.dataset.id + '"]').remove();
      else button.disabled = false;
    });
  }
}

async function load() {
  const res = await fetch("/v1/admin/review", { headers: Object.assign({ Accept: "application/json" }, auth()) });
  if (res.status === 401) {
    sessionStorage.removeItem(STORE);
    app.innerHTML = "<h1>Wrong secret</h1><p class='empty'>Reload and try again.</p>";
    return;
  }
  const doc = new DOMParser().parseFromString(await res.text(), "text/html");
  app.replaceChildren.apply(app, Array.from(doc.querySelector("main").childNodes));
  wire();
}

document.getElementById("keyForm").addEventListener("submit", (event) => {
  event.preventDefault();
  sessionStorage.setItem(STORE, document.getElementById("key").value);
  load();
});

if (sessionStorage.getItem(STORE)) load();
</script></body></html>`;
}
```

Mount it in `backend/src/index.ts`:

```ts
import { adminRoute } from "./routes/admin";
// ...
app.route("/", observationsRoute);
app.route("/", adminRoute);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && npx vitest run && npx tsc --noEmit`
Expected: `admin.test.ts` 12 passed; every other suite still green.

- [ ] **Step 5: Deploy and check the page in a real browser**

```bash
cd backend && npm run migrate:remote && npm run deploy
```

Then post one low-confidence submission against the deployed Worker so there is something to review:

```bash
curl -s -X POST "https://shrunk-api.<account>.workers.dev/v1/observations" \
  -F gtin=0028400642255 -F device_id=manual-test -F quantity=793.786 \
  -F unit_kind=mass -F raw_text="NET WT 28 OZ (794g)" -F ocr_confidence=0.2 \
  -F photo=@/path/to/any.jpg
```

Expected: `{"status":"pending","confidence":...,"observation_id":...}`. Open `https://shrunk-api.<account>.workers.dev/v1/admin/review` in a browser, paste `ADMIN_SECRET`, confirm the card renders with the photo, click **Reject**, and confirm the card disappears and a reload shows "Nothing waiting for review."

- [ ] **Step 6: Update the README and commit**

Replace the endpoints line in `backend/README.md`:

```markdown
Endpoints: `GET /health`, `GET /v1/product/:gtin?locationId=`, `POST /v1/observations` (multipart crowd submission),
`GET /v1/admin/review` (paste `ADMIN_SECRET` in the browser), `GET /v1/admin/photo/:id`, `POST /v1/admin/review/:id`.

Secrets: `FDC_API_KEY`, `ADMIN_SECRET`. R2 bucket `shrunk-photos` holds label photos for pending submissions only.
```

```bash
git add backend/src/routes/admin.ts backend/src/index.ts backend/test/admin.test.ts backend/README.md
git commit -m "feat(backend): bearer-protected review page with photo and accept/reject"
```

---

### Task 5: iOS `NetContentParser` (Swift port of the normalizer)

**Files:**
- Create: `Shrunk/Features/Contribute/NetContentParser.swift`
- Modify: `project.yml`
- Test: `ShrunkTests/NetContentParserTests.swift`

**Interfaces:**
- Produces: `enum UnitKind: String { case mass, volume, count }` with `var displayLabel: String` → `"g"` / `"mL"` / `"count"`.
- Produces: `struct ParsedQuantity: Equatable { let quantity: Double; let unitKind: UnitKind; let raw: String }` — quantity in grams / millilitres / count, rounded to 3 decimals.
- Produces: `struct NetContentMatch: Equatable { let line: String; let lineIndex: Int; let parsed: ParsedQuantity }`.
- Produces: `enum NetContentParser` with `static func parse(_ raw: String) -> ParsedQuantity?`, `static func isNetContentLine(_ line: String) -> Bool`, `static func firstNetContent(in lines: [String]) -> NetContentMatch?`.
- Third port of the same algorithm as `backend/src/normalize.ts` and `scripts/fdc/normalize.py`; all three must pass `fixtures/package_weights.json`.

Run the tests with:

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/NetContentParserTests -quiet 2>&1 | tail -30
```

- [ ] **Step 1: Put the shared fixture in the test bundle**

In `project.yml`, replace the `ShrunkTests` `sources:` block with:

```yaml
    sources:
      - path: ShrunkTests
      - path: fixtures/package_weights.json
        type: file
        buildPhase: resources
```

- [ ] **Step 2: Write the failing tests**

`ShrunkTests/NetContentParserTests.swift`:

```swift
import XCTest
@testable import Shrunk

final class NetContentParserTests: XCTestCase {

    // MARK: - Shared fixtures (must agree with the Python and TypeScript ports)

    private struct FixtureCase: Decodable {
        let input: String
        let quantity: Double?
        let unit_kind: String?
        let note: String
    }

    func test_sharedFixtures() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "package_weights", withExtension: "json"),
            "package_weights.json is missing from the test bundle — check the resources entry in project.yml"
        )
        let cases = try JSONDecoder().decode([FixtureCase].self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(cases.count, 28)

        for fixture in cases {
            let result = NetContentParser.parse(fixture.input)
            if let expected = fixture.quantity {
                let parsed = try XCTUnwrap(result, "expected a parse for \(fixture.input) — \(fixture.note)")
                XCTAssertEqual(parsed.unitKind.rawValue, fixture.unit_kind, fixture.note)
                XCTAssertEqual(parsed.quantity, expected, accuracy: 0.01, fixture.note)
                XCTAssertEqual(parsed.raw, fixture.input, fixture.note)
            } else {
                XCTAssertNil(result, "expected a reject for \(fixture.input) — \(fixture.note)")
            }
        }
    }

    // MARK: - Real label strings (spec §10)

    func test_realLabelStrings() {
        let cases: [(String, Double, UnitKind)] = [
            ("NET WT 12 OZ (340g)",                  340.194,  .mass),
            ("NET WT 8 OZ (227g)",                   226.796,  .mass),
            ("NET WT. 1 LB 4 OZ (567g)",             566.990,  .mass),
            ("e 500 g",                              500,      .mass),
            ("500 g e",                              500,      .mass),
            ("NET CONTENTS 28 FL OZ (828 mL)",       828.058,  .volume),
            ("12 – 12 FL OZ CANS",                   4258.584, .volume),
            ("NET WT 16 OZ (1 LB) 453g",             453.592,  .mass),
            ("NET WT 5.3 OZ (150g)",                 150.252,  .mass),
            ("NET WT 1.5 LB (680g)",                 680.388,  .mass),
            ("NET 2 LB (907 g)",                     907.184,  .mass),
            ("1 GAL (3.78 L)",                       3785.410, .volume),
            ("64 FL OZ (1.89 L)",                    1892.704, .volume),
            ("NET WT 10 OZ",                         283.495,  .mass),
            ("NET WEIGHT 750 g",                     750,      .mass),
            ("NET WT 2.6 OZ (74g)",                  73.709,   .mass),
            ("18 CT",                                18,       .count),
            ("NET WT 19.5 OZ (1 LB 3.5 OZ) 553g",    552.815,  .mass),
            ("NET WT 1 LB 8 OZ (680 g)",             680.388,  .mass),
            ("6 x 12 FL OZ",                         2129.292, .volume),
            ("NET WT 32 OZ (2 LB) 907g",             907.184,  .mass),
            ("NET WT 4.4 OZ (125g)",                 124.738,  .mass),
            ("CONTENIDO NETO 400 g",                 400,      .mass),
            ("NET WT 3.5 OZ (99g)",                  99.223,   .mass),
            ("1 QT (946 mL)",                        946.353,  .volume),
            ("NET WT 24 OZ (1 LB 8 OZ) 680g",        680.388,  .mass),
            ("NET WT 7 OZ (198g)",                   198.447,  .mass),
            ("e 250 ml",                             250,      .volume),
            ("NET WT 12.5 OZ (354g)",                354.369,  .mass),
            ("NET WT 16.9 FL OZ (500 mL)",           499.792,  .volume),
            ("NET WT 1.36 kg (3 LB)",                1360,     .mass)
        ]

        for (input, quantity, kind) in cases {
            guard let parsed = NetContentParser.parse(input) else {
                XCTFail("expected a parse for \(input)")
                continue
            }
            XCTAssertEqual(parsed.quantity, quantity, accuracy: 0.01, input)
            XCTAssertEqual(parsed.unitKind, kind, input)
        }
    }

    func test_labelStringsThatMustNotParse() {
        let rejects = [
            "SERVING SIZE 1 CUP",
            "NET WT",
            "INGREDIENTS: WATER, SUGAR, SALT",
            "NET WT 0 OZ",
            "NET WT 12 OZ (500g)",     // segments disagree by 47%
            "BEST BY 12/25/2027"
        ]
        for input in rejects {
            XCTAssertNil(NetContentParser.parse(input), "expected a reject for \(input)")
        }
    }

    // MARK: - Line selection

    func test_isNetContentLine_matchesTheSpecRegex() {
        XCTAssertTrue(NetContentParser.isNetContentLine("NET WT 12 OZ"))
        XCTAssertTrue(NetContentParser.isNetContentLine("net weight 750 g"))
        XCTAssertTrue(NetContentParser.isNetContentLine("NET CONTENTS 28 FL OZ"))
        XCTAssertTrue(NetContentParser.isNetContentLine("e 500 g"))
        XCTAssertFalse(NetContentParser.isNetContentLine("INGREDIENTS: WATER"))
        XCTAssertFalse(NetContentParser.isNetContentLine("12 – 12 FL OZ CANS"))
    }

    func test_firstNetContent_prefersTheNetContentLine() {
        let lines = ["DORITOS", "12 CT", "NET WT 9.75 OZ (276g)", "INGREDIENTS: CORN"]
        let match = NetContentParser.firstNetContent(in: lines)
        XCTAssertEqual(match?.lineIndex, 2)
        XCTAssertEqual(match?.line, "NET WT 9.75 OZ (276g)")
        XCTAssertEqual(match?.parsed.unitKind, .mass)
        XCTAssertEqual(match?.parsed.quantity ?? 0, 276.408, accuracy: 0.01)
    }

    func test_firstNetContent_fallsBackToAMassOrVolumeLine() {
        // Many US labels print the size with no "NET WT" prefix at all.
        let lines = ["COCA-COLA", "12 – 12 FL OZ CANS", "CAFFEINE FREE"]
        let match = NetContentParser.firstNetContent(in: lines)
        XCTAssertEqual(match?.lineIndex, 1)
        XCTAssertEqual(match?.parsed.unitKind, .volume)
        XCTAssertEqual(match?.parsed.quantity ?? 0, 4258.584, accuracy: 0.01)
    }

    func test_firstNetContent_neverGuessesFromABareCount() {
        // "12 CT" alone is as likely to be servings as packages, so the fallback
        // tier ignores count-only lines and the sheet falls back to manual entry.
        XCTAssertNil(NetContentParser.firstNetContent(in: ["DORITOS", "12 CT", "PARTY SIZE"]))
    }

    func test_firstNetContent_returnsNilWhenNothingParses() {
        XCTAssertNil(NetContentParser.firstNetContent(in: ["DORITOS", "INGREDIENTS: CORN", ""]))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run the command above.
Expected: compile error `cannot find 'NetContentParser' in scope`.

- [ ] **Step 4: Implement the parser**

`Shrunk/Features/Contribute/NetContentParser.swift`:

```swift
import Foundation

/// Base unit per kind: grams, millilitres, or a plain count (spec §5.1).
enum UnitKind: String, CaseIterable, Codable {
    case mass, volume, count

    /// Label used in the confirm sheet and the admin review page.
    var displayLabel: String {
        switch self {
        case .mass:   return "g"
        case .volume: return "mL"
        case .count:  return "count"
        }
    }
}

struct ParsedQuantity: Equatable {
    let quantity: Double        // grams | millilitres | count
    let unitKind: UnitKind
    let raw: String
}

struct NetContentMatch: Equatable {
    let line: String
    let lineIndex: Int
    let parsed: ParsedQuantity
}

/// Swift port of `backend/src/normalize.ts` / `scripts/fdc/normalize.py`.
/// All three must pass `fixtures/package_weights.json` — change one, change all three.
enum NetContentParser {

    // MARK: - Units

    private static let units: [String: (UnitKind, Double)] = [
        // mass -> grams
        "g": (.mass, 1), "gr": (.mass, 1), "gram": (.mass, 1), "grams": (.mass, 1), "grm": (.mass, 1),
        "kg": (.mass, 1000), "kgm": (.mass, 1000), "kilogram": (.mass, 1000), "kilograms": (.mass, 1000),
        "oz": (.mass, 28.3495), "onz": (.mass, 28.3495), "ounce": (.mass, 28.3495), "ounces": (.mass, 28.3495),
        "lb": (.mass, 453.592), "lbs": (.mass, 453.592), "lbr": (.mass, 453.592),
        "pound": (.mass, 453.592), "pounds": (.mass, 453.592),
        // volume -> millilitres
        "ml": (.volume, 1), "mlt": (.volume, 1), "milliliter": (.volume, 1),
        "milliliters": (.volume, 1), "millilitre": (.volume, 1),
        "l": (.volume, 1000), "ltr": (.volume, 1000), "liter": (.volume, 1000),
        "liters": (.volume, 1000), "litre": (.volume, 1000), "litres": (.volume, 1000),
        "floz": (.volume, 29.5735), "oza": (.volume, 29.5735),
        "pt": (.volume, 473.176), "ptl": (.volume, 473.176), "pint": (.volume, 473.176), "pints": (.volume, 473.176),
        "qt": (.volume, 946.353), "qtl": (.volume, 946.353), "quart": (.volume, 946.353), "quarts": (.volume, 946.353),
        "gal": (.volume, 3785.41), "gll": (.volume, 3785.41), "gallon": (.volume, 3785.41), "gallons": (.volume, 3785.41),
        // count
        "ct": (.count, 1), "count": (.count, 1), "pk": (.count, 1), "pack": (.count, 1),
        "ea": (.count, 1), "each": (.count, 1), "h87": (.count, 1),
        "pc": (.count, 1), "pcs": (.count, 1), "piece": (.count, 1), "pieces": (.count, 1)
    ]

    /// Longest token first so "milliliters" wins over "ml"; sorted for determinism.
    private static let unitAlternation: String = units.keys
        .sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
        .map { NSRegularExpression.escapedPattern(for: $0) }
        .joined(separator: "|")

    private static let numberPattern = #"(\d+(?:[.,]\d+)?)"#

    /// "12 - 12 FL OZ", "6 x 330 ml" — multiplier, then quantity and unit.
    private static let multipack = try! NSRegularExpression(
        pattern: "\(numberPattern)\\s*(?:[-–x×*]|pk\\s+of|pack\\s+of)\\s*\(numberPattern)\\s*(fl\\s?oz|\(unitAlternation))\\b"
    )

    private static let quantityUnit = try! NSRegularExpression(
        pattern: "\(numberPattern)\\s*(fl\\s?oz|\(unitAlternation))\\b"
    )

    /// "12 oz/340 g" and "NET WT 12 OZ (340g)" both split into comparable segments.
    private static let segmentSplit = try! NSRegularExpression(pattern: #"\s*/\s*|\s*\(|\)\s*"#)

    /// Spec §6.3 — the lines a label uses to announce net content.
    private static let netContentMarker = try! NSRegularExpression(
        pattern: #"NET\s*(WT|WEIGHT|CONTENTS?)|e\s*\d"#,
        options: [.caseInsensitive]
    )

    private static let tolerance = 0.02

    // MARK: - Public API

    static func parse(_ raw: String) -> ParsedQuantity? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let parsed = segments(of: text).compactMap(parseSegment)
        guard !parsed.isEmpty else { return nil }

        // Prefer mass/volume over count when both appear ("12 ct / 340 g").
        let nonCount = parsed.filter { $0.kind != .count }
        let chosen = nonCount.isEmpty ? parsed : nonCount
        let head = chosen[0]

        // Same-kind segments must agree within 2%, or the string is malformed.
        for other in chosen.dropFirst() where other.kind == head.kind {
            if abs(other.value - head.value) / head.value > tolerance { return nil }
        }

        return ParsedQuantity(
            quantity: (head.value * 1000).rounded() / 1000,
            unitKind: head.kind,
            raw: raw
        )
    }

    static func isNetContentLine(_ line: String) -> Bool {
        netContentMarker.firstMatch(in: line, range: fullRange(of: line)) != nil
    }

    /// Picks the OCR line to submit.
    /// Tier 1 is spec §6.3's rule — lines that announce net content.
    /// Tier 2 catches labels that print the size with no prefix ("12 – 12 FL OZ
    /// CANS"); it accepts mass/volume only, so a bare "12 CT" (as likely to be
    /// servings as packages) falls through to the manual entry sheet (spec §8).
    static func firstNetContent(in lines: [String]) -> NetContentMatch? {
        for (index, line) in lines.enumerated() where isNetContentLine(line) {
            if let parsed = parse(line) {
                return NetContentMatch(line: line, lineIndex: index, parsed: parsed)
            }
        }
        for (index, line) in lines.enumerated() {
            if let parsed = parse(line), parsed.unitKind != .count {
                return NetContentMatch(line: line, lineIndex: index, parsed: parsed)
            }
        }
        return nil
    }

    // MARK: - Internals

    private struct Segment {
        let value: Double
        let kind: UnitKind
    }

    private static func fullRange(of text: String) -> NSRange {
        NSRange(location: 0, length: (text as NSString).length)
    }

    private static func segments(of text: String) -> [String] {
        let ns = text as NSString
        var result: [String] = []
        var cursor = 0
        for match in segmentSplit.matches(in: text, range: fullRange(of: text)) {
            result.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = match.range.location + match.range.length
        }
        result.append(ns.substring(from: cursor))
        return result
    }

    private static func parseSegment(_ segment: String) -> Segment? {
        let text = segment.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let ns = text as NSString
        let range = fullRange(of: text)

        if let match = multipack.firstMatch(in: text, range: range),
           let unit = unit(ns.substring(with: match.range(at: 3))) {
            let value = number(ns.substring(with: match.range(at: 1)))
                * number(ns.substring(with: match.range(at: 2)))
                * unit.1
            return value > 0 ? Segment(value: value, kind: unit.0) : nil
        }

        let matches = quantityUnit.matches(in: text, range: range)
        guard let head = matches.first,
              let headUnit = unit(ns.substring(with: head.range(at: 2))) else { return nil }

        var total = number(ns.substring(with: head.range(at: 1))) * headUnit.1
        // Compound imperial ("1 lb 4 oz"): same-kind trailing matches add up.
        for extra in matches.dropFirst() {
            guard let extraUnit = unit(ns.substring(with: extra.range(at: 2))),
                  extraUnit.0 == headUnit.0 else { break }
            total += number(ns.substring(with: extra.range(at: 1))) * extraUnit.1
        }
        return total > 0 ? Segment(value: total, kind: headUnit.0) : nil
    }

    private static func number(_ token: String) -> Double {
        Double(token.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private static func unit(_ token: String) -> (UnitKind, Double)? {
        units[token.lowercased().replacingOccurrences(of: " ", with: "")]
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run the command from the top of this task.
Expected: `Test Suite 'NetContentParserTests' passed`, 8 tests.

If `test_sharedFixtures` fails on `XCTUnwrap`, the resource entry did not take — run `xcodegen generate` again and confirm `package_weights.json` appears under the ShrunkTests target's *Copy Bundle Resources* phase in Xcode.

- [ ] **Step 6: Commit**

```bash
git add Shrunk/Features/Contribute/NetContentParser.swift ShrunkTests/NetContentParserTests.swift project.yml
git commit -m "feat(ios): net-content parser sharing the normalizer fixtures"
```

---

### Task 6: iOS `LabelOCRService` (Vision)

**Files:**
- Create: `Shrunk/Features/Contribute/LabelOCRService.swift`
- Test: `ShrunkTests/LabelOCRServiceTests.swift`

**Interfaces:**
- Produces: `struct OCRLine: Equatable { let text: String; let confidence: Double }`.
- Produces: `protocol LabelTextRecognizing: Sendable { func recognizeText(in image: CGImage) async throws -> [OCRLine] }`.
- Produces: `enum LabelOCRError: LocalizedError { case recognitionFailed(Error) }`.
- Produces: `final class LabelOCRService: LabelTextRecognizing` — `VNRecognizeTextRequest`, `.accurate`, `["en-US"]`, language correction **off**.

Run the tests with:

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/LabelOCRServiceTests -quiet 2>&1 | tail -30
```

- [ ] **Step 1: Write the failing test**

`ShrunkTests/LabelOCRServiceTests.swift`:

```swift
import XCTest
import UIKit
@testable import Shrunk

final class LabelOCRServiceTests: XCTestCase {

    /// Draws black label text on white so Vision has something realistic to read.
    private func labelImage(_ lines: [String]) throws -> CGImage {
        let size = CGSize(width: 800, height: 400)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 56, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            for (index, line) in lines.enumerated() {
                line.draw(at: CGPoint(x: 40, y: 40 + 90 * index), withAttributes: attributes)
            }
        }
        return try XCTUnwrap(image.cgImage)
    }

    func test_recognizeText_readsTheNetContentLine() async throws {
        let image = try labelImage(["DORITOS", "NET WT 12 OZ"])
        let lines = try await LabelOCRService().recognizeText(in: image)

        try XCTSkipIf(lines.isEmpty, "Vision text recognition is unavailable on this simulator host")

        let joined = lines.map(\.text).joined(separator: " ").uppercased()
        XCTAssertTrue(joined.contains("12"), "expected the quantity in \(joined)")
        XCTAssertTrue(joined.contains("OZ"), "expected the unit in \(joined)")
        for line in lines {
            XCTAssertGreaterThan(line.confidence, 0)
            XCTAssertLessThanOrEqual(line.confidence, 1)
        }
    }

    func test_recognizeText_returnsNoLinesForABlankImage() async throws {
        let lines = try await LabelOCRService().recognizeText(in: try labelImage([]))
        XCTAssertTrue(lines.isEmpty)
    }

    /// The parser and the OCR service have to agree end to end.
    func test_recognizedLinesFeedTheParser() async throws {
        let image = try labelImage(["DORITOS", "NET WT 12 OZ"])
        let lines = try await LabelOCRService().recognizeText(in: image)
        try XCTSkipIf(lines.isEmpty, "Vision text recognition is unavailable on this simulator host")

        guard let match = NetContentParser.firstNetContent(in: lines.map(\.text)) else {
            throw XCTSkip("Vision read \(lines.map(\.text)) — no net-content line to parse")
        }
        XCTAssertEqual(match.parsed.unitKind, .mass)
        XCTAssertEqual(match.parsed.quantity, 340.194, accuracy: 0.5)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run the command above.
Expected: compile error `cannot find 'LabelOCRService' in scope`.

- [ ] **Step 3: Implement the service**

`Shrunk/Features/Contribute/LabelOCRService.swift`:

```swift
import Foundation
import Vision
import CoreGraphics

struct OCRLine: Equatable {
    let text: String
    /// Vision's confidence for this line's top candidate, 0...1.
    let confidence: Double
}

enum LabelOCRError: LocalizedError {
    case recognitionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .recognitionFailed(let error):
            return "Couldn't read the label. (\(error.localizedDescription))"
        }
    }
}

protocol LabelTextRecognizing: Sendable {
    func recognizeText(in image: CGImage) async throws -> [OCRLine]
}

/// Vision text recognition tuned for package labels.
///
/// `usesLanguageCorrection` is deliberately off: correction rewrites "12 OZ"
/// into dictionary words and destroys the exact net-content line we parse.
/// The request is synchronous, so this stays a plain non-isolated async method —
/// callers on `@MainActor` hop off the main thread automatically.
final class LabelOCRService: LabelTextRecognizing {

    func recognizeText(in image: CGImage) async throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            throw LabelOCRError.recognitionFailed(error)
        }

        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(text: candidate.string, confidence: Double(candidate.confidence))
        }
    }
}
```

If the compiler reports `request.results` as `[any VNObservation]?`, change that line to
`let observations = (request.results as? [VNRecognizedTextObservation]) ?? []`.

- [ ] **Step 4: Run tests to verify they pass**

Run the command from the top of this task.
Expected: `Test Suite 'LabelOCRServiceTests' passed`, 3 tests (one or two may report as skipped on an Intel host).

- [ ] **Step 5: Commit**

```bash
git add Shrunk/Features/Contribute/LabelOCRService.swift ShrunkTests/LabelOCRServiceTests.swift
git commit -m "feat(ios): Vision label OCR returning lines with confidence"
```

---

### Task 7: `DeviceIdentity`, `needsConfirmation`, `ShrunkAPIClient.submitObservation`

**Files:**
- Create: `Shrunk/Services/DeviceIdentity.swift`
- Modify: `Shrunk/Models/ShrunkProduct.swift`
- Modify: `Shrunk/Services/ShrunkAPIClient.swift`
- Test: `ShrunkTests/ShrunkAPIClientTests.swift` (append)

**Interfaces:**
- Produces: `enum DeviceIdentity { static let key = "device_id"; static var current: String }` — mints a UUID on first read and keeps it in `@AppStorage("device_id")`.
- Produces: `ShrunkProduct.needsConfirmation: Bool` (declared **last**, default `false`, so every existing memberwise call site still compiles). Phase 3 sets it when the live Kroger size disagrees with the latest non-Kroger observation (spec §4 step 4).
- Produces: `struct SubmissionResult: Equatable { enum Status: String { case accepted, pending }; let status: Status; let confidence: Double; let observationId: Int }`.
- Produces: `protocol ObservationSubmitting: Sendable { func submitObservation(gtin: String, quantity: Double, unitKind: UnitKind, rawText: String, ocrConfidence: Double, deviceId: String, photoJPEG: Data?) async throws -> SubmissionResult }`, with `ShrunkAPIClient` conforming.
- Produces: `static func multipartBody(boundary: String, fields: [String: String], photoJPEG: Data?) -> Data` on `ShrunkAPIClient` — pure and directly testable (a custom `URLProtocol` never sees `httpBody`).
- Throws `ShrunkError.invalidResponse` on any non-200, `.network` on transport errors, `.decoding` on bad JSON.

Run the tests with:

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/ShrunkAPIClientTests -quiet 2>&1 | tail -30
```

- [ ] **Step 1: Write the failing tests**

Append to `ShrunkTests/ShrunkAPIClientTests.swift`, inside the class:

```swift
    // MARK: - Device identity

    func test_deviceIdentity_mintsOnceAndSticks() {
        UserDefaults.standard.removeObject(forKey: DeviceIdentity.key)
        let first = DeviceIdentity.current
        XCTAssertFalse(first.isEmpty)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(DeviceIdentity.current, first)
        XCTAssertEqual(UserDefaults.standard.string(forKey: DeviceIdentity.key), first)
    }

    // MARK: - Multipart encoding

    func test_multipartBody_encodesFieldsAndPhoto() throws {
        let data = ShrunkAPIClient.multipartBody(
            boundary: "BOUND",
            fields: ["gtin": "0028400642255", "quantity": "340.194", "unit_kind": "mass"],
            photoJPEG: Data([0xff, 0xd8, 0xff, 0xd9])
        )
        let body = try XCTUnwrap(String(data: data, encoding: .isoLatin1))

        XCTAssertTrue(body.contains("--BOUND\r\nContent-Disposition: form-data; name=\"gtin\"\r\n\r\n0028400642255\r\n"))
        XCTAssertTrue(body.contains("name=\"quantity\"\r\n\r\n340.194\r\n"))
        XCTAssertTrue(body.contains("name=\"unit_kind\"\r\n\r\nmass\r\n"))
        XCTAssertTrue(body.contains("Content-Disposition: form-data; name=\"photo\"; filename=\"label.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"))
        XCTAssertTrue(body.hasSuffix("--BOUND--\r\n"))
    }

    func test_multipartBody_omitsThePhotoPartWhenThereIsNone() throws {
        let data = ShrunkAPIClient.multipartBody(boundary: "BOUND", fields: ["gtin": "0028400642255"], photoJPEG: nil)
        let body = try XCTUnwrap(String(data: data, encoding: .isoLatin1))
        XCTAssertFalse(body.contains("name=\"photo\""))
        XCTAssertTrue(body.hasSuffix("--BOUND--\r\n"))
    }

    // MARK: - submitObservation

    func test_submitObservation_postsMultipartAndMapsTheResult() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/observations")
            XCTAssertEqual(request.httpMethod, "POST")
            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary=shrunk-"), contentType)
            return (200, Data(#"{"status":"accepted","confidence":0.9,"observation_id":42}"#.utf8))
        }

        let result = try await client.submitObservation(
            gtin: "0028400642255", quantity: 340.194, unitKind: .mass,
            rawText: "NET WT 12 OZ (340g)", ocrConfidence: 0.95,
            deviceId: "device-1", photoJPEG: Data([0xff, 0xd8])
        )

        XCTAssertEqual(result, SubmissionResult(status: .accepted, confidence: 0.9, observationId: 42))
    }

    func test_submitObservation_mapsPending() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"status":"pending","confidence":0.5,"observation_id":7}"#.utf8)) }
        let result = try await client.submitObservation(
            gtin: "0028400642255", quantity: 500, unitKind: .volume,
            rawText: "", ocrConfidence: 0, deviceId: "device-1", photoJPEG: nil
        )
        XCTAssertEqual(result.status, .pending)
        XCTAssertEqual(result.confidence, 0.5)
        XCTAssertEqual(result.observationId, 7)
    }

    func test_submitObservation_400_throwsInvalidResponse() async {
        StubURLProtocol.handler = { _ in (400, Data(#"{"error":"invalid_gtin"}"#.utf8)) }
        do {
            _ = try await client.submitObservation(
                gtin: "123", quantity: 1, unitKind: .mass,
                rawText: "", ocrConfidence: 0, deviceId: "device-1", photoJPEG: nil
            )
            XCTFail("expected throw")
        } catch ShrunkError.invalidResponse {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_submitObservation_unknownStatus_throwsInvalidResponse() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"status":"weird","confidence":0.9,"observation_id":1}"#.utf8)) }
        do {
            _ = try await client.submitObservation(
                gtin: "0028400642255", quantity: 1, unitKind: .mass,
                rawText: "", ocrConfidence: 0, deviceId: "device-1", photoJPEG: nil
            )
            XCTFail("expected throw")
        } catch ShrunkError.invalidResponse {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Product flag

    func test_needsConfirmation_defaultsToFalse() {
        let product = ShrunkProduct(
            id: "0028400642255", name: "Doritos", brand: "Doritos", category: "Snacks",
            imageURL: nil, sizeHistory: [], currentPrice: nil, currency: "USD"
        )
        XCTAssertFalse(product.needsConfirmation)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run the command above.
Expected: compile errors — `cannot find 'DeviceIdentity' in scope`, `value of type 'ShrunkAPIClient' has no member 'submitObservation'`.

- [ ] **Step 3: Add `DeviceIdentity`**

`Shrunk/Services/DeviceIdentity.swift`:

```swift
import SwiftUI

/// Stable per-install identifier. Crowd submissions carry it so a reviewer can
/// see repeat contributors, and Phase 4's `/v1/devices` sync reuses it.
///
/// Stored under the `device_id` key, so a SwiftUI view can read the same value
/// with `@AppStorage("device_id")`.
enum DeviceIdentity {
    /// Exposed for tests; the literal below must stay in sync (a property-wrapper
    /// attribute cannot reference another static of the same type reliably).
    static let key = "device_id"

    @AppStorage("device_id") private static var stored: String = ""

    static var current: String {
        if !stored.isEmpty { return stored }
        let fresh = UUID().uuidString
        stored = fresh
        return fresh
    }
}
```

- [ ] **Step 4: Add the product flag**

In `Shrunk/Models/ShrunkProduct.swift`, add the property as the **last** member of the struct so the memberwise initializer keeps every existing call site valid:

```swift
struct ShrunkProduct: Identifiable, Codable, Hashable {
    let id: String              // barcode (UPC / EAN)
    let name: String
    let brand: String
    let category: String
    let imageURL: URL?
    let sizeHistory: [SizeRecord]
    let currentPrice: Double?
    let currency: String
    /// Set in Phase 3 when the live store size disagrees with the latest
    /// non-Kroger observation (spec §4 step 4). Drives the "Confirm with a
    /// label photo" card on ResultView.
    var needsConfirmation: Bool = false
}
```

- [ ] **Step 5: Add `submitObservation`**

In `Shrunk/Services/ShrunkAPIClient.swift`, add inside the `actor ShrunkAPIClient` body, after `fetchProduct`:

```swift
    /// Uploads a crowd label observation. The server recomputes the confidence
    /// gate (spec §6.3) — `ocrConfidence` is evidence, not a verdict.
    func submitObservation(
        gtin: String,
        quantity: Double,
        unitKind: UnitKind,
        rawText: String,
        ocrConfidence: Double,
        deviceId: String,
        photoJPEG: Data?
    ) async throws -> SubmissionResult {
        let boundary = "shrunk-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appending(path: "v1/observations"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            fields: [
                "gtin": gtin,
                "quantity": String(quantity),
                "unit_kind": unitKind.rawValue,
                "raw_text": rawText,
                "ocr_confidence": String(ocrConfidence),
                "device_id": deviceId
            ],
            photoJPEG: photoJPEG
        )

        let data: Data
        do {
            let (received, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ShrunkError.invalidResponse
            }
            data = received
        } catch let error as ShrunkError {
            throw error
        } catch {
            throw ShrunkError.network(error)
        }

        let dto: SubmissionDTO
        do {
            dto = try decoder.decode(SubmissionDTO.self, from: data)
        } catch {
            throw ShrunkError.decoding(error)
        }
        guard let status = SubmissionResult.Status(rawValue: dto.status) else {
            throw ShrunkError.invalidResponse
        }
        return SubmissionResult(status: status, confidence: dto.confidence, observationId: dto.observation_id)
    }

    /// Built separately from the request so it can be tested directly — a custom
    /// `URLProtocol` receives `httpBody` as nil, so the wire format is otherwise
    /// unobservable from a stubbed session.
    static func multipartBody(boundary: String, fields: [String: String], photoJPEG: Data?) -> Data {
        var body = Data()
        for key in fields.keys.sorted() {          // sorted so the body is deterministic
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            body.appendString("\(fields[key] ?? "")\r\n")
        }
        if let photoJPEG {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"photo\"; filename=\"label.jpg\"\r\n")
            body.appendString("Content-Type: image/jpeg\r\n\r\n")
            body.append(photoJPEG)
            body.appendString("\r\n")
        }
        body.appendString("--\(boundary)--\r\n")
        return body
    }
```

Append at the bottom of the same file:

```swift
// MARK: - Crowd submission

struct SubmissionResult: Equatable {
    enum Status: String {
        case accepted, pending
    }

    let status: Status
    let confidence: Double
    let observationId: Int
}

/// Seam for stubbing the upload in `ContributeViewModel` tests.
protocol ObservationSubmitting: Sendable {
    func submitObservation(
        gtin: String,
        quantity: Double,
        unitKind: UnitKind,
        rawText: String,
        ocrConfidence: Double,
        deviceId: String,
        photoJPEG: Data?
    ) async throws -> SubmissionResult
}

extension ShrunkAPIClient: ObservationSubmitting {}

struct SubmissionDTO: Decodable {
    let status: String
    let confidence: Double
    let observation_id: Int
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run the command from the top of this task.
Expected: `Test Suite 'ShrunkAPIClientTests' passed` — Phase 1's 4 tests plus the 8 new ones.

- [ ] **Step 7: Commit**

```bash
git add Shrunk/Services/DeviceIdentity.swift Shrunk/Services/ShrunkAPIClient.swift \
        Shrunk/Models/ShrunkProduct.swift ShrunkTests/ShrunkAPIClientTests.swift
git commit -m "feat(ios): device id, needsConfirmation flag, multipart observation upload"
```

---

### Task 8: `ContributeViewModel`

**Files:**
- Create: `Shrunk/Features/Contribute/ContributeViewModel.swift`
- Test: `ShrunkTests/ContributeViewModelTests.swift`

**Interfaces:**
- Consumes: `NetContentParser`, `UnitKind`, `ParsedQuantity` (Task 5); `LabelTextRecognizing`, `OCRLine` (Task 6); `ObservationSubmitting`, `SubmissionResult`, `DeviceIdentity` (Task 7).
- Produces: `@MainActor final class ContributeViewModel: ObservableObject` with
  - `enum Step: Equatable { case capture, reading, confirm, submitting, finished(SubmissionResult), failed(String) }`
  - `@Published private(set) var step: Step`
  - `@Published var quantityText: String`, `@Published var unitKind: UnitKind`
  - `@Published private(set) var sourceLine: String`
  - `let gtin: String`, `var canSubmit: Bool`
  - `init(gtin: String, deviceId: String = DeviceIdentity.current, ocr: any LabelTextRecognizing = LabelOCRService(), api: any ObservationSubmitting = ShrunkAPIClient.shared)`
  - `func handleCapture(image: CGImage, jpegData: Data) async`
  - `func beginManualEntry()`
  - `func submit() async`
  - `static func toastMessage(for result: SubmissionResult) -> String`
  - `static func format(_ quantity: Double) -> String`

Run the tests with:

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/ContributeViewModelTests -quiet 2>&1 | tail -30
```

- [ ] **Step 1: Write the failing tests**

`ShrunkTests/ContributeViewModelTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import Shrunk

// MARK: - Stubs

final class StubOCR: LabelTextRecognizing, @unchecked Sendable {
    var lines: [OCRLine] = []
    var error: Error?

    func recognizeText(in image: CGImage) async throws -> [OCRLine] {
        if let error { throw error }
        return lines
    }
}

final class StubSubmitter: ObservationSubmitting, @unchecked Sendable {
    struct Call: Equatable {
        let gtin: String
        let quantity: Double
        let unitKind: UnitKind
        let rawText: String
        let ocrConfidence: Double
        let deviceId: String
        let photoBytes: Int
    }

    private(set) var calls: [Call] = []
    var result = SubmissionResult(status: .accepted, confidence: 0.9, observationId: 42)
    var error: Error?

    func submitObservation(
        gtin: String, quantity: Double, unitKind: UnitKind, rawText: String,
        ocrConfidence: Double, deviceId: String, photoJPEG: Data?
    ) async throws -> SubmissionResult {
        calls.append(Call(
            gtin: gtin, quantity: quantity, unitKind: unitKind, rawText: rawText,
            ocrConfidence: ocrConfidence, deviceId: deviceId, photoBytes: photoJPEG?.count ?? 0
        ))
        if let error { throw error }
        return result
    }
}

// MARK: - Tests

@MainActor
final class ContributeViewModelTests: XCTestCase {

    private let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])

    private func pixel() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeVM(ocr: StubOCR, api: StubSubmitter) -> ContributeViewModel {
        ContributeViewModel(gtin: "0028400642255", deviceId: "device-1", ocr: ocr, api: api)
    }

    func test_handleCapture_parsesTheNetContentLineIntoTheConfirmStep() async throws {
        let ocr = StubOCR()
        ocr.lines = [
            OCRLine(text: "DORITOS", confidence: 0.99),
            OCRLine(text: "NET WT 12 OZ (340g)", confidence: 0.94),
            OCRLine(text: "INGREDIENTS: CORN", confidence: 0.88)
        ]
        let vm = makeVM(ocr: ocr, api: StubSubmitter())

        await vm.handleCapture(image: try pixel(), jpegData: jpeg)

        XCTAssertEqual(vm.step, .confirm)
        XCTAssertEqual(vm.quantityText, "340.194")
        XCTAssertEqual(vm.unitKind, .mass)
        XCTAssertEqual(vm.sourceLine, "NET WT 12 OZ (340g)")
        XCTAssertTrue(vm.canSubmit)
    }

    func test_handleCapture_withNoNetContentLine_fallsBackToManualEntry() async throws {
        let ocr = StubOCR()
        ocr.lines = [OCRLine(text: "DORITOS", confidence: 0.99), OCRLine(text: "PARTY SIZE", confidence: 0.9)]
        let vm = makeVM(ocr: ocr, api: StubSubmitter())

        await vm.handleCapture(image: try pixel(), jpegData: jpeg)

        XCTAssertEqual(vm.step, .confirm)
        XCTAssertEqual(vm.quantityText, "")
        XCTAssertEqual(vm.sourceLine, "")
        XCTAssertFalse(vm.canSubmit)
    }

    func test_handleCapture_whenOCRThrows_fallsBackToManualEntry() async throws {
        let ocr = StubOCR()
        ocr.error = LabelOCRError.recognitionFailed(URLError(.unknown))
        let vm = makeVM(ocr: ocr, api: StubSubmitter())

        await vm.handleCapture(image: try pixel(), jpegData: jpeg)

        XCTAssertEqual(vm.step, .confirm)
        XCTAssertEqual(vm.quantityText, "")
    }

    func test_submit_sendsTheConfirmedValuesAndThePhoto() async throws {
        let ocr = StubOCR()
        ocr.lines = [OCRLine(text: "NET WT 12 OZ (340g)", confidence: 0.94)]
        let api = StubSubmitter()
        let vm = makeVM(ocr: ocr, api: api)

        await vm.handleCapture(image: try pixel(), jpegData: jpeg)
        await vm.submit()

        XCTAssertEqual(api.calls, [StubSubmitter.Call(
            gtin: "0028400642255", quantity: 340.194, unitKind: .mass,
            rawText: "NET WT 12 OZ (340g)", ocrConfidence: 0.94,
            deviceId: "device-1", photoBytes: 4
        )])
        XCTAssertEqual(vm.step, .finished(SubmissionResult(status: .accepted, confidence: 0.9, observationId: 42)))
    }

    func test_submit_sendsTheEditedQuantityAndUnit() async throws {
        let ocr = StubOCR()
        ocr.lines = [OCRLine(text: "NET WT 12 OZ (340g)", confidence: 0.94)]
        let api = StubSubmitter()
        let vm = makeVM(ocr: ocr, api: api)

        await vm.handleCapture(image: try pixel(), jpegData: jpeg)
        vm.quantityText = "283.5"
        vm.unitKind = .volume
        await vm.submit()

        XCTAssertEqual(api.calls.first?.quantity, 283.5)
        XCTAssertEqual(api.calls.first?.unitKind, .volume)
        // The raw label line is preserved even when the shopper corrects the number.
        XCTAssertEqual(api.calls.first?.rawText, "NET WT 12 OZ (340g)")
    }

    func test_submit_manualEntry_sendsZeroOCRConfidenceAndNoRawText() async throws {
        let api = StubSubmitter()
        let vm = makeVM(ocr: StubOCR(), api: api)

        await vm.handleCapture(image: try pixel(), jpegData: jpeg)
        vm.quantityText = "500"
        vm.unitKind = .volume
        await vm.submit()

        XCTAssertEqual(api.calls.first?.ocrConfidence, 0)
        XCTAssertEqual(api.calls.first?.rawText, "")
        XCTAssertEqual(api.calls.first?.quantity, 500)
    }

    func test_submit_networkFailure_showsTheOfflineCopy() async throws {
        let ocr = StubOCR()
        ocr.lines = [OCRLine(text: "NET WT 12 OZ (340g)", confidence: 0.94)]
        let api = StubSubmitter()
        api.error = ShrunkError.network(URLError(.notConnectedToInternet))
        let vm = makeVM(ocr: ocr, api: api)

        await vm.handleCapture(image: try pixel(), jpegData: jpeg)
        await vm.submit()

        guard case .failed(let message) = vm.step else {
            return XCTFail("expected .failed, got \(vm.step)")
        }
        XCTAssertEqual(message, "Couldn't reach Shrunk — check connection.")
    }

    func test_submit_isARefusedNoOpWithoutAUsableQuantity() async {
        let api = StubSubmitter()
        let vm = makeVM(ocr: StubOCR(), api: api)
        vm.beginManualEntry()

        for text in ["", "0", "-1", "abc"] {
            vm.quantityText = text
            XCTAssertFalse(vm.canSubmit, text)
            await vm.submit()
        }
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertEqual(vm.step, .confirm)
    }

    func test_toastMessage() {
        XCTAssertEqual(
            ContributeViewModel.toastMessage(for: SubmissionResult(status: .accepted, confidence: 1, observationId: 1)),
            "Added — thanks for the label."
        )
        XCTAssertEqual(
            ContributeViewModel.toastMessage(for: SubmissionResult(status: .pending, confidence: 0.5, observationId: 1)),
            "Thanks — we'll review your photo."
        )
    }

    func test_format_trimsTrailingZerosWithoutLosingPrecision() {
        XCTAssertEqual(ContributeViewModel.format(340.194), "340.194")
        XCTAssertEqual(ContributeViewModel.format(500), "500")
        XCTAssertEqual(ContributeViewModel.format(4258.584), "4258.584")
        XCTAssertEqual(ContributeViewModel.format(73.709), "73.709")
        XCTAssertEqual(ContributeViewModel.format(1360), "1360")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the command above.
Expected: compile error `cannot find 'ContributeViewModel' in scope`.

- [ ] **Step 3: Implement the view model**

`Shrunk/Features/Contribute/ContributeViewModel.swift`:

```swift
import Foundation
import CoreGraphics

/// Drives the contribution flow: still capture → OCR → confirm → upload.
@MainActor
final class ContributeViewModel: ObservableObject {

    enum Step: Equatable {
        case capture
        case reading
        case confirm
        case submitting
        case finished(SubmissionResult)
        case failed(String)
    }

    @Published private(set) var step: Step = .capture
    @Published var quantityText: String = ""
    @Published var unitKind: UnitKind = .mass
    /// The label line the quantity came from. Sent as `raw_text` and shown in
    /// the confirm sheet so the shopper can see what we read.
    @Published private(set) var sourceLine: String = ""

    let gtin: String

    private let deviceId: String
    private let ocr: any LabelTextRecognizing
    private let api: any ObservationSubmitting

    private var photoJPEG: Data?
    private var ocrConfidence: Double = 0

    init(
        gtin: String,
        deviceId: String = DeviceIdentity.current,
        ocr: any LabelTextRecognizing = LabelOCRService(),
        api: any ObservationSubmitting = ShrunkAPIClient.shared
    ) {
        self.gtin = gtin
        self.deviceId = deviceId
        self.ocr = ocr
        self.api = api
    }

    var canSubmit: Bool {
        guard let value = Double(quantityText) else { return false }
        return value > 0
    }

    /// Camera hand-off: the still frame feeds Vision, the JPEG rides along in
    /// case the gate holds the row for review.
    func handleCapture(image: CGImage, jpegData: Data) async {
        photoJPEG = jpegData
        step = .reading

        let lines: [OCRLine]
        do {
            lines = try await ocr.recognizeText(in: image)
        } catch {
            beginManualEntry()
            return
        }

        guard let match = NetContentParser.firstNetContent(in: lines.map(\.text)) else {
            beginManualEntry()
            return
        }

        ocrConfidence = lines[match.lineIndex].confidence
        sourceLine = match.line
        quantityText = Self.format(match.parsed.quantity)
        unitKind = match.parsed.unitKind
        step = .confirm
    }

    /// Spec §8: "OCR finds no net-content line: manual entry sheet with quantity + unit."
    func beginManualEntry() {
        ocrConfidence = 0
        sourceLine = ""
        quantityText = ""
        unitKind = .mass
        step = .confirm
    }

    func submit() async {
        guard let quantity = Double(quantityText), quantity > 0 else { return }
        step = .submitting
        do {
            let result = try await api.submitObservation(
                gtin: gtin,
                quantity: quantity,
                unitKind: unitKind,
                rawText: sourceLine,
                ocrConfidence: ocrConfidence,
                deviceId: deviceId,
                photoJPEG: photoJPEG
            )
            step = .finished(result)
        } catch ShrunkError.network(_) {
            // Spec §8, verbatim.
            step = .failed("Couldn't reach Shrunk — check connection.")
        } catch let error as ShrunkError {
            step = .failed(error.errorDescription ?? "Couldn't reach Shrunk — check connection.")
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    static func toastMessage(for result: SubmissionResult) -> String {
        switch result.status {
        case .accepted: return "Added — thanks for the label."
        case .pending:  return "Thanks — we'll review your photo."
        }
    }

    /// Up to three decimals with the trailing zeros trimmed, so an unedited
    /// 340.194 g submits at full precision but 500 mL reads as "500".
    static func format(_ quantity: Double) -> String {
        var text = String(format: "%.3f", quantity)
        while text.contains("."), text.hasSuffix("0") || text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the command from the top of this task.
Expected: `Test Suite 'ContributeViewModelTests' passed`, 10 tests.

`test_submit_isARefusedNoOpWithoutAUsableQuantity` failing on `.confirm` means `submit()` moved the step before validating — the `guard` must come first.

- [ ] **Step 5: Commit**

```bash
git add Shrunk/Features/Contribute/ContributeViewModel.swift ShrunkTests/ContributeViewModelTests.swift
git commit -m "feat(ios): contribute view model with OCR, manual fallback, upload"
```

---

### Task 9: Label capture camera and confirm sheet

**Files:**
- Create: `Shrunk/Features/Contribute/LabelCaptureController.swift`
- Create: `Shrunk/Features/Contribute/LabelCaptureView.swift`
- Create: `Shrunk/Features/Contribute/ContributeConfirmSheet.swift`
- Modify: `Shrunk/Features/Contribute/ContributeViewModel.swift` (adds `retake()`)
- Test: `ShrunkTests/ContributeViewModelTests.swift` (append)

**Interfaces:**
- Consumes: `CameraPreviewLayer(session:)` from `Shrunk/Features/Scanner/CameraPreviewLayer.swift`; `ContributeViewModel` (Task 8); `ShrunkButton`, `ShrunkTheme`, `Color.*` from Core.
- Produces: `ContributeViewModel.retake()` — clears the captured photo and returns to `.capture`.
- Produces: `@MainActor final class LabelCaptureController: NSObject, ObservableObject` with `session`, `@Published private(set) var isAuthorized/isRunning/isCapturing`, `@Published var error: String?`, `func bootstrap()`, `func stop()`, `func capture(_ completion: @escaping (CGImage, Data) -> Void)`.
- Produces: `static func prepare(photoData: Data) -> (image: CGImage, jpeg: Data)?` on `LabelCaptureController` — orientation-normalized, longest edge ≤ 1600 px, JPEG quality 0.7. Pure and unit-tested.
- Produces: `struct LabelCaptureView: View { init(gtin: String, onFinished: @escaping (SubmissionResult) -> Void) }`.
- Produces: `struct ContributeConfirmSheet: View { @ObservedObject var vm: ContributeViewModel }`.

- [ ] **Step 1: Write the failing test**

Append to `ShrunkTests/ContributeViewModelTests.swift`, inside the class:

```swift
    // MARK: - Photo preparation

    func test_prepare_downscalesAndReencodes() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        }
        let original = try XCTUnwrap(big.jpegData(compressionQuality: 1))

        let prepared = try XCTUnwrap(LabelCaptureController.prepare(photoData: original))

        XCTAssertEqual(prepared.image.width, 1600)
        XCTAssertEqual(prepared.image.height, 1067)
        XCTAssertLessThan(prepared.jpeg.count, 1_000_000, "uploads must stay well under the 5 MB server cap")
        XCTAssertGreaterThan(prepared.jpeg.count, 0)
    }

    func test_prepare_leavesASmallImageAtItsOwnSize() throws {
        let small = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        let prepared = try XCTUnwrap(LabelCaptureController.prepare(photoData: try XCTUnwrap(small.jpegData(compressionQuality: 1))))
        XCTAssertEqual(prepared.image.width, 800)
        XCTAssertEqual(prepared.image.height, 600)
    }

    func test_prepare_rejectsNonImageData() {
        XCTAssertNil(LabelCaptureController.prepare(photoData: Data("not an image".utf8)))
    }
```

Add `import UIKit` at the top of `ContributeViewModelTests.swift`.

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/ContributeViewModelTests -quiet 2>&1 | tail -30
```
Expected: compile error `cannot find 'LabelCaptureController' in scope`.

- [ ] **Step 3: Implement the capture controller**

`Shrunk/Features/Contribute/LabelCaptureController.swift`:

```swift
import AVFoundation
import UIKit
import Combine

/// Still-photo capture for label contributions.
///
/// Same session discipline as `BarcodeProcessor`: `@Published` UI state lives on
/// the main actor, and every `AVCaptureSession` mutation happens on one private
/// serial queue. Session state is `nonisolated` because that queue *is* the
/// synchronization mechanism.
@MainActor
final class LabelCaptureController: NSObject, ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var isRunning = false
    @Published private(set) var isCapturing = false
    @Published var error: String?

    nonisolated let session = AVCaptureSession()
    nonisolated private let queue = DispatchQueue(label: "com.shrunk.contribute.session")
    nonisolated private let output = AVCapturePhotoOutput()
    private nonisolated(unsafe) var configured = false

    private var onCapture: ((CGImage, Data) -> Void)?

    // MARK: - Lifecycle

    func bootstrap() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            startInternal()
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                self.isAuthorized = granted
                if granted { self.startInternal() }
                else { self.error = "Camera access is required to photograph a label." }
            }
        case .denied, .restricted:
            isAuthorized = false
            error = "Camera access denied. Enable it in Settings → Shrunk."
        @unknown default:
            isAuthorized = false
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            Task { @MainActor [weak self] in self?.isRunning = false }
        }
    }

    func capture(_ completion: @escaping (CGImage, Data) -> Void) {
        guard isRunning, !isCapturing else { return }
        isCapturing = true
        onCapture = completion
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.photoQualityPrioritization = .balanced
        queue.async { [weak self] in
            guard let self else { return }
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - Session-side (nonisolated, runs on `queue`)

    nonisolated private func startInternal() {
        queue.async { [weak self] in
            guard let self else { return }
            self.configureIfNeeded()
            if !self.session.isRunning { self.session.startRunning() }
            let running = self.session.isRunning
            Task { @MainActor [weak self] in self?.isRunning = running }
        }
    }

    nonisolated private func configureIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !configured else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            session.commitConfiguration()
            Task { @MainActor [weak self] in self?.error = "No camera available on this device." }
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            session.commitConfiguration()
            let message = error.localizedDescription
            Task { @MainActor [weak self] in self?.error = message }
            return
        }

        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
    }

    // MARK: - Photo preparation

    /// Normalizes EXIF orientation and caps the longest edge at 1600 px, which
    /// keeps OCR accurate while holding uploads to a few hundred KB — far under
    /// the Worker's 5 MB cap.
    static func prepare(photoData: Data) -> (image: CGImage, jpeg: Data)? {
        guard let source = UIImage(data: photoData), source.size.width > 0, source.size.height > 0 else { return nil }

        let maxEdge: CGFloat = 1600
        let scale = min(1, maxEdge / max(source.size.width, source.size.height))
        let size = CGSize(
            width: (source.size.width * scale).rounded(),
            height: (source.size.height * scale).rounded()
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        // Redrawing also bakes in the orientation, so Vision sees an upright image.
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }

        guard let cgImage = normalized.cgImage,
              let jpeg = normalized.jpegData(compressionQuality: 0.7) else { return nil }
        return (cgImage, jpeg)
    }
}

extension LabelCaptureController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let data = photo.fileDataRepresentation()
        let message = error?.localizedDescription

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isCapturing = false
            guard let data, let prepared = Self.prepare(photoData: data) else {
                self.error = message ?? "Couldn't save that photo — try again."
                return
            }
            let handler = self.onCapture
            self.onCapture = nil
            handler?(prepared.image, prepared.jpeg)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the command from Step 2.
Expected: `Test Suite 'ContributeViewModelTests' passed`, 13 tests.

If `prepared.image.height` comes back as 1066 rather than 1067, the renderer rounded differently on this OS — relax the assertion to `XCTAssertEqual(prepared.image.height, 1067, accuracy: 1)` using `XCTAssertEqual(Double(prepared.image.height), 1067, accuracy: 1)`.

- [ ] **Step 5: Build the confirm sheet**

`Shrunk/Features/Contribute/ContributeConfirmSheet.swift`:

```swift
import SwiftUI

/// Last stop before upload: the shopper checks (and can correct) what we read.
struct ContributeConfirmSheet: View {
    @ObservedObject var vm: ContributeViewModel
    let onRetake: () -> Void

    @FocusState private var quantityFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Check the size")
                    .font(.shrunkTitle)
                    .foregroundStyle(Color.ink)
                if vm.sourceLine.isEmpty {
                    Text("We couldn't read a net-content line. Type the size from the label.")
                        .font(.shrunkCallout)
                        .foregroundStyle(Color.smoke)
                } else {
                    Text("From the label: \(vm.sourceLine)")
                        .font(.shrunkMonoSmall)
                        .foregroundStyle(Color.smoke)
                        .lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
                Text("QUANTITY").shrunkSectionLabel()
                TextField("0", text: $vm.quantityText)
                    .keyboardType(.decimalPad)
                    .focused($quantityFocused)
                    .font(.shrunkMonoBig)
                    .foregroundStyle(Color.ink)
                    .padding(ShrunkTheme.Spacing.md)
                    .background(Color.mist)
                    .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous))

                Text("UNIT").shrunkSectionLabel()
                Picker("Unit", selection: $vm.unitKind) {
                    ForEach(UnitKind.allCases, id: \.self) { kind in
                        Text(kind.displayLabel).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            }

            Spacer(minLength: 0)

            VStack(spacing: ShrunkTheme.Spacing.sm) {
                ShrunkButton(
                    "Submit",
                    icon: "checkmark",
                    isLoading: vm.step == .submitting
                ) {
                    Task { await vm.submit() }
                }
                .disabled(!vm.canSubmit)

                ShrunkButton("Retake photo", icon: "arrow.counterclockwise", variant: .ghost, action: onRetake)
            }
        }
        .padding(ShrunkTheme.Spacing.lg)
        .background(Color.paper.ignoresSafeArea())
        .onAppear { quantityFocused = vm.quantityText.isEmpty }
    }
}
```

- [ ] **Step 6: Build the capture screen**

`Shrunk/Features/Contribute/LabelCaptureView.swift`:

```swift
import SwiftUI

/// Camera → OCR → confirm → upload. Dismisses itself once the Worker answers,
/// handing the result back so the presenting screen can show the toast.
struct LabelCaptureView: View {
    @StateObject private var camera = LabelCaptureController()
    @StateObject private var vm: ContributeViewModel
    @Environment(\.dismiss) private var dismiss

    private let onFinished: (SubmissionResult) -> Void

    init(gtin: String, onFinished: @escaping (SubmissionResult) -> Void) {
        _vm = StateObject(wrappedValue: ContributeViewModel(gtin: gtin))
        self.onFinished = onFinished
    }

    private var showsConfirmSheet: Bool {
        switch vm.step {
        case .confirm, .submitting: return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isAuthorized {
                CameraPreviewLayer(session: camera.session)
                    .ignoresSafeArea()
                guideOverlay
            } else {
                permissionPrompt
            }

            if vm.step == .reading {
                busyOverlay(message: "Reading the label…")
            }
        }
        .onAppear { camera.bootstrap() }
        .onDisappear { camera.stop() }
        .sheet(isPresented: .constant(showsConfirmSheet)) {
            ContributeConfirmSheet(vm: vm) { vm.retake() }
                .presentationDetents([.height(420)])
                .interactiveDismissDisabled()
        }
        .onChange(of: vm.step) { _, step in
            if case .finished(let result) = step {
                onFinished(result)
                dismiss()
            }
        }
        .alert(
            "Couldn't reach Shrunk",
            isPresented: Binding(
                get: { if case .failed = vm.step { return true } else { return false } },
                set: { if !$0 { vm.retake() } }
            ),
            actions: { Button("OK", role: .cancel) { vm.retake() } },
            message: { Text(failureMessage) }
        )
        .alert(
            "Camera problem",
            isPresented: Binding(get: { camera.error != nil }, set: { if !$0 { camera.error = nil } }),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(camera.error ?? "") }
        )
        .preferredColorScheme(.dark)
    }

    private var failureMessage: String {
        if case .failed(let message) = vm.step { return message }
        return ""
    }

    // MARK: - Overlays

    private var guideOverlay: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .accessibilityLabel("Close")
                Spacer()
            }
            .padding(ShrunkTheme.Spacing.md)

            Spacer()

            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous)
                .stroke(Color.white.opacity(0.85), lineWidth: 2)
                .frame(height: 110)
                .padding(.horizontal, ShrunkTheme.Spacing.lg)

            Text("Line up the net weight — \"NET WT 12 OZ\"")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.5))
                .clipShape(Capsule())
                .padding(.top, ShrunkTheme.Spacing.md)

            Spacer()

            Button {
                camera.capture { image, jpeg in
                    Task { await vm.handleCapture(image: image, jpegData: jpeg) }
                }
            } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
                    Circle().fill(Color.white).frame(width: 62, height: 62)
                }
            }
            .disabled(camera.isCapturing || !camera.isRunning)
            .accessibilityLabel("Take label photo")
            .padding(.bottom, ShrunkTheme.Spacing.xl)
        }
    }

    private func busyOverlay(message: String) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: ShrunkTheme.Spacing.sm) {
                ProgressView().controlSize(.large).tint(.white)
                Text(message)
                    .font(.shrunkCallout)
                    .foregroundStyle(.white)
            }
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: ShrunkTheme.Spacing.md) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.8))
            Text("Camera access is required to photograph a label.")
                .font(.shrunkBody)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            ShrunkButton("Open Settings", variant: .ghost) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
        .padding(ShrunkTheme.Spacing.xl)
    }
}
```

Add the `retake()` helper to `ContributeViewModel` (next to `beginManualEntry`):

```swift
    /// Back to the viewfinder — used by the confirm sheet's retake button and
    /// after a failed upload.
    func retake() {
        photoJPEG = nil
        ocrConfidence = 0
        sourceLine = ""
        quantityText = ""
        step = .capture
    }
```

- [ ] **Step 7: Build the whole suite**

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -30
```
Expected: build succeeds, all suites pass.

- [ ] **Step 8: Commit**

```bash
git add Shrunk/Features/Contribute/LabelCaptureController.swift \
        Shrunk/Features/Contribute/LabelCaptureView.swift \
        Shrunk/Features/Contribute/ContributeConfirmSheet.swift \
        Shrunk/Features/Contribute/ContributeViewModel.swift \
        ShrunkTests/ContributeViewModelTests.swift
git commit -m "feat(ios): label capture camera, photo preparation, confirm sheet"
```

---

### Task 10: ResultView entry points and toast

**Files:**
- Modify: `Shrunk/Features/Result/ResultView.swift`
- Modify: `Shrunk/Features/Result/ResultViewModel.swift`
- Modify: `Shrunk/Resources/Info.plist`

**Interfaces:**
- Consumes: `LabelCaptureView(gtin:onFinished:)`, `ContributeViewModel.toastMessage(for:)` (Tasks 8–9); `ShrunkProduct.needsConfirmation` (Task 7); `Toast`, `ShrunkButton`, `EmptyStateView` from Core.
- Produces: `ResultViewModel.reload(barcode:) async` — forces a fresh fetch so a contribution shows up immediately (`load` deliberately no-ops on an already-loaded state).
- Entry point 1: the `.notFound` state, carrying spec §8's copy verbatim.
- Entry point 2: a "Confirm with a label photo" card in the loaded state when `product.needsConfirmation` is true.

- [ ] **Step 1: Add `reload` to `ResultViewModel`**

Insert after `load(barcode:)` in `Shrunk/Features/Result/ResultViewModel.swift`:

```swift
    /// Force a fresh fetch. `load` deliberately no-ops on an already-loaded
    /// state, so a crowd contribution needs this to surface its new observation.
    func reload(barcode: String) async {
        state = .loading
        await load(barcode: barcode)
    }
```

- [ ] **Step 2: Broaden the camera usage string**

In `Shrunk/Resources/Info.plist`, replace the `NSCameraUsageDescription` value:

```xml
    <key>NSCameraUsageDescription</key>
    <string>Shrunk uses your camera to scan product barcodes and, when you choose to contribute, to photograph a product label so we can read its net weight.</string>
```

- [ ] **Step 3: Add the state and the sheet to `ResultView`**

In `Shrunk/Features/Result/ResultView.swift`, add to the `@State` block:

```swift
    @State private var showLabelCapture = false
    @State private var contributionToast: String?
```

Replace the `body` so the sheet and toast apply in every state:

```swift
    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .overlay(alignment: .bottom) { toastOverlay }
        }
        .task(id: barcode) {
            if let prebake { vm.prebake(product: prebake.product, record: prebake.record) }
            await vm.load(barcode: barcode)
        }
        .fullScreenCover(isPresented: $showLabelCapture) {
            LabelCaptureView(gtin: barcode) { result in
                contributionToast = ContributeViewModel.toastMessage(for: result)
                Task { await vm.reload(barcode: barcode) }
            }
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let contributionToast {
            Toast(message: contributionToast)
                .padding(.bottom, ShrunkTheme.Spacing.xl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: contributionToast) {
                    try? await Task.sleep(nanoseconds: 2_800_000_000)
                    withAnimation { self.contributionToast = nil }
                }
        }
    }
```

- [ ] **Step 4: Replace the not-found state (entry point 1)**

Replace `notFoundView(barcode:)` entirely — the Open Food Facts hand-off is gone with the OFF scan path (spec §7):

```swift
    private func notFoundView(barcode: String) -> some View {
        VStack(spacing: ShrunkTheme.Spacing.md) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.mist)
                    .frame(width: 96, height: 96)
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Color.smoke)
            }
            Text("Not in our database yet — snap the label to add it")
                .font(.shrunkTitle)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .padding(.top, ShrunkTheme.Spacing.sm)
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
            Text("Barcode \(barcode). One photo of the net-weight line adds it for every Shrunk user.")
                .font(.shrunkBody)
                .foregroundStyle(Color.smoke)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
            VStack(spacing: 10) {
                ShrunkButton("Snap the label", icon: "camera.fill") {
                    showLabelCapture = true
                }
                Button("Close") { dismiss() }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.smoke)
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
            .padding(.top, ShrunkTheme.Spacing.md)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper)
    }
```

- [ ] **Step 5: Add the confirmation card (entry point 2)**

In `loadedView(product:record:)`, insert the card right after `comparisonRow(record: record)`:

```swift
                comparisonRow(record: record)
                if product.needsConfirmation {
                    confirmationCard
                        .padding(.horizontal, ShrunkTheme.Spacing.lg)
                }
```

And add the card itself next to the other section builders:

```swift
    /// Shown when the live store size disagrees with our latest observation
    /// (spec §4 step 4). Phase 3 sets `needsConfirmation`; the flow is live now.
    private var confirmationCard: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            HStack(spacing: 8) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.verdictWarnDeep)
                Text("SIZE UNCONFIRMED").shrunkSectionLabel()
            }
            Text("The size we're showing might be out of date. A photo of the net-weight line settles it.")
                .font(.shrunkCallout)
                .foregroundStyle(Color.smoke)
                .fixedSize(horizontal: false, vertical: true)
            ShrunkButton("Confirm with a label photo", icon: "camera.fill", variant: .ghost) {
                showLabelCapture = true
            }
        }
        .shrunkCard(radius: ShrunkTheme.Radius.lg, padding: ShrunkTheme.Spacing.md)
    }
```

- [ ] **Step 6: Build and run the full iOS suite**

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -30
```
Expected: build succeeds; `NetContentParserTests`, `LabelOCRServiceTests`, `ContributeViewModelTests`, `ShrunkAPIClientTests`, `ShrinkDetectorTests` all pass.

- [ ] **Step 7: Manual smoke test on a device**

The simulator has no usable camera, so run on hardware. Point `ShrunkAPIClient.defaultBaseURL` at the deployed Worker (or set the `useLocalAPI` default with `wrangler dev` running).

1. Scan a barcode that is not in the database → the result screen reads **"Not in our database yet — snap the label to add it"**. Tap **Snap the label**, photograph a label, confirm the parsed quantity, submit.
2. Expect a bottom toast: "Added — thanks for the label." (gate ≥ 0.8) or "Thanks — we'll review your photo." (below it), and the screen reloading into the product.
3. If the toast said *review*, open `https://shrunk-api.<account>.workers.dev/v1/admin/review`, paste `ADMIN_SECRET`, confirm the photo renders, click **Accept**, then re-scan the barcode and confirm the size now appears in the history.
4. Verify the photo is gone: `npx wrangler r2 object get shrunk-photos/submissions/<id>.jpg` should report the object does not exist.

- [ ] **Step 8: Commit**

```bash
git add Shrunk/Features/Result/ResultView.swift Shrunk/Features/Result/ResultViewModel.swift Shrunk/Resources/Info.plist
git commit -m "feat(ios): label contribution entry points and result toast"
```

---

## Phase 2 exit criteria

- `cd backend && npx vitest run && npx tsc --noEmit` → all suites pass (health, normalize, gtin, product, lookup, db-submissions, gate, observations, admin).
- `xcodegen generate && xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17'` → all suites pass, including `NetContentParser` over `fixtures/package_weights.json` and the 31 real label strings.
- A contribution from a device produces an `observations` row with `source='crowd'`; a high-confidence one is `accepted` with no R2 object, a low-confidence one is `pending` with exactly one.
- The deployed review page lists pending submissions with photos behind `Authorization: Bearer <ADMIN_SECRET>`, and accept/reject deletes the photo from R2 and flips both rows.
- Accepting a crowd observation smaller than the previous accepted same-kind one leaves exactly one unsent `alert_jobs(kind='size_drop')` row for Phase 4's cron to drain.

Phase 3 (Kroger client, proxy endpoints, store picker, live-price panel, alternatives rewrite) consumes `ShrunkProduct.needsConfirmation` — it sets the flag when the live Kroger size differs from the latest non-Kroger observation, which lights up the "Confirm with a label photo" card built here.
