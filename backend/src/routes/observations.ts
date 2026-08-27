import { Hono } from "hono";
import type { Env } from "../env";
import { normalizeGTIN } from "../gtin";
import {
  buildInsertObservation,
  buildInsertSubmission,
  clearSubmissionPhotoKey,
  getLatestAcceptedObservation,
  getProduct,
  insertProduct,
  type ProductRow,
} from "../db";
import { scoreSubmission } from "../gate";
import { finalizeAcceptance } from "../crowd";
import { canonicalDeviceId, hitRateLimit, isValidDeviceId, OBSERVATIONS_HOURLY_LIMIT } from "../ratelimit";

export const observationsRoute = new Hono<{ Bindings: Env }>();

const MAX_PHOTO_BYTES = 5 * 1024 * 1024;
const KINDS = new Set(["mass", "volume", "count"]);
const MAX_RAW_TEXT = 500;
/** Room for multipart field overhead above the photo itself (I7). */
const CONTENT_LENGTH_SLACK = 64 * 1024;

/** I5: the client's own Content-Type is attacker-controlled — check the bytes. */
function isJpeg(bytes: Uint8Array): boolean {
  return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
}

/**
 * I7: c.req.formData() buffers the entire request body before the old
 * post-parse `file.size` check ever ran — on a public endpoint an attacker
 * could push the platform's full body limit through memory before the cap
 * fired. Exported as a pure function so the boundary is testable without
 * depending on a runtime's Content-Length behaviour.
 */
export function declaredBodyTooLarge(contentLengthHeader: string | null | undefined): boolean {
  const declared = Number(contentLengthHeader ?? "");
  return Number.isFinite(declared) && declared > MAX_PHOTO_BYTES + CONTENT_LENGTH_SLACK;
}

observationsRoute.post("/v1/observations", async (c) => {
  if (declaredBodyTooLarge(c.req.header("Content-Length"))) {
    return c.json({ error: "photo_too_large" }, 400);
  }

  let form: FormData;
  try {
    form = await c.req.formData();
  } catch {
    return c.json({ error: "invalid_multipart" }, 400);
  }

  const gtin = normalizeGTIN(String(form.get("gtin") ?? ""));
  if (!gtin) return c.json({ error: "invalid_gtin" }, 400);

  const rawDeviceId = String(form.get("device_id") ?? "").trim();
  if (!rawDeviceId) return c.json({ error: "missing_device_id" }, 400);
  // R42 — validate the UUID shape before canonicalising, same as /v1/devices
  // and /v1/kroger/*: a malformed id is rejected outright rather than
  // silently lower-cased into a submissions row the app would never produce.
  if (!isValidDeviceId(rawDeviceId)) return c.json({ error: "invalid_device_id" }, 400);
  // R40 — canonical (lowercase) form is what lands in submissions.device_id
  // and the rate-limit key below, so the same physical device always draws
  // on the same quota and erase-by-id can find it regardless of case.
  const deviceId = canonicalDeviceId(rawDeviceId);

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

  // I5: read the bytes once, up front — reused for the JPEG check and (when
  // the row lands pending) the R2 put, and validated regardless of the
  // client's declared Content-Type, which is attacker-controlled.
  let photoBytes: ArrayBuffer | null = null;
  if (file) {
    photoBytes = await file.arrayBuffer();
    if (!isJpeg(new Uint8Array(photoBytes, 0, Math.min(3, photoBytes.byteLength)))) {
      return c.json({ error: "invalid_photo" }, 400);
    }
  }

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
  const willStorePhoto = gate.status === "pending" && file !== null && photoBytes !== null;
  const photoKey = willStorePhoto ? `submissions/${submissionId}.jpg` : null;

  // I1: the observation and submission rows must land together or not at
  // all. Two separate .run() calls used to let a D1 failure between them
  // strand a `pending` observation whose submission never existed — no admin
  // route could ever find or resolve it, and its R2 object (written even
  // earlier, before either insert) was never deleted either.
  const [obsResult] = await c.env.DB.batch([
    buildInsertObservation(c.env.DB, {
      gtin,
      quantity,
      unit_kind: unitKind,
      raw_text: rawText,
      observed_at: now,
      source: "crowd",
      source_ref: submissionId,
      confidence: gate.confidence,
      status: gate.status,
    }),
    buildInsertSubmission(c.env.DB, {
      id: submissionId,
      device_id: deviceId,
      gtin,
      photo_key: photoKey,
      ocr_text: rawText,
      parsed_quantity: quantity,
      parsed_kind: unitKind,
      status: gate.status,
      created_at: now,
    }),
  ]);
  const observationId = Number(obsResult.meta.last_row_id);

  // The photo is written only after the DB rows are durable. If R2 fails
  // here, the rows already exist — null out photo_key so the row stays
  // `pending` and reviewable instead of pointing at an object that was never
  // written. I5: content-type is always forced to image/jpeg, never the
  // client's declared type, since the bytes are already verified JPEG.
  if (willStorePhoto && photoBytes) {
    try {
      await c.env.PHOTOS.put(photoKey!, photoBytes, { httpMetadata: { contentType: "image/jpeg" } });
    } catch {
      await clearSubmissionPhotoKey(c.env.DB, submissionId);
    }
  }

  if (gate.status === "accepted") {
    await finalizeAcceptance(c.env.DB, {
      gtin,
      quantity,
      unitKind,
      previousQuantity: latest?.quantity ?? null,
      previousObservedAt: latest?.observed_at ?? null,
      observedAt: now,
      brand: product.brand,
      now,
    });
  }

  return c.json({ status: gate.status, confidence: gate.confidence, observation_id: observationId });
});
