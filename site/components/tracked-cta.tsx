"use client";

import { usePathname } from "next/navigation";
import { track, type AppId, type CtaLocation } from "@/lib/analytics";

/**
 * An anchor that reports itself to the funnel.
 *
 * Each mini-site keeps its own CTA component — they differ in markup, badge
 * art and styling — but they all want the same two events, the same pathname
 * tagging and the same `target="_blank"` handling on an outbound href. Rather
 * than repeat that in a dozen places (and get one of them subtly wrong), each
 * mini-site's CTA renders this and passes its own `className`/`style`.
 *
 * An http(s) href counts as leaving the site, so it fires `outbound_click` in
 * addition to `cta_click` and opens in a new tab. A relative href is in-app
 * navigation: `cta_click` only, same tab.
 *
 * DepreScan is the exception — it has its own DownloadLink because its CTA
 * flips between an App Store link and a mailto depending on launch state.
 */
export function TrackedCta({
  app,
  location,
  href,
  className,
  style,
  ariaLabel,
  children,
}: {
  app: AppId;
  location: CtaLocation;
  href: string;
  className?: string;
  style?: React.CSSProperties;
  ariaLabel?: string;
  children: React.ReactNode;
}) {
  const page = usePathname();
  const outbound = /^https?:\/\//i.test(href);

  return (
    <a
      href={href}
      className={className}
      style={style}
      aria-label={ariaLabel}
      onClick={() => {
        track("cta_click", { app, page, location });
        if (outbound) track("outbound_click", { app, page, href });
      }}
      {...(outbound ? { target: "_blank", rel: "noopener noreferrer" } : {})}
    >
      {children}
    </a>
  );
}
