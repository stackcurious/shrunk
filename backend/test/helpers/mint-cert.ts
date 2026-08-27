import { bytesToBase64 } from "../../src/appstore/root";

// AlgorithmIdentifier for ecdsa-with-SHA256: SEQUENCE { OID 1.2.840.10045.4.3.2 }
const ALG_ID_ECDSA_SHA256 = new Uint8Array([0x30, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]);
// OID 2.5.4.3 (id-at-commonName), already TLV-encoded
const OID_COMMON_NAME = new Uint8Array([0x06, 0x03, 0x55, 0x04, 0x03]);

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function encodeLength(length: number): Uint8Array {
  if (length < 0x80) return new Uint8Array([length]);
  const bytes: number[] = [];
  let n = length;
  while (n > 0) {
    bytes.unshift(n & 0xff);
    n >>= 8;
  }
  return new Uint8Array([0x80 | bytes.length, ...bytes]);
}

function tlv(tag: number, content: Uint8Array): Uint8Array {
  return concat(new Uint8Array([tag]), encodeLength(content.length), content);
}

function integer(value: number): Uint8Array {
  const bytes: number[] = [];
  let n = value;
  do {
    bytes.unshift(n & 0xff);
    n = Math.floor(n / 256);
  } while (n > 0);
  if (bytes[0] & 0x80) bytes.unshift(0); // keep it positive
  return tlv(0x02, new Uint8Array(bytes));
}

function utcTime(date: Date): Uint8Array {
  const p = (n: number) => String(n).padStart(2, "0");
  const text =
    `${p(date.getUTCFullYear() % 100)}${p(date.getUTCMonth() + 1)}${p(date.getUTCDate())}` +
    `${p(date.getUTCHours())}${p(date.getUTCMinutes())}${p(date.getUTCSeconds())}Z`;
  return tlv(0x17, new TextEncoder().encode(text));
}

/** Name ::= SEQUENCE { SET { SEQUENCE { OID commonName, UTF8String cn } } } */
function nameDER(cn: string): Uint8Array {
  const attribute = tlv(0x30, concat(OID_COMMON_NAME, tlv(0x0c, new TextEncoder().encode(cn))));
  return tlv(0x30, tlv(0x31, attribute));
}

/** WebCrypto emits r||s; X.509 wants DER SEQUENCE { INTEGER r, INTEGER s }. */
function rawToDerEcdsa(raw: Uint8Array): Uint8Array {
  const half = raw.length / 2;
  const asInteger = (value: Uint8Array) => {
    let start = 0;
    while (start < value.length - 1 && value[start] === 0) start++;
    const trimmed = value.subarray(start);
    return tlv(0x02, trimmed[0] & 0x80 ? concat(new Uint8Array([0]), trimmed) : trimmed);
  };
  return tlv(0x30, concat(asInteger(raw.subarray(0, half)), asInteger(raw.subarray(half))));
}

interface MintOptions {
  subjectCN: string;
  issuerCN: string;
  subjectPublicKey: CryptoKey;
  issuerPrivateKey: CryptoKey;
  notBefore: Date;
  notAfter: Date;
  serial: number;
}

async function mintCert(options: MintOptions): Promise<Uint8Array> {
  const spki = new Uint8Array((await crypto.subtle.exportKey("spki", options.subjectPublicKey)) as ArrayBuffer);
  const tbs = tlv(
    0x30,
    concat(
      tlv(0xa0, integer(2)), // [0] EXPLICIT version, v3
      integer(options.serial),
      ALG_ID_ECDSA_SHA256,
      nameDER(options.issuerCN),
      tlv(0x30, concat(utcTime(options.notBefore), utcTime(options.notAfter))),
      nameDER(options.subjectCN),
      spki,
    ),
  );
  const rawSignature = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, options.issuerPrivateKey, tbs),
  );
  const signatureBits = tlv(0x03, concat(new Uint8Array([0x00]), rawToDerEcdsa(rawSignature)));
  return tlv(0x30, concat(tbs, ALG_ID_ECDSA_SHA256, signatureBits));
}

export interface TestChain {
  rootDer: Uint8Array;
  leafPrivateKey: CryptoKey;
  /** [leaf, intermediate, root], base64 DER — the shape Apple puts in the JWS header. */
  x5c: string[];
}

export async function newTestChain(opts: { notBefore?: Date; notAfter?: Date } = {}): Promise<TestChain> {
  const notBefore = opts.notBefore ?? new Date("2020-01-01T00:00:00Z");
  const notAfter = opts.notAfter ?? new Date("2035-01-01T00:00:00Z");
  const generate = () =>
    crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as Promise<CryptoKeyPair>;

  const root = await generate();
  const intermediate = await generate();
  const leaf = await generate();

  const rootDer = await mintCert({
    subjectCN: "Shrunk Test Root", issuerCN: "Shrunk Test Root",
    subjectPublicKey: root.publicKey, issuerPrivateKey: root.privateKey,
    notBefore, notAfter, serial: 1,
  });
  const intermediateDer = await mintCert({
    subjectCN: "Shrunk Test Intermediate", issuerCN: "Shrunk Test Root",
    subjectPublicKey: intermediate.publicKey, issuerPrivateKey: root.privateKey,
    notBefore, notAfter, serial: 2,
  });
  const leafDer = await mintCert({
    subjectCN: "Shrunk Test Leaf", issuerCN: "Shrunk Test Intermediate",
    subjectPublicKey: leaf.publicKey, issuerPrivateKey: intermediate.privateKey,
    notBefore, notAfter, serial: 3,
  });

  return {
    rootDer,
    leafPrivateKey: leaf.privateKey,
    x5c: [bytesToBase64(leafDer), bytesToBase64(intermediateDer), bytesToBase64(rootDer)],
  };
}

export function base64UrlEncode(bytes: Uint8Array): string {
  return bytesToBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function signTestJWS(chain: TestChain, payload: unknown): Promise<string> {
  const header = base64UrlEncode(new TextEncoder().encode(JSON.stringify({ alg: "ES256", x5c: chain.x5c })));
  const body = base64UrlEncode(new TextEncoder().encode(JSON.stringify(payload)));
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      chain.leafPrivateKey,
      new TextEncoder().encode(`${header}.${body}`),
    ),
  );
  return `${header}.${body}.${base64UrlEncode(signature)}`;
}
