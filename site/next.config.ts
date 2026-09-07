import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  /* Every public URL is stackcurious.com/shrunk/*, served through the parent
     zone's rewrites (see ~/Projects/stackcurious/next.config.ts). The basePath
     makes this app own that prefix, so its routes, static chunks and next/link
     hrefs all line up with what the parent forwards.

     Consequences to remember when editing pages:
       - next/link hrefs are auto-prefixed → write them basePath-relative
         ("/privacy", "/shrinkflation/oreo-family-size").
       - next/image `src` and metadata.icons are NOT prefixed → keep them
         written out as "/shrunk/whatever.png".
       - plain <a href> is never prefixed, so a link that leaves the zone
         (the Stack Curious attribution) is written absolute. */
  basePath: "/shrunk",
  // This app is a lockfile island inside the Shrunk repo; without this, Next
  // walks up and infers ~/ as the workspace root.
  turbopack: { root: import.meta.dirname },
};

export default nextConfig;
