/**
 * Typed funnel events for Vercel Web Analytics.
 *
 * Page views are collected automatically by `<Analytics />` in app/layout.tsx,
 * which sits in the single root layout and therefore covers every route —
 * studio pages and the product mini-sites alike. This module is the other
 * half: the small set of custom events that turn those page views into a
 * funnel (land on a page -> click a CTA -> leave for the App Store).
 *
 * Two constraints shape the shape of everything below.
 *
 * 1. Vercel accepts only flat scalar properties on a custom event, so every
 *    payload is a flat object of string | number | boolean. Nested objects and
 *    arrays are rejected at collection time, silently, which is why the types
 *    here refuse them at compile time instead.
 * 2. No PII. Nothing a visitor typed, and nothing that identifies them, is
 *    allowed in a property: no email addresses, no calculator inputs, no free
 *    text. `href` values are stripped of their query string and hash before
 *    they are sent (see `withoutQuery`), which both honours that rule and
 *    keeps event cardinality low enough to be readable in the dashboard.
 *
 * Callers must be client components — `track` is a browser API.
 */
import { track as vercelTrack } from "@vercel/analytics";

/** The only property value types Vercel Web Analytics will store. */
type Scalar = string | number | boolean;

/**
 * One id per site under stackcurious.com. Spelling these out (rather than
 * accepting any string) is the point: a stray "depreScan" would quietly split
 * a funnel across two names and neither half would look wrong in isolation.
 * Mirrors the mini-site list in components/chrome.tsx, plus "studio" for the
 * stackcurious.com pages that keep the studio chrome.
 */
export type AppId =
  | "studio"
  | "autocal"
  | "babamanah"
  | "deprescan"
  | "glassmode"
  | "okphoto"
  | "pepeffect"
  | "prayerrequest"
  | "rateradar"
  | "shiftcheck"
  | "shrunk"
  | "smilestreak"
  | "waqt";

/**
 * Where on the page a CTA sits. Kept to a closed set so "which placement earns
 * the click" is answerable by grouping on a single property.
 *
 * "sticky" is the mobile bar pinned to the bottom of the viewport, which
 * ShiftCheck, Shrunk and AutoCal all use. It is deliberately not folded into
 * "footer": the two perform very differently, and merging them would hide the
 * one number those bars exist to move.
 */
export type CtaLocation =
  | "header"
  | "hero"
  | "pricing"
  | "final"
  | "footer"
  | "sticky";

/** Event name -> the exact properties that event carries. */
export type EventMap = {
  /** An in-app call to action was clicked. */
  cta_click: { app: AppId; page: string; location: CtaLocation };
  /** A link leaving stackcurious.com was clicked (App Store, Apple support). */
  outbound_click: { app: AppId; page: string; href: string };
  /** A visitor began interacting with a calculator or generator. */
  tool_start: { app: AppId; tool: string };
  /**
   * A tool produced a result. `result` is a bucket label or a small derived
   * count — a PHQ-9 severity band, a step count — never a raw answer, and
   * never anything the visitor typed.
   */
  tool_complete: { app: AppId; tool: string; result?: string | number };
  /** A guide article was read past the point of a bounce. */
  guide_read: { app: AppId; slug: string };
};

export type AnalyticsEvent = keyof EventMap;

/**
 * Drop the query string and fragment from a URL. A mailto: href carries its
 * subject line in the query, and App Store links pick up campaign parameters —
 * neither belongs in an analytics property, and both would explode the number
 * of distinct `href` values the dashboard has to group.
 */
function withoutQuery(href: string): string {
  const cut = href.search(/[?#]/);
  return cut === -1 ? href : href.slice(0, cut);
}

/**
 * Send one funnel event. The overload on `EventMap` means the property object
 * is checked against the event name: `track("cta_click", { app, page })` is a
 * compile error for the missing `location`, and an unknown property is too.
 */
export function track<E extends AnalyticsEvent>(event: E, props: EventMap[E]): void {
  const payload: Record<string, Scalar> = {};
  for (const [key, value] of Object.entries(props)) {
    // Optional properties (`result`) arrive as undefined when unset; Vercel
    // has no representation for that, so the key is simply omitted.
    if (value === undefined) continue;
    payload[key] = key === "href" ? withoutQuery(String(value)) : (value as Scalar);
  }
  vercelTrack(event, payload);
}
