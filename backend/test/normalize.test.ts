import fixtures from "../../fixtures/package_weights.json";
import { describe, expect, it } from "vitest";
import { parsePackageWeight } from "../src/normalize";

describe("parsePackageWeight", () => {
  for (const c of fixtures) {
    it(c.note, () => {
      const result = parsePackageWeight(c.input);
      if (c.quantity === null) {
        expect(result).toBeNull();
      } else {
        expect(result).not.toBeNull();
        expect(result!.unitKind).toBe(c.unit_kind);
        expect(result!.quantity).toBeCloseTo(c.quantity, 1);
        expect(result!.raw).toBe(c.input);
      }
    });
  }
});
