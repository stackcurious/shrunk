import { describe, expect, it } from "vitest";
import { readTLV } from "../src/appstore/asn1";
import { APPLE_ROOT_CA_G3_DER, bytesEqual } from "../src/appstore/root";
import { ecdsaDerToRaw, importPublicKey, parseCertificate } from "../src/appstore/x509";

describe("Apple Root CA - G3 constant", () => {
  it("parses as a self-signed P-384 certificate valid until 2039", () => {
    const cert = parseCertificate(APPLE_ROOT_CA_G3_DER);
    expect(cert.curve).toBe("P-384");
    expect(cert.sigHash).toBe("SHA-384");
    expect(cert.notBefore.toISOString()).toBe("2014-04-30T18:19:06.000Z");
    expect(cert.notAfter.toISOString()).toBe("2039-04-30T18:19:06.000Z");
    expect(bytesEqual(cert.issuer, cert.subject)).toBe(true);
  });

  it("carries the expected subject common name", () => {
    const cert = parseCertificate(APPLE_ROOT_CA_G3_DER);
    expect(new TextDecoder().decode(cert.subject)).toContain("Apple Root CA - G3");
  });

  it("verifies its own signature", async () => {
    const cert = parseCertificate(APPLE_ROOT_CA_G3_DER);
    const key = await importPublicKey(cert);
    const ok = await crypto.subtle.verify(
      { name: "ECDSA", hash: cert.sigHash },
      key,
      ecdsaDerToRaw(cert.signatureDer, 48),
      new Uint8Array(cert.tbs),
    );
    expect(ok).toBe(true);
  });
});

describe("readTLV truncated/malformed long-form lengths", () => {
  it("throws on a header truncated inside the long-form length octets", () => {
    expect(() => readTLV(new Uint8Array([0x30, 0x82, 0x01]), 0)).toThrow();
  });

  it("throws when the declared length exceeds the buffer", () => {
    expect(() => readTLV(new Uint8Array([0x30, 0x82, 0x00, 0x05, 0x01]), 0)).toThrow();
  });

  it("throws on indefinite length (0x80)", () => {
    expect(() => readTLV(new Uint8Array([0x30, 0x80]), 0)).toThrow();
  });
});
