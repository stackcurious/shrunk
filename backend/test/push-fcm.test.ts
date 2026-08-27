import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { FCMSender } from "../src/push/fcm";
import { APNsSender } from "../src/push/apns";
import { pushSender } from "../src/push";
import type { Env } from "../src/env";

const TOKEN = "fcm-registration-token";

async function serviceAccountJSON(): Promise<string> {
  // @cloudflare/workers-types declares generateKey/exportKey with untyped unions
  // (CryptoKey | CryptoKeyPair, ArrayBuffer | JsonWebKey); narrow with casts.
  const pair = (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"]
  )) as CryptoKeyPair;
  const pkcs8 = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const b64 = btoa(String.fromCharCode(...pkcs8)).match(/.{1,64}/g)!.join("\n");
  return JSON.stringify({
    type: "service_account",
    project_id: "shrunk-app",
    client_email: "pusher@shrunk-app.iam.gserviceaccount.com",
    private_key: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`,
    token_uri: "https://oauth2.googleapis.com/token",
  });
}

function decodeJWT(jwt: string) {
  const pad = (s: string) => s + "=".repeat((4 - (s.length % 4)) % 4);
  const json = (part: string) => JSON.parse(atob(pad(part.replace(/-/g, "+").replace(/_/g, "/"))));
  const [header, claims] = jwt.split(".");
  return { header: json(header), claims: json(claims) };
}

interface Call { url: string; init: RequestInit }

function stubFetch(replies: Array<{ status: number; body?: string }>): Call[] {
  const calls: Call[] = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: unknown, init: RequestInit) => {
      calls.push({ url: String(input), init });
      const reply = replies.shift() ?? { status: 200, body: "{}" };
      return new Response(reply.body ?? "{}", { status: reply.status });
    })
  );
  return calls;
}

const OAUTH_OK = { status: 200, body: JSON.stringify({ access_token: "ya29.test", expires_in: 3599 }) };

let fcmEnv: Env;

beforeEach(async () => {
  fcmEnv = { ...env, PUSH_PROVIDER: "fcm", FCM_SERVICE_ACCOUNT_JSON: await serviceAccountJSON() } as Env;
  await env.KV.delete("fcm:token");
});

afterEach(() => vi.unstubAllGlobals());

describe("pushSender", () => {
  it("picks the sender named by PUSH_PROVIDER, defaulting to APNs", () => {
    expect(pushSender({ ...env, PUSH_PROVIDER: "fcm" } as Env)).toBeInstanceOf(FCMSender);
    expect(pushSender({ ...env, PUSH_PROVIDER: "apns" } as Env)).toBeInstanceOf(APNsSender);
    expect(pushSender({ ...env, PUSH_PROVIDER: "" } as Env)).toBeInstanceOf(APNsSender);
  });
});

describe("FCMSender", () => {
  it("exchanges a service-account JWT for an OAuth token, then sends", async () => {
    const calls = stubFetch([OAUTH_OK, { status: 200, body: JSON.stringify({ name: "projects/shrunk-app/messages/1" }) }]);

    const result = await new FCMSender(fcmEnv).send(TOKEN, {
      title: "Gatorade just shrank",
      body: "Now 28 fl oz — was 32 fl oz. Tap to see the history.",
      gtin: "0052000133417",
      kind: "sizeDrop",
      collapseId: "size_drop:0052000133417",
    });
    expect(result).toEqual({ ok: true, status: 200, invalidToken: false });

    expect(calls[0].url).toBe("https://oauth2.googleapis.com/token");
    expect((calls[0].init.headers as Record<string, string>)["content-type"]).toBe("application/x-www-form-urlencoded");
    const form = new URLSearchParams(calls[0].init.body as string);
    expect(form.get("grant_type")).toBe("urn:ietf:params:oauth:grant-type:jwt-bearer");
    const { header, claims } = decodeJWT(form.get("assertion")!);
    expect(header).toEqual({ alg: "RS256", typ: "JWT" });
    expect(claims.iss).toBe("pusher@shrunk-app.iam.gserviceaccount.com");
    expect(claims.aud).toBe("https://oauth2.googleapis.com/token");
    expect(claims.scope).toBe("https://www.googleapis.com/auth/firebase.messaging");
    expect(claims.exp - claims.iat).toBe(3600);

    expect(calls[1].url).toBe("https://fcm.googleapis.com/v1/projects/shrunk-app/messages:send");
    expect((calls[1].init.headers as Record<string, string>).authorization).toBe("Bearer ya29.test");
    expect(JSON.parse(calls[1].init.body as string)).toEqual({
      message: {
        token: TOKEN,
        notification: { title: "Gatorade just shrank", body: "Now 28 fl oz — was 32 fl oz. Tap to see the history." },
        data: { kind: "sizeDrop", gtin: "0052000133417" },
        apns: {
          headers: {
            "apns-topic": "com.shrunk.app",
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-collapse-id": "size_drop:0052000133417",
          },
          payload: {
            aps: {
              alert: { title: "Gatorade just shrank", body: "Now 28 fl oz — was 32 fl oz. Tap to see the history." },
              sound: "default",
              "content-available": 1,
            },
            kind: "sizeDrop",
            gtin: "0052000133417",
          },
        },
      },
    });
  });

  it("caches the OAuth token in KV", async () => {
    const calls = stubFetch([OAUTH_OK, { status: 200 }, { status: 200 }]);
    const sender = new FCMSender(fcmEnv);
    await sender.send(TOKEN, { title: "a", body: "b", kind: "digest" });
    expect(await env.KV.get("fcm:token")).toBe("ya29.test");

    await sender.send(TOKEN, { title: "a", body: "b", kind: "digest" });
    expect(calls).toHaveLength(3);                       // one OAuth call, two sends
    expect(calls[2].url).toContain("messages:send");
  });

  it("reports an invalid token when FCM says UNREGISTERED", async () => {
    stubFetch([OAUTH_OK, { status: 404, body: JSON.stringify({ error: { status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } }) }]);
    expect(await new FCMSender(fcmEnv).send(TOKEN, { title: "a", body: "b", kind: "digest" })).toEqual({
      ok: false, status: 404, invalidToken: true,
    });
  });

  it("reports an invalid token on 400 UNREGISTERED", async () => {
    stubFetch([OAUTH_OK, { status: 400, body: JSON.stringify({ error: { status: "UNREGISTERED" } }) }]);
    expect(await new FCMSender(fcmEnv).send(TOKEN, { title: "a", body: "b", kind: "digest" })).toEqual({
      ok: false, status: 400, invalidToken: true,
    });
  });

  it("does not blame the token for a server error", async () => {
    stubFetch([OAUTH_OK, { status: 503, body: JSON.stringify({ error: { status: "UNAVAILABLE" } }) }]);
    expect(await new FCMSender(fcmEnv).send(TOKEN, { title: "a", body: "b", kind: "digest" })).toEqual({
      ok: false, status: 503, invalidToken: false,
    });
  });

  it("does not blame the token for a 503 whose body happens to mention UNREGISTERED", async () => {
    stubFetch([OAUTH_OK, { status: 503, body: JSON.stringify({ error: { status: "UNREGISTERED" } }) }]);
    expect(await new FCMSender(fcmEnv).send(TOKEN, { title: "a", body: "b", kind: "digest" })).toEqual({
      ok: false, status: 503, invalidToken: false,
    });
  });

  it("fails cleanly when the OAuth exchange fails", async () => {
    stubFetch([{ status: 401, body: JSON.stringify({ error: "invalid_grant" }) }]);
    expect(await new FCMSender(fcmEnv).send(TOKEN, { title: "a", body: "b", kind: "digest" })).toEqual({
      ok: false, status: 401, invalidToken: false,
    });
    expect(await env.KV.get("fcm:token")).toBeNull();
  });

  it("includes product_name in data and aps when present", async () => {
    const calls = stubFetch([OAUTH_OK, { status: 200, body: JSON.stringify({ name: "projects/shrunk-app/messages/1" }) }]);
    await new FCMSender(fcmEnv).send(TOKEN, {
      title: "Gatorade just shrank",
      body: "Now 28 fl oz — was 32 fl oz. Tap to see the history.",
      gtin: "0052000133417",
      kind: "sizeDrop",
      collapseId: "size_drop:0052000133417",
      productName: "Gatorade Thirst Quencher",
    });

    const body = JSON.parse(calls[1].init.body as string);
    expect(body.message.data.product_name).toBe("Gatorade Thirst Quencher");
    expect(body.message.apns.payload.product_name).toBe("Gatorade Thirst Quencher");
  });

  it("omits product_name when not present", async () => {
    const calls = stubFetch([OAUTH_OK, { status: 200, body: JSON.stringify({ name: "projects/shrunk-app/messages/1" }) }]);
    await new FCMSender(fcmEnv).send(TOKEN, {
      title: "What shrank this week",
      body: "3 new shrinks in Snacks, 1 in Dairy",
      kind: "digest",
    });

    const body = JSON.parse(calls[1].init.body as string);
    expect(body.message.data.product_name).toBeUndefined();
    expect(body.message.apns.payload.product_name).toBeUndefined();
  });
});
