import { Hono } from "hono";
import type { Env } from "./env";
import { productRoute } from "./routes/product";

const app = new Hono<{ Bindings: Env }>();

app.get("/health", (c) => c.json({ ok: true }));
app.route("/", productRoute);

export default app;
