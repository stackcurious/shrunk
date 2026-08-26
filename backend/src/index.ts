import { Hono } from "hono";
import type { Env } from "./env";
import { productRoute } from "./routes/product";
import { observationsRoute } from "./routes/observations";

const app = new Hono<{ Bindings: Env }>();

app.get("/health", (c) => c.json({ ok: true }));
app.route("/", productRoute);
app.route("/", observationsRoute);

export default app;
