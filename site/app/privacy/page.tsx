import type { Metadata } from "next";
import Link from "next/link";
import { SHRUNK_URL, SUPPORT_EMAIL } from "../_lib/constants";

export const metadata: Metadata = {
  title: "Privacy Policy",
  description:
    "The Shrunk iOS app has no accounts, in-app analytics, ad tracking, or advertising SDK. This policy also explains the limited measurement used on the Shrunk website.",
  alternates: { canonical: `${SHRUNK_URL}/privacy` },
};

/** Mirrors the "What Shrunk stores" table in the app repo's docs/PRIVACY_POLICY.md. */
const STORED: {
  what: string;
  when: string;
  where: React.ReactNode;
  howLong: React.ReactNode;
}[] = [
  {
    what: "The barcode you scanned (a 13-digit product number)",
    when: "Every scan",
    where: "Sent to our API to look the product up. Not stored as a record of your scanning.",
    howLong: "Not retained",
  },
  {
    what: "A random device id (a UUID generated on your phone at first launch)",
    when: "First launch",
    where: (
      <>
        On your device, and in a <Code>devices</Code> row in our database
      </>
    ),
    howLong: "Until you ask us to delete it",
  },
  {
    what: "Your Apple push token",
    when: "Only if you allow notifications",
    where: (
      <>
        Same <Code>devices</Code> row
      </>
    ),
    howLong: "Until you turn notifications off or ask us to delete it",
  },
  {
    what: "The Kroger store you picked (a store id, not your location)",
    when: "When you pick a store",
    where: (
      <>
        On your device and in the <Code>devices</Code> row
      </>
    ),
    howLong: "Until you change or clear it",
  },
  {
    what: "Your approximate location",
    when: "Only when you tap Use Current Location to find stores",
    where: "Processed transiently on your device through Apple Location Services; never sent to or stored by Shrunk",
    howLong: "Discarded after nearby stores are ranked",
  },
  {
    what: "Your category and notification preferences",
    when: "Onboarding and Settings",
    where: (
      <>
        On your device and in the <Code>devices</Code> row
      </>
    ),
    howLong: "Until you change them",
  },
  {
    what: "Your watchlist (product barcodes and brands)",
    when: "When you add a product",
    where: (
      <>
        On your device and in a <Code>watches</Code> row
      </>
    ),
    howLong: "Until you remove the item",
  },
  {
    what: "A label photo you choose to contribute",
    when: "Uploaded to our server with every contribution",
    where: "Written to Cloudflare R2 in a private human-review queue",
    howLong: (
      <>
        <strong className="text-foreground">Deleted the moment it is reviewed</strong>, whether
        accepted or rejected
      </>
    ),
  },
  {
    what:
      "Your submission record (the barcode, the size you reported, the label text Shrunk read, your device id, and whether it was accepted)",
    when: "When you contribute",
    where: (
      <>
        In a <Code>submissions</Code> row in our database
      </>
    ),
    howLong: "Until you ask us to delete it",
  },
  {
    what: "The net weight read from a label",
    when: "When you contribute",
    where: (
      <>
        Stored as product data (<Code>observations</Code>)
      </>
    ),
    howLong: "Kept as part of the product's size history",
  },
  {
    what: "Your subscription status",
    when: "After a purchase or restore",
    where: (
      <>
        Apple&apos;s signed transaction is verified and reduced to an expiry date in the{" "}
        <Code>devices</Code> row
      </>
    ),
    howLong: "Until it expires or you ask us to delete it",
  },
  {
    what: "Your recent scans",
    when: "Every scan",
    where: (
      <>
        <strong className="text-foreground">On your device only</strong> (
        <Code>UserDefaults</Code>), never uploaded
      </>
    ),
    howLong: "Until you tap “Clear scan history” or delete the app",
  },
];

export default function ShrunkPrivacy() {
  return (
    <article className="animate-fade-up mx-auto max-w-2xl px-6 py-16 md:py-24">
      <Breadcrumb />

      <header className="mt-8 mb-12">
        <h1 className="text-3xl font-bold tracking-tight text-foreground md:text-4xl">
          Privacy Policy
        </h1>
        <p className="mt-3 text-sm text-muted">Last updated: September 8, 2026</p>
      </header>

      <div className="space-y-10 text-[15px] leading-relaxed">
        <Section title="The short version">
          <p>
            The Shrunk iOS app has no accounts or logins, analytics or advertising SDKs, ads, or
            cross-app tracking. The app stores the minimum needed to look up a product, alert you
            about something you asked us to watch, and honour a subscription you bought from
            Apple. This website uses the limited, non-advertising measurement described below.
          </p>
        </Section>

        <Section title="Website measurement">
          <p>
            The Shrunk website uses Vercel Web Analytics and Speed Insights to measure page
            views, web performance, and whether an App Store call to action was clicked. Our
            custom CTA events contain the page path, CTA placement, and outbound destination
            with its query string and fragment removed. They never contain barcodes, store or
            location data, email addresses, form input, the app&apos;s device id, or app activity.
          </p>
          <p className="mt-3">
            These tools run only on this website. They are not included in the Shrunk iOS app,
            are not used for advertising, and are not used to follow you across other apps or
            websites.
          </p>
        </Section>

        <Section title="What Shrunk stores">
          <div className="space-y-3">
            {STORED.map((row) => (
              <div key={row.what} className="rounded-2xl border border-border bg-card p-5">
                <p className="text-sm font-semibold text-foreground">{row.what}</p>
                <dl className="mt-3 space-y-1.5 text-sm">
                  <Field label="When" value={row.when} />
                  <Field label="Where" value={row.where} />
                  <Field label="How long" value={row.howLong} />
                </dl>
              </div>
            ))}
          </div>

          <p className="mt-5">
            <strong className="text-foreground">Shrunk never collects:</strong> your name, email
            address, postal address, phone number, device location, contacts, photo library,
            health data, payment details, or any advertising identifier. If you tap Use Current
            Location, Apple Location Services processes a one-time location on your device to
            find and rank nearby stores; Shrunk does not transmit or retain the coordinate. There
            is no advertising SDK and no analytics SDK in the app.
          </p>
        </Section>

        <Section title="Label photos">
          <p>
            Contributing a photo is optional and free. On your phone, Shrunk reads the label
            with Apple&apos;s on-device Vision framework to make an initial read. When you
            submit, the photo is uploaded to our server along with that reading,{" "}
            <strong className="text-foreground">every time</strong> — not only when the reading
            is unclear. Every contribution is written to a private review queue so a human can
            compare the submitted reading with the label. The photo is deleted as soon as that
            review is accepted or rejected. No crowd reading becomes public and no alert is sent
            before this review. The number that survives review becomes part of the
            product&apos;s public size history and is not attributed to you.
          </p>
          <p className="mt-3">
            Barcode scanning is separate, and no image ever leaves your phone: camera frames are
            read on device to extract the barcode digits, and only those digits are sent to our
            API to look the product up.
          </p>
        </Section>

        <Section title="Notifications">
          <p>
            If you allow notifications, Apple issues a push token for this install and we store
            it so watchlist alerts and the weekly digest can reach you. Turning notifications
            off in iOS Settings stops delivery; asking us to delete your device row removes the
            token.
          </p>
        </Section>

        <Section title="Purchases">
          <p>
            Shrunk Pro is an auto-renewable subscription sold by Apple. Apple handles payment;
            we never see your card, your Apple Account, or your billing details. Our server
            receives Apple&apos;s cryptographically signed transaction, verifies it, and stores
            an expiry date plus the random purchase token the app generated, so your
            subscription survives a reinstall — alongside two internal bookkeeping fields (a
            timestamp and a notification id) that only make sure Apple&apos;s renewal updates
            are applied in the right order and are never applied twice. Neither identifies you
            beyond what the purchase token already does.
          </p>
        </Section>

        <Section title="Who else sees this data">
          <ul className="list-disc space-y-3 pl-5 marker:text-rose-400">
            <li>
              <strong className="text-foreground">Cloudflare</strong> — hosts our API, database,
              photo storage and cache (United States).
            </li>
            <li>
              <strong className="text-foreground">Vercel</strong> — hosts this website and
              provides the page-view, performance, and CTA measurement described above. It does
              not receive activity from the Shrunk iOS app.
            </li>
            <li>
              <strong className="text-foreground">Apple</strong> — delivers push notifications,
              processes subscriptions, and resolves an optional one-time location or typed place
              on your device into a ZIP and coordinate. The coordinate ranks stores on-device and
              is then discarded.
            </li>
            <li>
              <strong className="text-foreground">Kroger</strong> — when you have a store
              selected, we ask Kroger&apos;s Products API for that store&apos;s price and size
              for the barcode you scanned; we send the barcode and the store id. To find stores,
              we send only the ZIP resolved from your location or place search to Kroger&apos;s
              Locations API. To find alternatives, we send the product&apos;s category as a search
              term to Kroger&apos;s Products API. Neither the ZIP nor the category is stored by us,
              and{" "}
              <strong className="text-foreground">
                we never send Kroger your device id, push token, coordinate, or search text.
              </strong>
            </li>
            <li>
              <strong className="text-foreground">USDA FoodData Central</strong> and{" "}
              <strong className="text-foreground">Open Food Facts</strong> — queried by barcode
              when a product is new to us, to fill in a name and image.
            </li>
          </ul>
          <p className="mt-4">
            We do not sell or rent data, or share it with advertisers or data brokers. Website
            measurement is limited to the Vercel services described above.
          </p>
        </Section>

        <Section title="Data sources and attribution">
          <ul className="list-disc space-y-3 pl-5 marker:text-rose-400">
            <li>
              <strong className="text-foreground">
                U.S. Department of Agriculture, FoodData Central
              </strong>{" "}
              — Branded Foods package sizes. Public domain data; USDA does not endorse Shrunk.
            </li>
            <li>
              <strong className="text-foreground">Kroger Products API</strong> — live store
              prices and sizes, shown in the app with the attribution &ldquo;Prices from
              Kroger&rdquo;. Shrunk is not affiliated with, endorsed by, or sponsored by The
              Kroger Co.
            </li>
            <li>
              <strong className="text-foreground">Open Food Facts</strong> — product names and
              images, licensed under the{" "}
              <a
                href="https://opendatacommons.org/licenses/odbl/1-0/"
                target="_blank"
                rel="noopener noreferrer"
                className="text-rose-400 transition-colors hover:text-rose-300"
              >
                Open Database License (ODbL)
              </a>
              . Open Food Facts is a nonprofit, community-maintained project and does not
              endorse Shrunk.
            </li>
            <li>
              <strong className="text-foreground">Shoppers</strong> — label photos and net-weight
              readings contributed through the app.
            </li>
            <li>
              Brand and product names are trademarks of their owners, used to identify products.
            </li>
          </ul>
        </Section>

        <Section title="Your choices">
          <ul className="list-disc space-y-3 pl-5 marker:text-rose-400">
            <li>
              <strong className="text-foreground">Stop everything:</strong> delete the app.
              Nothing further is sent.
            </li>
            <li>
              <strong className="text-foreground">Delete what is on the server:</strong> email us
              the Device ID shown in Settings → About → Device ID and we will erase the device
              record, your watchlist, your notification settings, and any submissions tied to it.
              Accepted size observations stay, because they are product facts and carry no
              identifier.
            </li>
            <li>
              <strong className="text-foreground">Turn off alerts:</strong> Settings →
              Notification preferences, or iOS Settings → Notifications → Shrunk.
            </li>
            <li>
              <strong className="text-foreground">Clear local scan history:</strong> Settings →
              Clear scan history.
            </li>
            <li>
              <strong className="text-foreground">Manage or cancel Pro:</strong> iOS Settings →
              your name → Subscriptions. Apple handles cancellations and refunds.
            </li>
          </ul>
        </Section>

        <Section title="Children">
          <p>
            Shrunk is not directed at children under 13 and we do not knowingly collect data from
            them. There is nothing in the app that asks for a name or an age.
          </p>
        </Section>

        <Section title="Security">
          <p>
            Everything travels over HTTPS. The API stores no credentials for you, because there
            are none. Our own service credentials live in encrypted secret storage, never in the
            app.
          </p>
        </Section>

        <Section title="Changes">
          <p>
            If this policy changes materially, we will update the date at the top and note the
            change in the app&apos;s release notes. The current version always lives at this URL.
          </p>
        </Section>

        <Section title="Contact">
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

function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-0.5 sm:flex-row sm:gap-3">
      <dt className="shrink-0 text-[11px] font-semibold uppercase tracking-wider text-muted/70 sm:w-20 sm:pt-1">
        {label}
      </dt>
      <dd className="text-muted">{value}</dd>
    </div>
  );
}

function Code({ children }: { children: React.ReactNode }) {
  return (
    <code className="rounded bg-surface px-1 py-0.5 text-xs text-foreground/80">{children}</code>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section>
      <h2 className="mb-4 text-lg font-semibold text-foreground">
        <span className="border-b-2 border-rose-400/40 pb-1">{title}</span>
      </h2>
      <div className="text-muted">{children}</div>
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
