# Shrunk — release readiness (2026-08-27)

Context: v2.0.0 (2) is on TestFlight for oakley801@gmail.com. User is testing. Meanwhile:

## A. Marketing site funnel + SEO (~/Projects/stackcurious, /shrunk/*)  — subagent
- [ ] Fix stale v1 copy (no "pay once"/"no subscription"); v2 pricing from docs/APP_STORE_LISTING.md
- [ ] Meta: per-page title/description/canonical, OG image (generated), twitter override, smart app banner (itunes appId 6805856154)
- [ ] JSON-LD: SoftwareApplication, FAQPage, BreadcrumbList, Organization
- [ ] Programmatic pages: /shrunk/shrinkflation (index) + /shrunk/shrinkflation/[slug] from data/trending.json (35 cases)
- [ ] Download CTA on every page → https://apps.apple.com/us/app/id6805856154
- [ ] sitemap.ts includes every shrunk route; `npm run build` + lint pass
- [ ] Review (Opus), push to main → Vercel deploy, verify live meta

## B. App Store Connect — ready for "Add for Review"  — me via ASC API
- [ ] Version record → 2.0.0, copyright
- [ ] Subtitle, promo text, keywords, description (+ subscription disclosure), support/marketing URLs
- [ ] App Review contact + notes
- [ ] Attach build bb3c0b75 (2.0.0/2)
- [ ] Subscriptions: review note + review screenshot → READY_TO_SUBMIT; group localization
- [ ] Six 6.9" screenshots (subagent captures via XCUITest) uploaded to en-US
- [ ] Final state check: every "missing" item enumerated

## C. Screenshots (1320×2868) — subagent
- [ ] ShrunkUITests target + `-ui-testing` overrides (Pro on, store preselected, fixture alerts)
- [ ] 01 result / 02 scan / 03 live price / 04 contribute / 05 alerts / 06 paywall → marketing/screenshots/v2/
- [ ] v1 screenshots deleted

## D. TestFlight build-2 feedback (spec docs/superpowers/specs/2026-08-27-scan-value-and-native-ui.md)
- [ ] Backend: on-miss lookup keeps FDC/OFF size as an observation (test first) — subagent, then deploy
- [ ] iOS wave 1: Watch outcome logic + single-snapshot / no-size Result states + live-size adoption (tests first) — subagent in worktree
- [ ] iOS wave 2: native HIG restyle (§3) — after wave 1 + screenshot agent land
- [ ] Retake screenshots on the restyled UI; build 2.0.0 (3) → TestFlight (oakley801)

## Review
(filled at the end)
