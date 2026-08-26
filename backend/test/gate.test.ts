import { describe, expect, it } from "vitest";
import { scoreSubmission } from "../src/gate";

const base = {
  quantity: 793.786,
  unitKind: "mass",
  ocrConfidence: 0,
  productUnitKind: null as string | null,
  latestAcceptedQuantity: null as number | null,
};

describe("scoreSubmission components", () => {
  it("gives 0.5 for a parsed quantity alone and holds it pending", () => {
    const result = scoreSubmission(base);
    expect(result.components).toEqual({ parsed: 0.5, kindMatch: 0, range: 0, ocr: 0 });
    expect(result.confidence).toBe(0.5);
    expect(result.status).toBe("pending");
  });

  it("gives 0 for parsed when the quantity is not a positive number", () => {
    expect(scoreSubmission({ ...base, quantity: 0 }).components.parsed).toBe(0);
    expect(scoreSubmission({ ...base, quantity: -5 }).components.parsed).toBe(0);
    expect(scoreSubmission({ ...base, quantity: Number.NaN }).components.parsed).toBe(0);
  });

  it("gives 0 for parsed when the unit kind is not one of mass/volume/count", () => {
    expect(scoreSubmission({ ...base, unitKind: "grams" }).components.parsed).toBe(0);
    expect(scoreSubmission({ ...base, unitKind: "" }).components.parsed).toBe(0);
  });

  it("adds 0.2 only when the kind matches the product's dominant kind", () => {
    expect(scoreSubmission({ ...base, productUnitKind: "mass" }).components.kindMatch).toBe(0.2);
    expect(scoreSubmission({ ...base, productUnitKind: "volume" }).components.kindMatch).toBe(0);
    expect(scoreSubmission({ ...base, productUnitKind: null }).components.kindMatch).toBe(0);
  });

  it("adds 0.2 only inside 0.5x-1.5x of the latest accepted observation", () => {
    const at = (quantity: number) => scoreSubmission({ ...base, quantity, latestAcceptedQuantity: 1000 }).components.range;
    expect(at(500)).toBe(0.2);    // exactly 0.5x
    expect(at(1500)).toBe(0.2);   // exactly 1.5x
    expect(at(1000)).toBe(0.2);
    expect(at(499)).toBe(0);
    expect(at(1501)).toBe(0);
    expect(scoreSubmission({ ...base, latestAcceptedQuantity: null }).components.range).toBe(0);
    expect(scoreSubmission({ ...base, latestAcceptedQuantity: 0 }).components.range).toBe(0);
  });

  it("adds 0.1 only when OCR confidence reaches 0.9", () => {
    expect(scoreSubmission({ ...base, ocrConfidence: 0.9 }).components.ocr).toBe(0.1);
    expect(scoreSubmission({ ...base, ocrConfidence: 1 }).components.ocr).toBe(0.1);
    expect(scoreSubmission({ ...base, ocrConfidence: 0.89 }).components.ocr).toBe(0);
  });
});

describe("scoreSubmission threshold", () => {
  it("accepts at exactly 0.8 despite floating-point addition", () => {
    // 0.5 + 0.2 + 0.1 is 0.7999999999999999 in IEEE-754. It must still accept.
    const result = scoreSubmission({ ...base, productUnitKind: "mass", ocrConfidence: 0.95 });
    expect(result.confidence).toBe(0.8);
    expect(result.status).toBe("accepted");
  });

  it("accepts at 0.8 from parsed + range + ocr when the product has no dominant kind", () => {
    const result = scoreSubmission({ ...base, latestAcceptedQuantity: 907.184, ocrConfidence: 0.95 });
    expect(result.confidence).toBe(0.8);
    expect(result.status).toBe("accepted");
  });

  it("holds 0.7 pending", () => {
    const result = scoreSubmission({ ...base, productUnitKind: "mass" });
    expect(result.confidence).toBe(0.7);
    expect(result.status).toBe("pending");
  });

  it("scores a perfect submission 1.0", () => {
    const result = scoreSubmission({
      ...base, productUnitKind: "mass", latestAcceptedQuantity: 907.184, ocrConfidence: 0.97,
    });
    expect(result.confidence).toBe(1);
    expect(result.status).toBe("accepted");
  });
});
