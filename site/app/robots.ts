import type { MetadataRoute } from "next";
import { SHRUNK_URL } from "./_lib/constants";

export default function robots(): MetadataRoute.Robots {
  return {
    rules: {
      userAgent: "*",
      allow: "/shrunk/",
    },
    sitemap: `${SHRUNK_URL}/sitemap.xml`,
  };
}
