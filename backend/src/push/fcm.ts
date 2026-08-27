import type { Env } from "../env";
import { APNS_TOPIC, base64url, base64urlText, pemToDer, type PushPayload, type PushResult, type PushSender } from "./PushSender";

const TOKEN_KV_KEY = "fcm:token";
const TOKEN_TTL_SECONDS = 3000;
const SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token";
const MAX_COLLAPSE_ID = 64;

interface ServiceAccount {
  client_email: string;
  private_key: string;
  project_id: string;
  token_uri?: string;
}

/** Thrown internally when the OAuth exchange fails; turned into a PushResult. */
class OAuthError extends Error {
  constructor(readonly status: number) {
    super(`oauth ${status}`);
  }
}

export class FCMSender implements PushSender {
  constructor(private readonly env: Env) {}

  private account(): ServiceAccount {
    return JSON.parse(this.env.FCM_SERVICE_ACCOUNT_JSON) as ServiceAccount;
  }

  async accessToken(now: number = Math.floor(Date.now() / 1000)): Promise<string> {
    const cached = await this.env.KV.get(TOKEN_KV_KEY);
    if (cached) return cached;

    const account = this.account();
    const tokenUri = account.token_uri ?? DEFAULT_TOKEN_URI;
    const signingInput =
      `${base64urlText(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.` +
      `${base64urlText(JSON.stringify({ iss: account.client_email, scope: SCOPE, aud: tokenUri, iat: now, exp: now + 3600 }))}`;

    const key = await crypto.subtle.importKey(
      "pkcs8",
      pemToDer(account.private_key),
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"]
    );
    const signature = new Uint8Array(
      await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(signingInput))
    );

    const res = await fetch(tokenUri, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: `${signingInput}.${base64url(signature)}`,
      }).toString(),
    });
    if (!res.ok) throw new OAuthError(res.status);

    const { access_token } = (await res.json()) as { access_token: string };
    await this.env.KV.put(TOKEN_KV_KEY, access_token, { expirationTtl: TOKEN_TTL_SECONDS });
    return access_token;
  }

  async send(token: string, payload: PushPayload): Promise<PushResult> {
    let access: string;
    try {
      access = await this.accessToken();
    } catch (error) {
      const status = error instanceof OAuthError ? error.status : 0;
      return { ok: false, status, invalidToken: false };
    }

    const apnsHeaders: Record<string, string> = {
      "apns-topic": APNS_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
    };
    if (payload.collapseId) apnsHeaders["apns-collapse-id"] = payload.collapseId.slice(0, MAX_COLLAPSE_ID);

    const data: Record<string, string> = { kind: payload.kind };
    if (payload.gtin) data.gtin = payload.gtin;

    const aps: Record<string, unknown> = {
      // Same `content-available` as the direct APNs path, for the same reason.
      aps: { alert: { title: payload.title, body: payload.body }, sound: "default", "content-available": 1 },
      kind: payload.kind,
    };
    if (payload.gtin) aps.gtin = payload.gtin;

    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${this.account().project_id}/messages:send`, {
      method: "POST",
      headers: { authorization: `Bearer ${access}`, "content-type": "application/json" },
      body: JSON.stringify({
        message: {
          token,
          notification: { title: payload.title, body: payload.body },
          data,
          apns: { headers: apnsHeaders, payload: aps },
        },
      }),
    });
    if (res.ok) return { ok: true, status: res.status, invalidToken: false };

    const text = await res.text().catch(() => "");
    return {
      ok: false,
      status: res.status,
      invalidToken: res.status === 404 || (res.status === 400 && text.includes("UNREGISTERED")),
    };
  }
}
