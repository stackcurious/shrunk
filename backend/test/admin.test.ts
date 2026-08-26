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

  it("serves a data-free key form to an unauthenticated browser, even with submissions pending", async () => {
    // T4b/M2: the shell must leak no submission data to an unauthenticated
    // GET. Assert that directly (no id, gtin, or OCR text present) rather
    // than banning a specific attribute-name substring the production JS
    // would otherwise have to obfuscate just to dodge this assertion.
    const { submissionId } = await seedPending();
    const res = await app.request("/v1/admin/review", { headers: { Accept: "text/html" } }, env);
    expect(res.status).toBe(401);
    expect(res.headers.get("content-type")).toContain("text/html");
    const html = await res.text();
    expect(html).toContain('id="keyForm"');
    expect(html).not.toContain(submissionId);
    expect(html).not.toContain(GTIN);
    expect(html).not.toContain("Gatorade");
    expect(html).not.toContain("NET WT 28 OZ");
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
