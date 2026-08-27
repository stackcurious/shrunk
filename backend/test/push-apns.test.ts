import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { APNsSender, mintAPNsJWT } from "../src/push/apns";
import type { Env } from "../src/env";

const TOKEN = "740f4707bebcf74f9b7c25d48e3358945f6aa01da5ddb387462c7eaf61bb78ad";

/** A throwaway P-256 key in the same PEM shape as Apple's AuthKey_*.p8. */
async function generateP8(): Promise<string> {
  // @cloudflare/workers-types declares generateKey/exportKey with untyped unions
  // (no overloads keyed on literal params like lib.dom.d.ts has), so narrow here.
  const pair = (await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"]
  )) as CryptoKeyPair;
  const pkcs8 = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const b64 = btoa(String.fromCharCode(...pkcs8)).match(/.{1,64}/g)!.join("\n");
  return `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`;
}

function decodeJWT(jwt: string) {
  const [header, claims, signature] = jwt.split(".");
  const pad = (s: string) => s + "=".repeat((4 - (s.length % 4)) % 4);
  const json = (part: string) => JSON.parse(atob(pad(part.replace(/-/g, "+").replace(/_/g, "/"))));
  return { header: json(header), claims: json(claims), signature };
}

interface Call { url: string; init: RequestInit }

function stubFetch(replies: Array<{ status: number; body?: string }>): Call[] {
  const calls: Call[] = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: unknown, init: RequestInit) => {
      calls.push({ url: String(input), init });
      const reply = replies.shift() ?? { status: 200 };
      return new Response(reply.body ?? "", { status: reply.status });
    })
  );
  return calls;
}

let p8: string;
let apnsEnv: Env;

beforeEach(async () => {
  p8 = await generateP8();
  apnsEnv = { ...env, APNS_KEY_P8: p8, APNS_KEY_ID: "ABC1234567", APNS_TEAM_ID: "TEAM123456", APNS_ENV: "sandbox" } as Env;
  await env.KV.delete("apns:jwt");
});

afterEach(() => vi.unstubAllGlobals());

describe("mintAPNsJWT", () => {
  it("signs an ES256 JWT with the key id and team id", async () => {
    const jwt = await mintAPNsJWT(apnsEnv, 1700000000);
    const { header, claims, signature } = decodeJWT(jwt);
    expect(header).toEqual({ alg: "ES256", kid: "ABC1234567" });
    expect(claims).toEqual({ iss: "TEAM123456", iat: 1700000000 });
    expect(signature).not.toContain("=");
    expect(signature).not.toContain("+");
    // ES256 signatures are 64 raw bytes -> 86 base64url characters.
    expect(signature.length).toBe(86);
  });
});

describe("APNsSender", () => {
  it("posts to the sandbox host with the required headers and payload", async () => {
    const calls = stubFetch([{ status: 200 }]);
    const result = await new APNsSender(apnsEnv).send(TOKEN, {
      title: "Gatorade just shrank",
      body: "Now 28 fl oz — was 32 fl oz. Tap to see the history.",
      gtin: "0052000133417",
      kind: "sizeDrop",
      collapseId: "size_drop:0052000133417",
    });

    expect(result).toEqual({ ok: true, status: 200, invalidToken: false });
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe(`https://api.sandbox.push.apple.com/3/device/${TOKEN}`);
    expect(calls[0].init.method).toBe("POST");

    const headers = calls[0].init.headers as Record<string, string>;
    expect(headers["apns-topic"]).toBe("com.shrunk.app");
    expect(headers["apns-push-type"]).toBe("alert");
    expect(headers["apns-priority"]).toBe("10");
    expect(headers["apns-collapse-id"]).toBe("size_drop:0052000133417");
    expect(headers.authorization).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/);

    expect(JSON.parse(calls[0].init.body as string)).toEqual({
      aps: {
        alert: { title: "Gatorade just shrank", body: "Now 28 fl oz — was 32 fl oz. Tap to see the history." },
        sound: "default",
        "content-available": 1,
      },
      kind: "sizeDrop",
      gtin: "0052000133417",
    });
  });

  it("uses the production host when APNS_ENV says so and omits an absent gtin", async () => {
    const calls = stubFetch([{ status: 200 }]);
    await new APNsSender({ ...apnsEnv, APNS_ENV: "production" } as Env).send(TOKEN, {
      title: "What shrank this week",
      body: "3 new shrinks in Snacks, 1 in Dairy",
      kind: "digest",
    });
    expect(calls[0].url).toBe(`https://api.push.apple.com/3/device/${TOKEN}`);
    const body = JSON.parse(calls[0].init.body as string);
    expect(body.gtin).toBeUndefined();
    expect((calls[0].init.headers as Record<string, string>)["apns-collapse-id"]).toBeUndefined();
  });

  it("caches the JWT in KV and reuses it on the next send", async () => {
    const calls = stubFetch([{ status: 200 }, { status: 200 }]);
    const sender = new APNsSender(apnsEnv);
    await sender.send(TOKEN, { title: "a", body: "b", kind: "sizeDrop" });
    const cached = await env.KV.get("apns:jwt");
    expect(cached).toBeTruthy();

    await sender.send(TOKEN, { title: "a", body: "b", kind: "sizeDrop" });
    const first = (calls[0].init.headers as Record<string, string>).authorization;
    const second = (calls[1].init.headers as Record<string, string>).authorization;
    expect(second).toBe(first);
    expect(second).toBe(`bearer ${cached}`);
  });

  it("reports an invalid token on 410", async () => {
    stubFetch([{ status: 410, body: JSON.stringify({ reason: "Unregistered" }) }]);
    expect(await new APNsSender(apnsEnv).send(TOKEN, { title: "a", body: "b", kind: "sizeDrop" })).toEqual({
      ok: false, status: 410, invalidToken: true,
    });
  });

  it("reports an invalid token on 400 BadDeviceToken", async () => {
    stubFetch([{ status: 400, body: JSON.stringify({ reason: "BadDeviceToken" }) }]);
    expect(await new APNsSender(apnsEnv).send(TOKEN, { title: "a", body: "b", kind: "sizeDrop" })).toEqual({
      ok: false, status: 400, invalidToken: true,
    });
  });

  it("does not blame the token for other failures", async () => {
    stubFetch([{ status: 500, body: JSON.stringify({ reason: "InternalServerError" }) }]);
    expect(await new APNsSender(apnsEnv).send(TOKEN, { title: "a", body: "b", kind: "sizeDrop" })).toEqual({
      ok: false, status: 500, invalidToken: false,
    });
  });
});
