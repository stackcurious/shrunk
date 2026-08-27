import type { Env } from "../env";
import { APNS_TOPIC, base64url, base64urlText, pemToDer, type PushPayload, type PushResult, type PushSender } from "./PushSender";

const JWT_KV_KEY = "apns:jwt";
/** Apple rejects a token older than 60 minutes; refresh at 50 (spec §6.5). */
const JWT_TTL_SECONDS = 3000;
const MAX_COLLAPSE_ID = 64;

/** ES256 JWT: `{alg:"ES256",kid}` / `{iss:teamId,iat}` signed with the .p8 key. */
export async function mintAPNsJWT(env: Env, now: number): Promise<string> {
  const signingInput =
    `${base64urlText(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }))}.` +
    `${base64urlText(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }))}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(env.APNS_KEY_P8),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signingInput))
  );
  return `${signingInput}.${base64url(signature)}`;
}

export class APNsSender implements PushSender {
  constructor(private readonly env: Env) {}

  host(): string {
    return this.env.APNS_ENV === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  }

  async jwt(now: number = Math.floor(Date.now() / 1000)): Promise<string> {
    const cached = await this.env.KV.get(JWT_KV_KEY);
    if (cached) return cached;
    const fresh = await mintAPNsJWT(this.env, now);
    await this.env.KV.put(JWT_KV_KEY, fresh, { expirationTtl: JWT_TTL_SECONDS });
    return fresh;
  }

  async send(token: string, payload: PushPayload): Promise<PushResult> {
    const headers: Record<string, string> = {
      authorization: `bearer ${await this.jwt()}`,
      "apns-topic": APNS_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    };
    if (payload.collapseId) headers["apns-collapse-id"] = payload.collapseId.slice(0, MAX_COLLAPSE_ID);

    const body: Record<string, unknown> = {
      // `content-available` lets iOS wake the app in the background so the row
      // reaches the Alerts feed even if the banner is never tapped (spec §7).
      aps: { alert: { title: payload.title, body: payload.body }, sound: "default", "content-available": 1 },
      kind: payload.kind,
    };
    if (payload.gtin) body.gtin = payload.gtin;
    if (payload.productName) body.product_name = payload.productName;

    const res = await fetch(`https://${this.host()}/3/device/${token}`, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });
    if (res.ok) return { ok: true, status: res.status, invalidToken: false };

    const text = await res.text().catch(() => "");
    return {
      ok: false,
      status: res.status,
      invalidToken: res.status === 410 || (res.status === 400 && text.includes("BadDeviceToken")),
    };
  }
}
