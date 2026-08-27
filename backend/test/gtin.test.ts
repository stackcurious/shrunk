import { describe, expect, it } from "vitest";
import { normalizeGTIN } from "../src/gtin";

describe("normalizeGTIN", () => {
  it.each([
    ["028400642255", "0028400642255"],
    ["0028400642255", "0028400642255"],
    ["00027000612323", "0027000612323"],
    [" 028400642255 ", "0028400642255"],
    ["028-400-642255", "0028400642255"],
    ["10027000612323", null],
    ["12345678", null],
    ["", null],
    ["abc", null],
  ])("%s -> %s", (raw, expected) => {
    expect(normalizeGTIN(raw)).toBe(expected);
  });
});
