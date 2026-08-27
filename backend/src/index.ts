import { Hono } from "hono";
import type { Env } from "./env";
import { productRoute } from "./routes/product";
import { observationsRoute } from "./routes/observations";
import { adminRoute } from "./routes/admin";
import { adminKrogerRoute } from "./routes/admin-kroger";
import { adminVerifiedRoute } from "./routes/admin-verified";
import { krogerRoute } from "./routes/kroger";
import { devicesRoute } from "./routes/devices";
import { feedRoute } from "./routes/feed";
import { appstoreRoute } from "./routes/appstore";

const app = new Hono<{ Bindings: Env }>();

app.get("/health", (c) => c.json({ ok: true }));
app.route("/", productRoute);
app.route("/", observationsRoute);
// Mount adminKrogerRoute and adminVerifiedRoute before adminRoute: their local bearer checks
// must run first so they keep working even if the Phase 2 review page's middleware breaks.
app.route("/", adminKrogerRoute);
app.route("/", adminVerifiedRoute);
app.route("/", adminRoute);
app.route("/", krogerRoute);
app.route("/", devicesRoute);
app.route("/", feedRoute);
app.route("/", appstoreRoute);

export default app;
