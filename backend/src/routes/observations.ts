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
import { hitRateLimit, OBSERVATIONS_HOURLY_LIMIT } from "../ratelimit";

export const observationsRoute = new Hono<{ Bindings: Env }>();

const MAX_PHOTO_BYTES = 5 * 1024 * 1024;
const KINDS = new Set(["mass", "volume", "count"]);
const MAX_RAW_TEXT = 500;
const MAX_DEVICE_ID_LENGTH = 64;

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
  // I4/T3b: the client always sends UUID().uuidString (36 chars); 64 leaves
  // headroom without letting an attacker write unbounded text into the column.
  if (deviceId.length > MAX_DEVICE_ID_LENGTH) return c.json({ error: "invalid_device_id" }, 400);

  // I4: this is the app's only unauthenticated write endpoint. Reuse the
  // per-device KV counter the Kroger proxy already uses (spec §6.6), in its
  // own "observations" bucket so the two quotas cannot steal from each other.
  const { allowed } = await hitRateLimit(c.env.KV, deviceId, OBSERVATIONS_HOURLY_LIMIT, "observations");
  if (!allowed) return c.json({ error: "rate_limited" }, 429);

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
