import { Hono } from "hono";
import type { Env } from "../env";
import {
  eraseDevice,
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
import { canonicalDeviceId, isValidDeviceId } from "../ratelimit";

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
  // I5: photos are only ever stored as image/jpeg (observations.ts forces
  // this at write time and validates the magic bytes), so serve that
  // unconditionally rather than trusting the object's own metadata, and add
  // nosniff since this is a stored-content route on the public API origin.
  return new Response(object.body, {
    headers: {
      "Content-Type": "image/jpeg",
      "X-Content-Type-Options": "nosniff",
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
      previousObservedAt: previous?.observed_at ?? null,
      observedAt: observation.observed_at,
      brand: product?.brand ?? null,
      now,
    });
  }

  return c.json({ ok: true, id, status, alerted });
});

/**
 * R39 — the privacy policy promises "email us your Device ID and we erase
 * everything tied to it." Deletes the device's watches, its device row, its
 * submissions, and the R2 photo behind any still-pending one. Idempotent —
 * a second call against the same id returns all zeros.
 */
adminRoute.post("/v1/admin/devices/:id/erase", async (c) => {
  const id = canonicalDeviceId(c.req.param("id"));
  if (!isValidDeviceId(id)) return c.json({ error: "invalid_device_id" }, 400);

  const deleted = await eraseDevice(c.env.DB, c.env.PHOTOS, id);
  console.log(
    `admin erase: devices=${deleted.devices} watches=${deleted.watches} submissions=${deleted.submissions} photos=${deleted.photos}`
  );
  return c.json({ ok: true, deleted });
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
