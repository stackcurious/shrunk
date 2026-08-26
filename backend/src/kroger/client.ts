import type { Env } from "../env";

/** Shown wherever Kroger data appears (spec §6.6, §9). */
export const KROGER_ATTRIBUTION = "Prices from Kroger";

const TOKEN_KEY = "kroger:token";
const TOKEN_TTL_SECONDS = 1500; // 25 min; Kroger tokens live 1800s
const TOKEN_URL = "https://api.kroger.com/v1/connect/oauth2/token";
const API_BASE = "https://api.kroger.com/v1";

/** Carries the upstream status so routes can pass 401/429 through unchanged. */
export class KrogerError extends Error {
  constructor(public readonly status: number) {
    super(`kroger_${status}`);
    this.name = "KrogerError";
  }
}

export class KrogerClient {
  constructor(
    private readonly env: Env,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  /** Client-credentials token, cached in KV for 25 minutes. */
  async token(): Promise<string> {
    const cached = await this.env.KV.get(TOKEN_KEY);
    if (cached) return cached;

    const res = await this.fetchImpl(TOKEN_URL, {
      method: "POST",
      headers: {
        authorization: `Basic ${btoa(`${this.env.KROGER_CLIENT_ID}:${this.env.KROGER_CLIENT_SECRET}`)}`,
        "content-type": "application/x-www-form-urlencoded",
      },
      body: "grant_type=client_credentials&scope=product.compact",
    });
    if (!res.ok) throw new KrogerError(res.status);

    const body = (await res.json()) as { access_token?: string };
    if (!body.access_token) throw new KrogerError(502);
    await this.env.KV.put(TOKEN_KEY, body.access_token, { expirationTtl: TOKEN_TTL_SECONDS });
    return body.access_token;
  }
}

export { API_BASE, TOKEN_KEY };
