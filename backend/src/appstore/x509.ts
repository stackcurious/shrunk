import { children, oidToString, parseTime, readTLV, span } from "./asn1";

const OID_ECDSA_SHA256 = "1.2.840.10045.4.3.2";
const OID_ECDSA_SHA384 = "1.2.840.10045.4.3.3";
const OID_P256 = "1.2.840.10045.3.1.7";
const OID_P384 = "1.3.132.0.34";

export interface Certificate {
  der: Uint8Array;
  tbs: Uint8Array;          // tbsCertificate including its header — the signed bytes
  issuer: Uint8Array;       // raw issuer Name, compared byte-for-byte against a parent's subject
  subject: Uint8Array;
  spki: Uint8Array;         // SubjectPublicKeyInfo, importable straight into WebCrypto
  notBefore: Date;
  notAfter: Date;
  curve: "P-256" | "P-384"; // this certificate's own key
  sigHash: "SHA-256" | "SHA-384"; // hash used by whoever signed this certificate
  signatureDer: Uint8Array; // DER SEQUENCE { INTEGER r, INTEGER s }
}

/**
 * Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
 * TBSCertificate ::= SEQUENCE { [0] version, serialNumber, signature, issuer,
 *                               validity, subject, subjectPublicKeyInfo, ... }
 */
export function parseCertificate(der: Uint8Array): Certificate {
  const cert = readTLV(der, 0);
  const top = children(der, cert);
  if (top.length < 3) throw new Error("x509: malformed certificate");
  const [tbsTLV, sigAlgTLV, sigTLV] = top;

  const sigAlgOID = oidToString(der, children(der, sigAlgTLV)[0]);
  const sigHash =
    sigAlgOID === OID_ECDSA_SHA384 ? "SHA-384" :
    sigAlgOID === OID_ECDSA_SHA256 ? "SHA-256" : null;
  if (!sigHash) throw new Error(`x509: unsupported signature algorithm ${sigAlgOID}`);

  // signatureValue is a BIT STRING whose first content byte is the unused-bit count.
  const signatureDer = der.subarray(sigTLV.start + 1, sigTLV.end);

  const tbs = children(der, tbsTLV);
  let i = tbs[0].tag === 0xa0 ? 1 : 0; // skip [0] EXPLICIT version when present
  i++;                                  // serialNumber
  i++;                                  // inner AlgorithmIdentifier
  const issuer = span(der, tbs[i++]);
  const validityTLV = tbs[i++];
  const subject = span(der, tbs[i++]);
  const spkiTLV = tbs[i++];
  if (!spkiTLV) throw new Error("x509: missing subjectPublicKeyInfo");

  const [notBeforeTLV, notAfterTLV] = children(der, validityTLV);

  // SubjectPublicKeyInfo ::= SEQUENCE { AlgorithmIdentifier { OID ecPublicKey,
  //                                     OID namedCurve }, BIT STRING }
  const curveOID = oidToString(der, children(der, children(der, spkiTLV)[0])[1]);
  const curve =
    curveOID === OID_P384 ? "P-384" :
    curveOID === OID_P256 ? "P-256" : null;
  if (!curve) throw new Error(`x509: unsupported curve ${curveOID}`);

  return {
    der,
    tbs: span(der, tbsTLV),
    issuer,
    subject,
    spki: span(der, spkiTLV),
    notBefore: parseTime(der, notBeforeTLV),
    notAfter: parseTime(der, notAfterTLV),
    curve,
    sigHash,
    signatureDer,
  };
}

function leftPad(value: Uint8Array, size: number): Uint8Array {
  let start = 0;
  while (start < value.length - 1 && value[start] === 0) start++;
  const trimmed = value.subarray(start);
  if (trimmed.length > size) throw new Error("x509: ecdsa integer too large");
  const padded = new Uint8Array(size);
  padded.set(trimmed, size - trimmed.length);
  return padded;
}

/**
 * X.509 stores ECDSA signatures as DER SEQUENCE { r, s }; WebCrypto wants the
 * fixed-width r||s concatenation. `size` is the field size of the *signing*
 * key's curve: 32 for P-256, 48 for P-384.
 */
export function ecdsaDerToRaw(sig: Uint8Array, size: number): Uint8Array {
  const seq = readTLV(sig, 0);
  const [r, s] = children(sig, seq);
  const out = new Uint8Array(size * 2);
  out.set(leftPad(sig.subarray(r.start, r.end), size), 0);
  out.set(leftPad(sig.subarray(s.start, s.end), size), size);
  return out;
}

export function importPublicKey(cert: Certificate): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "spki",
    new Uint8Array(cert.spki),
    { name: "ECDSA", namedCurve: cert.curve },
    false,
    ["verify"],
  );
}
