/** One push. `kind` is the iOS camelCase alert kind the app maps straight onto `ShrinkAlert.Kind`. */
export interface PushPayload {
  title: string;
  body: string;
  gtin?: string;
  kind: string;
  collapseId?: string;
  /** Bare product label, so the client never parses it out of `title`. */
  productName?: string;
}

export interface PushResult {
  ok: boolean;
  status: number;
  /** The device token is dead — the caller clears `devices.apns_token`. */
  invalidToken: boolean;
}

export interface PushSender {
  send(token: string, payload: PushPayload): Promise<PushResult>;
}

/** Bundle id, and therefore the APNs topic (spec §6.5). */
export const APNS_TOPIC = "com.shrunk.app";

/** PEM (PKCS#8) -> DER bytes, for `crypto.subtle.importKey`. */
export function pemToDer(pem: string): ArrayBuffer {
  const base64 = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

export function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64urlText(text: string): string {
  return base64url(new TextEncoder().encode(text));
}
