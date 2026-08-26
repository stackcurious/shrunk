import { Hono } from "hono";
import type { Env } from "../env";
import { buildFeed } from "../feed";

export const feedRoute = new Hono<{ Bindings: Env }>();

feedRoute.get("/v1/feed", async (c) => {
  const feed = await buildFeed(c.env, c.req.query("category") ?? null, Math.floor(Date.now() / 1000));
  c.header("Cache-Control", "public, max-age=300");
  return c.json(feed);
});
