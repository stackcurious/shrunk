# Shrunk — release readiness (2026-08-27)

Context: v2.0.0 (2) is on TestFlight for oakley801@gmail.com. User is testing. Meanwhile:

## A. Marketing site funnel + SEO (~/Projects/stackcurious, /shrunk/*)  — subagent
- [x] Fix stale v1 copy (no "pay once"/"no subscription"); v2 pricing from docs/APP_STORE_LISTING.md
- [x] Meta: per-page title/description/canonical, OG image (generated), twitter override, smart app banner (itunes appId 6805856154)
- [x] JSON-LD: SoftwareApplication, FAQPage, BreadcrumbList, Organization
- [x] Programmatic pages: /shrunk/shrinkflation (index) + /shrunk/shrinkflation/[slug] from data/trending.json (35 cases)
- [x] Download CTA on every page → https://apps.apple.com/us/app/id6805856154
- [x] sitemap.ts includes every shrunk route; `npm run build` + lint pass
- [x] Review (Opus) done; push BLOCKED by another session's unpushed shiftcheck work on stackcurious/main — goes live with the next push

## B. App Store Connect — ready for "Add for Review"  — me via ASC API
- [x] Version record → 2.0.0, copyright
- [x] Subtitle, promo text, keywords, description (+ subscription disclosure), support/marketing URLs
- [x] App Review contact + notes
- [x] Attach build bb3c0b75 (2.0.0/2)
- [x] Subscriptions: review note + review screenshot → READY_TO_SUBMIT; group localization
- [x] Six 6.9" screenshots uploaded to en-US (set f6a5cec3)
- [ ] Final state check: every "missing" item enumerated (after build 4 attaches)

## C. Screenshots (1320×2868) — subagent
- [x] ShrunkUITests target + `-ui-testing` overrides (Pro on, store preselected, fixture alerts)
- [x] 01 result / 02 scan / 03 live price / 04 contribute / 05 alerts / 06 paywall → marketing/screenshots/v2/
- [x] v1 screenshots deleted

## D. TestFlight build-2 feedback (spec docs/superpowers/specs/2026-08-27-scan-value-and-native-ui.md)
- [x] Backend: on-miss lookup keeps FDC/OFF size as an observation (test first) — subagent, then deploy
- [x] iOS wave 1: Watch outcome logic + single-snapshot / no-size Result states + live-size adoption (tests first) — subagent in worktree
- [x] iOS wave 2: native HIG restyle (§3) — after wave 1 + screenshot agent land
- [x] Retake screenshots on the restyled UI
- [x] Whole-app review (Opus) → fixes → re-review PASS; build 2.0.0 (3) uploaded
- [ ] Build 2.0.0 (4) with detector fix → TestFlight (oakley801) — in progress
- [x] Upload six 6.9" shots + paywall shot to ASC — all COMPLETE; both subscriptions READY_TO_SUBMIT
- [x] Curated catalogue re-verified from real sources → 25 cases, hit-rate 25/25; marketing cases.ts regenerated; detector run-collapse fix; prod orphan rows cleaned (user-approved)

## Review
- Root causes surfaced by testing the common path: Result screen built for the 1.5 % of products with a recorded size change; Watch silently no-op'd; on-miss lookup dropped sizes; FDC lookup leg ~90 % dead (gtinUpc spelling); normalizer comma/mixed/decimal-pack bugs (25 prod rows corrected); detector compared last two observations instead of size runs; curated catalogue was fabricated (fake barcodes, 404 sources) → re-verified to 25 real cases.
- UI: full native-HIG restyle (custom theme deleted), Dynamic Type AX5 verified, dark mode verified, 305 unit + 6 UI tests.
- User-owned decisions still open: Ohio vs Florida governing law; privacy@stackcurious.com mailbox; push of stackcurious/main (blocked by other session's work); Kroger secret rotation; acceptance run on device.
