import type { Metadata } from "next";
import Link from "next/link";
import { PRICE_MONTHLY, PRICE_YEARLY, SHRUNK_URL, SUPPORT_EMAIL, TRIAL_DAYS } from "../_lib/constants";

export const metadata: Metadata = {
  title: "Terms of Service",
  description:
    "Terms of Service for the Shrunk iOS app, including the Shrunk Pro auto-renewable subscription terms.",
  alternates: { canonical: `${SHRUNK_URL}/terms` },
};

export default function ShrunkTerms() {
  return (
    <article className="animate-fade-up mx-auto max-w-2xl px-6 py-16 md:py-24">
      <Breadcrumb />

      <header className="mt-8 mb-12">
        <h1 className="text-3xl font-bold tracking-tight text-foreground md:text-4xl">
          Terms of Service
        </h1>
        <p className="mt-3 text-sm text-muted">Last updated: August 26, 2026</p>
      </header>

      <div className="space-y-8 text-[15px] leading-relaxed text-muted">
        <Section number="1" title="What Shrunk is">
          <p>
            Shrunk is an iOS app that scans a grocery barcode and shows you how a
            product&apos;s package size and price-per-unit have changed, using public data,
            live retailer prices, and observations contributed by shoppers. Using the app means
            you accept these terms.
          </p>
        </Section>

        <Section number="2" title="No accounts">
          <p>
            There is no sign-up and no login. Your watchlist and preferences are tied to a
            random id generated on your device. If you delete the app, that link is gone; we
            cannot restore your data afterwards.
          </p>
        </Section>

        <Section number="3" title="Shrunk Pro">
          <p>Shrunk Pro is an auto-renewable subscription sold through Apple:</p>
          <ul className="my-3 list-disc space-y-1 pl-5 marker:text-rose-400">
            <li>
              <strong className="text-foreground">Shrunk Pro Yearly</strong> — ${PRICE_YEARLY}{" "}
              per year, with a {TRIAL_DAYS}-day free trial for new subscribers.
            </li>
            <li>
              <strong className="text-foreground">Shrunk Pro Monthly</strong> — ${PRICE_MONTHLY}{" "}
              per month.
            </li>
          </ul>
          <p>
            Pro unlocks watchlist alerts, the weekly &ldquo;what shrank this week&rdquo; digest,
            unlimited ranked alternatives at your store, full price and size history charts, and
            the savings dashboard. Scanning, verdicts, size history, current price, the browse
            feed, contributing label photos, and three alternatives per scan are free and always
            will be.
          </p>
          <p className="mt-3">
            Payment is charged to your Apple Account at confirmation of purchase.{" "}
            <strong className="text-foreground">The subscription renews automatically</strong>{" "}
            unless it is cancelled at least 24 hours before the end of the current period; your
            account is charged for renewal within 24 hours before the period ends. Any unused
            portion of a free trial is forfeited when you buy a subscription. Manage or cancel
            your subscription in iOS Settings → your name → Subscriptions. Prices are in U.S.
            dollars and may change with notice; refunds are handled by Apple under Apple&apos;s
            Media Services terms, not by us.
          </p>
        </Section>

        <Section number="4" title="What you contribute">
          <p>
            When you send a label photo or a net-weight reading, you confirm you took the photo
            yourself and you grant us a non-exclusive, worldwide, royalty-free licence to use it
            to verify and publish product size data in Shrunk. Photos awaiting review are
            deleted once reviewed (see the{" "}
            <Link href="/privacy" className="text-rose-400 hover:text-rose-300">
              Privacy Policy
            </Link>
            ); the resulting size figure becomes part of the product&apos;s public history. Do
            not submit photos of people, of anything other than a product label, or of anything
            you do not have the right to share. We may reject or remove any submission.
          </p>
        </Section>

        <Section number="5" title="Accuracy">
          <p>
            Shrunk reports what the available data says. Package sizes come from the USDA&apos;s
            FoodData Central dataset, from retailer APIs, from curated cases with published
            evidence, and from shoppers. Data can be stale, mis-keyed at the source, or simply
            missing, and prices change constantly and vary by store.{" "}
            <strong className="text-foreground">
              Verdicts, prices and savings figures are informational estimates, not a guarantee,
              and not financial advice.
            </strong>{" "}
            Check the package before you buy.
          </p>
        </Section>

        <Section number="6" title="Independence">
          <p>
            Shrunk is independent. No brand, manufacturer or retailer pays for placement, and
            there is no advertising in the app. Shrunk is not affiliated with, endorsed by, or
            sponsored by The Kroger Co., the U.S. Department of Agriculture, Open Food Facts, or
            any brand whose products appear. Product and brand names are trademarks of their
            owners and are used only to identify products. Data attributions are listed in the
            app under Settings → Data sources and in the{" "}
            <Link href="/privacy" className="text-rose-400 hover:text-rose-300">
              Privacy Policy
            </Link>
            .
          </p>
        </Section>

        <Section number="7" title="Acceptable use">
          <p>
            Do not scrape, resell or redistribute the app&apos;s data feeds; do not attempt to
            break, overload or reverse-engineer the service; do not submit false observations
            deliberately. We may rate-limit or block a device that does.
          </p>
        </Section>

        <Section number="8" title="Availability">
          <p>
            Shrunk is provided &ldquo;as is&rdquo;. We do not promise the service will be
            uninterrupted, and features that depend on third parties — retailer prices in
            particular — may change or disappear if those third parties change their terms. To
            the fullest extent the law allows, we are not liable for indirect or consequential
            losses, and our total liability is limited to what you paid us in the twelve months
            before the claim.
          </p>
        </Section>

        <Section number="9" title="Changes">
          <p>
            We may update these terms; the date above changes when we do, and material changes
            are noted in the app&apos;s release notes. Continuing to use Shrunk after an update
            means you accept it.
          </p>
        </Section>

        <Section number="10" title="Governing law">
          <p>
            These terms are governed by the laws of the State of Florida, United States, without
            regard to conflict-of-law rules.
          </p>
        </Section>

        <Section number="11" title="Contact">
          <p>
            <a
              href={`mailto:${SUPPORT_EMAIL}`}
              className="text-rose-400 transition-colors hover:text-rose-300"
            >
              {SUPPORT_EMAIL}
            </a>
          </p>
        </Section>
      </div>

      <FooterAttribution />
    </article>
  );
}

function Section({ number, title, children }: { number: string; title: string; children: React.ReactNode }) {
  return (
    <section>
      <h2 className="mb-4 flex items-baseline gap-3 text-lg font-semibold text-foreground">
        <span className="font-mono text-xs text-rose-400">{number}.</span>
        <span className="border-b-2 border-rose-400/40 pb-1">{title}</span>
      </h2>
      <div>{children}</div>
    </section>
  );
}

function Breadcrumb() {
  return (
    <Link
      href="/"
      className="inline-flex items-center gap-1.5 text-xs font-medium text-muted transition-colors hover:text-rose-400"
    >
      <svg className="h-3 w-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 19l-7-7 7-7" />
      </svg>
      Shrunk
    </Link>
  );
}

function FooterAttribution() {
  return (
    <div className="gradient-border mt-16 rounded-2xl border border-border bg-card p-5">
      <p className="text-xs text-muted">
        Shrunk is a product of{" "}
        {/* Leaves this zone for the studio site. A plain <a> is never
            basePath-prefixed, so it is written absolute. */}
        <a
          href="https://stackcurious.com"
          className="font-semibold text-foreground transition-colors hover:text-rose-400"
        >
          Stack Curious, LLC
        </a>{" "}
        · Florida, USA
      </p>
    </div>
  );
}
