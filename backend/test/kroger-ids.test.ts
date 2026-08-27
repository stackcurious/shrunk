import { describe, expect, it } from "vitest";
import { gtinFromKroger, krogerProductId, upcCheckDigit } from "../src/kroger/ids";

const PAIRS: Array<[string, string]> = [
  ["0028400642255", "0002840064225"], // Gatorade
  ["0037000138372", "0003700013837"], // P&G
  ["0011110417008", "0001111041700"], // Kroger private label
];

describe("krogerProductId", () => {
  it.each(PAIRS)("%s -> %s", (gtin, productId) => {
    expect(krogerProductId(gtin)).toBe(productId);
  });

  it("normalizes a 12-digit UPC-A first", () => {
    expect(krogerProductId("028400642255")).toBe("0002840064225");
  });

  it("returns null for an unusable barcode", () => {
    expect(krogerProductId("12345")).toBeNull();
    expect(krogerProductId("")).toBeNull();
  });

  it("returns null for a non-UPC EAN-13", () => {
    expect(krogerProductId("4006381333931")).toBeNull();
  });
});

describe("gtinFromKroger", () => {
  it.each(PAIRS)("%s <- %s", (gtin, productId) => {
    expect(gtinFromKroger(productId)).toBe(gtin);
  });

  it("round-trips both directions", () => {
    for (const [gtin, productId] of PAIRS) {
      expect(gtinFromKroger(krogerProductId(gtin)!)).toBe(gtin);
      expect(krogerProductId(gtinFromKroger(productId)!)).toBe(productId);
    }
  });

  it("returns null for junk", () => {
    expect(gtinFromKroger("")).toBeNull();
    expect(gtinFromKroger("00028400642255555")).toBeNull();
  });
});

describe("upcCheckDigit", () => {
  it("computes the UPC-A check digit over 11 data digits", () => {
    expect(upcCheckDigit("02840064225")).toBe("5");
    expect(upcCheckDigit("03700013837")).toBe("2");
    expect(upcCheckDigit("01111041700")).toBe("8");
  });
});
