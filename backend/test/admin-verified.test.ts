import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";

const GTIN = "0052000133417";

async function post(body: unknown, secret: string | null = "test-secret") {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (secret !== null) headers.Authorization = `Bearer ${secret}`;
  return app.request("/v1/admin/verified-case", { method: "POST", headers, body: JSON.stringify(body) }, env);
}

beforeEach(async () => {
  await env.DB.prepare("DELETE FROM alert_jobs").run();
});

describe("POST /v1/admin/verified-case", () => {
  it("files an unsent verified_case job", async () => {
    const res = await post({ gtin: "052000133417", brand: "Gatorade" });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });

    const row = await env.DB.prepare("SELECT kind, gtin, brand, location_id, sent_at, sent_count FROM alert_jobs").first<any>();
    expect(row).toMatchObject({ kind: "verified_case", gtin: GTIN, brand: "Gatorade", location_id: null, sent_at: null, sent_count: 0 });
  });

  it("accepts a brand-only case", async () => {
    expect((await post({ brand: "Doritos" })).status).toBe(200);
    const row = await env.DB.prepare("SELECT gtin, brand FROM alert_jobs").first<any>();
    expect(row).toMatchObject({ gtin: null, brand: "Doritos" });
  });

  it("rejects an empty case", async () => {
    const res = await post({ gtin: "nope" });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_case" });
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM alert_jobs").first<{ n: number }>()).toEqual({ n: 0 });
  });

  it("requires the admin bearer secret", async () => {
    expect((await post({ brand: "Doritos" }, null)).status).toBe(401);
    expect((await post({ brand: "Doritos" }, "wrong")).status).toBe(401);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM alert_jobs").first<{ n: number }>()).toEqual({ n: 0 });
  });
});
