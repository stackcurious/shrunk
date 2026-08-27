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

export interface KrogerAddress {
  addressLine1?: string;
  city?: string;
  state?: string;
  zipCode?: string;
}

export interface KrogerLocation {
  locationId: string;
  chain?: string;
  name?: string;
  address?: KrogerAddress;
  geolocation?: { latitude?: number; longitude?: number };
}

export interface KrogerItem {
  itemId?: string;
  size?: string;
  soldBy?: string;
  price?: { regular?: number; promo?: number; regularPerUnitEstimate?: number; promoPerUnitEstimate?: number };
  fulfillment?: { instore?: boolean; curbside?: boolean; delivery?: boolean; shiptohome?: boolean };
  inventory?: { stockLevel?: string };
}

export interface KrogerProduct {
  productId: string;
  upc?: string;
  brand?: string;
  description?: string;
  categories?: string[];
  images?: Array<{ perspective?: string; sizes?: Array<{ size?: string; url?: string }> }>;
  items?: KrogerItem[];
}

export interface KrogerResult<T> {
  data: T;
  cacheControl: string | null;
}

/** Kroger accepts at most 50 comma-separated productIds per call. */
export const KROGER_BATCH_LIMIT = 50;

export class KrogerClient {
  constructor(
    private readonly env: Env,
    // Wrapped so `this.fetchImpl(...)` never invokes the global fetch with a class instance as `this`
    // (workerd throws "Illegal invocation" for that; vitest's stub does not, which is why tests never saw it).
    private readonly fetchImpl: typeof fetch = (input, init) => fetch(input, init),
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

  async locations(zip: string): Promise<KrogerResult<KrogerLocation[]>> {
    const result = await this.getData<KrogerLocation[]>(
      `/locations?filter.zipCode.near=${encodeURIComponent(zip)}&filter.radiusInMiles=15&filter.limit=20`,
    );
    return { data: result.data ?? [], cacheControl: result.cacheControl };
  }

  async product(productId: string, locationId: string): Promise<KrogerResult<KrogerProduct | null>> {
    return this.getData<KrogerProduct>(
      `/products/${encodeURIComponent(productId)}?filter.locationId=${encodeURIComponent(locationId)}`,
    );
  }

  async products(productIds: string[], locationId: string): Promise<KrogerResult<KrogerProduct[]>> {
    // T4: filter.productId expects a literal comma-separated list. Encoding
    // the whole joined string turns every separator into %2C, which is
    // unconfirmed to decode correctly server-side — encode each id on its
    // own instead, and join with a literal comma.
    const ids = productIds
      .slice(0, KROGER_BATCH_LIMIT)
      .map((id) => encodeURIComponent(id))
      .join(",");
    const result = await this.getData<KrogerProduct[]>(
      `/products?filter.productId=${ids}&filter.locationId=${encodeURIComponent(locationId)}`,
    );
    return { data: result.data ?? [], cacheControl: result.cacheControl };
  }

  async search(term: string, locationId: string, limit = KROGER_BATCH_LIMIT): Promise<KrogerResult<KrogerProduct[]>> {
    const result = await this.getData<KrogerProduct[]>(
      `/products?filter.term=${encodeURIComponent(term)}&filter.locationId=${encodeURIComponent(locationId)}&filter.limit=${limit}`,
    );
    return { data: result.data ?? [], cacheControl: result.cacheControl };
  }

  /**
   * One authenticated GET. Never logs `path` — it carries barcodes and search
   * terms (spec §6.6).
   */
  private async getData<T>(path: string): Promise<{ data: T | null; cacheControl: string | null }> {
    const token = await this.token();
    const res = await this.fetchImpl(`${API_BASE}${path}`, {
      headers: { authorization: `Bearer ${token}`, accept: "application/json" },
    });
    if (res.status === 401) {
      // Revoked or rotated key: drop the cache so the next call re-authenticates.
      await this.env.KV.delete(TOKEN_KEY);
      throw new KrogerError(401);
    }
    if (!res.ok) throw new KrogerError(res.status);
    const body = (await res.json()) as { data?: T };
    return { data: body.data ?? null, cacheControl: res.headers.get("cache-control") };
  }
}

export { API_BASE, TOKEN_KEY };
