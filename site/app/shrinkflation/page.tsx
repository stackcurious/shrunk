import type { Metadata } from "next";
import Link from "next/link";
import { AppStoreCTA } from "../_components/AppStoreCTA";
import { StickyCta } from "../_components/StickyCta";
import { ShrinkflationList } from "../_components/ShrinkflationList";
import { CASES, CATEGORIES } from "../_lib/cases";
import { SHRUNK_URL, SITE_URL } from "../_lib/constants";

const TITLE = "Shrinkflation List 2026 — 25 Verified Cases";
const DESCRIPTION =
  "Every hand-verified shrinkflation case Shrunk tracks: product, before/after size, percent smaller, and a cited public source for each one. Grouped by category.";
const PAGE_URL = `${SHRUNK_URL}/shrinkflation`;

export const metadata: Metadata = {
  title: TITLE,
  description: DESCRIPTION,
  alternates: { canonical: PAGE_URL },
  openGraph: {
    title: TITLE,
    description: DESCRIPTION,
    url: PAGE_URL,
    siteName: "Stack Curious",
    type: "website",
    images: ["/opengraph-image"],
  },
  twitter: {
    card: "summary_large_image",
    title: TITLE,
    description: DESCRIPTION,
    images: ["/opengraph-image"],
  },
};

const breadcrumbJsonLd = {
  "@context": "https://schema.org",
  "@type": "BreadcrumbList",
  itemListElement: [
    { "@type": "ListItem", position: 1, name: "Shrunk", item: SHRUNK_URL },
    { "@type": "ListItem", position: 2, name: "Shrinkflation list", item: PAGE_URL },
  ],
};

const itemListJsonLd = {
  "@context": "https://schema.org",
  "@type": "ItemList",
  itemListElement: CASES.map((c, i) => ({
    "@type": "ListItem",
    position: i + 1,
    url: `${SITE_URL}/shrunk/shrinkflation/${c.slug}`,
    name: c.name,
  })),
};

export default function ShrinkflationIndexPage() {
  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(breadcrumbJsonLd) }}
      />
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(itemListJsonLd) }}
      />

      <div className="mx-auto max-w-5xl px-6 pb-24 pt-16 md:pt-24">
        <Breadcrumb />

        <header className="mt-8 max-w-3xl">
          <h1 className="text-3xl font-bold leading-tight tracking-tight text-foreground md:text-4xl">
            The shrinkflation list: 25 verified cases
          </h1>
          <p className="mt-4 text-lg leading-relaxed text-muted">
            Every entry here has a cited public source — no crowdsourced rumors, no guessing.
            Scan any barcode in the Shrunk app to check a product that isn&apos;t listed yet.
          </p>
          <div className="mt-6">
            <AppStoreCTA location="hero" />
          </div>
        </header>

        <div className="mt-14">
          <ShrinkflationList cases={CASES} categories={CATEGORIES} />
        </div>

        <div className="mt-16 rounded-2xl border border-border bg-card p-6 text-sm leading-relaxed text-muted">
          <strong className="text-foreground">How this list is built.</strong> Each case cites
          a published source — reporting from mouseprint.org, Consumer World, or a news
          investigation — for the before/after package size. Percent-smaller is computed
          directly from the two sizes; the price-per-unit jump on each case page assumes the
          shelf price shown held constant across the resize, which is the defining trait of
          shrinkflation. Data licensed CC-BY-4.0.
        </div>
      </div>

      <StickyCta />
    </>
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
