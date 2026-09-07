import Link from "next/link";
import { AppStoreCTA } from "./_components/AppStoreCTA";
import { StickyCta } from "./_components/StickyCta";
import { CaseCard } from "./_components/CaseCard";
import { CASES } from "./_lib/cases";
import {
  DATA_SOURCES,
  FREE_FEATURES,
  PRICE_MONTHLY,
  PRICE_YEARLY,
  PRO_FEATURES,
  RED,
  SHRUNK_URL,
  TRIAL_DAYS,
} from "./_lib/constants";

const PREVIEW_CASES = CASES.slice(0, 6);

const FAQS: { q: string; a: React.ReactNode; plain: string }[] = [
  {
    q: "What is shrinkflation?",
    plain:
      "Shrinkflation is when a manufacturer shrinks a product's size or quantity while keeping the price the same. The sticker price looks unchanged; you're paying more per ounce, per sheet, or per serving, and nothing on the label announces it.",
    a: "Shrinkflation is when a manufacturer shrinks a product's size or quantity while keeping the price the same. The sticker price looks unchanged; you're paying more per ounce, per sheet, or per serving, and nothing on the label announces it.",
  },
  {
    q: "What are some examples of shrinkflation in 2026?",
    plain:
      "Coffee cans, chip bags, toilet paper rolls, ice cream tubs, and paper towels are some of the most common categories. Shrunk's browse feed tracks 25 hand-verified cases, each with a public source — see the full shrinkflation list.",
    a: (
      <>
        Coffee cans, chip bags, toilet paper rolls, ice cream tubs, and paper towels are some
        of the most common categories. Shrunk&apos;s browse feed tracks 25 hand-verified cases,
        each with a public source — see the{" "}
        <Link href="/shrinkflation" className="text-rose-400 hover:text-rose-300">
          full shrinkflation list
        </Link>
        .
      </>
    ),
  },
  {
    q: "How do I spot shrinkflation at the store?",
    plain:
      "Compare the cost-per-unit printed on the shelf tag, not the sticker price, and check whether the package dimensions or count changed since your last purchase. Scanning the barcode with Shrunk does this automatically by pulling that product's size history.",
    a: "Compare the cost-per-unit printed on the shelf tag, not the sticker price, and check whether the package dimensions or count changed since your last purchase. Scanning the barcode with Shrunk does this automatically by pulling that product's size history.",
  },
  {
    q: "Is there an app that detects shrinkflation?",
    plain:
      "Yes — Shrunk. Point your camera at a grocery barcode and it checks the product's package-size history against USDA FoodData Central and Open Food Facts, then tells you whether it shrank, when, and by how much.",
    a: "Yes — Shrunk. Point your camera at a grocery barcode and it checks the product's package-size history against USDA FoodData Central and Open Food Facts, then tells you whether it shrank, when, and by how much.",
  },
  {
    q: "Is Shrunk free?",
    plain: `Yes. Scanning, verdicts, size history, current price and cost per unit, the browse feed, and label contributions are all free with no account required. Shrunk Pro ($${PRICE_MONTHLY}/month or $${PRICE_YEARLY}/year, with a ${TRIAL_DAYS}-day free trial on the yearly plan) adds the watchlist, alerts, unlimited alternatives, full history charts, and the savings dashboard.`,
    a: `Yes. Scanning, verdicts, size history, current price and cost per unit, the browse feed, and label contributions are all free with no account required. Shrunk Pro ($${PRICE_MONTHLY}/month or $${PRICE_YEARLY}/year, with a ${TRIAL_DAYS}-day free trial on the yearly plan) adds the watchlist, alerts, unlimited alternatives, full history charts, and the savings dashboard.`,
  },
  {
    q: "Which stores show live prices in Shrunk?",
    plain:
      "Live pricing, current package size, and stock come from the Kroger Products API for the store you pick. Every other feature — scanning, size history, the browse feed — works regardless of where you shop.",
    a: "Live pricing, current package size, and stock come from the Kroger Products API for the store you pick. Every other feature — scanning, size history, the browse feed — works regardless of where you shop.",
  },
  {
    q: "Does Shrunk track me?",
    plain:
      "No account, no login, and no ad SDKs. Your watchlist and scan activity are never sold or shared. See the full privacy policy for exactly what data the app touches.",
    a: (
      <>
        No account, no login, and no ad SDKs. Your watchlist and scan activity are never sold
        or shared. See the{" "}
        <Link href="/privacy" className="text-rose-400 hover:text-rose-300">
          full privacy policy
        </Link>{" "}
        for exactly what data the app touches.
      </>
    ),
  },
  {
    q: "How do I cancel Shrunk Pro?",
    plain:
      "Open Settings on your iPhone → your name → Subscriptions → Shrunk → Cancel Subscription. Cancel at least 24 hours before the current period ends to stop the next charge; you keep Pro until that period ends. Apple, not us, handles cancellations and refunds.",
    a: "Open Settings on your iPhone → your name → Subscriptions → Shrunk → Cancel Subscription. Cancel at least 24 hours before the current period ends to stop the next charge; you keep Pro until that period ends. Apple, not us, handles cancellations and refunds.",
  },
  {
    q: "Does Shrunk verify shrinkflation cases before listing them?",
    plain:
      "Every case in the browse feed is checked by hand against a cited public source — reporting from mouseprint.org, Consumer World, or a news investigation — before it ships. We fetch the page and confirm it states both the before and the after size for that exact product; anything we can't source that way is removed rather than published. No entry is guesswork.",
    a: "Every case in the browse feed is checked by hand against a cited public source — reporting from mouseprint.org, Consumer World, or a news investigation — before it ships. We fetch the page and confirm it states both the before and the after size for that exact product; anything we can't source that way is removed rather than published. No entry is guesswork.",
  },
];

const appJsonLd = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: "Shrunk: Shrinkflation Scanner",
  operatingSystem: "iOS",
  applicationCategory: "ShoppingApplication",
  description:
    "Scan grocery barcodes to see exactly which products have shrunk in size at the same price — real size history, today's shelf price at your Kroger store, and better-value alternatives.",
  url: SHRUNK_URL,
  offers: [
    { "@type": "Offer", name: "Free", price: "0", priceCurrency: "USD", category: "free" },
    {
      "@type": "Offer",
      name: "Shrunk Pro Monthly",
      price: PRICE_MONTHLY,
      priceCurrency: "USD",
      category: "subscription",
    },
    {
      "@type": "Offer",
      name: "Shrunk Pro Yearly",
      price: PRICE_YEARLY,
      priceCurrency: "USD",
      category: "subscription",
    },
  ],
  publisher: { "@type": "Organization", name: "Stack Curious" },
};

const faqJsonLd = {
  "@context": "https://schema.org",
  "@type": "FAQPage",
  mainEntity: FAQS.map((f) => ({
    "@type": "Question",
    name: f.q,
    acceptedAnswer: { "@type": "Answer", text: f.plain },
  })),
};

export default function ShrunkPage() {
  return (
    <>
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(appJsonLd) }} />
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(faqJsonLd) }} />

      {/* HERO */}
      <section className="relative overflow-hidden shrunk-hero-gradient">
        <div className="dot-grid absolute inset-0" />
        <div className="relative mx-auto max-w-6xl px-6 pb-24 pt-24 md:pb-32 md:pt-32">
          <div className="max-w-3xl">
            <div className="animate-fade-up mb-6 inline-flex items-center gap-2 rounded-full border border-border bg-surface px-4 py-1.5">
              <span
                className="h-2 w-2 rounded-full animate-glow-pulse"
                style={{ backgroundColor: RED }}
              />
              <span className="text-xs font-medium text-muted">
                iPhone · Free to scan · No brand pays us
              </span>
            </div>

            <h1 className="animate-fade-up text-4xl font-bold leading-[1.1] tracking-tight md:text-5xl lg:text-6xl">
              Catch{" "}
              <span className="shrunk-shimmer">shrinkflation</span>
              <br />
              before checkout.
            </h1>

            <p className="animate-fade-up-delay-1 mt-6 max-w-xl text-lg leading-relaxed text-muted md:text-xl">
              Same price tag. Less product inside. Most people never notice. Scan a barcode
              and Shrunk shows you exactly when the package shrunk, by how much, today&apos;s
              price at your store, and what to buy instead.
            </p>

            <div className="animate-fade-up-delay-2 mt-10 flex flex-col gap-4 sm:flex-row">
              <AppStoreCTA size="lg" location="hero" />
              <Link
                href="/shrinkflation"
                className="inline-flex items-center justify-center gap-2 rounded-xl border border-border px-6 py-3.5 text-sm font-semibold text-muted transition-all hover:border-border-hover hover:text-foreground hover:bg-card"
              >
                See 25 verified cases
              </Link>
            </div>
          </div>
        </div>
      </section>

      {/* HOW IT WORKS */}
      <section id="how-it-works" className="mx-auto max-w-6xl px-6 py-20 md:py-28">
        <h2 className="text-2xl font-bold tracking-tight md:text-3xl">How it works</h2>
        <div className="mt-10 grid gap-6 md:grid-cols-3">
          <Step
            number="01"
            title="Scan"
            body="Point your camera at any grocery barcode. No account, no sign-up — you're scanning in seconds."
          />
          <Step
            number="02"
            title="Get the verdict"
            body="Shrunk checks the package's size history against USDA FoodData Central and Open Food Facts and tells you whether it shrank, when, and by how much — with dates."
          />
          <Step
            number="03"
            title="Compare & switch"
            body="See today's price and cost per unit at your Kroger store, plus better-value alternatives ranked from the same shelf."
          />
        </div>
      </section>

      {/* VERIFIED CASES PREVIEW */}
      <section className="border-t border-border bg-surface py-20 md:py-28">
        <div className="mx-auto max-w-6xl px-6">
          <div className="flex flex-wrap items-end justify-between gap-4">
            <div>
              <h2 className="text-2xl font-bold tracking-tight md:text-3xl">
                25 verified shrinkflation cases
              </h2>
              <p className="mt-2 max-w-xl text-muted">
                Every case below is checked by hand against a public source — no guessing.
              </p>
            </div>
            <Link
              href="/shrinkflation"
              className="inline-flex items-center gap-1.5 text-sm font-semibold text-rose-400 hover:text-rose-300"
            >
              See the full list
              <svg className="h-3.5 w-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5l7 7-7 7" />
              </svg>
            </Link>
          </div>

          <div className="mt-10 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {PREVIEW_CASES.map((c) => (
              <CaseCard key={c.slug} c={c} />
            ))}
          </div>
        </div>
      </section>

      {/* FREE VS PRO */}
      <section id="pricing" className="mx-auto max-w-6xl px-6 py-20 md:py-28">
        <h2 className="text-2xl font-bold tracking-tight md:text-3xl">Free vs. Pro</h2>
        <p className="mt-2 max-w-xl text-muted">
          Scanning is free, forever. Pro is an optional subscription for people who want to be
          watched over, not just answered once.
        </p>

        <div className="mt-10 grid gap-6 md:grid-cols-2">
          <div className="rounded-3xl border border-border bg-card p-8">
            <h3 className="text-lg font-semibold text-foreground">Free</h3>
            <p className="mt-1 text-3xl font-bold tracking-tight text-foreground">$0</p>
            <ul className="mt-6 space-y-3 text-sm leading-relaxed text-muted">
              {FREE_FEATURES.map((f) => (
                <FeatureRow key={f} text={f} />
              ))}
            </ul>
          </div>

          <div className="gradient-border relative rounded-3xl border border-border bg-card p-8">
            <span
              className="absolute -top-3 left-8 rounded-full px-3 py-1 text-xs font-bold text-white"
              style={{ backgroundColor: RED }}
            >
              SHRUNK PRO
            </span>
            <h3 className="text-lg font-semibold text-foreground">Pro</h3>
            <p className="mt-1 text-3xl font-bold tracking-tight text-foreground">
              ${PRICE_MONTHLY}
              <span className="text-base font-normal text-muted">/month</span>
            </p>
            <p className="mt-1 text-sm text-muted">
              or ${PRICE_YEARLY}/year — {TRIAL_DAYS}-day free trial for new subscribers
            </p>
            <ul className="mt-6 space-y-3 text-sm leading-relaxed text-muted">
              {PRO_FEATURES.map((f) => (
                <FeatureRow key={f} text={f} accent />
              ))}
            </ul>
            <p className="mt-6 text-xs text-muted">
              Auto-renewable subscription, billed by Apple. Cancel any time in Settings →
              Subscriptions. See{" "}
              <Link href="/terms" className="text-rose-400 hover:text-rose-300">
                Terms
              </Link>{" "}
              for full renewal details.
            </p>
          </div>
        </div>
      </section>

      {/* DATA SOURCES / TRUST */}
      <section className="border-t border-border bg-surface py-20 md:py-28">
        <div className="mx-auto max-w-4xl px-6">
          <h2 className="text-2xl font-bold tracking-tight md:text-3xl">
            Where the data comes from
          </h2>
          <p className="mt-3 max-w-2xl text-muted">
            No brand pays us. No sponsorships, no affiliate placements inside the app. Every
            verdict traces back to one of these sources.
          </p>
          <div className="mt-10 grid gap-5 sm:grid-cols-2">
            {DATA_SOURCES.map((s) => (
              <div key={s.name} className="rounded-2xl border border-border bg-card p-6">
                <h3 className="font-semibold text-foreground">
                  {s.url ? (
                    <a
                      href={s.url}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="hover:text-rose-400"
                    >
                      {s.name}
                    </a>
                  ) : (
                    s.name
                  )}
                </h3>
                <p className="mt-2 text-sm leading-relaxed text-muted">{s.body}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* FAQ */}
      <section id="faq" className="mx-auto max-w-4xl px-6 py-20 md:py-28">
        <h2 className="text-2xl font-bold tracking-tight md:text-3xl">
          Frequently asked questions
        </h2>
        <div className="mt-10 space-y-4">
          {FAQS.map((f) => (
            <div key={f.q} className="rounded-2xl border border-border bg-card p-6">
              <h3 className="font-semibold text-foreground">{f.q}</h3>
              <p className="mt-2 text-sm leading-relaxed text-muted">{f.a}</p>
            </div>
          ))}
        </div>
      </section>

      {/* FINAL CTA */}
      <section className="border-t border-border bg-surface py-20 md:py-28">
        <div className="mx-auto max-w-2xl px-6 text-center">
          <h2 className="text-3xl font-bold tracking-tight md:text-4xl">
            Stop paying more for less.
          </h2>
          <p className="mt-4 text-muted">Free to scan. No account. No brand pays us.</p>
          <div className="mt-8 flex justify-center">
            <AppStoreCTA size="lg" location="final" />
          </div>
        </div>
      </section>

      {/* FOOTER LINKS */}
      <section className="mx-auto max-w-2xl px-6 pb-24">
        <div className="grid gap-3 sm:grid-cols-3">
          <LinkCard href="/privacy" label="Privacy" />
          <LinkCard href="/terms" label="Terms" />
          <LinkCard href="/support" label="Support" />
        </div>
      </section>

      <StickyCta />
    </>
  );
}

function Step({ number, title, body }: { number: string; title: string; body: string }) {
  return (
    <div className="rounded-2xl border border-border bg-card p-6">
      <span className="font-mono text-xs text-muted">{number}</span>
      <h3 className="mt-3 text-xl font-semibold tracking-tight">{title}</h3>
      <p className="mt-2 text-sm leading-relaxed text-muted">{body}</p>
    </div>
  );
}

function FeatureRow({ text, accent = false }: { text: string; accent?: boolean }) {
  return (
    <li className="flex items-start gap-2.5">
      <svg
        className="mt-0.5 h-4 w-4 shrink-0"
        style={{ color: accent ? RED : undefined }}
        fill="none"
        stroke="currentColor"
        viewBox="0 0 24 24"
      >
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7" />
      </svg>
      <span>{text}</span>
    </li>
  );
}

function LinkCard({ href, label }: { href: string; label: string }) {
  return (
    <Link
      href={href}
      className="flex items-center justify-between rounded-xl border border-border bg-card px-5 py-4 text-sm font-medium text-foreground transition-all hover:bg-surface"
    >
      <span>{label}</span>
      <svg className="h-4 w-4 text-muted" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5l7 7-7 7" />
      </svg>
    </Link>
  );
}
