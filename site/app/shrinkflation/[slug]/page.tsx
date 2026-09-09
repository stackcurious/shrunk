import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { AppStoreCTA } from "../../_components/AppStoreCTA";
import { StickyCta } from "../../_components/StickyCta";
import { CASES, caseBySlug, formatQuantity, relatedCases, type Case } from "../../_lib/cases";
import { SHRUNK_URL, SITE_URL } from "../../_lib/constants";

function pct(n: number): string {
  const r = Math.round(n * 10) / 10;
  return Number.isInteger(r) ? `${r}` : `${r.toFixed(1)}`;
}

function money(n: number): string {
  return `$${n.toFixed(4).replace(/0+$/, "").replace(/\.$/, "")}`;
}

function caseTitle(c: Case): string {
  return `${c.name} shrinkflation: ${formatQuantity(c.before)} → ${formatQuantity(c.after)} (-${pct(c.percentSmaller)}%)`;
}

export function generateStaticParams() {
  return CASES.map((c) => ({ slug: c.slug }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>;
}): Promise<Metadata> {
  const { slug } = await params;
  const c = caseBySlug(slug);
  if (!c) return {};

  const title = caseTitle(c);
  const description = `${c.brand}'s ${c.name} shrank from ${formatQuantity(c.before)} to ${formatQuantity(c.after)} (${pct(c.percentSmaller)}% smaller), documented by a cited public source. See the dated size evidence and available current price.`;
  const url = `${SHRUNK_URL}/shrinkflation/${c.slug}`;

  return {
    title,
    description,
    alternates: { canonical: url },
    openGraph: {
      title,
      description,
      url,
      siteName: "Stack Curious",
      type: "article",
      images: ["/opengraph-image"],
    },
    twitter: {
      card: "summary_large_image",
      title,
      description,
      images: ["/opengraph-image"],
    },
  };
}

export default async function CasePage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const c = caseBySlug(slug);
  if (!c) notFound();

  const related = relatedCases(c, 3);
  const url = `${SHRUNK_URL}/shrinkflation/${c.slug}`;

  const breadcrumbJsonLd = {
    "@context": "https://schema.org",
    "@type": "BreadcrumbList",
    itemListElement: [
      { "@type": "ListItem", position: 1, name: "Shrunk", item: SHRUNK_URL },
      {
        "@type": "ListItem",
        position: 2,
        name: "Shrinkflation list",
        item: `${SHRUNK_URL}/shrinkflation`,
      },
      { "@type": "ListItem", position: 3, name: c.name, item: url },
    ],
  };

  const articleJsonLd = {
    "@context": "https://schema.org",
    "@type": "Article",
    headline: caseTitle(c),
    description: `${c.brand}'s ${c.name} shrank from ${formatQuantity(c.before)} to ${formatQuantity(c.after)}, a documented ${pct(c.percentSmaller)}% package-size reduction.`,
    image: c.image_url ? [c.image_url] : undefined,
    datePublished: c.added_at,
    dateModified: c.added_at,
    author: { "@type": "Organization", name: "Stack Curious", url: SITE_URL },
    publisher: { "@type": "Organization", name: "Stack Curious", url: SITE_URL },
    mainEntityOfPage: { "@type": "WebPage", "@id": url },
    about: { "@type": "Product", name: c.name, brand: { "@type": "Brand", name: c.brand } },
  };

  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(breadcrumbJsonLd) }}
      />
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(articleJsonLd) }}
      />

      <article className="mx-auto max-w-3xl px-6 pb-24 pt-16 md:pt-24">
        <Breadcrumb name={c.name} />

        <header className="mt-8">
          <p className="text-xs font-semibold uppercase tracking-wider text-rose-400">
            {c.category}
          </p>
          <h1 className="mt-2 text-3xl font-bold leading-tight tracking-tight text-foreground md:text-4xl">
            {c.name} shrank {pct(c.percentSmaller)}%
          </h1>
          <p className="mt-4 text-lg leading-relaxed text-muted">
            {c.brand}&apos;s {c.name} went from {formatQuantity(c.before)} to{" "}
            {formatQuantity(c.after)} — first documented at the reduced size around{" "}
            {monthYear(c.after.date)}. Price history is evaluated separately.
          </p>
        </header>

        {/* BEFORE / AFTER */}
        <section className="mt-10 grid grid-cols-2 gap-4">
          <div className="rounded-2xl border border-border bg-card p-6 text-center">
            <p className="text-xs font-semibold uppercase tracking-wider text-muted">
              Before · {monthYear(c.before.date)}
            </p>
            <p className="mt-2 text-3xl font-bold tracking-tight text-foreground">
              {formatQuantity(c.before)}
            </p>
          </div>
          <div className="rounded-2xl border border-rose-400/30 bg-rose-400/5 p-6 text-center">
            <p className="text-xs font-semibold uppercase tracking-wider text-rose-400">
              After · {monthYear(c.after.date)}
            </p>
            <p className="mt-2 text-3xl font-bold tracking-tight text-foreground">
              {formatQuantity(c.after)}
            </p>
          </div>
        </section>

        <section className="mt-6 rounded-2xl border border-border bg-card p-6">
          <div className="flex items-center justify-between">
            <p className="text-sm font-semibold text-foreground">Package size</p>
            <p className="text-sm font-bold text-rose-400">-{pct(c.percentSmaller)}%</p>
          </div>
          <div className="mt-3 h-2 overflow-hidden rounded-full bg-border">
            <div
              className="h-full rounded-full bg-rose-400"
              style={{ width: `${100 - c.percentSmaller}%` }}
            />
          </div>
          <div className="mt-2 flex items-center justify-between text-xs text-muted">
            <span>Reduced size = {formatQuantity(c.after)}</span>
            <span>Earlier size = {formatQuantity(c.before)}</span>
          </div>
        </section>

        {/* PRICE PER UNIT */}
        {c.current_price !== null &&
          c.pricePerUnitAtEarlierSize !== null &&
          c.pricePerUnitAtReducedSize !== null &&
          c.unitPriceDifferencePercent !== null && (
            <section className="mt-6 rounded-2xl border border-border bg-card p-6">
              <p className="text-sm font-semibold text-foreground">
                Unit-price effect at the current price
              </p>
              <p className="mt-2 text-sm leading-relaxed text-muted">
                At the available tracked price of ${c.current_price.toFixed(2)}, the earlier
                package quantity works out to{" "}
                <strong className="text-foreground">
                  {money(c.pricePerUnitAtEarlierSize)} per {c.before.unit}
                </strong>
                {", compared with "}
                <strong className="text-foreground">
                  {money(c.pricePerUnitAtReducedSize)} per {c.after.unit}
                </strong>{" "}
                for the reduced size — a{" "}
                <strong className="text-rose-400">
                  {pct(c.unitPriceDifferencePercent)}% difference in cost per unit
                </strong>
                . This applies one current price to both documented package sizes to make them
                comparable; it is not historical price evidence.
              </p>
            </section>
          )}

        {/* SOURCE */}
        <section className="mt-6 rounded-2xl border border-border bg-card p-6">
          <p className="text-sm font-semibold text-foreground">Source</p>
          <p className="mt-2 text-sm leading-relaxed text-muted">
            Verified against{" "}
            <a
              href={c.evidence_url}
              target="_blank"
              rel="nofollow noopener"
              className="font-medium text-rose-400 hover:text-rose-300"
            >
              {c.source}
            </a>{" "}
            ({c.sourceDomain}), which states both the before and the after size for this
            product. Added to Shrunk&apos;s browse feed {monthYear(c.added_at)}.
          </p>
        </section>

        {/* CTA */}
        <section className="mt-12 rounded-3xl border border-border bg-surface p-8 text-center">
          <h2 className="text-xl font-bold tracking-tight text-foreground">
            Check your own pantry
          </h2>
          <p className="mx-auto mt-2 max-w-md text-sm text-muted">
            Scan or enter a supported grocery barcode to check available dated size evidence —
            free, with no account needed.
          </p>
          <div className="mt-6 flex justify-center">
            <AppStoreCTA location="hero" />
          </div>
        </section>

        {/* RELATED */}
        {related.length > 0 && (
          <section className="mt-14">
            <h2 className="text-sm font-semibold uppercase tracking-wider text-muted">
              Related cases
            </h2>
            <div className="mt-4 grid gap-3 sm:grid-cols-3">
              {related.map((r) => (
                <Link
                  key={r.slug}
                  href={`/shrinkflation/${r.slug}`}
                  className="rounded-xl border border-border bg-card p-4 transition-colors hover:border-border-hover hover:bg-card-hover"
                >
                  <p className="text-sm font-semibold text-foreground">{r.name}</p>
                  <p className="mt-1 text-xs text-muted">
                    {formatQuantity(r.before)} → {formatQuantity(r.after)} · -{pct(r.percentSmaller)}%
                  </p>
                </Link>
              ))}
            </div>
          </section>
        )}

        <p className="mt-14 text-sm">
          <Link href="/shrinkflation" className="font-semibold text-rose-400 hover:text-rose-300">
            ← See all 25 verified cases
          </Link>
        </p>
      </article>

      <StickyCta />
    </>
  );
}

function monthYear(dateStr: string): string {
  const d = new Date(dateStr);
  if (Number.isNaN(d.getTime())) return dateStr;
  return d.toLocaleDateString("en-US", { month: "long", year: "numeric", timeZone: "UTC" });
}

function Breadcrumb({ name }: { name: string }) {
  return (
    <nav className="flex items-center gap-1.5 text-xs font-medium text-muted">
      <Link href="/" className="transition-colors hover:text-rose-400">
        Shrunk
      </Link>
      <span aria-hidden="true">/</span>
      <Link href="/shrinkflation" className="transition-colors hover:text-rose-400">
        Shrinkflation list
      </Link>
      <span aria-hidden="true">/</span>
      <span className="truncate text-foreground/70">{name}</span>
    </nav>
  );
}
