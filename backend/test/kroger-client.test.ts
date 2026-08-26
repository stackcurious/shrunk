import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { KrogerClient, KrogerError } from "../src/kroger/client";

const TOKEN_BODY = { access_token: "tok-123", expires_in: 1800, token_type: "bearer" };

function jsonResponse(body: unknown, status = 200, responseHeaders?: Record<string, string>): Response {
  return new Response(JSON.stringify(body), { status, headers: responseHeaders });
}

/**
 * Stubs global `fetch` for one test. `handler` returns the Response for a call
 * it recognizes, or `undefined` for one it doesn't — which fails the test
 * loudly instead of silently hitting the real network.
 */
function stubFetch(handler: (url: URL, init: RequestInit | undefined) => Response | undefined | Promise<Response | undefined>) {
  const mock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const res = await handler(url, init);
    if (!res) throw new Error(`unexpected fetch: ${init?.method ?? "GET"} ${url.pathname}${url.search}`);
    return res;
  });
  vi.stubGlobal("fetch", mock);
  return mock;
}

/** Like `stubFetch`, but the token exchange always succeeds first. */
function stubKroger(handler: (url: URL, init: RequestInit | undefined) => Response | undefined | Promise<Response | undefined>) {
  return stubFetch(async (url, init) => {
    if (url.pathname === "/v1/connect/oauth2/token") return jsonResponse(TOKEN_BODY);
    return handler(url, init);
  });
}

beforeEach(async () => {
  await env.KV.delete("kroger:token");
});

afterEach(() => vi.unstubAllGlobals());

describe("KrogerClient.token", () => {
  it("requests a client-credentials token and caches it in KV", async () => {
    const fetchMock = stubFetch((url, init) => {
      expect(url.pathname).toBe("/v1/connect/oauth2/token");
      expect(init?.method).toBe("POST");
      expect(init?.body).toBe("grant_type=client_credentials&scope=product.compact");
      expect((init?.headers as Record<string, string>).authorization).toBe(`Basic ${btoa("test-client:test-secret")}`);
      return jsonResponse(TOKEN_BODY);
    });

    const client = new KrogerClient(env);
    expect(await client.token()).toBe("tok-123");
    expect(await env.KV.get("kroger:token")).toBe("tok-123");

    // Second call must be served from KV — a second HTTP call would bump this count.
    expect(await client.token()).toBe("tok-123");
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("throws KrogerError with the upstream status when the token call fails", async () => {
    stubFetch(() => jsonResponse({ error: "invalid_client" }, 401));

    await expect(new KrogerClient(env).token()).rejects.toMatchObject({ status: 401 });
    expect(await env.KV.get("kroger:token")).toBeNull();
  });

  it("exposes KrogerError for callers to branch on", () => {
    expect(new KrogerError(429).status).toBe(429);
    expect(new KrogerError(429)).toBeInstanceOf(Error);
  });
});
