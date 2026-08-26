import { Hono } from "hono";
import type { Env } from "./env";
import { productRoute } from "./routes/product";
import { observationsRoute } from "./routes/observations";
import { adminRoute } from "./routes/admin";
import { adminKrogerRoute } from "./routes/admin-kroger";
import { krogerRoute } from "./routes/kroger";

const app = new Hono<{ Bindings: Env }>();

app.get("/health", (c) => c.json({ ok: true }));
app.route("/", productRoute);
app.route("/", observationsRoute);
// Mount adminKrogerRoute before adminRoute: its local bearer check must run first
// so the purge keeps working even if the Phase 2 review page's middleware breaks.
app.route("/", adminKrogerRoute);
app.route("/", adminRoute);
app.route("/", krogerRoute);

export default app;
