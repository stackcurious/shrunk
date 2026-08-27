import { parsePackageWeight } from "../normalize";
import type { KrogerItem, KrogerProduct } from "./client";
import { gtinFromKroger } from "./ids";

/** The shape both /v1/kroger/product and /v1/kroger/search return. */
export interface LiveProduct {
  gtin: string | null;
  product_id: string;
  brand: string;
  description: string;
  category: string;
  image_url: string | null;
  size: string | null;
  quantity: number | null; // grams | millilitres | count
  unit_kind: string | null; // mass | volume | count
  regular: number | null;
  promo: number | null;
  per_unit_estimate: number | null; // Kroger's own estimate, in Kroger's unit — display only
  price_per_base_unit: number | null; // ours: effective price / quantity — ranking uses this
  stock_level: string | null;
}

export function frontImage(product: KrogerProduct): string | null {
  const front = product.images?.find((i) => i.perspective === "front") ?? product.images?.[0];
  const sizes = front?.sizes ?? [];
  const chosen = sizes.find((s) => s.size === "large") ?? sizes.find((s) => s.size === "medium") ?? sizes[0];
  return chosen?.url ?? null;
}

/** Promo when there is one, otherwise the regular shelf price. */
export function effectivePrice(item: KrogerItem | undefined): number | null {
  const promo = item?.price?.promo ?? 0;
  if (promo > 0) return promo;
  const regular = item?.price?.regular ?? 0;
  return regular > 0 ? regular : null;
}

function perUnitEstimate(item: KrogerItem | undefined): number | null {
  const promo = item?.price?.promoPerUnitEstimate ?? 0;
  if (promo > 0) return promo;
  const regular = item?.price?.regularPerUnitEstimate ?? 0;
  return regular > 0 ? regular : null;
}

export function toLiveProduct(product: KrogerProduct): LiveProduct {
  const item = product.items?.[0];
  const parsed = item?.size ? parsePackageWeight(item.size) : null;
  const price = effectivePrice(item);

  return {
    gtin: gtinFromKroger(product.upc ?? product.productId),
    product_id: product.productId,
    brand: (product.brand ?? "").trim(),
    description: (product.description ?? "").trim(),
    category: (product.categories?.[0] ?? "").trim(),
    image_url: frontImage(product),
    size: item?.size ?? null,
    quantity: parsed?.quantity ?? null,
    unit_kind: parsed?.unitKind ?? null,
    regular: item?.price?.regular ?? null,
    promo: item?.price?.promo ?? null,
    per_unit_estimate: perUnitEstimate(item),
    price_per_base_unit: price !== null && parsed && parsed.quantity > 0 ? price / parsed.quantity : null,
    stock_level: item?.inventory?.stockLevel ?? null,
  };
}
