import type { Metadata } from "next";
import Link from "next/link";
import { PRICE_MONTHLY, PRICE_YEARLY, SHRUNK_URL, SUPPORT_EMAIL, TRIAL_DAYS } from "../_lib/constants";

export const metadata: Metadata = {
  title: "Support",
  description:
    "Get help with Shrunk — how to manage or cancel Shrunk Pro, restore purchases, FAQs, troubleshooting, and contact information.",
  alternates: { canonical: `${SHRUNK_URL}/support` },
};

export default function ShrunkSupport() {
  return (
    <article className="animate-fade-up mx-auto max-w-2xl px-6 py-16 md:py-24">
      <Breadcrumb />

      <header className="mt-8 mb-12">
        <h1 className="text-3xl font-bold tracking-tight text-foreground md:text-4xl">
          Support
        </h1>
        <p className="mt-3 text-sm text-muted">We&apos;re here to help</p>
      </header>

      <div className="space-y-8 text-[15px] leading-relaxed text-foreground/85">
        <Section title="Manage or cancel Shrunk Pro">
          <ol className="list-decimal space-y-2 pl-5 marker:text-rose-400">
            <li>Open the Settings app on your iPhone.</li>
            <li>Tap your name at the top, then tap Subscriptions.</li>
            <li>Tap Shrunk, then tap Cancel Subscription (or change your plan).</li>
          </ol>
          <p className="mt-3">
            Turning off auto-renew at least 24 hours before the end of your current period
            stops the next charge; you keep Pro access until that period ends. This is an
            Apple-managed setting — Shrunk cannot cancel it for you from inside the app, and
            Apple, not us, handles cancellations and refunds.
          </p>
        </Section>

        <Section title="Restore your purchase on a new device">
          <p>
            Sign in with the same Apple Account you subscribed with, open Shrunk, go to
            Settings in the app, and tap &ldquo;Restore purchases.&rdquo; This re-verifies your
            subscription with Apple and unlocks Pro on the new device.
          </p>
        </Section>

        <Section title="Delete your data">
          <p>
            Shrunk has no account to close. To erase what is on our server, email us the Device
            ID shown in Settings → About → Device ID and we will delete the device record, your
            watchlist, your notification settings, and any submissions tied to it. Accepted size
            observations stay, because they are product facts and carry no identifier. Deleting
            the app stops everything being sent; Settings → Clear scan history clears the local
            scan list.
          </p>
        </Section>

        <Section title="Frequently Asked Questions">
          <div className="space-y-6">
            <FAQ
              q="Is Shrunk a subscription?"
              a={`Shrunk itself is free. Shrunk Pro is an optional auto-renewable subscription — $${PRICE_MONTHLY}/month or $${PRICE_YEARLY}/year, with a ${TRIAL_DAYS}-day free trial on the yearly plan for new subscribers. You can cancel anytime; see "Manage or cancel Shrunk Pro" above.`}
            />
            <FAQ
              q="What do I get for free?"
              a="Unlimited barcode scans, available size evidence and package-change results, available current Kroger pricing, the full Browse feed of verified cases, label contributions, and up to 3 available alternatives per scan — no account required."
            />
            <FAQ
              q="What does Pro unlock?"
              a="Watchlist alerts after periodic checks find a documented size change or a 5% Kroger unit-price jump, a weekly category digest, all available ranked alternatives at your store, full available price and size history charts, and a savings dashboard built from observed data."
            />
            <FAQ
              q="Where does the data come from?"
              a="Historical package sizes come from the USDA's public FoodData Central dataset. Live prices, current sizes, and stock come from the Kroger Products API for the store you pick. Product names and images are supplemented from Open Food Facts. Our curated Browse catalog cites a published source for every entry — chiefly Edgar Dworsky's mouseprint.org downsizing archive — and the cited page has to state both the before and the after size for that exact product."
            />
            <FAQ
              q="Why does my scan say 'insufficient data'?"
              a="Not every barcode has a recorded historical size in USDA FoodData Central or Open Food Facts yet. If we can't find an earlier size to compare against the current one, we honestly report that we can't compute a verdict — and you can help by contributing a label photo."
            />
            <FAQ
              q="Is my data private?"
              a="The Shrunk iOS app has no account, login, in-app analytics, or advertising SDKs. We never sell or share app data with advertisers or data brokers. Your watchlist, store choice and notification preferences are stored on your device and in a row in our database keyed to a random device id — never your name, email or Apple Account. Your recent scans stay on your device only. The website uses the limited page-view, performance, and CTA measurement described in the privacy policy."
            />
            <FAQ
              q="How do I restore my purchase on a new device?"
              a='Go to Settings in the app → tap "Restore purchases." This re-verifies your subscription with Apple and unlocks Pro on your new device.'
            />
            <FAQ
              q="Which store do live prices come from?"
              a="Kroger, via its official Products API. During onboarding or in Settings, tap Use Current Location or search by city, neighborhood, store name, ZIP, or ZIP+4. When Kroger returns data for a product, its current price, unit cost, promotion, and stock appear on the result screen."
            />
            <FAQ
              q="Can I suggest a shrinkflation case I noticed?"
              a={`Yes — two ways. In the app, use "Contribute a label" to photograph the net-weight label on a product, and we'll add it to that product's size history after review. Or email us at ${SUPPORT_EMAIL} with the product, before/after sizes, and a source link; verified cases get added to the curated Browse catalog.`}
            />
            <FAQ
              q="Does Shrunk work outside the US?"
              a="Scanning and the USDA/Open Food Facts size history work for US grocery barcodes. Live Kroger pricing is US-only, since Kroger only operates in the US. Multi-retailer and international support is on the roadmap."
            />
          </div>
        </Section>

        <Section title="Troubleshooting">
          <div className="space-y-6">
            <FAQ
              q="The Browse tab is empty"
              a="The app ships with a bundled fallback catalog so this shouldn't happen. If it does, pull down on the Browse view to refresh. If still empty, force-quit and relaunch."
            />
            <FAQ
              q="My subscription isn't showing as unlocked"
              a='Go to Settings → "Restore purchases." Make sure you are signed into the same Apple Account you subscribed with.'
            />
            <FAQ
              q="Background watchlist sweeps don't seem to run"
              a="iOS controls when background tasks fire — it learns your usage patterns and runs sweeps when convenient (typically once or twice a day). You can also pull down on the Watchlist tab to force a refresh."
            />
            <FAQ
              q="The camera permission prompt didn't appear"
              a="If you previously denied camera access, iOS won't re-prompt. Go to iOS Settings → Privacy & Security → Camera → enable Shrunk."
            />
            <FAQ
              q="No nearby stores appear"
              a="Tap Use Current Location or search by city, neighborhood, store name, 5-digit ZIP, or ZIP+4. If location access is off, typed search still works. If no Kroger-family store operates nearby, scanning and available size evidence still work without local pricing."
            />
          </div>
        </Section>

        <Section title="Contact us">
          <p className="text-muted">Can&apos;t find what you need? Reach out directly:</p>
          <div className="mt-4 space-y-3">
            <a
              href={`mailto:${SUPPORT_EMAIL}`}
              className="flex items-center gap-3 rounded-xl border border-border bg-card p-4 transition-all hover:bg-surface"
            >
              <span className="text-xl">✉️</span>
              <div>
                <p className="text-sm font-semibold text-foreground">Email</p>
                <p className="text-xs text-muted">{SUPPORT_EMAIL}</p>
              </div>
            </a>
          </div>
          <p className="mt-6 text-xs text-muted">
            We typically respond within 24 hours on business days. See also{" "}
            <Link href="/privacy" className="text-rose-400 hover:text-rose-300">
              Privacy Policy
            </Link>{" "}
            and{" "}
            <Link href="/terms" className="text-rose-400 hover:text-rose-300">
              Terms of Service
            </Link>
            .
          </p>
        </Section>
      </div>

      <FooterAttribution />
    </article>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section>
      <h2 className="mb-6 text-lg font-semibold text-foreground">
        <span className="border-b-2 border-rose-400/40 pb-1">{title}</span>
      </h2>
      <div>{children}</div>
    </section>
  );
}

function FAQ({ q, a }: { q: string; a: string }) {
  return (
    <div>
      <h3 className="text-sm font-semibold text-foreground">{q}</h3>
      <p className="mt-1.5 text-sm text-muted">{a}</p>
    </div>
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
