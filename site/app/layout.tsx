import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { Analytics } from "@vercel/analytics/react";
import { SpeedInsights } from "@vercel/speed-insights/next";
import { APP_STORE_ID, SHRUNK_URL } from "./_lib/constants";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

const TITLE = "Shrunk — Catch shrinkflation before checkout";
const DESCRIPTION =
  "Scan supported grocery barcodes to check documented package-size changes, available current Kroger pricing, and better-value alternatives. Free to scan. Independent: no brand pays us.";

export const metadata: Metadata = {
  title: {
    default: TITLE,
    template: "%s | Shrunk",
  },
  description: DESCRIPTION,
  // The pages are served at stackcurious.com/shrunk/* through the parent zone's
  // rewrites. The `/shrunk` path is part of the base on purpose: Next resolves
  // file-based metadata images (opengraph-image) against metadataBase and does
  // NOT apply basePath to them, so a bare https://stackcurious.com base would
  // emit og:image=https://stackcurious.com/opengraph-image — a 404.
  metadataBase: new URL(SHRUNK_URL),
  keywords: [
    "shrinkflation",
    "shrinkflation scanner",
    "shrinkflation app",
    "shrinkflation examples",
    "grocery barcode scanner",
    "unit price calculator",
    "grocery savings app",
    "price tracker app",
  ],
  alternates: { canonical: SHRUNK_URL },
  itunes: { appId: APP_STORE_ID },
  icons: {
    icon: "/shrunk/app-icon.png",
    apple: "/shrunk/app-icon.png",
  },
  openGraph: {
    title: TITLE,
    description: DESCRIPTION,
    url: SHRUNK_URL,
    siteName: "Stack Curious",
    locale: "en_US",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: TITLE,
    description: DESCRIPTION,
  },
  robots: {
    index: true,
    follow: true,
  },
  // Google Search Console ownership (URL-prefix property https://stackcurious.com/),
  // inherited from the parent zone's root layout so these pages keep emitting it.
  verification: { google: "rHpF074yJ8NxoGCiPugik6gBD5Y7ASb3lt4XQ82i6_0" },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col" suppressHydrationWarning>
        {/* Shrunk is a mini-site: it carries its own nav and footer inside each
            page, so there is no studio chrome here — matching how the parent
            zone switched its Nav/Footer off for /shrunk. */}
        <main className="flex-1">{children}</main>
        {/* Page views. Custom funnel events go through lib/analytics.ts. */}
        <Analytics />
        <SpeedInsights />
      </body>
    </html>
  );
}
