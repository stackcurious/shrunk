import type { MetadataRoute } from "next";
import { CASES } from "@/app/_lib/cases";

/**
 * Served at /shrunk/sitemap.xml because of the basePath, and the
 * stackcurious.com hub forwards /shrunk/* here — so every `url` below is the
 * absolute public address on stackcurious.com, not this app's own domain.
 */
export default function sitemap(): MetadataRoute.Sitemap {
  return [
    { url: "https://stackcurious.com/shrunk", lastModified: new Date() },
    {
      url: "https://stackcurious.com/shrunk/privacy",
      lastModified: new Date(),
    },
    {
      url: "https://stackcurious.com/shrunk/support",
      lastModified: new Date(),
    },
    { url: "https://stackcurious.com/shrunk/terms", lastModified: new Date() },
    {
      url: "https://stackcurious.com/shrunk/shrinkflation",
      lastModified: new Date(),
    },
    ...CASES.map((c) => ({
      url: `https://stackcurious.com/shrunk/shrinkflation/${c.slug}`,
      lastModified: new Date(c.added_at),
    })),
  ];
}
