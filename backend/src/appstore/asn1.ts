/**
 * The smallest DER reader that can walk an X.509 certificate. Only the
 * constructs Apple's certificate chain uses are supported; anything else
 * throws, and the caller turns a throw into "not verified".
 */
export interface TLV {
  tag: number;
  offset: number;        // index of the tag byte
  headerLength: number;  // tag + length bytes
  length: number;        // content length
  start: number;         // index of the first content byte
  end: number;           // one past the last content byte
  next: number;          // one past the whole element
}

export function readTLV(bytes: Uint8Array, offset: number): TLV {
  if (offset + 2 > bytes.length) throw new Error("asn1: truncated header");
  const tag = bytes[offset];
  let length = bytes[offset + 1];
  let headerLength = 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count === 0 || count > 4) throw new Error("asn1: unsupported length form");
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + bytes[offset + 2 + i];
    headerLength = 2 + count;
  }
  const start = offset + headerLength;
  const end = start + length;
  if (end > bytes.length) throw new Error("asn1: truncated content");
  return { tag, offset, headerLength, length, start, end, next: end };
}

export function children(bytes: Uint8Array, seq: TLV): TLV[] {
  const out: TLV[] = [];
  let offset = seq.start;
  while (offset < seq.end) {
    const tlv = readTLV(bytes, offset);
    out.push(tlv);
    offset = tlv.next;
  }
  return out;
}

/** The element including its tag and length bytes — what signatures cover. */
export function span(bytes: Uint8Array, tlv: TLV): Uint8Array {
  return bytes.subarray(tlv.offset, tlv.next);
}

export function oidToString(bytes: Uint8Array, tlv: TLV): string {
  const content = bytes.subarray(tlv.start, tlv.end);
  if (content.length === 0) throw new Error("asn1: empty oid");
  const parts: number[] = [Math.floor(content[0] / 40), content[0] % 40];
  let value = 0;
  for (let i = 1; i < content.length; i++) {
    value = value * 128 + (content[i] & 0x7f);
    if (!(content[i] & 0x80)) {
      parts.push(value);
      value = 0;
    }
  }
  return parts.join(".");
}

function isoDate(year: number, rest: string): Date {
  const mm = rest.slice(0, 2);
  const dd = rest.slice(2, 4);
  const hh = rest.slice(4, 6);
  const mi = rest.slice(6, 8);
  const ss = rest.slice(8, 10) || "00";
  const parsed = new Date(`${String(year).padStart(4, "0")}-${mm}-${dd}T${hh}:${mi}:${ss}Z`);
  if (Number.isNaN(parsed.getTime())) throw new Error("asn1: bad time");
  return parsed;
}

/** UTCTime (0x17, YYMMDDhhmmssZ) and GeneralizedTime (0x18, YYYYMMDDhhmmssZ). */
export function parseTime(bytes: Uint8Array, tlv: TLV): Date {
  const text = new TextDecoder().decode(bytes.subarray(tlv.start, tlv.end));
  if (tlv.tag === 0x17) {
    const yy = Number(text.slice(0, 2));
    // RFC 5280: 00-49 => 20xx, 50-99 => 19xx.
    return isoDate(yy >= 50 ? 1900 + yy : 2000 + yy, text.slice(2));
  }
  if (tlv.tag === 0x18) return isoDate(Number(text.slice(0, 4)), text.slice(4));
  throw new Error("asn1: unsupported time tag");
}
