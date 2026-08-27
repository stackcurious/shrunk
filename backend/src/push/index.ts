import type { Env } from "../env";
import { APNsSender } from "./apns";
import { FCMSender } from "./fcm";
import type { PushSender } from "./PushSender";

export type { PushPayload, PushResult, PushSender } from "./PushSender";

/** Spec §6.5 — APNs by default; FCM is the fallback if HTTP/2 to Apple ever fails. */
export function pushSender(env: Env): PushSender {
  return env.PUSH_PROVIDER === "fcm" ? new FCMSender(env) : new APNsSender(env);
}
