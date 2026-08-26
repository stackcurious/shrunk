import { Hono } from "hono";
import type { Env } from "./env";
import { productRoute } from "./routes/product";
import { observationsRoute } from "./routes/observations";
import { adminRoute } from "./routes/admin";
import { krogerRoute } from "./routes/kroger";

const app = new Hono<{ Bindings: Env }>();

app.get("/health", (c) => c.json({ ok: true }));
app.route("/", productRoute);
app.route("/", observationsRoute);
app.route("/", adminRoute);
app.route("/", krogerRoute);

export default app;
