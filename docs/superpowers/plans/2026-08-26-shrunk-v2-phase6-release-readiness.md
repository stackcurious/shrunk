# Shrunk v2 — Phase 6: Release Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the finished `feat/v2-real-data` branch into a submittable, maintainable 2.0.0 release — CI on every push, a monorepo a stranger (or a future session) can run and deploy from the docs alone, published privacy/terms/attribution copy that matches what the app actually stores, a correct App Store Connect record, the spec's acceptance run executed and recorded, and the branch merged and tagged.

**Architecture:** Phase 6 adds almost no product code. It adds (a) a GitHub Actions workflow with four independent jobs — `backend`, `scripts`, `fixtures`, `ios` — so every push proves the three toolchains still build; (b) one small Python script, `scripts/seed_curated.py`, that loads the curated catalogue into D1 as `source='curated'` observations, without which spec §10's "35/35 verdicts" is arithmetically impossible (FDC is food-only); (c) documentation — a monorepo README, a `CLAUDE.md` of conventions, a complete backend endpoint table, a privacy policy and terms matching the real data flows, and App Store paperwork; and (d) three operational runbooks — closing out the user-gated deploy/account steps left open by Phases 1–5, the acceptance run, and the PR/merge/tag.

**Tech Stack:** GitHub Actions (`ubuntu-latest` + `macos-latest`) · Node 20, TypeScript, Vitest 4 with `@cloudflare/vitest-pool-workers` · Python 3.12+ with pytest · Swift 5.9 / iOS 17 / XcodeGen / xcodebuild · Wrangler 4 (D1, R2, KV, Cron) · `gh` CLI 2.86.

**Spec:** `docs/superpowers/specs/2026-08-26-shrunk-v2-design.md` (§3 Free vs Pro, §5.2 curated source, §6.1 endpoint table, §9 Kroger terms and mitigations, §10 Testing / Acceptance before submission, §11 week 6, Appendix A).

**Prior plans this one closes out:**
- `docs/superpowers/plans/2026-08-26-shrunk-v2-week1-data-backbone.md` — Tasks 9 (deploy + FDC import), 12 Step 3 (base-URL substitution), 13 (hit-rate run), 14 (APNs spike), 15 (Kroger account + permission email).
- `docs/superpowers/plans/2026-08-26-shrunk-v2-phase3-kroger-live-layer.md` — Task 11 (KV namespace, Kroger secrets, deploy).
- `docs/superpowers/plans/2026-08-26-shrunk-v2-phase4-push-devices-crons.md` — Task 10 (APNs key, push secrets, three crons deployed).
- `docs/superpowers/plans/2026-08-26-shrunk-v2-phase5-subscription-onboarding-dashboard.md` — Task 12 (ASC subscription group, intro offer, Server Notifications URL).

## Global Constraints

- **Version:** this release is `MARKETING_VERSION: "2.0.0"`, `CURRENT_PROJECT_VERSION: "2"`, git tag `v2.0.0`.
- **Pricing (spec §2, verbatim):** auto-renewable subscription, `com.shrunk.pro.monthly` **$2.99** and `com.shrunk.pro.yearly` **$14.99** with a **7-day introductory free trial**. The `com.shrunk.pro.lifetime` non-consumable is removed. Every piece of copy written in this phase uses exactly these products and prices.
- **Free vs Pro (spec §3, verbatim):** Free = unlimited scans → verdict, size history (FDC/curated/crowd/Kroger), current price and cost-per-unit at the user's Kroger store; browse feed; contribute label photos; 3 alternatives per scan. Pro = watchlist alerts; weekly "what shrank this week" digest; unlimited ranked alternatives at the user's store; price + size history charts (free sees the latest before/after only); real savings dashboard.
- **Attribution (spec §6.6, §9):** the string is exactly `"Prices from Kroger"`, shown wherever Kroger data appears. USDA FoodData Central and Open Food Facts (ODbL) are credited in the app, the privacy policy and the App Store listing.
- **Acceptance thresholds (spec §10, verbatim):** "scanning all 35 curated products yields a verdict for 35/35; a 30-item kitchen scan yields history for ≥60% of food items; a Kroger store set in Cincinnati shows live prices for ≥25 of those 30."
- **Barcodes** are 13-digit zero-padded GTINs. **US only.** iOS 17+, Swift 5.9.
- `project.yml` is the source of truth for the Xcode project; `Shrunk.xcodeproj` is git-ignored and regenerated with `xcodegen generate`.
- Worker tests: `cd backend && npx vitest run` (Vitest 4 + `cloudflareTest` plugin). Outbound HTTP is stubbed with `vi.stubGlobal("fetch", …)` + `vi.unstubAllGlobals()` — **`fetchMock` from `cloudflare:test` does not exist in this toolchain.**
- **No secrets in the repo, ever.** `.p8` keys, Kroger credentials, FDC keys and service-account JSON live in `wrangler secret put` and the git-ignored `backend/.dev.vars`. `.gitignore` already covers `*.p8`, `*.p12`, `*.mobileprovision`.
- **Commit by pathspec** (`tasks/lessons.md`): `git add <explicit paths>` then `git commit -m "…" -- <the same paths>`. Never `git add -A`, never a bare `git commit`.
- Commit after every task. Nothing in this phase force-pushes, rebases, stashes or resets.

## File Structure

```
.github/workflows/ci.yml                     NEW  four jobs: backend, scripts, fixtures, ios
scripts/check_repo_data.py                   NEW  cross-directory data invariants CI enforces
scripts/tests/test_check_repo_data.py        NEW
scripts/seed_curated.py                      NEW  data/trending.json -> curated observations SQL
scripts/tests/test_seed_curated.py           NEW
scripts/tests/test_hit_rate.py               NEW  covers the verdict() duplicate collapse
scripts/hit_rate.py                          MOD  collapse consecutive same-size observations (spec §5.1)
scripts/fdc/importer.py                      MOD  Product gains image_url (default None)
scripts/acceptance.md                        NEW  spec §10 acceptance run: procedure + results tables
Shrunk/Services/ShrinkDetector.swift         MOD  same duplicate-size collapse as hit_rate.py (spec §5.1)
ShrunkTests/ShrinkDetectorTests.swift        MOD  pins the duplicate-size collapse
README.md                                    REWRITE  monorepo map, run, deploy, data flow, CI
CLAUDE.md                                    NEW  conventions for future sessions
backend/README.md                            REWRITE  complete endpoint/binding/secret/cron tables
data/README.md                               MOD  /v1/feed is the live path; three copies of trending.json
docs/PRIVACY_POLICY.md                       NEW  publish at stackcurious.com/shrunk/privacy
docs/TERMS.md                                NEW  publish at stackcurious.com/shrunk/terms
docs/APP_STORE_LISTING.md                    REWRITE  v2 copy, subscription disclosure, screenshot list
docs/ASC_SETUP.md                            MOD  §1 push capability, §4 App Privacy, §5, §6, export compliance, checklist
docs/RELEASE_CHECKLIST.md                    NEW  the user-gated deploy/account runbook carried over from phases 1-5
ExportOptions.plist                          NEW  App Store export options for xcodebuild -exportArchive
Shrunk/Features/Settings/SettingsView.swift  MOD  data-source attribution card (spec §9)
project.yml                                  MOD  MARKETING_VERSION 2.0.0, CURRENT_PROJECT_VERSION 2
docs/superpowers/specs/…-shrunk-v2-design.md MOD  evidence lines: §6.5 spike, §9 email date, §10 acceptance results
```

---

### Task 0: Confirm Phases 3–5 have landed

This plan assumes `feat/v2-real-data` already has `GET /v1/feed`, push infrastructure and its three cron triggers, `POST /v1/admin/verified-case`, `POST /v1/appstore/notifications`, and the subscription rework of `StoreKitService` / `docs/ASC_SETUP.md` §2 — Phase 4 and Phase 5 work. Every other task in this plan writes CI, docs, an App Store listing, a curated seeder, or an acceptance run against that surface; running ahead of it produces CI that is green for the wrong reasons and paperwork describing a build that cannot do what it claims. Task 3 Step 1 and Task 6 Step 1 already check their own narrower slice of this before writing; this task is the same check, once, for everything the other eight tasks assume without checking.

**Files:** none — this task only runs commands.

- [ ] **Step 1: Check every Phase 3–5 artifact this plan depends on**

```bash
cd /Users/drao/Projects/shrunk
grep -q feedRoute backend/src/index.ts \
  && echo "ok   GET /v1/feed mounted (Phase 4)" \
  || echo "MISS GET /v1/feed not mounted — land Phase 4 first"
ls backend/src/push/PushSender.ts >/dev/null 2>&1 \
  && echo "ok   push sender exists (Phase 4)" \
  || echo "MISS backend/src/push/PushSender.ts missing — land Phase 4 first"
grep -n "^crons" backend/wrangler.toml
grep -rq "admin/verified-case" backend/src/routes \
  && echo "ok   POST /v1/admin/verified-case (Phase 4)" \
  || echo "MISS /v1/admin/verified-case — land Phase 4 first"
grep -rq "appstore/notifications" backend/src \
  && echo "ok   POST /v1/appstore/notifications (Phase 5)" \
  || echo "MISS /v1/appstore/notifications — land Phase 5 first"
if grep -q "pro.lifetime" Shrunk/Services/StoreKitService.swift; then
  echo "MISS StoreKitService still sells com.shrunk.pro.lifetime — land Phase 5 first"
else
  echo "ok   no lifetime IAP (Phase 5)"
fi
grep -q "pro.yearly\|pro.monthly" Shrunk/Services/StoreKitService.swift \
  && echo "ok   subscription products present (Phase 5)" \
  || echo "MISS StoreKitService has no subscription products — land Phase 5 first"
grep -n "^## 2\." docs/ASC_SETUP.md
```

Expected: every scripted line prints `ok`; the `crons` line lists three schedules — `*/5 * * * *` (alert drain), `0 */6 * * *` (Kroger sweep), `0 1 * * 1` (weekly digest); `## 2.` reads `## 2. Subscriptions`, not `## 2. In-App Purchase`. **Any `MISS`, fewer than three crons, or `## 2. In-App Purchase` means a prior phase has not landed — stop and land it (see "Prior plans this one closes out" above) before starting Task 1.** Re-run this whenever picking the plan back up after a gap; the branch may have moved since you last checked.

---

### Task 1: CI on every push

**Precondition:** Task 0 passed. If it did not, stop and land the missing phase before starting this task.

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `scripts/check_repo_data.py`
- Test: `scripts/tests/test_check_repo_data.py`

**Interfaces:**
- Produces: `check(root: Path) -> list[str]` in `scripts/check_repo_data.py` — a list of human-readable problems, empty when the repo is consistent. CLI `python3 scripts/check_repo_data.py` prints each problem prefixed `FAIL: ` and exits 1 when the list is non-empty.
- Produces: a workflow named `CI` with exactly four job ids — `backend`, `scripts`, `fixtures`, `ios`. **Those four strings are the status-check context names** used by branch protection here and by the merge gate in Task 11. Renaming a job breaks both.

- [ ] **Step 1: Write the failing test**

`scripts/tests/test_check_repo_data.py`:

```python
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_repo_data import check  # noqa: E402

FIXTURES = [
    {"input": f"{n} g", "quantity": float(n), "unit_kind": "mass", "note": "generated"}
    for n in range(1, 29)
]
FEED = {
    "version": 1,
    "trending": [{"barcode": f"{i:013d}", "name": f"Product {i}"} for i in range(35)],
}


def build(tmp: Path, *, fixtures=None, feed=None, copies=None) -> Path:
    (tmp / "fixtures").mkdir()
    (tmp / "fixtures" / "package_weights.json").write_text(
        json.dumps(FIXTURES if fixtures is None else fixtures)
    )
    (tmp / "data").mkdir()
    (tmp / "data" / "trending.json").write_text(json.dumps(FEED if feed is None else feed))
    for rel, body in (copies or {}).items():
        path = tmp / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(body))
    return tmp


def test_consistent_repo_reports_no_problems(tmp_path):
    root = build(tmp_path, copies={
        "Shrunk/Resources/trending.json": FEED,
        "backend/src/data/trending.json": FEED,
    })
    assert check(root) == []


def test_an_absent_copy_is_not_a_problem(tmp_path):
    # backend/src/data/trending.json only exists once Phase 4 has landed.
    root = build(tmp_path, copies={"Shrunk/Resources/trending.json": FEED})
    assert check(root) == []


def test_a_drifted_copy_is_reported(tmp_path):
    drifted = {"version": 1, "trending": FEED["trending"][:34]}
    root = build(tmp_path, copies={
        "Shrunk/Resources/trending.json": drifted,
        "backend/src/data/trending.json": FEED,
    })
    problems = check(root)
    assert len(problems) == 1
    assert "Shrunk/Resources/trending.json" in problems[0]


def test_unparseable_fixtures_are_reported(tmp_path):
    root = build(tmp_path)
    (root / "fixtures" / "package_weights.json").write_text("{not json")
    assert any("package_weights.json" in p and "parse" in p for p in check(root))


def test_a_short_curated_catalogue_is_reported(tmp_path):
    root = build(tmp_path, feed={"version": 1, "trending": FEED["trending"][:34]})
    assert any("34" in p and "35" in p for p in check(root))


def test_an_unknown_unit_kind_is_reported(tmp_path):
    bad = FIXTURES + [{"input": "3 furlongs", "quantity": 3.0, "unit_kind": "length", "note": "bogus"}]
    root = build(tmp_path, fixtures=bad)
    assert any("unit_kind" in p for p in check(root))
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/drao/Projects/shrunk/scripts && python3 -m pytest tests/test_check_repo_data.py -q
```
Expected: collection error — `ModuleNotFoundError: No module named 'check_repo_data'`.

- [ ] **Step 3: Write the checker**

`scripts/check_repo_data.py`:

```python
#!/usr/bin/env python3
"""Repo-wide data invariants that CI enforces on every push.

Two things no unit test can see, because they span directories:

1. `fixtures/package_weights.json` — the single normalizer fixture file shared
   by the Python importer, the Worker and the iOS app — parses, is non-trivial,
   and uses only unit kinds all three implementations agree on.
2. Every copy of the curated catalogue is identical to the canonical
   `data/trending.json`: `Shrunk/Resources/trending.json` (the app's offline
   fallback) and `backend/src/data/trending.json` (the copy the Worker bundles
   for `GET /v1/feed`).
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

MIN_FIXTURES = 28
MIN_CURATED = 35
UNIT_KINDS = {"mass", "volume", "count", None}
FEED_COPIES = ("Shrunk/Resources/trending.json", "backend/src/data/trending.json")


def _load(path: Path) -> tuple[object | None, str | None]:
    try:
        return json.loads(path.read_text()), None
    except FileNotFoundError:
        return None, f"{path} is missing"
    except json.JSONDecodeError as exc:
        return None, f"{path} does not parse as JSON: {exc}"


def check(root: Path) -> list[str]:
    """Return a list of problems. Empty means the repo is consistent."""
    problems: list[str] = []

    fixtures, err = _load(root / "fixtures" / "package_weights.json")
    if err:
        problems.append(err)
    elif not isinstance(fixtures, list):
        problems.append("fixtures/package_weights.json must be a JSON array of cases")
    else:
        if len(fixtures) < MIN_FIXTURES:
            problems.append(
                f"fixtures/package_weights.json has {len(fixtures)} cases, "
                f"expected at least {MIN_FIXTURES}"
            )
        for case in fixtures:
            if not isinstance(case, dict) or "input" not in case:
                problems.append(f"fixture case without an 'input' key: {case!r}")
                continue
            if case.get("unit_kind") not in UNIT_KINDS:
                problems.append(
                    f"fixture {case['input']!r} has unit_kind {case.get('unit_kind')!r}; "
                    "expected mass, volume, count or null"
                )

    canonical, err = _load(root / "data" / "trending.json")
    if err:
        problems.append(err)
        return problems

    entries = canonical.get("trending") if isinstance(canonical, dict) else None
    if not isinstance(entries, list):
        problems.append("data/trending.json has no 'trending' array")
    elif len(entries) < MIN_CURATED:
        problems.append(
            f"data/trending.json has {len(entries)} curated entries, "
            f"expected at least {MIN_CURATED}"
        )

    for rel in FEED_COPIES:
        copy = root / rel
        if not copy.exists():
            continue  # the Worker copy only exists once Phase 4 has landed
        body, err = _load(copy)
        if err:
            problems.append(err)
        elif body != canonical:
            problems.append(
                f"{rel} has drifted from data/trending.json — re-copy it "
                "(`cp data/trending.json Shrunk/Resources/trending.json`, "
                "`cd backend && npm run sync:trending`)"
            )

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description="Check repo-wide data invariants.")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()

    problems = check(args.root)
    for problem in problems:
        print(f"FAIL: {problem}")
    if problems:
        return 1
    print("repo data OK: normalizer fixtures and every curated-feed copy are consistent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Run the tests to verify they pass, then run the checker for real**

```bash
cd /Users/drao/Projects/shrunk/scripts && python3 -m pytest tests -q
cd /Users/drao/Projects/shrunk && python3 scripts/check_repo_data.py
```
Expected: every pytest passes (46 existing + 6 new), then `repo data OK: …`. If the checker reports drift in `Shrunk/Resources/trending.json`, fix the drift with the command in the message — do not relax the check.

- [ ] **Step 5: Write the workflow**

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: ["**"]

concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  backend:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: npm
          cache-dependency-path: backend/package-lock.json
      - name: Install dependencies
        run: npm ci
      - name: Typecheck
        run: npx tsc --noEmit
      - name: Unit tests (Workers runtime)
        run: npx vitest run

  scripts:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - name: Install pytest
        run: pip install pytest
      - name: Importer, normalizer and tooling tests
        run: python -m pytest tests -q
        working-directory: scripts

  fixtures:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - name: Fixture and curated-catalogue integrity
        run: python3 scripts/check_repo_data.py

  ios:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install XcodeGen
        run: brew install xcodegen
      - name: Generate Shrunk.xcodeproj
        run: xcodegen generate
      - name: Choose an available iPhone simulator
        run: |
          set -eu
          xcodebuild -version
          DEVICES="$(xcrun simctl list devices available)"
          echo "$DEVICES"
          NAME="$(printf '%s\n' "$DEVICES" \
            | sed -n 's/^ *\(.*iPhone[^(]*[^ (]\) *(.*/\1/p' \
            | head -n 1)"
          if [ -z "$NAME" ]; then
            echo "::error::no available iPhone simulator on this runner"
            exit 1
          fi
          echo "SIMULATOR_NAME=$NAME" >> "$GITHUB_ENV"
          echo "Using simulator: $NAME"
      - name: Build
        run: |
          xcodebuild build \
            -scheme Shrunk \
            -destination 'generic/platform=iOS Simulator' \
            CODE_SIGNING_ALLOWED=NO \
            -quiet
      - name: Unit tests
        run: |
          xcodebuild test \
            -scheme Shrunk \
            -destination "platform=iOS Simulator,name=$SIMULATOR_NAME" \
            CODE_SIGNING_ALLOWED=NO \
            -quiet
```

Notes for whoever touches this again:
- No `pull_request:` trigger, deliberately: this is a single-repo workflow (no forks), and `push: branches: ["**"]` already runs on every commit to an open PR's branch. Adding `pull_request:` alongside it would double-run every job on every push to a PR branch — a `push` event carries `github.ref = refs/heads/<branch>` while the matching `pull_request` event carries `github.ref = refs/pull/<n>/merge`, so the `concurrency` group below would not dedupe them. GitHub's required-status-checks UI reads status from push-triggered runs on the head branch fine.
- `Shrunk.xcodeproj` is git-ignored, so `xcodegen generate` is mandatory before any `xcodebuild` call.
- `CODE_SIGNING_ALLOWED=NO` is what lets a runner with no certificates build the app and its test host; the simulator SDK needs no provisioning profile, and the `aps-environment` entitlement is inert there.
- The simulator name is discovered rather than hard-coded because GitHub rotates runner images; locally the destination is `platform=iOS Simulator,name=BabSnap iPhone 17`.
- The `sed` matches the **first device whose name contains `iPhone`**, not only Apple's default names — that way the same expression works on a runner (`iPhone 16 Pro`) and on a machine with renamed simulators (`BabSnap iPhone 17`). Verify it before trusting it: `xcrun simctl list devices available | sed -n 's/^ *\(.*iPhone[^(]*[^ (]\) *(.*/\1/p' | head -1`.
- `set -eu` without `pipefail` is deliberate: `sed … | head -n 1` closes the pipe early and `pipefail` would turn that into a spurious failure.

- [ ] **Step 6: Dry-run every job's commands locally**

```bash
cd /Users/drao/Projects/shrunk/backend && npm ci && npx tsc --noEmit && npx vitest run
cd /Users/drao/Projects/shrunk/scripts && python3 -m pytest tests -q
cd /Users/drao/Projects/shrunk && python3 scripts/check_repo_data.py
cd /Users/drao/Projects/shrunk && xcodegen generate >/dev/null && \
  xcodebuild build -scheme Shrunk -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' CODE_SIGNING_ALLOWED=NO -quiet
```
Expected: all four green. Anything failing here fails on the runner too — fix it before pushing.

- [ ] **Step 7: Commit and push, then watch the first run**

```bash
cd /Users/drao/Projects/shrunk
git add .github/workflows/ci.yml scripts/check_repo_data.py scripts/tests/test_check_repo_data.py
git commit -m "ci: backend, scripts, fixtures and iOS jobs on every push" -- \
  .github/workflows/ci.yml scripts/check_repo_data.py scripts/tests/test_check_repo_data.py
git push origin feat/v2-real-data
gh run watch --exit-status
```
Expected: four jobs, all green. `gh run watch` exits non-zero if any job fails — read the log with `gh run view --log-failed`.

- [ ] **Step 8: Require the four checks on `main` (manual, one-time)**

```bash
gh api -X PUT repos/stackcurious/shrunk/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["backend", "scripts", "fixtures", "ios"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```

Expected: a JSON body echoing the protection rule. If it returns `403 Upgrade to GitHub Pro`, the repo is private on the Free plan and branch protection is unavailable — skip it; Task 11 still refuses to merge until the PR's own checks are green. The equivalent web path is Settings → Branches → Add branch protection rule → Branch name pattern `main` → *Require status checks to pass before merging* → tick `backend`, `scripts`, `fixtures`, `ios`.

Record the outcome (protected / not available) in `docs/RELEASE_CHECKLIST.md` when Task 8 creates it.

---

### Task 2: Monorepo README and a CLAUDE.md of conventions

**Precondition:** Task 0 passed. If it did not, stop and land the missing phase before starting this task.

**Files:**
- Modify: `README.md` (full rewrite — the current text describes the v1 OFF-only app and a $9.99 lifetime IAP)
- Create: `CLAUDE.md` (repo root)

**Interfaces:**
- Consumes: the job ids from Task 1 (`backend`, `scripts`, `fixtures`, `ios`).
- Produces: nothing code-level. Later tasks link to these two files from `backend/README.md`, `data/README.md` and the PR body.

- [ ] **Step 1: Rewrite `README.md`**

Replace the entire file with:

````markdown
# Shrunk

Scan a grocery barcode; Shrunk tells you whether the package shrank while the price held — from observed size and price data, not vibes.

- **Free** — unlimited scans → verdict, size history, current price and cost-per-unit at your Kroger store; the browse feed; contributing label photos; 3 alternatives per scan.
- **Pro** — $2.99/month or $14.99/year with a 7-day free trial: watchlist alerts, the weekly "what shrank this week" digest, unlimited ranked alternatives, full price + size history charts, and a savings dashboard computed from real observations.

## Layout

| Path | What it is |
|---|---|
| `Shrunk/` | The iOS app — SwiftUI, iOS 17+, SwiftData, StoreKit 2, Vision OCR. |
| `ShrunkTests/` | XCTest unit tests for the app. |
| `backend/` | `shrunk-api` — the Cloudflare Worker (Hono 4) over D1 + R2 + KV. Every endpoint the app calls. |
| `scripts/` | Python 3.12+ tooling: the USDA FoodData Central importer, the curated seeder, the hit-rate report, repo-data checks. |
| `fixtures/` | `package_weights.json` — the one normalizer fixture file shared by Python, TypeScript and Swift. |
| `data/` | `trending.json` — the curated, human-verified shrinkflation catalogue. See [data/README.md](./data/README.md). |
| `docs/` | The v2 spec and phase plans (`docs/superpowers/`), App Store paperwork, privacy policy, terms. |
| `marketing/` | App Store screenshots. |
| `tasks/` | Session notes and `lessons.md`. |

`project.yml` is the source of truth for the Xcode project. `Shrunk.xcodeproj` is generated and **not** committed.

## Run it

### iOS app

```bash
brew install xcodegen
xcodegen generate
open Shrunk.xcodeproj          # or: xcodebuild build -scheme Shrunk -destination 'generic/platform=iOS Simulator'
```

Tests (substitute a simulator from `xcrun simctl list devices available`):

```bash
xcodegen generate && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17'
```

The app's base URL lives in `Shrunk/Services/ShrunkAPIClient.swift`. Point it at `http://localhost:8787` to run against a local Worker (`NSAllowsLocalNetworking` is already set in `Info.plist`).

### Worker

```bash
cd backend
npm ci
npm run dev            # http://localhost:8787, needs backend/.dev.vars
npm test               # Vitest 4 in the Workers runtime, migrations applied
npm run typecheck
```

See [backend/README.md](./backend/README.md) for the endpoint table, bindings, secrets and cron schedule.

### Python tooling

```bash
cd scripts
python3 -m pytest tests -q

# Reload USDA FoodData Central (twice a year, on each release):
python3 fdc_import.py --zip /tmp/fdc_branded.zip --out out/fdc.sql \
  --report out/report.json --curated ../data/trending.json

# Seed the curated catalogue as source='curated' observations:
python3 seed_curated.py --curated ../data/trending.json --out out/curated.sql

# Coverage of the deployed API over the curated 35:
python3 hit_rate.py --api https://shrunk-api.<account>.workers.dev
```

## How the data flows

```
data/trending.json ──cp──────────────▶ Shrunk/Resources/trending.json   (app offline fallback)
        │
        ├──npm run sync:trending─────▶ backend/src/data/trending.json ──▶ GET /v1/feed
        │
        └──scripts/seed_curated.py───▶ SQL ──wrangler d1 execute──▶ D1 observations (source='curated', 1.0)

USDA FDC release zip ──scripts/fdc_import.py──▶ SQL ──wrangler d1 execute──▶ D1 products + observations (source='fdc', 0.9)

label photo ──Vision OCR on device──▶ POST /v1/observations ──▶ D1 (source='crowd') + R2 photo while pending review

Kroger Products API ──Worker proxy──▶ live size/price ──(KROGER_PERSIST=on)──▶ price_snapshots + observations (source='kroger', 0.8)

iOS app ──GET /v1/product/{gtin}?locationId=──▶ merged accepted observations + last 12 snapshots
        └──ShrinkDetector──▶ verdict, size history, cost-per-unit then/now
```

Quantities are normalized to grams, millilitres or count before storage; observations of different kinds are never compared.

## Deploy

```bash
cd backend
npx wrangler d1 migrations apply shrunk --remote
npx wrangler deploy
```

Full first-time setup — Cloudflare account, D1, KV, R2, every secret, the Kroger and Apple accounts — is in [docs/RELEASE_CHECKLIST.md](./docs/RELEASE_CHECKLIST.md).

## CI

`.github/workflows/ci.yml` runs on every push — including every push to an open PR's branch, so there is no separate `pull_request` trigger to double it up:

| Job | Runner | What it proves |
|---|---|---|
| `backend` | ubuntu | `npm ci`, `tsc --noEmit`, `vitest run` |
| `scripts` | ubuntu | `pytest` over the importer, normalizers and tooling |
| `fixtures` | ubuntu | `scripts/check_repo_data.py` — fixtures parse, every `trending.json` copy is in sync |
| `ios` | macOS | `xcodegen generate`, `xcodebuild build`, `xcodebuild test` on a discovered simulator |

## Docs

- Design spec: [`docs/superpowers/specs/2026-08-26-shrunk-v2-design.md`](./docs/superpowers/specs/2026-08-26-shrunk-v2-design.md)
- Phase plans: [`docs/superpowers/plans/`](./docs/superpowers/plans/)
- Release runbook: [`docs/RELEASE_CHECKLIST.md`](./docs/RELEASE_CHECKLIST.md) · Acceptance run: [`scripts/acceptance.md`](./scripts/acceptance.md)
- App Store: [`docs/APP_STORE_LISTING.md`](./docs/APP_STORE_LISTING.md) · [`docs/ASC_SETUP.md`](./docs/ASC_SETUP.md)
- Legal: [`docs/PRIVACY_POLICY.md`](./docs/PRIVACY_POLICY.md) · [`docs/TERMS.md`](./docs/TERMS.md)

## Data sources and attribution

- **USDA FoodData Central**, Branded Foods — public domain. The size-history backbone.
- **Kroger Products API** — live store prices and sizes, shown with "Prices from Kroger".
- **Open Food Facts** — product name and image fallback, licensed ODbL.
- **Shoppers** — label photos contributed through the app.

## License

Code: all rights reserved (for now).
`data/trending.json`: CC-BY-4.0 — facts are facts; attribute the curation if you reuse it.
````

- [ ] **Step 2: Write `CLAUDE.md`**

`CLAUDE.md` at the repo root:

```markdown
# Shrunk — working notes for future sessions

Read `docs/superpowers/specs/2026-08-26-shrunk-v2-design.md` first. It is the binding design; the phase plans in `docs/superpowers/plans/` argue from it and record how each slice was built.

## Commands

| What | Command |
|---|---|
| iOS build | `xcodegen generate && xcodebuild build -scheme Shrunk -destination 'generic/platform=iOS Simulator' -quiet` |
| iOS tests | `xcodegen generate && xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet` |
| Worker tests | `cd backend && npx vitest run` |
| Worker typecheck | `cd backend && npx tsc --noEmit` |
| Python tests | `cd scripts && python3 -m pytest tests -q` |
| Repo data check | `python3 scripts/check_repo_data.py` |
| Worker deploy | `cd backend && npx wrangler d1 migrations apply shrunk --remote && npx wrangler deploy` |

`BabSnap iPhone 17` is this machine's simulator; CI discovers one with `xcrun simctl list devices available`. Substitute whatever you have.

## Conventions

- **XcodeGen is the source of truth.** Edit `project.yml`, never `Shrunk.xcodeproj` (it is git-ignored). Run `xcodegen generate` after adding, removing or renaming any Swift file or target setting; a `cannot find 'X' in scope` error is almost always a missed regenerate.
- **Commit by pathspec.** `git add <explicit paths>` then `git commit -m "…" -- <the same paths>`. Never `git add -A`, never a bare `git commit` — concurrent agents share one index and a bare commit sweeps someone else's staged work (see `tasks/lessons.md`).
- **Never `git stash`, `checkout` or `reset`** in a shared worktree.
- **Worker tests stub `fetch` with `vi.stubGlobal("fetch", vi.fn(...))` plus `afterEach(() => vi.unstubAllGlobals())`.** `fetchMock` from `cloudflare:test` does not exist in this toolchain. D1 and KV bindings are real in tests; cron handlers are tested by calling `runAlertDrain` / `runWeeklyDigest` / `runKrogerSweep` directly with `env`.
- **One normalizer, three implementations.** `scripts/fdc/normalize.py`, `backend/src/normalize.ts` and `Shrunk/Features/Contribute/NetContentParser.swift` must agree on `fixtures/package_weights.json`. Add a case there first, then make all three pass it.
- **GTINs are 13-digit zero-padded** everywhere — storage, API, app.
- **Quantities are normalized** to grams / millilitres / count with `unit_kind ∈ {mass, volume, count}`. Never compare across kinds.
- **No secrets in the repo.** `wrangler secret put` for the Worker, `backend/.dev.vars` (git-ignored) for local dev, `~/keys/` for `.p8` files.
- **Curated catalogue lives in three places** — `data/trending.json` (canonical), `Shrunk/Resources/trending.json` (app offline fallback), `backend/src/data/trending.json` (bundled into `/v1/feed`). CI fails when they drift; re-sync with `cp` and `cd backend && npm run sync:trending`.

## Where things live

- Spec: `docs/superpowers/specs/2026-08-26-shrunk-v2-design.md`
- Phase plans (1 = week1-data-backbone, then phase2…phase6): `docs/superpowers/plans/`
- Execution ledgers from subagent-driven runs: `.superpowers/sdd/<plan-name>/progress.md` (git-ignored, scratch)
- Corrections worth not repeating: `tasks/lessons.md`
- Release runbook: `docs/RELEASE_CHECKLIST.md`; acceptance run: `scripts/acceptance.md`

## Things that are deliberately gone

`OpenFoodFactsService`, `UPCItemDBService`, `SavingsForecast`, the 10-screen quiz onboarding and its "$/yr exposure" reveal, and the `com.shrunk.pro.lifetime` non-consumable. Do not reintroduce them; the spec explains why (§1, §3).
```

- [ ] **Step 3: Check every link resolves**

```bash
cd /Users/drao/Projects/shrunk
for f in data/README.md backend/README.md docs/superpowers/specs/2026-08-26-shrunk-v2-design.md \
         docs/APP_STORE_LISTING.md docs/ASC_SETUP.md tasks/lessons.md project.yml; do
  test -e "$f" && echo "ok   $f" || echo "MISS $f"
done
```
Expected: all `ok`. `docs/RELEASE_CHECKLIST.md`, `docs/PRIVACY_POLICY.md`, `docs/TERMS.md` and `scripts/acceptance.md` are created in Tasks 4, 5, 8 and 9 — they will be `MISS` until then, which is fine as long as those tasks land before Task 11.

- [ ] **Step 4: Commit**

```bash
cd /Users/drao/Projects/shrunk
git add README.md CLAUDE.md
git commit -m "docs: monorepo README and CLAUDE.md conventions" -- README.md CLAUDE.md
```

---

### Task 3: Complete `backend/README.md` and correct `data/README.md`

**Files:**
- Modify: `backend/README.md` (full rewrite — it lists five of the twelve endpoints)
- Modify: `data/README.md` (the "Deployment" section still describes jsDelivr as the live feed; Phase 4 moved the app to `GET /v1/feed`)

**Interfaces:**
- Consumes: the endpoint set from spec §6.1 plus the admin routes Phases 2–4 added (`/v1/admin/photo/:id`, `/v1/admin/verified-case`).
- Produces: the canonical endpoint/binding/secret/cron reference the release checklist and PR body point at.

- [ ] **Step 1: Verify the endpoint list against the code before writing it down**

```bash
cd /Users/drao/Projects/shrunk/backend
grep -rn "app.route\|\.get(\|\.post(" src/index.ts
ls src/routes
grep -n "crons" wrangler.toml
grep -n "" src/env.ts | head -40
```
Expected: routes for product, feed, kroger, observations, devices, admin, admin-kroger, appstore. Anything in `src/routes` that is not in the table below must be added to it; anything in the table that does not exist yet belongs to a phase that has not landed — stop and land it first.

- [ ] **Step 2: Rewrite `backend/README.md`**

````markdown
# shrunk-api

The Cloudflare Worker behind the Shrunk iOS app: Hono 4 on Workers, D1 for owned data, R2 for label photos awaiting review, KV for the Kroger OAuth token and rate-limit counters.

## Endpoints

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/health` | — | `{"ok":true}`. |
| GET | `/v1/product/:gtin?locationId=` | — | Product identity, every **accepted** observation merged across sources, and the last 12 `price_snapshots` for `locationId`. Creates unknown products from the FDC API, then Open Food Facts. Sets `needs_confirmation` when the live Kroger size disagrees with the latest non-Kroger observation. |
| GET | `/v1/feed?category=` | — | The curated catalogue merged with accepted shrink observations from the last 30 days. |
| GET | `/v1/kroger/locations?zip=` | — | Proxy to Kroger Locations, `filter.radiusInMiles=15`, `limit=20`. |
| GET | `/v1/kroger/product/:gtin?locationId=` | — | Proxy; forwards Kroger's `Cache-Control`; writes a snapshot (and an observation when the size parses) while `KROGER_PERSIST="on"`. |
| GET | `/v1/kroger/search?term=&locationId=` | — | Proxy for alternatives, ranked by per-unit price server-side. **Never persisted.** |
| POST | `/v1/observations` | — | Crowd submission (multipart: gtin, quantity, unit_kind, raw_text, confidence, optional photo). Applies the confidence gate; returns `accepted` or `pending`. |
| POST | `/v1/devices` | — | Upserts the device row: APNs token, `location_id`, categories, watches, notification prefs, and the App Store transaction JWS that sets `pro_until`. |
| POST | `/v1/appstore/notifications` | Apple's signature | App Store Server Notifications V2. Verified against a pinned Apple Root CA - G3; answers `401 {"error":"invalid_signature"}` to anything unverifiable. No shared secret. |
| GET/POST | `/v1/admin/review` and `/v1/admin/review/:id` | `Bearer ADMIN_SECRET` | Single-page HTML queue of pending submissions; accept/reject. The photo is deleted from R2 either way. |
| GET | `/v1/admin/photo/:id` | `Bearer ADMIN_SECRET` | Serves a pending submission's photo out of R2. |
| POST | `/v1/admin/verified-case` | `Bearer ADMIN_SECRET` | Files a `verifiedCase` alert job for a gtin/brand. |
| POST | `/v1/admin/purge-kroger` | `Bearer ADMIN_SECRET` | Deletes every `price_snapshots` row and every `observations` row with `source='kroger'`. |

Every response carrying Kroger data includes `"attribution": "Prices from Kroger"` (spec §6.6).

## Bindings

| Binding | Kind | Name | Holds |
|---|---|---|---|
| `DB` | D1 | `shrunk` | `products`, `observations`, `price_snapshots`, `devices`, `watches`, `alert_jobs`, `submissions` |
| `PHOTOS` | R2 | `shrunk-photos` | Label photos, for pending submissions only |
| `KV` | KV | `KROGER` | Kroger client-credentials token (30 min) and per-device rate-limit counters |

## Vars and secrets

`[vars]` in `wrangler.toml` — plain, committed, changeable without a code change:

| Var | Values | Meaning |
|---|---|---|
| `ENV` | `dev` / `production` | Environment label. |
| `KROGER_PERSIST` | `on` / `off` | `off` stops **every** Kroger write immediately (spec §9 kill switch). |
| `PUSH_PROVIDER` | `apns` / `fcm` | Which `PushSender` implementation runs. |
| `APNS_ENV` | `sandbox` / `production` | `sandbox` for development and TestFlight builds; `production` for the App Store build. |

Secrets — `npx wrangler secret put <NAME>`, mirrored into the git-ignored `backend/.dev.vars` for `wrangler dev`. **Never committed.**

`FDC_API_KEY` · `ADMIN_SECRET` · `KROGER_CLIENT_ID` · `KROGER_CLIENT_SECRET` · `APNS_KEY_P8` · `APNS_KEY_ID` · `APNS_TEAM_ID` · `FCM_SERVICE_ACCOUNT_JSON` (only when `PUSH_PROVIDER="fcm"`).

## Cron triggers

| Schedule | Job |
|---|---|
| `*/5 * * * *` | Drain `alert_jobs`: push to watching Pro devices, mark sent. Max 40 pushes per invocation. |
| `0 */6 * * *` | Kroger sweep (only while `KROGER_PERSIST="on"`): re-check every watched `(gtin, location_id)`, file `size_drop` and `price_hike` jobs. |
| `0 1 * * 1` | Weekly digest: one push per Pro device with activity in a subscribed category. |

## Develop

```
npm ci
npm run dev          # http://localhost:8787 — needs backend/.dev.vars
npm test             # Vitest 4 in the Workers runtime, migrations applied by test/apply-migrations.ts
npm run typecheck
npm run check:trending   # fails when src/data/trending.json has drifted from ../data/trending.json
npm run sync:trending    # re-copies it
```

Test convention: outbound HTTP is stubbed with `vi.stubGlobal("fetch", vi.fn(...))` and `afterEach(() => vi.unstubAllGlobals())`. `fetchMock` from `cloudflare:test` does not exist in this toolchain. D1 and KV bindings are real; cron handlers are called directly (`runAlertDrain`, `runKrogerSweep`, `runWeeklyDigest`).

## Deploy

```
npm run migrate:remote
npm run deploy
```

First-time provisioning (account, D1, KV, R2, every secret) is in [`../docs/RELEASE_CHECKLIST.md`](../docs/RELEASE_CHECKLIST.md).

## Loading data

```
# USDA FoodData Central, ~twice a year on each release:
python3 ../scripts/fdc_import.py --zip /tmp/fdc_branded.zip --out ../scripts/out/fdc.sql \
  --report ../scripts/out/report.json --curated ../data/trending.json
npx wrangler d1 execute shrunk --remote --file ../scripts/out/fdc.sql

# The curated catalogue, after every edit to data/trending.json:
python3 ../scripts/seed_curated.py --curated ../data/trending.json --out ../scripts/out/curated.sql
npx wrangler d1 execute shrunk --remote --file ../scripts/out/curated.sql
```

## Kroger kill switch (spec §9)

Kroger's terms prohibit building a database from their responses; snapshots are retained while a written-permission request is pending, and are isolated so they can go in one command.

```
# stop new writes
sed -i '' 's/KROGER_PERSIST = "on"/KROGER_PERSIST = "off"/' wrangler.toml && npx wrangler deploy

# remove everything already retained
curl -X POST "$API/v1/admin/purge-kroger" -H "Authorization: Bearer $ADMIN_SECRET"
```
````

- [ ] **Step 3: Fix `data/README.md`**

Replace the `## Deployment` section (heading through the line ending `cp data/trending.json Shrunk/Resources/trending.json` and its closing fence) with:

````markdown
## Where this file goes

`data/trending.json` is canonical. Two copies are derived from it, and CI (`scripts/check_repo_data.py`, job `fixtures`) fails the build when either drifts:

| Copy | Purpose | Re-sync with |
|---|---|---|
| `backend/src/data/trending.json` | Bundled into the Worker and merged into `GET /v1/feed`, which is what the app's Browse tab reads. | `cd backend && npm run sync:trending` |
| `Shrunk/Resources/trending.json` | The app's offline fallback, and the source of images, prices and evidence links that `/v1/feed` does not carry. | `cp data/trending.json Shrunk/Resources/trending.json` |

The catalogue is also seeded into D1 as `source='curated'` observations (confidence 1.0, `source_ref` = the evidence URL), which is what makes a curated product produce a verdict when it is scanned:

```
python3 scripts/seed_curated.py --curated data/trending.json --out scripts/out/curated.sql
cd backend && npx wrangler d1 execute shrunk --remote --file ../scripts/out/curated.sql
```

So publishing an edit is: edit `data/trending.json` → re-sync both copies → re-seed D1 → commit → `cd backend && npx wrangler deploy`.

> **Historical note.** Up to v1 the app fetched this file straight from jsDelivr
> (`https://cdn.jsdelivr.net/gh/stackcurious/shrunk@main/data/trending.json`).
> Phase 4 moved the live feed to `GET /v1/feed` so crowd and Kroger observations
> could be merged in; the app no longer contacts jsDelivr at all. The CDN URL
> still resolves and remains a fine way for anyone else to consume the CC-BY data.
````

Then update the "Adding a new entry" list — step 6 currently says only to copy into `Shrunk/Resources/trending.json`. Replace steps 5–7 with:

```markdown
5. Add the entry to `trending.json`.
6. Re-sync both copies: `cp data/trending.json Shrunk/Resources/trending.json` and `cd backend && npm run sync:trending`.
7. Re-seed D1: `python3 scripts/seed_curated.py --curated data/trending.json --out scripts/out/curated.sql` then `cd backend && npx wrangler d1 execute shrunk --remote --file ../scripts/out/curated.sql`.
8. Run `python3 scripts/check_repo_data.py` — it must print `repo data OK`.
9. Bump `version` only if you are changing the schema, not the data.
```

Finally, replace the `## Future automation` section with:

```markdown
## Related automation

- `scripts/fdc_import.py` streams a USDA FoodData Central Branded Foods release into `products` + `observations` (`source='fdc'`) and cross-checks this catalogue, reporting which curated GTINs FDC knows about. Re-run on each FDC release (April/October).
- `POST /v1/observations` adds crowd label observations continuously, so `/v1/feed` surfaces shrinks this file has not caught yet.
- Curation stays human: an entry only lands here with a primary-source `evidence_url`.
```

- [ ] **Step 4: Verify the docs match reality**

```bash
cd /Users/drao/Projects/shrunk
python3 scripts/check_repo_data.py
grep -c "^| " backend/README.md                       # endpoint + binding + var + cron rows
grep -rn "jsdelivr" data/README.md README.md          # only the historical note may remain
grep -rn "jsdelivr" Shrunk --include=*.swift || echo "app no longer references jsDelivr"
```
Expected: `repo data OK`; the only `jsdelivr` hits are the historical note in `data/README.md`; the app has no reference (Phase 4 Task 16 removed it). If the app still points at jsDelivr, Phase 4 Task 16 has not landed — stop and land it.

- [ ] **Step 5: Commit**

```bash
cd /Users/drao/Projects/shrunk
git add backend/README.md data/README.md
git commit -m "docs: complete backend endpoint reference; data feed now served from /v1/feed" -- \
  backend/README.md data/README.md
```

---

### Task 4: Privacy policy, terms, and in-app attribution

**Precondition:** Task 0 passed. If it did not, stop and land the missing phase before starting this task.

**Files:**
- Create: `docs/PRIVACY_POLICY.md`
- Create: `docs/TERMS.md`
- Modify: `Shrunk/Features/Settings/SettingsView.swift:30-40` (the "Data" section) and `:41-53` (the "About" section)

**Interfaces:**
- Consumes: `DeviceIdentity.current` (`Shrunk/Services/DeviceIdentity.swift`) — a per-install UUID string.
- Produces: the two documents the app already links to. The app expects them published at **`https://stackcurious.com/shrunk/privacy`** and **`https://stackcurious.com/shrunk/terms`** — those exact URLs are hard-coded in `SettingsView` and in the paywall, and the privacy URL also goes into App Store Connect. Publish the Markdown at those paths; do not change the URLs.
- Produces: the factual base for `docs/ASC_SETUP.md` §4 (App Privacy answers) in Task 6. If you change what the app stores, change the policy first and the ASC answers second.

- [ ] **Step 1: Confirm what the app actually stores before writing that it does**

```bash
cd /Users/drao/Projects/shrunk
grep -rn "AppStorage\|UserDefaults.standard" Shrunk --include=*.swift | grep -v "^Binary" | sed 's/:.*AppStorage/: @AppStorage/' | head -30
grep -rn "device_id\|apns_token\|location_id\|categories\|app_account_token" backend/src/routes/devices.ts | head -20
grep -rn "PHOTOS.put\|PHOTOS.delete" backend/src | head
grep -rn "photo_key" backend/src/routes/admin.ts | head
```
Expected: the D1 `devices` row holds an app-generated UUID, an APNs token, a Kroger `location_id`, categories/prefs, `pro_until` and `app_account_token`; `submissions` holds a device id, gtin, `photo_key`, OCR text and parsed quantity; R2 photos are written on `pending` and deleted on accept **and** reject. Every claim in the policy below must match this output — if the code diverges, correct the policy, not the code.

- [ ] **Step 2: Write `docs/PRIVACY_POLICY.md`**

```markdown
# Shrunk — Privacy Policy

**Last updated: 2026-08-26**

Publish this document at `https://stackcurious.com/shrunk/privacy`. The app links to that exact URL from Settings and from the subscription paywall, and App Store Connect points at it too.

## The short version

Shrunk has no accounts and no logins. We do not sell your data, we run no ads, we use no analytics or advertising SDKs, and we do not track you across other apps or websites. We store the minimum needed to look up a product, alert you about something you asked us to watch, and honour a subscription you bought from Apple.

## What Shrunk stores

| What | When it is stored | Where | How long |
|---|---|---|---|
| The barcode you scanned (a 13-digit product number) | Every scan | Sent to our API to look the product up. Not stored as a record of your scanning. | Not retained |
| A random device id (a UUID generated on your phone at first launch) | First launch | On your device, and in a `devices` row in our database | Until you ask us to delete it |
| Your Apple push token | Only if you allow notifications | Same `devices` row | Until you turn notifications off or ask us to delete it |
| The Kroger store you picked (a store id, not your location) | When you pick a store | On your device and in the `devices` row | Until you change or clear it |
| Your category and notification preferences | Onboarding and Settings | On your device and in the `devices` row | Until you change them |
| Your watchlist (product barcodes and brands) | When you add a product | On your device and in a `watches` row | Until you remove the item |
| A label photo you choose to contribute | Only when the automatic reading is not confident enough to accept on its own | Cloudflare R2, alongside a submission record carrying your device id | **Deleted the moment it is reviewed**, accepted or rejected |
| The net weight read from a label | When you contribute | Stored as product data (`observations`) | Kept as part of the product's size history |
| Your subscription status | After a purchase or restore | Apple's signed transaction is verified and reduced to an expiry date in the `devices` row | Until it expires or you ask us to delete it |
| Your recent scans | Every scan | **On your device only** (`UserDefaults`), never uploaded | Until you tap "Clear scan history" or delete the app |

**Shrunk never collects:** your name, email address, postal address, phone number, precise location, contacts, photo library, health data, payment details, or any advertising identifier. There is no advertising SDK and no analytics SDK in the app.

## Label photos

Contributing a photo is optional and free. On your phone, Shrunk reads the label with Apple's on-device Vision framework — the image is not uploaded to read it. If the reading is confident (a clear net-weight line that agrees with what we already know about the product), only the number is sent; **the photo never leaves your phone**. If it is not confident, the photo is uploaded so a human can check it, and it is deleted from our storage as soon as that check happens, whether the submission is accepted or rejected. The number that survives review becomes part of the product's public size history and is not attributed to you.

## Notifications

If you allow notifications, Apple issues a push token for this install and we store it so watchlist alerts and the weekly digest can reach you. Turning notifications off in iOS Settings stops delivery; asking us to delete your device row removes the token.

## Purchases

Shrunk Pro is an auto-renewable subscription sold by Apple. Apple handles payment; we never see your card, your Apple Account, or your billing details. Our server receives Apple's cryptographically signed transaction, verifies it, and stores only an expiry date plus the random purchase token the app generated, so your subscription survives a reinstall.

## Who else sees this data

- **Cloudflare** — hosts our API, database, photo storage and cache (United States).
- **Apple** — delivers push notifications and processes subscriptions.
- **Kroger** — when you have a store selected, we ask Kroger's Products API for that store's price and size for the barcode you scanned. We send the barcode and the store id. **We never send your device id, push token, or anything else about you.**
- **USDA FoodData Central** and **Open Food Facts** — queried by barcode when a product is new to us, to fill in a name and image.

Nobody else. We do not sell, rent or share data with advertisers, data brokers or analytics companies.

## Data sources and attribution

- **U.S. Department of Agriculture, FoodData Central** — Branded Foods package sizes. Public domain data; USDA does not endorse Shrunk.
- **Kroger Products API** — live store prices and sizes, shown in the app with the attribution "Prices from Kroger". Shrunk is not affiliated with, endorsed by, or sponsored by The Kroger Co.
- **Open Food Facts** — product names and images, licensed under the [Open Database License (ODbL)](https://opendatacommons.org/licenses/odbl/1-0/). Open Food Facts is a nonprofit, community-maintained project and does not endorse Shrunk.
- **Shoppers** — label photos and net-weight readings contributed through the app.
- Brand and product names are trademarks of their owners, used to identify products.

## Your choices

- **Stop everything:** delete the app. Nothing further is sent.
- **Delete what is on the server:** email us the first eight characters of the device id shown in Settings → About → Device ID and we will delete the matching `devices`, `watches` and `submissions` rows. Accepted size observations stay, because they are product facts and carry no identifier.
- **Turn off alerts:** Settings → Notification preferences, or iOS Settings → Notifications → Shrunk.
- **Clear local scan history:** Settings → Clear scan history.
- **Manage or cancel Pro:** iOS Settings → your name → Subscriptions. Apple handles cancellations and refunds.

## Children

Shrunk is not directed at children under 13 and we do not knowingly collect data from them. There is nothing in the app that asks for a name or an age.

## Security

Everything travels over HTTPS. The API stores no credentials for you, because there are none. Our own service credentials live in encrypted secret storage, never in the app.

## Changes

If this policy changes materially, we will update the date at the top and note the change in the app's release notes. The current version always lives at this URL.

## Contact

privacy@stackcurious.com
```

> Before publishing, make sure `privacy@stackcurious.com` is a mailbox you actually read — Apple's reviewers do email support addresses, and a deletion request must reach a human. If you would rather use a different address, change it here, in `docs/TERMS.md`, and in the App Store Connect support fields, so all three agree.

- [ ] **Step 3: Write `docs/TERMS.md`**

```markdown
# Shrunk — Terms of Service

**Last updated: 2026-08-26**

Publish this document at `https://stackcurious.com/shrunk/terms`. The app links to that exact URL from Settings and from the subscription paywall.

## 1. What Shrunk is

Shrunk is an iOS app that scans a grocery barcode and shows you how a product's package size and price-per-unit have changed, using public data, live retailer prices, and observations contributed by shoppers. Using the app means you accept these terms.

## 2. No accounts

There is no sign-up and no login. Your watchlist and preferences are tied to a random id generated on your device. If you delete the app, that link is gone; we cannot restore your data afterwards.

## 3. Shrunk Pro

Shrunk Pro is an auto-renewable subscription sold through Apple:

- **Shrunk Pro Yearly** — $14.99 per year, with a 7-day free trial for new subscribers.
- **Shrunk Pro Monthly** — $2.99 per month.

Pro unlocks watchlist alerts, the weekly "what shrank this week" digest, unlimited ranked alternatives at your store, full price and size history charts, and the savings dashboard. Scanning, verdicts, size history, current price, the browse feed, contributing label photos, and three alternatives per scan are free and always will be.

Payment is charged to your Apple Account at confirmation of purchase. **The subscription renews automatically** unless it is cancelled at least 24 hours before the end of the current period; your account is charged for renewal within 24 hours before the period ends. Any unused portion of a free trial is forfeited when you buy a subscription. Manage or cancel your subscription in iOS Settings → your name → Subscriptions. Prices are in U.S. dollars and may change with notice; refunds are handled by Apple under Apple's Media Services terms, not by us.

## 4. What you contribute

When you send a label photo or a net-weight reading, you confirm you took the photo yourself and you grant us a non-exclusive, worldwide, royalty-free licence to use it to verify and publish product size data in Shrunk. Photos awaiting review are deleted once reviewed (see the [Privacy Policy](https://stackcurious.com/shrunk/privacy)); the resulting size figure becomes part of the product's public history. Do not submit photos of people, of anything other than a product label, or of anything you do not have the right to share. We may reject or remove any submission.

## 5. Accuracy

Shrunk reports what the available data says. Package sizes come from the USDA's FoodData Central dataset, from retailer APIs, from curated cases with published evidence, and from shoppers. Data can be stale, mis-keyed at the source, or simply missing, and prices change constantly and vary by store. **Verdicts, prices and savings figures are informational estimates, not a guarantee, and not financial advice.** Check the package before you buy.

## 6. Independence

Shrunk is independent. No brand, manufacturer or retailer pays for placement, and there is no advertising in the app. Shrunk is not affiliated with, endorsed by, or sponsored by The Kroger Co., the U.S. Department of Agriculture, Open Food Facts, or any brand whose products appear. Product and brand names are trademarks of their owners and are used only to identify products. Data attributions are listed in the app under Settings → Data sources and in the Privacy Policy.

## 7. Acceptable use

Do not scrape, resell or redistribute the app's data feeds; do not attempt to break, overload or reverse-engineer the service; do not submit false observations deliberately. We may rate-limit or block a device that does.

## 8. Availability

Shrunk is provided "as is". We do not promise the service will be uninterrupted, and features that depend on third parties — retailer prices in particular — may change or disappear if those third parties change their terms. To the fullest extent the law allows, we are not liable for indirect or consequential losses, and our total liability is limited to what you paid us in the twelve months before the claim.

## 9. Changes

We may update these terms; the date above changes when we do, and material changes are noted in the app's release notes. Continuing to use Shrunk after an update means you accept it.

## 10. Governing law

These terms are governed by the laws of the State of Ohio, United States, without regard to conflict-of-law rules.

## 11. Contact

privacy@stackcurious.com
```

- [ ] **Step 4: Make the app's attribution match the policy (spec §9)**

In `Shrunk/Features/Settings/SettingsView.swift`, replace the whole `sectionGroup(title: "Data", …)` block — which still credits only Open Food Facts and links to OFF's own contribution flow, superseded by Shrunk's own — with:

```swift
                    sectionGroup(title: "Data sources", subtitle: "Shrunk has no relationship with any brand or manufacturer. Size history comes from the USDA's public FoodData Central dataset, from shoppers' label photos, and from Kroger.") {
                        SettingsRow(icon: "building.columns.fill", iconTint: .verdictGood, label: "USDA FoodData Central", isLink: true) {
                            if let url = URL(string: "https://fdc.nal.usda.gov") { openURL(url) }
                        }
                        SettingsRow(icon: "cart.fill", iconTint: .verdictGood, label: "Prices from Kroger", isLink: true) {
                            if let url = URL(string: "https://www.kroger.com") { openURL(url) }
                        }
                        SettingsRow(icon: "leaf.fill", iconTint: .verdictGood, label: "Open Food Facts (ODbL)", isLink: true) {
                            if let url = URL(string: "https://world.openfoodfacts.org") { openURL(url) }
                        }
                        SettingsRow(icon: "trash.fill", iconTint: .smoke, label: "Clear scan history") {
                            UserDefaults.standard.removeObject(forKey: "shrunk.recent_barcodes")
                        }
                    }
```

Then, in the `sectionGroup(title: "About", …)` block, add a device-id row directly **after** the existing `Version` row, so the deletion path in the privacy policy is something a user can actually follow:

```swift
                        SettingsValueRow(icon: "number", iconTint: .smoke, label: "Device ID", value: String(DeviceIdentity.current.prefix(8)))
```

- [ ] **Step 5: Build and eyeball it**

```bash
xcodegen generate >/dev/null && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -20
```
Expected: build succeeds and the whole suite still passes. Then run the app, open Settings, and confirm: the section is titled "DATA SOURCES" with three attribution rows and "Clear scan history"; About shows Version and an 8-character Device ID; the Privacy policy and Terms rows open `stackcurious.com/shrunk/privacy` and `/terms`.

- [ ] **Step 6: Check the policy and the app agree on the URLs**

```bash
cd /Users/drao/Projects/shrunk
grep -rn "stackcurious.com/shrunk/\(privacy\|terms\)" Shrunk docs/PRIVACY_POLICY.md docs/TERMS.md | sort
```
Expected: `SettingsView.swift` and the paywall point at both URLs, and each document names its own URL. Any other spelling of these URLs is a bug — the App Store record uses the same two strings.

- [ ] **Step 7: Commit**

```bash
cd /Users/drao/Projects/shrunk
git add docs/PRIVACY_POLICY.md docs/TERMS.md Shrunk/Features/Settings/SettingsView.swift
git commit -m "docs: privacy policy and terms; credit every data source in Settings" -- \
  docs/PRIVACY_POLICY.md docs/TERMS.md Shrunk/Features/Settings/SettingsView.swift
```

---

### Task 5: App Store listing copy for v2

**Precondition:** Task 0 passed. If it did not, stop and land the missing phase before starting this task.

**Files:**
- Modify: `docs/APP_STORE_LISTING.md` (full rewrite — every section sells the v1 $9.99 lifetime IAP and names Open Food Facts as the data source)

**Interfaces:**
- Consumes: pricing and Free/Pro wording from Global Constraints (spec §2, §3), and the attribution list from Task 4.
- Produces: the copy Task 6's checklist tells the operator to paste into App Store Connect, and the release notes Task 10 reuses.

- [ ] **Step 1: Rewrite `docs/APP_STORE_LISTING.md`**

Replace the whole file with:

````markdown
# Shrunk — App Store Listing Copy (v2.0.0)

Copy-paste ready. Character counts are noted where Apple enforces a limit. Every price and feature line here must match `docs/superpowers/specs/2026-08-26-shrunk-v2-design.md` §2 and §3 — if they diverge, the spec wins.

---

## App Name (≤30 chars)

```
Shrunk: Shrinkflation Scanner
```
(29 chars)

## Subtitle (≤30 chars)

```
Catch shrinking groceries
```
(25 chars)

## Promotional Text (≤170 chars — editable any time without review)

```
Same price, less product? Scan any grocery barcode and Shrunk shows the real size history, today's shelf price, and what to buy instead. No brand pays us.
```
(154 chars)

## Keyword Field (≤100 chars, comma-separated, no spaces after commas)

```
shrinkflation,grocery savings,barcode scanner,price tracker,unit price,inflation,groceries,deals
```
(96 chars)

> Do not repeat words already in the App Name or Subtitle ("Shrunk", "scanner") — Apple indexes those automatically.

## Categories

**Shopping** (primary) · **Food & Drink** (secondary)

The job-to-be-done is a purchase decision at the shelf — comparison, alternatives, savings tracking — which is Shopping behaviour. Food & Drink is the natural secondary: the catalogue is grocery, and USDA FoodData Central is a food dataset.

---

## Full Description

```
They shrunk it. We caught them.

Shrinkflation is when a brand quietly shrinks the package — fewer chips, less coffee, a smaller bottle — while the price stays exactly the same. Shrunk shows you the receipt.

Point your camera at any grocery barcode. In seconds you get:

• Whether the package shrank, and by how much
• The size history behind that verdict, with dates
• Today's price and cost per ounce at your Kroger store
• Better value alternatives on the same shelf

WHERE THE DATA COMES FROM
Shrunk is built on the USDA's public FoodData Central dataset, which records package sizes for hundreds of thousands of US grocery products going back years — that's the "before". Live prices and current sizes come from Kroger's official Products API for the store you choose. Verified shrinkflation cases are curated by hand with a published source for every one. And shoppers add what no database has: snap a label, and Shrunk reads the net weight on your phone.

FREE, FOREVER
• Unlimited barcode scans
• Shrink verdict and size history
• Current price and cost per unit at your store
• The browse feed of verified cases
• Contribute label photos
• 3 alternatives per scan

SHRUNK PRO
• Watchlist alerts — a push the moment something you watch gets smaller, or its price per unit jumps 5%
• Weekly "what shrank this week" digest for your categories
• Unlimited ranked alternatives at your store, cheapest per unit first
• Full price and size history charts
• Savings dashboard built from what you actually scan — no invented numbers

$2.99/month or $14.99/year. New subscribers get a 7-day free trial on the yearly plan.

INDEPENDENT BY DESIGN
No brand pays us. No sponsors. No ads. No account, no login, no tracking. Our only job is to be on your side at the shelf.

Prices from Kroger. Size data from USDA FoodData Central. Product names and images from Open Food Facts (ODbL). Shrunk is not affiliated with any brand or retailer.

Stop paying more for less.
```

## Subscription disclosure (required by Apple for auto-renewables)

Apple requires the length, price and renewal terms, plus functional links to the terms and privacy policy, to be visible **in the app's description and on the paywall itself**. Paste this at the end of the App Store description, below the marketing copy:

```
Shrunk Pro is an auto-renewable subscription.

• Shrunk Pro Yearly — $14.99 per year, with a 7-day free trial for new subscribers
• Shrunk Pro Monthly — $2.99 per month

Payment is charged to your Apple Account at confirmation of purchase. The subscription renews automatically unless auto-renew is turned off at least 24 hours before the end of the current period. Your account is charged for renewal within 24 hours before the current period ends. Any unused portion of a free trial is forfeited when you purchase a subscription. Manage your subscription or turn off auto-renew in iOS Settings → your name → Subscriptions after purchase.

Privacy Policy: https://stackcurious.com/shrunk/privacy
Terms of Service: https://stackcurious.com/shrunk/terms
```

The in-app paywall already shows plan length, price and both links (Phase 5, Task 8) — confirm on the device build before submitting, because a paywall missing them is a routine rejection.

---

## What's New (v2.0.0)

```
Shrunk v2 — every verdict now comes from real, dated observations.

• Real size history: hundreds of thousands of US products from the USDA's public FoodData Central dataset, plus verified cases and shopper contributions
• Live prices: pick your Kroger store and see today's price, cost per unit, and stock, right on the result screen
• Snap a label: Shrunk reads the net weight on your phone and adds it to a product's history
• Alternatives that are actually on the shelf at your store, ranked by price per unit
• Shrunk Pro is now a subscription — $2.99/month or $14.99/year with a 7-day free trial — and every Pro feature is backed by observed data: watchlist alerts, the weekly digest, unlimited alternatives, full history charts, and a savings dashboard computed from what you scan

The onboarding quiz and its guessed "yearly exposure" number are gone. We would rather show you one real number than five invented ones.
```

---

## URLs

- **Support URL:** https://stackcurious.com/shrunk/support
- **Marketing URL:** https://stackcurious.com/shrunk
- **Privacy Policy:** https://stackcurious.com/shrunk/privacy
- **Terms of Service (EULA field):** https://stackcurious.com/shrunk/terms

All four must resolve before submission — a 404 on the privacy URL is an automatic rejection.

---

## Screenshots

Required: 6.9" (1320×2868). The four files in `marketing/screenshots/` are **v1 and must not be reused** — they show the lifetime IAP, the removed quiz onboarding, and a Browse tab without live prices.

Capture six on a physical device running the 2.0.0 build, signed into a StoreKit sandbox account with Pro active, with a Cincinnati Kroger store selected:

| # | File | Screen | Why |
|---|---|---|---|
| 1 | `01_result_shrunk.png` | Result view for a curated product with a clear shrink verdict, size history chart and the live-price panel showing "Prices from Kroger" | The core promise, in one shot |
| 2 | `02_scan.png` | Scanner with the reticle over a real package | Shows the interaction |
| 3 | `03_live_price.png` | Result view scrolled to the live-price panel: regular/promo, cost per unit, stock, attribution | The v2 differentiator |
| 4 | `04_contribute.png` | Label capture confirm sheet with a parsed net weight | The growth loop, and it is free |
| 5 | `05_alerts.png` | Alerts feed with a `sizeDrop` and a `priceHike` entry | What Pro delivers |
| 6 | `06_paywall.png` | Paywall with yearly preselected, "Save 58%", the 7-day trial, and the terms/privacy links | Also the screenshot ASC asks for when reviewing the subscription |

Delete `01_browse.png`, `02_watchlist.png`, `03_settings.png` and `04_alerts.png` once the replacements exist, so nobody uploads the v1 set by mistake.
````

- [ ] **Step 2: Check the copy against the spec**

```bash
cd /Users/drao/Projects/shrunk
grep -n "2.99\|14.99\|7-day\|3 alternatives\|save 58%\|Save 58%" docs/APP_STORE_LISTING.md
grep -rn "9.99\|lifetime\|one-time" docs/APP_STORE_LISTING.md || echo "no v1 pricing left"
grep -n "Prices from Kroger" docs/APP_STORE_LISTING.md
```
Expected: the subscription prices appear in the description, the disclosure and the What's New; `no v1 pricing left`; the Kroger attribution string appears verbatim.

- [ ] **Step 3: Commit**

```bash
cd /Users/drao/Projects/shrunk
git add docs/APP_STORE_LISTING.md
git commit -m "docs: App Store listing copy for v2 with subscription disclosure" -- docs/APP_STORE_LISTING.md
```

---

### Task 6: App Store Connect setup sheet — privacy, capabilities, export compliance

**Files:**
- Modify: `docs/ASC_SETUP.md` — §1 (push capability), §3 (age rating note), §4 (App Privacy, full replacement), §5 (permissions), §6 (build & signing), §8 (new: export compliance), and the pre-submission checklist

**Interfaces:**
- Consumes: `docs/PRIVACY_POLICY.md` from Task 4 — the App Privacy answers below are derived from it, line for line.
- Consumes: §2 (subscription group, intro offer) and §7 (reviewer note) as **already rewritten by Phase 5 Task 12** — do not touch them. If §2 still describes a `com.shrunk.pro.lifetime` non-consumable, Phase 5 Task 12 has not landed; stop and land it first.
- Produces: the final pre-submission checklist Task 11 walks before merging.

- [ ] **Step 1: Confirm Phase 5's edits are present**

```bash
cd /Users/drao/Projects/shrunk
grep -n "## 2\." docs/ASC_SETUP.md
grep -n "com.shrunk.pro.yearly\|com.shrunk.pro.monthly\|Server Notifications" docs/ASC_SETUP.md | head
grep -n "lifetime" docs/ASC_SETUP.md || echo "no lifetime references"
```
Expected: §2 is "Subscriptions", both product ids appear, App Store Server Notifications V2 is documented, and `no lifetime references`.

- [ ] **Step 2: Add the push capability to §1, and re-check §3**

Replace the blockquote under §1 with:

```markdown
> The bundle ID `com.shrunk.app` must already exist as an App ID in the Apple Developer portal (Certificates, Identifiers & Profiles) under team **X4VJ56X38V**, with the **Push Notifications** capability enabled — the app registers for remote notifications and the Worker sends watchlist alerts and the weekly digest through APNs. The same portal holds the APNs auth key (`.p8`) the Worker signs with; see `docs/RELEASE_CHECKLIST.md`. The app also declares the `aps-environment` entitlement through `Shrunk/Shrunk.entitlements`, wired via `CODE_SIGN_ENTITLEMENTS` in `project.yml` — `development` for TestFlight, and the App Store build is re-signed to `production` automatically at distribution.
```

Then append to §3, after the two existing bullets:

```markdown
- **Still 4+ in v2, and the two questions that changed both stay "No".** Label photos are user-generated, but they are sent to a private review queue and are never shown to other users, so there is no in-app user-generated content to moderate; and the only outbound links are fixed, first-party-chosen URLs (privacy, terms, USDA, Kroger, Open Food Facts), so "Unrestricted Web Access" remains No.
```

- [ ] **Step 3: Replace §4 in full — the app now has a backend**

Delete everything between `## 4. App Privacy — Nutrition Label` and the `---` that closes it, and write:

```markdown
## 4. App Privacy — Nutrition Label (ASC → app → App Privacy)

**This answer changed in v2.** v1 truthfully answered "no data collected" because the app had no backend. v2 talks to a first-party Cloudflare Worker and stores a device row, so the answer is now **Yes**, with everything marked *not linked to identity* and *not used for tracking*. The facts below come from `docs/PRIVACY_POLICY.md` — if that document changes, change these answers with it.

"Do you or your third-party partners collect data from this app?" → **Yes**.

| Data type (Apple's taxonomy) | What it is | Purpose | Linked to the user? | Used for tracking? |
|---|---|---|---|---|
| Identifiers → **Device ID** | A UUID the app generates at first launch, and the APNs push token | App Functionality | **No** | **No** |
| User Content → **Photos or Videos** | A label photo, uploaded **only** when the on-device reading is not confident enough to auto-accept; deleted as soon as it is reviewed | App Functionality | **No** | **No** |
| User Content → **Other User Content** | The net-weight reading parsed from a label | App Functionality | **No** | **No** |
| Purchases → **Purchase History** | Subscription expiry derived from Apple's signed transaction, plus the app-generated purchase token | App Functionality | **No** | **No** |
| Other Data → **Other Data Types** | The Kroger store id you pick, your category choices and notification preferences, and your watchlist | App Functionality (and Product Personalisation for categories) | **No** | **No** |

Answer **No** to tracking on every data type, and **No** to "Do you use data for tracking purposes?" — there is no advertising SDK, no analytics SDK, no ad identifier, and nothing is shared with data brokers. App Tracking Transparency is therefore not required and the app never shows the ATT prompt.

Not collected, and must stay unticked: Contact Info, Health & Fitness, Financial Info (Apple handles payment — we never see it), **Location** (the app asks for a *store*, never the device's location, and requests no location permission), Contacts, Search History, Browsing History, Sensitive Info, Diagnostics, Usage Data.

Supporting facts if a reviewer asks:

- **No account, no login.** There is no user identity to link anything to.
- **Scan history stays on the device** (`UserDefaults`) and is never uploaded.
- **Kroger requests carry only the barcode and the store id** — never the device id or push token.
- **Photos are transient.** They exist in R2 only while a submission is pending human review and are deleted on accept and on reject alike.
```

- [ ] **Step 4: Update §5 (permissions) and §6 (build & signing)**

Replace the bullet list in §5 with:

```markdown
- `NSCameraUsageDescription` — "Shrunk uses your camera to scan product barcodes and, when you choose to contribute, to photograph a product label so we can read its net weight." Covers both the scanner and the label-capture flow.
- `UIBackgroundModes` — `fetch`, `processing` (the watchlist live-size check) and `remote-notification` (silent handling of alert pushes).
- `BGTaskSchedulerPermittedIdentifiers` — `com.shrunk.refresh-watchlist`.
- Push Notifications — remote alerts from the Worker (watchlist, digest, verified cases) plus local notifications.
- `NSAppTransportSecurity` → `NSAllowsLocalNetworking` — development only, so the app can talk to `wrangler dev` on `localhost:8787`. It permits **local** connections only, does not weaken ATS for any remote host, and needs no justification to review.

No HealthKit, no location, no contacts, no photo library, no microphone. The label-capture flow uses the camera, never the photo library, so `NSPhotoLibraryUsageDescription` is deliberately absent.
```

Replace §6 with:

```markdown
## 6. Build & Signing

- Team **X4VJ56X38V** (`project.yml` → `DEVELOPMENT_TEAM`, automatic signing).
- Marketing version **2.0.0**, build **2** — both from `project.yml`; `Info.plist` reads them through `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`.
- The Xcode project is generated: `xcodegen generate` before any archive. `Shrunk.xcodeproj` is not in git.
- Archive and upload with the commands in `docs/RELEASE_CHECKLIST.md` (`xcodebuild archive` → `-exportArchive` with `ExportOptions.plist` → `xcrun altool --upload-app`), or Xcode → Product → Archive → Distribute App.
```

- [ ] **Step 5: Add §8 — export compliance**

Insert a new section before the pre-submission checklist:

````markdown
## 8. Export compliance

`Shrunk/Resources/Info.plist` already declares:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

That is correct and means ASC will **not** ask the encryption questions on every build. Shrunk uses only HTTPS/TLS through the OS (App Transport Security) and Apple's own StoreKit and Vision frameworks; it implements no cryptography of its own and ships no custom encryption. That falls squarely inside the exemption for apps that merely use standard OS-provided encryption.

The Worker's App Store JWS verification runs **on the server**, not in the app, so it does not affect this answer.

If a build ever prompts for encryption answers anyway, the correct chain is: "Does your app use encryption?" → Yes → "Does it qualify for any of the exemptions?" → Yes, "only uses encryption available in iOS/macOS" → no CCATS or French declaration needed for a US-only release.
````

- [ ] **Step 6: Replace the pre-submission checklist**

Replace everything from `## Pre-submission checklist` to the end of the file (including the two stray fenced lines at the bottom, which are a v1 typo) with:

```markdown
## Pre-submission checklist

App record
- [ ] App record exists with bundle id `com.shrunk.app`, team X4VJ56X38V, Push Notifications capability enabled
- [ ] Name, subtitle, promotional text, keywords, description **including the subscription disclosure**, and What's New pasted from `docs/APP_STORE_LISTING.md`
- [ ] Support, Marketing, Privacy Policy and EULA/Terms URLs set, and all four load in a browser
- [ ] Age rating completed → 4+

Subscriptions (details in §2)
- [ ] Subscription group `Shrunk Pro` created
- [ ] `com.shrunk.pro.yearly` ($14.99/yr, level 1) and `com.shrunk.pro.monthly` ($2.99/mo, level 2) created and submitted **with the build**
- [ ] 7-day Free Trial introductory offer on the yearly product only
- [ ] Paywall screenshot uploaded for subscription review
- [ ] App Store Server Notifications set to Version 2, both URLs pointing at `https://<worker>/v1/appstore/notifications`, and ASC's **Test Notification** returns 200

Privacy and compliance
- [ ] App Privacy re-answered per §4 — **"Yes, we collect data"**, five data types, all *not linked* and *not used for tracking*
- [ ] `ITSAppUsesNonExemptEncryption=false` present in the built Info.plist (§8)
- [ ] `https://stackcurious.com/shrunk/privacy` and `/terms` publish the current `docs/PRIVACY_POLICY.md` and `docs/TERMS.md`

Build
- [ ] Six 6.9" screenshots re-captured on a device from the 2.0.0 build (`docs/APP_STORE_LISTING.md`); the v1 set deleted
- [ ] Reviewer note pasted (§7)
- [ ] Version 2.0.0 (2) uploaded, processed, and attached to the release
- [ ] `scripts/acceptance.md` filled in and passing — 35/35 curated verdicts, ≥60% kitchen-scan history, ≥25/30 live prices
```

- [ ] **Step 7: Verify the sheet is internally consistent**

```bash
cd /Users/drao/Projects/shrunk
grep -n "^## " docs/ASC_SETUP.md
grep -c "No, we do not collect data" docs/ASC_SETUP.md   # must be 0
grep -n "2.0.0" docs/ASC_SETUP.md
```
Expected: sections 1–8 plus the checklist, in order; zero occurrences of the v1 "no data collected" answer; version 2.0.0 named in §6 and the checklist.

- [ ] **Step 8: Commit**

```bash
cd /Users/drao/Projects/shrunk
git add docs/ASC_SETUP.md
git commit -m "docs: ASC app privacy answers, capabilities, export compliance and final checklist" -- docs/ASC_SETUP.md
```

---

### Task 7: Seed the curated catalogue into D1 as `source='curated'` observations

Spec §5.2 lists `curated` as a first-class source (confidence 1.0, accepted on insert) and §10 requires 35/35 curated products to produce a verdict. Nothing in Phases 1–5 ever writes a curated observation: the FDC importer only *cross-checks* `data/trending.json` in its report, and `/v1/feed` reads its own bundled copy at request time. FDC is food-only, so paper, cleaning and personal-care entries would have no history at all and the acceptance run could not pass. This task closes that gap.

**Precondition:** Task 0 passed. If it did not, stop and land the missing phase before starting this task.

**Files:**
- Create: `scripts/seed_curated.py`
- Modify: `scripts/fdc/importer.py` (`Product` gains `image_url`, `write_sql` emits it)
- Test: `scripts/tests/test_seed_curated.py`

**Interfaces:**
- Consumes: `parse_package_weight(raw) -> ParsedQuantity | None` (`scripts/fdc/normalize.py`), `normalize_gtin(raw) -> str | None` (`scripts/fdc/gtin.py`), and `Product`, `Observation`, `ImportResult`, `write_sql` (`scripts/fdc/importer.py`).
- Produces: `build_curated_rows(entries: list[dict]) -> ImportResult` and `write_curated_sql(result: ImportResult, out_path: Path) -> None` in `scripts/seed_curated.py`. `write_curated_sql` writes `DELETE FROM observations WHERE source='curated';` as its first line, then an `INSERT INTO products ... ON CONFLICT(gtin) DO UPDATE SET ...` upsert for every curated product — **not** `write_sql`'s `INSERT OR IGNORE`, which would silently no-op on a GTIN the FDC importer already loaded, dropping the curated `image_url`/name/brand/category — before delegating the observations to `write_sql`. Both the observation purge and the product upsert make re-seeding idempotent, including metadata corrections.
- Produces: CLI `python3 scripts/seed_curated.py --curated data/trending.json --out scripts/out/curated.sql`, printing `products=N observations=M skipped=K`.
- Changes: `Product` becomes `Product(gtin, name, brand, category, unit_kind, image_url=None)` — the new field is last and defaulted, so the FDC importer's construction is unchanged and emits `NULL` exactly as before.

- [ ] **Step 1: Write the failing test**

`scripts/tests/test_seed_curated.py`:

```python
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from seed_curated import build_curated_rows, write_curated_sql  # noqa: E402

GATORADE = {
    "barcode": "0052000133417",
    "name": "Gatorade Thirst Quencher",
    "brand": "Gatorade",
    "category": "Beverages",
    "image_url": "https://images.openfoodfacts.org/x.jpg",
    "history": [
        {"date": "2018-01-01", "quantity": 32, "unit": "fl oz"},
        {"date": "2021-06-01", "quantity": 28, "unit": "fl oz"},
    ],
    "evidence_url": "https://www.mouseprint.org/gatorade",
    "added_at": "2025-09-15",
}


def test_builds_one_product_and_one_observation_per_history_point():
    result = build_curated_rows([GATORADE])

    assert list(result.products) == ["0052000133417"]
    product = result.products["0052000133417"]
    assert product.name == "Gatorade Thirst Quencher"
    assert product.unit_kind == "volume"
    assert product.image_url == "https://images.openfoodfacts.org/x.jpg"

    assert len(result.observations) == 2
    first, second = result.observations
    assert first.quantity == 946.352
    assert second.quantity == 828.058
    assert first.observed_at < second.observed_at
    assert {o.source for o in result.observations} == {"curated"}
    assert {o.confidence for o in result.observations} == {1.0}
    assert second.source_ref == "https://www.mouseprint.org/gatorade"
    assert second.raw_text == "28 fl oz"


def test_history_points_of_another_kind_are_dropped():
    entry = dict(GATORADE)
    entry["history"] = [
        {"date": "2017-01-01", "quantity": 12, "unit": "count"},
        {"date": "2018-01-01", "quantity": 32, "unit": "fl oz"},
        {"date": "2021-06-01", "quantity": 28, "unit": "fl oz"},
    ]
    result = build_curated_rows([entry])

    assert result.products["0052000133417"].unit_kind == "volume"
    assert len(result.observations) == 2
    assert all(o.unit_kind == "volume" for o in result.observations)


def test_consecutive_equal_sizes_collapse():
    entry = dict(GATORADE)
    entry["history"] = [
        {"date": "2018-01-01", "quantity": 32, "unit": "fl oz"},
        {"date": "2019-01-01", "quantity": 32, "unit": "fl oz"},
        {"date": "2021-06-01", "quantity": 28, "unit": "fl oz"},
    ]
    result = build_curated_rows([entry])

    assert len(result.observations) == 2


def test_an_entry_with_fewer_than_two_usable_points_is_skipped():
    entry = dict(GATORADE)
    entry["history"] = [{"date": "2018-01-01", "quantity": 32, "unit": "fl oz"}]
    result = build_curated_rows([entry])

    assert result.observations == []
    assert result.stats["skipped"] == 1
    assert "0052000133417" in result.products, "the product row is still worth having"


def test_a_bad_barcode_is_skipped_without_raising():
    entry = dict(GATORADE)
    entry["barcode"] = "nope"
    result = build_curated_rows([entry])

    assert result.products == {}
    assert result.stats["skipped"] == 1


def test_sql_purges_previous_curated_rows_first(tmp_path):
    out = tmp_path / "curated.sql"
    write_curated_sql(build_curated_rows([GATORADE]), out)
    lines = out.read_text().strip().splitlines()

    assert lines[0] == "DELETE FROM observations WHERE source='curated';"
    assert any("INSERT OR IGNORE INTO products" in line for line in lines)
    assert any("'curated'" in line for line in lines)
    assert any("'https://images.openfoodfacts.org/x.jpg'" in line for line in lines)
    assert all(line.endswith(";") for line in lines)


def test_reseeding_after_an_image_url_edit_changes_the_emitted_sql(tmp_path):
    # write_sql's INSERT OR IGNORE would silently no-op on a GTIN the FDC
    # importer already loaded, dropping the curated image_url. Re-seeding
    # must actually change the emitted SQL for an already-known GTIN, which
    # only an upsert (ON CONFLICT DO UPDATE) delivers.
    first = tmp_path / "first.sql"
    write_curated_sql(build_curated_rows([GATORADE]), first)
    first_sql = first.read_text()

    edited = dict(GATORADE, image_url="https://images.openfoodfacts.org/y.jpg")
    second = tmp_path / "second.sql"
    write_curated_sql(build_curated_rows([edited]), second)
    second_sql = second.read_text()

    assert "'https://images.openfoodfacts.org/x.jpg'" in first_sql
    assert "'https://images.openfoodfacts.org/y.jpg'" in second_sql
    assert "'https://images.openfoodfacts.org/x.jpg'" not in second_sql
    assert "ON CONFLICT(gtin) DO UPDATE SET" in second_sql
    assert "image_url=excluded.image_url" in second_sql
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/drao/Projects/shrunk/scripts && python3 -m pytest tests/test_seed_curated.py -q
```
Expected: `ModuleNotFoundError: No module named 'seed_curated'`.

- [ ] **Step 3: Teach `Product` about `image_url`**

In `scripts/fdc/importer.py`, add the field to the dataclass:

```python
@dataclass
class Product:
    gtin: str
    name: str
    brand: str
    category: str
    unit_kind: str
    image_url: str | None = None
```

and use it in `write_sql`, replacing the hard-coded `NULL` in the products VALUES tuple:

```python
                f"({_q(p.gtin)}, {_q(p.name)}, {_q(p.brand)}, {_q(p.category)}, {_q(p.image_url)}, {_q(p.unit_kind)}, {now}, {now})"
```

In the same file, widen one annotation on `Observation` so a curated row without an evidence URL is honestly typed (`_q` already turns `None` into `NULL`):

```python
    source_ref: str | None
```

Nothing else changes: the FDC path never sets `image_url` and always passes an `fdc_id`, so its output is byte-identical to before.

- [ ] **Step 4: Write the seeder**

`scripts/seed_curated.py`:

```python
#!/usr/bin/env python3
"""Turn the curated catalogue into `source='curated'` observations for D1.

    python3 scripts/seed_curated.py --curated data/trending.json --out scripts/out/curated.sql
    cd backend && npx wrangler d1 execute shrunk --remote --file ../scripts/out/curated.sql

Spec §5.2: curated observations carry confidence 1.0 and are accepted on
insert. They are what makes a hand-verified product — including the paper,
cleaning and personal-care entries USDA FoodData Central does not cover —
produce a verdict when it is scanned.

The generated file starts by deleting every existing curated observation, so
re-running it after an edit to `data/trending.json` replaces rather than
duplicates.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from fdc.gtin import normalize_gtin  # noqa: E402
from fdc.importer import ImportResult, Observation, Product, _q, write_sql  # noqa: E402
from fdc.normalize import parse_package_weight  # noqa: E402

SAME_SIZE_TOLERANCE = 0.01  # spec §5.1: within 1% is the same size


def _epoch(date: str) -> int | None:
    try:
        return int(datetime.strptime(date, "%Y-%m-%d").replace(tzinfo=timezone.utc).timestamp())
    except (ValueError, TypeError):
        return None


def build_curated_rows(entries: list[dict]) -> ImportResult:
    result = ImportResult()
    stats = {"entries": len(entries), "skipped": 0, "points_dropped": 0}

    for entry in entries:
        gtin = normalize_gtin(str(entry.get("barcode", "")))
        if not gtin:
            stats["skipped"] += 1
            continue

        points = []
        for point in entry.get("history", []):
            raw = f"{point['quantity']} {point['unit']}"
            parsed = parse_package_weight(raw)
            observed_at = _epoch(point.get("date", ""))
            if not parsed or observed_at is None:
                stats["points_dropped"] += 1
                continue
            points.append({
                "quantity": parsed.quantity,
                "unit_kind": parsed.unit_kind,
                "raw": raw,
                "observed_at": observed_at,
            })

        if not points:
            stats["skipped"] += 1
            continue

        points.sort(key=lambda p: p["observed_at"])
        kind = points[-1]["unit_kind"]           # dominant kind = the most recent point's
        same_kind = [p for p in points if p["unit_kind"] == kind]
        stats["points_dropped"] += len(points) - len(same_kind)

        kept: list[dict] = []
        for point in same_kind:
            if kept and abs(point["quantity"] - kept[-1]["quantity"]) / kept[-1]["quantity"] <= SAME_SIZE_TOLERANCE:
                continue
            kept.append(point)

        result.products[gtin] = Product(
            gtin=gtin,
            name=str(entry.get("name", "")).strip(),
            brand=str(entry.get("brand", "")).strip(),
            category=str(entry.get("category", "")).strip(),
            unit_kind=kind,
            image_url=entry.get("image_url") or None,
        )

        if len(kept) < 2:
            # Worth a product row (name, brand, image) but it cannot make a verdict.
            stats["skipped"] += 1
            continue

        evidence = str(entry.get("evidence_url", "")) or None
        for point in kept:
            result.observations.append(Observation(
                gtin=gtin,
                quantity=point["quantity"],
                unit_kind=point["unit_kind"],
                raw_text=point["raw"],
                observed_at=point["observed_at"],
                source="curated",
                source_ref=evidence,
                confidence=1.0,
            ))

    result.stats = stats
    return result


def write_curated_sql(result: ImportResult, out_path: Path) -> None:
    """Purge previous curated rows, then upsert every curated product's
    metadata before delegating observations to the shared writer.

    `write_sql`'s `INSERT OR IGNORE` would silently no-op on a GTIN the FDC
    importer already loaded — most of the curated catalogue's food items —
    dropping the curated `image_url`, name, brand and category. Writing our
    own `ON CONFLICT(gtin) DO UPDATE SET ...` here first means a corrected
    curated entry always overwrites what FDC (or an earlier curated seed)
    left behind; `write_sql`'s own `INSERT OR IGNORE` for the same rows,
    emitted afterwards, is then a harmless no-op.
    """
    now = int(datetime.now(tz=timezone.utc).timestamp())
    out_path.parent.mkdir(parents=True, exist_ok=True)
    body_path = out_path.with_suffix(".body.sql")
    write_sql(result, body_path)
    with out_path.open("w", encoding="utf-8") as out:
        out.write("DELETE FROM observations WHERE source='curated';\n")
        products = list(result.products.values())
        if products:
            values = ", ".join(
                f"({_q(p.gtin)}, {_q(p.name)}, {_q(p.brand)}, {_q(p.category)}, {_q(p.image_url)}, {_q(p.unit_kind)}, {now}, {now})"
                for p in products
            )
            out.write(
                "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES "
                + values +
                " ON CONFLICT(gtin) DO UPDATE SET name=excluded.name, brand=excluded.brand, "
                "category=excluded.category, image_url=excluded.image_url, unit_kind=excluded.unit_kind, "
                "updated_at=excluded.updated_at;\n"
            )
        out.write(body_path.read_text(encoding="utf-8"))
    body_path.unlink()


def main() -> int:
    parser = argparse.ArgumentParser(description="Seed curated observations into D1.")
    parser.add_argument("--curated", type=Path, default=Path("data/trending.json"))
    parser.add_argument("--out", type=Path, default=Path("scripts/out/curated.sql"))
    args = parser.parse_args()

    entries = json.loads(args.curated.read_text())["trending"]
    result = build_curated_rows(entries)
    write_curated_sql(result, args.out)
    print(
        f"products={len(result.products)} observations={len(result.observations)} "
        f"skipped={result.stats['skipped']} points_dropped={result.stats['points_dropped']}"
    )
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /Users/drao/Projects/shrunk/scripts && python3 -m pytest tests -q
```
Expected: every test passes, including the seven new `test_seed_curated` cases and the untouched `test_importer` suite (the `image_url` default keeps `test_write_sql_batches_and_escapes` green — `write_sql` itself is unchanged; the upsert lives only in `write_curated_sql`).

- [ ] **Step 6: Generate the real seed and read it**

```bash
cd /Users/drao/Projects/shrunk
python3 scripts/seed_curated.py --curated data/trending.json --out scripts/out/curated.sql
head -3 scripts/out/curated.sql
grep -c "INSERT" scripts/out/curated.sql
```
Expected: `products=35 observations=70 skipped=0 points_dropped=0` (or a small non-zero `skipped` if an entry has a single history point — check `data/trending.json` for that entry and add its second point rather than accepting the skip, because every skipped entry is a curated product that will not produce a verdict in the acceptance run). Line 1 is the `DELETE`, followed by the product and observation inserts. `scripts/out/` is git-ignored, so the SQL is never committed.

- [ ] **Step 7: Commit**

```bash
cd /Users/drao/Projects/shrunk
git add scripts/seed_curated.py scripts/tests/test_seed_curated.py scripts/fdc/importer.py
git commit -m "feat(scripts): seed curated observations into D1 (spec 5.2)" -- \
  scripts/seed_curated.py scripts/tests/test_seed_curated.py scripts/fdc/importer.py
```

---

### Task 8: Close out the user-gated steps from Phases 1–5

Phases 1–5 each ended with steps that need a human with credentials: Cloudflare login, API keys, an Apple key, a Kroger account, App Store Connect configuration. Some may already be done. This task walks every one of them, records the evidence the spec asks for, and leaves a runbook behind so the next release is not archaeology.

**Files:**
- Create: `docs/RELEASE_CHECKLIST.md`
- Modify: `docs/superpowers/specs/2026-08-26-shrunk-v2-design.md` (evidence lines under §6.5 and §9)
- Modify: `Shrunk/Services/ShrunkAPIClient.swift` (production base URL) — only if it still says `REPLACE-ME`

**Interfaces:**
- Consumes: Phase 1 Tasks 9, 12, 13, 14, 15; Phase 3 Task 11; Phase 4 Task 10; Phase 5 Task 12.
- Produces: `$API` — the deployed Worker origin (`https://shrunk-api.<account>.workers.dev`) — which Tasks 9 and 10 both need, and the App Store Server Notifications URL `$API/v1/appstore/notifications`.

- [ ] **Step 1: Find out what is already done**

```bash
cd /Users/drao/Projects/shrunk/backend
npx wrangler whoami
grep -n "database_id\|^id = " wrangler.toml            # zeros mean unprovisioned
npx wrangler secret list
npx wrangler deployments list | head -20
npx wrangler d1 execute shrunk --remote --command "SELECT COUNT(*) AS products FROM products;"
npx wrangler d1 execute shrunk --remote --command "SELECT source, COUNT(*) AS n FROM observations GROUP BY source;"
cd /Users/drao/Projects/shrunk
grep -n "REPLACE-ME\|workers.dev\|baseURL" Shrunk/Services/ShrunkAPIClient.swift | head
grep -n "APNs spike result" docs/superpowers/specs/2026-08-26-shrunk-v2-design.md
grep -n "Permission email sent" docs/superpowers/specs/2026-08-26-shrunk-v2-design.md
```

Write the answers down — each one decides whether the matching step below is a no-op or real work. `secret list` should eventually show `FDC_API_KEY`, `ADMIN_SECRET`, `KROGER_CLIENT_ID`, `KROGER_CLIENT_SECRET`, `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`.

- [ ] **Step 2: Phase 1 Task 9 — Cloudflare, D1, the FDC key, deploy, and the FDC import**

Skip any sub-step whose evidence Step 1 already found.

```bash
cd /Users/drao/Projects/shrunk/backend
npx wrangler login                       # interactive, opens a browser
npx wrangler d1 create shrunk            # copy database_id into wrangler.toml
npx wrangler r2 bucket create shrunk-photos
npx wrangler secret put FDC_API_KEY      # free key from https://api.data.gov/signup/
npx wrangler secret put ADMIN_SECRET     # any long random string; keep it in your password manager
npm run migrate:remote && npm run deploy
curl -s https://shrunk-api.<account>.workers.dev/health
```
Expected: `{"ok":true}`. Confirm the account is on **Workers Paid** (dashboard → Workers & Pages → Plans) — the FDC import exceeds the free tier's 100k D1 writes/day.

Then the import (~430 MB download, several minutes to load):

```bash
cd /Users/drao/Projects/shrunk
curl -L -o /tmp/fdc_branded.zip "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_branded_food_csv_2026-04-30.zip"
python3 scripts/fdc_import.py --zip /tmp/fdc_branded.zip --out scripts/out/fdc.sql \
  --report scripts/out/report.json --curated data/trending.json
cat scripts/out/report.json
cd backend && npx wrangler d1 execute shrunk --remote --file ../scripts/out/fdc.sql
```
If wrangler rejects the file for size, split it — every line is a complete statement:

```bash
cd /Users/drao/Projects/shrunk/backend
split -l 1000 -d ../scripts/out/fdc.sql ../scripts/out/fdc_part_
for f in ../scripts/out/fdc_part_*; do npx wrangler d1 execute shrunk --remote --file "$f"; done
```

- [ ] **Step 3: Load the curated catalogue (Task 7's seeder)**

```bash
cd /Users/drao/Projects/shrunk
python3 scripts/seed_curated.py --curated data/trending.json --out scripts/out/curated.sql
cd backend && npx wrangler d1 execute shrunk --remote --file ../scripts/out/curated.sql
npx wrangler d1 execute shrunk --remote --command "SELECT source, COUNT(*) AS n FROM observations GROUP BY source;"
```
Expected: a `curated` row with roughly 70 observations alongside the `fdc` rows. This must happen **after** the FDC load, because the FDC file has no `DELETE` and the curated file's `DELETE` only touches `source='curated'`.

- [ ] **Step 4: Phase 3 Task 11 — KV, Kroger secrets, deploy**

```bash
cd /Users/drao/Projects/shrunk/backend
npx wrangler kv namespace create KROGER   # copy the id into the [[kv_namespaces]] block, keep binding = "KV"
npx wrangler secret put KROGER_CLIENT_ID
npx wrangler secret put KROGER_CLIENT_SECRET
npm run deploy

API=https://shrunk-api.<account>.workers.dev
curl -s "$API/v1/kroger/locations?zip=45044" | head -c 400
curl -si "$API/v1/kroger/product/0028400642255?locationId=<locationId>" | head -20
```
Expected: `"attribution":"Prices from Kroger"` in both bodies, a forwarded `Cache-Control` header, and a `regular` price. `{"error":"kroger_upstream","status":401}` means the credentials are wrong.

- [ ] **Step 5: Phase 1 Task 15 — Kroger account and the permission email (spec §9)**

1. Register at https://developer.kroger.com, create an application with the **Products** and **Locations** APIs, note the Client ID and Secret (used in Step 4).
2. Send the email drafted in spec **Appendix A** to the support contact on developer.kroger.com/support, with the Client ID filled in.
3. Record the send date in the spec. Under §9, replace the line `- Permission email draft: Appendix A. Send in week 1.` with:

```markdown
- Permission email draft: Appendix A. **Sent YYYY-MM-DD** from privacy@stackcurious.com to Kroger developer support (client id `<client id>`); no reply as of YYYY-MM-DD. Until it is answered, `KROGER_PERSIST` stays on and `POST /v1/admin/purge-kroger` is the one-command retraction.
```

Fill both dates with the real ones. This line is the record that the mitigation in §9 was actually carried out — a reviewer, or Kroger, may ask.

- [ ] **Step 6: Phase 1 Task 14 — the APNs spike result (spec §6.5)**

If §6.5 has no result line, run the spike from Phase 1 Task 14 (`backend/spikes/apns-probe.ts`) and then append one line under §6.5:

```markdown
APNs spike result (YYYY-MM-DD): direct APNs from Workers returns 200 — Phase 4 ships `PUSH_PROVIDER="apns"`.
```

or, if it failed:

```markdown
APNs spike result (YYYY-MM-DD): direct APNs from Workers failed (<the error>) — Phase 4 ships `PUSH_PROVIDER="fcm"` behind the same `PushSender` interface.
```

Whichever line you write must match the `PUSH_PROVIDER` value in `backend/wrangler.toml`. Check it: `grep -n PUSH_PROVIDER backend/wrangler.toml`.

- [ ] **Step 7: Phase 4 Task 10 — APNs key, push secrets, crons**

1. developer.apple.com → Certificates, Identifiers & Profiles → **Keys** → **+** → name `Shrunk APNs`, tick **Apple Push Notifications service (APNs)** → Register → download `AuthKey_XXXXXXXXXX.p8` (**one download only**; store it in `~/keys/`, never in the repo).
2. Confirm the App ID `com.shrunk.app` has **Push Notifications** enabled.

```bash
cd /Users/drao/Projects/shrunk/backend
npx wrangler secret put APNS_KEY_P8      # paste the whole file including BEGIN/END, then Ctrl-D
npx wrangler secret put APNS_KEY_ID      # the 10 characters from the filename
npx wrangler secret put APNS_TEAM_ID     # X4VJ56X38V
npx wrangler deploy
```
Expected: the deploy output lists all three schedules — `*/5 * * * *`, `0 */6 * * *`, `0 1 * * 1`. `APNS_ENV` stays `"sandbox"` for TestFlight; flip it to `"production"` in `[vars]` and redeploy when the App Store build ships (Task 10, Step 8).

- [ ] **Step 8: Phase 1 Task 12 — the app's base URL**

```bash
cd /Users/drao/Projects/shrunk
grep -n "REPLACE-ME" Shrunk/Services/ShrunkAPIClient.swift
```
If it matches, replace the placeholder with the real origin from Step 2, then rebuild:

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -10
```
Expected: no `REPLACE-ME` anywhere in `Shrunk/`, and the suite passes.

- [ ] **Step 9: Phase 5 Task 12 — App Store Connect subscriptions**

Work through `docs/ASC_SETUP.md` §2 in App Store Connect: the `Shrunk Pro` group, `com.shrunk.pro.yearly` ($14.99, level 1) and `com.shrunk.pro.monthly` ($2.99, level 2), the 7-day Free Trial introductory offer on the **yearly product only**, and App Store Server Notifications **Version 2** with both URLs set to `$API/v1/appstore/notifications`.

Then press ASC's **Test Notification** button and confirm it returns 200:

```bash
cd /Users/drao/Projects/shrunk/backend && npx wrangler tail --format pretty
```
Expected: the tail shows the notification arriving and being verified. A `401 invalid_signature` means the URL is right but the pinned root or the parser is wrong — that is a Phase 5 bug, not a configuration one.

- [ ] **Step 10: Write `docs/RELEASE_CHECKLIST.md`**

````markdown
# Shrunk — release runbook

Everything that needs a human with credentials. Run top to bottom for a first deploy; for a routine release, only "Ship a build" and "Acceptance" apply.

## Accounts

| Account | Used for | Where the credential lives |
|---|---|---|
| Cloudflare (Workers **Paid**, $5/mo) | Worker, D1, R2, KV, cron | `wrangler login` on this machine |
| api.data.gov | USDA FoodData Central API key | Worker secret `FDC_API_KEY` |
| developer.kroger.com | Products + Locations APIs | Worker secrets `KROGER_CLIENT_ID` / `KROGER_CLIENT_SECRET` |
| Apple Developer (team X4VJ56X38V) | App ID `com.shrunk.app` with Push, APNs `.p8` key, signing | `~/keys/AuthKey_*.p8`, Worker secrets `APNS_KEY_P8` / `APNS_KEY_ID` / `APNS_TEAM_ID` |
| App Store Connect | Listing, subscriptions, TestFlight, Server Notifications | ASC API key in `~/.appstoreconnect/private_keys/` |

No credential belongs in this repository. `.gitignore` blocks `*.p8`, `*.p12`, `*.mobileprovision` and `backend/.dev.vars`.

## First-time backend provisioning

```
cd backend
npx wrangler login
npx wrangler d1 create shrunk              # database_id -> wrangler.toml
npx wrangler kv namespace create KROGER    # id -> wrangler.toml, binding stays "KV"
npx wrangler r2 bucket create shrunk-photos
npx wrangler secret put FDC_API_KEY
npx wrangler secret put ADMIN_SECRET
npx wrangler secret put KROGER_CLIENT_ID
npx wrangler secret put KROGER_CLIENT_SECRET
npx wrangler secret put APNS_KEY_P8
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npm run migrate:remote && npm run deploy
curl -s "$API/health"                      # {"ok":true}
```

Mirror the same secrets into the git-ignored `backend/.dev.vars` for `wrangler dev`.

## Loading data

```
# USDA FoodData Central — on each release (April/October)
curl -L -o /tmp/fdc_branded.zip "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_branded_food_csv_<release>.zip"
python3 scripts/fdc_import.py --zip /tmp/fdc_branded.zip --out scripts/out/fdc.sql \
  --report scripts/out/report.json --curated data/trending.json
cd backend && npx wrangler d1 execute shrunk --remote --file ../scripts/out/fdc.sql

# Curated catalogue — after every edit to data/trending.json
python3 scripts/seed_curated.py --curated data/trending.json --out scripts/out/curated.sql
cd backend && npx wrangler d1 execute shrunk --remote --file ../scripts/out/curated.sql
```

Order matters: FDC first (no purge), curated second (purges only `source='curated'`).

## App Store Connect

Work through `docs/ASC_SETUP.md` end to end. The two things that are easy to forget:

- App Store Server Notifications **V2**, production **and** sandbox URLs = `$API/v1/appstore/notifications`, verified with ASC's Test Notification button.
- The 7-day Free Trial introductory offer goes on the **yearly** product only.

## Ship a build

1. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`.
2. `xcodegen generate`
3. Archive, export and upload — see `scripts/acceptance.md` and the commands in the phase-6 plan, Task 10.
4. Flip `APNS_ENV` to `"production"` in `backend/wrangler.toml` and `npx wrangler deploy` **when the App Store build (not TestFlight) goes live**.

## Acceptance

`scripts/acceptance.md` — 35/35 curated verdicts, ≥60% kitchen-scan history, ≥25/30 live prices. Do not submit without it filled in.

## If Kroger revokes access (spec §9)

```
sed -i '' 's/KROGER_PERSIST = "on"/KROGER_PERSIST = "off"/' backend/wrangler.toml
cd backend && npx wrangler deploy
curl -X POST "$API/v1/admin/purge-kroger" -H "Authorization: Bearer $ADMIN_SECRET"
```
The app degrades to verdict + history + curated alternatives; nothing breaks.

## Status of the one-time steps

| Step | Done | Evidence |
|---|---|---|
| Cloudflare Workers Paid | | |
| D1 `shrunk` created and migrated | | `database_id` in `wrangler.toml` |
| KV `KROGER` created | | id in `wrangler.toml` |
| R2 `shrunk-photos` created | | |
| All secrets set | | `npx wrangler secret list` |
| FDC release imported | | `scripts/out/report.json` line |
| Curated catalogue seeded | | `SELECT source, COUNT(*) FROM observations` |
| APNs key created, push verified | | spec §6.5 result line |
| Kroger account + permission email | | spec §9 date line |
| ASC subscriptions + Server Notifications | | Test Notification 200 |
| Branch protection on `main` | | `gh api repos/stackcurious/shrunk/branches/main/protection` |

Fill this table in as you go — it is the answer to "did we ever actually do that?"
````

- [ ] **Step 11: Commit**

```bash
cd /Users/drao/Projects/shrunk
git add docs/RELEASE_CHECKLIST.md docs/superpowers/specs/2026-08-26-shrunk-v2-design.md \
  backend/wrangler.toml Shrunk/Services/ShrunkAPIClient.swift
git commit -m "chore: release runbook; record APNs spike and Kroger permission dates in the spec" -- \
  docs/RELEASE_CHECKLIST.md docs/superpowers/specs/2026-08-26-shrunk-v2-design.md \
  backend/wrangler.toml Shrunk/Services/ShrunkAPIClient.swift
```

(Drop any path from both commands that this task did not actually change.)

---

### Task 9: The acceptance run (spec §10)

Spec §10, verbatim: *"scanning all 35 curated products yields a verdict for 35/35; a 30-item kitchen scan yields history for ≥60% of food items; a Kroger store set in Cincinnati shows live prices for ≥25 of those 30."* The first is scriptable; the other two need a person, a phone and a kitchen — specifically the TestFlight build Task 10 produces, so this task scripts and scaffolds everything that does not need that build, and Task 10's own closing step runs the rest once it exists.

**Precondition:** Task 0 passed. If it did not, stop and land the missing phase before starting this task.

**Files:**
- Modify: `scripts/hit_rate.py` (`verdict` collapses duplicates and sorts explicitly)
- Create: `scripts/tests/test_hit_rate.py`
- Create: `scripts/acceptance.md`
- Modify: `Shrunk/Services/ShrinkDetector.swift` (apply the same duplicate-size collapse on the device, spec §5.1)
- Modify: `ShrunkTests/ShrinkDetectorTests.swift`

**Interfaces:**
- Consumes: `$API` from Task 8, and a deployed Worker with both FDC and curated observations loaded.
- Produces: `verdict(observations: list[dict]) -> str` returning one of `"no history"`, `"1 point"`, `"shrink -X.X%"` or `"no shrink (+X.X%)"`; and the summary line `found=N/35 with_history=N/35 shrink_detected=N/35`.
- Produces: `ShrinkDetector.collapseDuplicateSizes(_:) -> [SizeRecord]`, the on-device counterpart of `hit_rate.py`'s `_collapse`, applied inside `analyze()`'s `sameKind` filter.
- Produces: `scripts/acceptance.md`, authored in full here with §A's scripted result filled in. §A's on-device spot-check and Sections B–E need the TestFlight build and are completed in Task 10 Step 10 — the finished file is what `docs/ASC_SETUP.md`'s checklist and Task 11's PR body point at.

- [ ] **Step 1: Write the failing test**

`scripts/tests/test_hit_rate.py`:

```python
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from hit_rate import verdict  # noqa: E402


def obs(quantity, kind="volume", at=0, source="fdc"):
    return {"quantity": quantity, "unit_kind": kind, "observed_at": at, "source": source}


def test_no_observations_is_no_history():
    assert verdict([]) == "no history"


def test_a_single_observation_cannot_make_a_verdict():
    assert verdict([obs(946.352, at=1)]) == "1 point"


def test_a_shrink_is_reported_with_its_percentage():
    assert verdict([obs(946.352, at=1), obs(828.058, at=2)]) == "shrink -12.5%"


def test_growth_is_not_a_shrink():
    assert verdict([obs(828.058, at=1), obs(946.352, at=2)]) == "no shrink (+14.3%)"


def test_observations_of_another_kind_are_ignored():
    pair = [obs(12, kind="count", at=1), obs(946.352, at=2), obs(828.058, at=3)]
    assert verdict(pair) == "shrink -12.5%"


def test_out_of_order_observations_are_sorted_before_comparing():
    assert verdict([obs(828.058, at=2), obs(946.352, at=1)]) == "shrink -12.5%"


def test_a_duplicate_size_from_another_source_does_not_flatten_the_verdict():
    # Spec 5.1: two observations within 1% are the same size. A curated "after"
    # and an FDC "after" of the same size must not read as "no shrink".
    history = [
        obs(946.352, at=1, source="curated"),
        obs(828.058, at=2, source="curated"),
        obs(828.058, at=3, source="fdc"),
    ]
    assert verdict(history) == "shrink -12.5%"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/drao/Projects/shrunk/scripts && python3 -m pytest tests/test_hit_rate.py -q
```
Expected: `test_out_of_order_observations_are_sorted_before_comparing` and `test_a_duplicate_size_from_another_source_does_not_flatten_the_verdict` fail — the current `verdict` trusts the response order and compares the last two same-kind rows even when they are the same size.

- [ ] **Step 3: Fix `verdict`**

In `scripts/hit_rate.py`, replace the `verdict` function with:

```python
SAME_SIZE_TOLERANCE = 0.01  # spec §5.1: within 1% is the same size


def _collapse(observations: list[dict]) -> list[dict]:
    """Drop consecutive observations that normalize to the same size (spec §5.1)."""
    kept: list[dict] = []
    for o in observations:
        if kept and abs(o["quantity"] - kept[-1]["quantity"]) / kept[-1]["quantity"] <= SAME_SIZE_TOLERANCE:
            continue
        kept.append(o)
    return kept


def verdict(observations: list[dict]) -> str:
    if not observations:
        return "no history"
    ordered = sorted(observations, key=lambda o: o["observed_at"])
    kind = ordered[-1]["unit_kind"]
    same = _collapse([o for o in ordered if o["unit_kind"] == kind])
    if len(same) < 2:
        return "1 point"
    prev, cur = same[-2]["quantity"], same[-1]["quantity"]
    pct = (cur - prev) / prev * 100
    return f"shrink {pct:.1f}%" if pct < -1 else f"no shrink ({pct:+.1f}%)"
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/drao/Projects/shrunk/scripts && python3 -m pytest tests -q
```
Expected: everything green.

- [ ] **Step 5: Apply the same duplicate collapse to `ShrinkDetector` (iOS)**

`Shrunk/Services/ShrinkDetector.swift::analyze()` has the same bug `verdict` just had: it takes `sameKind[sameKind.count - 2]` / `sameKind.last!` directly, with no de-duplication. A curated product whose two most recent same-kind observations — say a curated "after" size and an FDC "after" observation confirming the same size — are within 1% of each other reads `.unchanged` on the device even though the fixed `hit_rate.py` now correctly calls it a shrink. Fix it the same way, on the device.

First, the failing test. Add to `ShrunkTests/ShrinkDetectorTests.swift`, in the "Cross-unit comparison" section:

```swift
func test_duplicateSizeFromAnotherSource_doesNotFlattenTheVerdict() {
    // Spec §5.1: two observations within 1% are the same size. A curated
    // "after" and an FDC "after" observation of the same size must not
    // become the two most recent records and wash the shrink out to
    // "unchanged" — mirrors hit_rate.py's
    // test_a_duplicate_size_from_another_source_does_not_flatten_the_verdict.
    let now = Date()
    let product = ShrunkProduct(
        id: "test", name: "Test", brand: "", category: "", imageURL: nil,
        sizeHistory: [
            SizeRecord(date: now.addingTimeInterval(-2 * 86_400), quantity: 32, unit: "oz", source: "curated"),
            SizeRecord(date: now.addingTimeInterval(-1 * 86_400), quantity: 28, unit: "oz", source: "curated"),
            SizeRecord(date: now,                                  quantity: 28, unit: "oz", source: "fdc")
        ],
        currentPrice: nil, currency: "USD"
    )
    let record = detector.analyze(product: product)
    XCTAssertTrue(record.verdict.isShrink)
    XCTAssertEqual(record.shrinkPercent, -12.5, accuracy: 0.01)
}
```

Run it to confirm it fails:

```bash
cd /Users/drao/Projects/shrunk
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/ShrinkDetectorTests/test_duplicateSizeFromAnotherSource_doesNotFlattenTheVerdict \
  -quiet 2>&1 | tail -20
```
Expected: fails — `record.verdict` comes back `.unchanged` (0%), because `analyze()` compares the two most recent records without collapsing the duplicate 28oz.

Now fix `Shrunk/Services/ShrinkDetector.swift`. Add a collapse helper and call it inside the `sameKind` closure, right after the kind filter — everything downstream already reads from `sameKind`, so nothing else in the function changes:

```swift
    /// Drop consecutive same-kind records that normalize within 1% of their
    /// predecessor (spec §5.1: within 1% is the same size) — otherwise two
    /// sources independently confirming the same physical size can crowd out
    /// the real shrink between the size before them and the size after.
    ///
    /// Only drops a record once two are already banked: a two-point history
    /// must never collapse down to one, or a legitimate "unchanged" verdict
    /// (two observations within 1% of each other, and nothing else) would
    /// wrongly read as "not enough history" instead — see
    /// `test_unchanged_withinOnePercent`.
    private static func collapseDuplicateSizes(_ records: [SizeRecord]) -> [SizeRecord] {
        var kept: [SizeRecord] = []
        for record in records {
            if kept.count >= 2, let last = kept.last {
                let normalizedQuantity = Self.normalize(record).quantity
                let lastNormalizedQuantity = Self.normalize(last).quantity
                if lastNormalizedQuantity > 0,
                   abs(normalizedQuantity - lastNormalizedQuantity) / lastNormalizedQuantity <= 0.01 {
                    continue
                }
            }
            kept.append(record)
        }
        return kept
    }
```

```swift
        let sameKind: [SizeRecord] = {
            guard let latestKind = sorted.last?.unitKind else { return [] }
            return Self.collapseDuplicateSizes(sorted.filter { $0.unitKind == latestKind })
        }()
```

Run the suite to confirm green:

```bash
cd /Users/drao/Projects/shrunk
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -20
```
Expected: the whole `ShrunkTests` suite passes, including the new test.

- [ ] **Step 6: Run the scripted acceptance against production**

```bash
cd /Users/drao/Projects/shrunk
mkdir -p scripts/out
API=https://shrunk-api.<account>.workers.dev
python3 scripts/hit_rate.py --api "$API" --curated data/trending.json | tee scripts/out/acceptance-hitrate.txt
tail -1 scripts/out/acceptance-hitrate.txt
```
Expected: `found=35/35 with_history=35/35 shrink_detected=35/35`.

- `with_history` below 35 means a curated entry produced fewer than two usable observations — check Task 7 Step 6's `skipped` count and the entry's `history` in `data/trending.json`, fix the data, re-seed, re-run.
- `found` below 35 means `/v1/product` 404'd or errored for a barcode — curl that one gtin and read the error.
- `shrink_detected` below `with_history` means a curated product genuinely does not read as a shrink; look at that product's observations before touching the code, because a wrong curated entry is more likely than a wrong detector.

- [ ] **Step 7: Write `scripts/acceptance.md`**

````markdown
# Shrunk — acceptance run (spec §10)

Run this on the TestFlight build, on a real iPhone, before submitting. Fill in the tables; the filled file is the evidence, and `docs/ASC_SETUP.md`'s pre-submission checklist refuses to pass without it.

**Build:** 2.0.0 (____) · **Date:** ____ · **Device:** ____ · **Store:** Kroger ____ (Cincinnati), locationId ____ · **API:** ____

---

## A. 35/35 curated verdicts — scripted

```
python3 scripts/hit_rate.py --api "$API" --curated data/trending.json | tee scripts/out/acceptance-hitrate.txt
```

**Pass:** `with_history=35/35` (a verdict needs two same-kind observations) **and** `shrink_detected=35/35` (every curated entry is a documented shrink, so anything else is a data bug).

Summary line: `____________________________________________`

| Failure | Barcode | What the observations looked like | Fix |
|---|---|---|---|
| | | | |

Then spot-check three by scanning them on the device, to prove the app agrees with the script: one food item, one non-food item (paper or cleaning), one with a live Kroger price.

| Product | Verdict on device | Matches the script? |
|---|---|---|
| | | |
| | | |
| | | |

---

## B. 30-item kitchen scan — history for ≥60% of food items

Pick 30 real items off your own shelves. Aim for the mix a shopper actually has: roughly two-thirds food, the rest paper, cleaning and personal care. Scan each one and record what the result screen shows.

**Pass:** of the **food** items, at least 60% show a size history (two or more observations, i.e. a real verdict rather than "Not enough history yet").

| # | Product | Food? | History points | Verdict shown | Live price shown | Notes |
|---|---|---|---|---|---|---|
| 1 | | | | | | |
| 2 | | | | | | |
| 3 | | | | | | |
| 4 | | | | | | |
| 5 | | | | | | |
| 6 | | | | | | |
| 7 | | | | | | |
| 8 | | | | | | |
| 9 | | | | | | |
| 10 | | | | | | |
| 11 | | | | | | |
| 12 | | | | | | |
| 13 | | | | | | |
| 14 | | | | | | |
| 15 | | | | | | |
| 16 | | | | | | |
| 17 | | | | | | |
| 18 | | | | | | |
| 19 | | | | | | |
| 20 | | | | | | |
| 21 | | | | | | |
| 22 | | | | | | |
| 23 | | | | | | |
| 24 | | | | | | |
| 25 | | | | | | |
| 26 | | | | | | |
| 27 | | | | | | |
| 28 | | | | | | |
| 29 | | | | | | |
| 30 | | | | | | |

Food items: ____ · With history: ____ · **Rate: ____%** (needs ≥60%)

For every food item with no history, contribute a label photo from the result screen. That is the growth loop working, and it should turn "not enough history yet" into a second observation on the spot.

---

## C. Live prices at a Cincinnati Kroger — ≥25 of the 30

With the store set (Settings → Store, or onboarding), the live-price panel must show a price for at least 25 of the same 30 items.

**Pass:** ____ / 30 items show a regular or promo price, and every one of them displays **"Prices from Kroger"**.

| Miss | Product | What the panel said |
|---|---|---|
| | | |

Spot-check the arithmetic on three: compare the app's cost-per-unit against the shelf tag's unit price. They will not match to the cent (Kroger's per-unit estimate is its own), but the order of magnitude and the unit must be right.

| Product | App cost/unit | Shelf tag | Same unit? |
|---|---|---|---|
| | | | |
| | | | |
| | | | |

---

## D. Subscription and push, end to end

- [ ] Paywall shows yearly preselected with "Save 58%", the 7-day trial, and working Terms and Privacy links
- [ ] Sandbox purchase of the yearly plan unlocks Pro, and `SELECT id, pro_until FROM devices WHERE pro_until IS NOT NULL` shows a future timestamp — the only check that exercises a genuinely Apple-signed JWS
- [ ] `POST /v1/admin/verified-case` for a watched brand delivers a push within five minutes; tapping it opens the product
- [ ] A non-Pro device receives nothing
- [ ] Turning "Weekly digest" off in Settings writes `prefs.digest=false` on the device row

---

## E. Degradation (spec §8)

- [ ] Airplane mode: a previously scanned product shows its cached result; an unknown one shows "Couldn't reach Shrunk — check connection." and never falls back to Open Food Facts
- [ ] With `KROGER_PERSIST="off"` deployed: the live panel says "Store prices unavailable right now", the verdict and history still render, alternatives fall back to curated cases
- [ ] An unknown barcode offers the contribution flow

---

## Result

- [ ] A: 35/35 · [ ] B: ≥60% · [ ] C: ≥25/30 · [ ] D · [ ] E

**Signed off:** ____ on ____
````

- [ ] **Step 8: Fill in §A's scripted result**

No TestFlight build exists yet at this point in the plan — Task 10 is what produces one — so this step only fills in what does not need a device. Paste Step 6's summary line into `scripts/acceptance.md`'s §A "Summary line" blank, and record any script failures in §A's failure table. Leave §A's on-device spot-check table and Sections B–E blank: they need a phone and the TestFlight build, and are completed in Task 10 Step 10 once that build exists.

- [ ] **Step 9: Commit**

```bash
cd /Users/drao/Projects/shrunk
git add scripts/hit_rate.py scripts/tests/test_hit_rate.py scripts/acceptance.md \
  Shrunk/Services/ShrinkDetector.swift ShrunkTests/ShrinkDetectorTests.swift
git commit -m "test(scripts,ios): collapse duplicate sizes in the hit-rate verdict and ShrinkDetector; scaffold the acceptance run" -- \
  scripts/hit_rate.py scripts/tests/test_hit_rate.py scripts/acceptance.md \
  Shrunk/Services/ShrinkDetector.swift ShrunkTests/ShrinkDetectorTests.swift
```

---

### Task 10: Version 2.0.0, the TestFlight build, and release notes

**Precondition:** Task 0 passed. If it did not, stop and land the missing phase before starting this task.

**Files:**
- Modify: `project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`)
- Create: `ExportOptions.plist` (repo root)
- Modify: `scripts/acceptance.md` (fill in §A's on-device spot-check and Sections B–E, deferred from Task 9)
- Modify: `docs/superpowers/specs/2026-08-26-shrunk-v2-design.md` (§10 acceptance results line)

**Interfaces:**
- Consumes: `$API` and the ASC configuration from Task 8; the What's New copy from Task 5; the scaffolded `scripts/acceptance.md` from Task 9.
- Produces: `build/Shrunk.xcarchive` and `build/export/Shrunk.ipa` (both under the git-ignored `build/`), a processed TestFlight build, and the "What to Test" text.
- Produces: the completed `scripts/acceptance.md` and the spec §10 evidence line — Task 9 could not produce either, because both need this task's TestFlight build on a real phone.

- [ ] **Step 1: Bump the version**

In `project.yml`, inside the `Shrunk` target's `settings.base`:

```yaml
        MARKETING_VERSION: "2.0.0"
        CURRENT_PROJECT_VERSION: "2"
```

- [ ] **Step 2: Regenerate and confirm the build carries it**

```bash
cd /Users/drao/Projects/shrunk
xcodegen generate >/dev/null
grep -n "MARKETING_VERSION\|CURRENT_PROJECT_VERSION" project.yml
xcodebuild -scheme Shrunk -showBuildSettings 2>/dev/null | grep -E "MARKETING_VERSION|CURRENT_PROJECT_VERSION"
```
Expected: `2.0.0` and `2` in both. `Info.plist` reads them through `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`, so nothing else changes. Settings → About will show `2.0.0 (2)`.

- [ ] **Step 3: Run the full suite once more**

```bash
cd /Users/drao/Projects/shrunk
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -20
cd backend && npx vitest run && npx tsc --noEmit && npm run check:trending
cd ../scripts && python3 -m pytest tests -q
cd .. && python3 scripts/check_repo_data.py
```
Expected: all green. Do not archive over a red suite.

- [ ] **Step 4: Write `ExportOptions.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>X4VJ56X38V</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
```

- [ ] **Step 5: Archive and export**

```bash
cd /Users/drao/Projects/shrunk
xcodegen generate >/dev/null
xcodebuild archive \
  -scheme Shrunk \
  -destination 'generic/platform=iOS' \
  -archivePath build/Shrunk.xcarchive \
  -quiet
xcodebuild -exportArchive \
  -archivePath build/Shrunk.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export
ls -la build/export
```
Expected: `build/export/Shrunk.ipa`. `build/` is already git-ignored.

Signing failures here are certificate problems, not code problems: the archive needs a **Distribution** certificate and an App Store provisioning profile for `com.shrunk.app` under team X4VJ56X38V. Automatic signing creates them if you are signed into the account in Xcode → Settings → Accounts → Manage Certificates.

- [ ] **Step 6: Upload to TestFlight**

Create an App Store Connect API key once (ASC → Users and Access → Integrations → App Store Connect API → **+**, role *App Manager*), download `AuthKey_<KEYID>.p8` and put it in `~/.appstoreconnect/private_keys/`. Then:

```bash
xcrun altool --upload-app -f build/export/Shrunk.ipa -t ios \
  --apiKey <KEYID> --apiIssuer <ISSUER-UUID>
```
Expected: `No errors uploading`. Processing takes 5–30 minutes; watch it in ASC → TestFlight.

The GUI equivalent, if the key is not set up: Xcode → Window → Organizer → select the archive → **Distribute App** → App Store Connect → Upload. Same artefact, more clicking.

- [ ] **Step 7: Fill in TestFlight metadata**

In ASC → TestFlight → the new build:

- **What to Test:**

```
Shrunk 2.0.0 — please run the acceptance pass in scripts/acceptance.md.

1. Scan 20-30 things from your own kitchen. Note anything that says "Not enough history yet" — especially food.
2. Set your Kroger store (Settings -> Store). Re-scan a few and check the live price panel: regular/promo, cost per unit, stock, and the "Prices from Kroger" line.
3. Snap a label on something with no history and check the reading it comes back with.
4. Start the 7-day trial on the yearly plan, add a couple of products to your watchlist, and confirm alerts arrive.
5. Turn on airplane mode and scan: you should see a cached result or a clear "couldn't reach Shrunk" message, never a crash.

Report anything wrong to privacy@stackcurious.com with the product name and barcode.
```

- **Test Information → Beta App Description:** the first paragraph of the App Store description in `docs/APP_STORE_LISTING.md`.
- **Beta App Review** is only needed for external testers; internal testers on your own team get the build as soon as it finishes processing.
- Export compliance: answered automatically from `ITSAppUsesNonExemptEncryption=false` (see `docs/ASC_SETUP.md` §8).

- [ ] **Step 8: Note the APNs environment**

TestFlight builds are signed with the `development` aps-environment and talk to APNs sandbox, so `APNS_ENV` stays `"sandbox"` in `backend/wrangler.toml` for the whole beta. Flip it to `"production"` and `npx wrangler deploy` **only when the App Store build goes live** — doing it early silently breaks TestFlight push. Add a reminder to the release checklist's "Ship a build" section if it is not already there.

- [ ] **Step 9: Commit**

```bash
cd /Users/drao/Projects/shrunk
git add project.yml ExportOptions.plist
git commit -m "chore: 2.0.0 (2) and App Store export options" -- project.yml ExportOptions.plist
git push origin feat/v2-real-data
```

- [ ] **Step 10: Run the device-dependent acceptance sections and record the result**

Task 9 already produced the scripted 35/35 curated result (`scripts/out/acceptance-hitrate.txt`) and the `scripts/acceptance.md` scaffold with §A's scripted result filled in. Everything left needs a phone and this specific build, not the simulator — do it once build 2.0.0 (2) has finished processing in TestFlight (Step 6/7 above) and you can install it.

Fill in the **Build**, **Date**, **Device**, **Store** and **API** line at the top of `scripts/acceptance.md`, then work through:
- §A's on-device spot-check (three products, cross-checked against the script)
- §B — 30-item kitchen scan, ≥60% of food items with history
- §C — Cincinnati Kroger live prices, ≥25/30
- §D — subscription and push, end to end
- §E — degradation (spec §8)

Tick every box in the Result line and sign off. If a threshold misses, fix the cause and re-run that section — a threshold in the spec is not negotiable by editing the spec.

Then append one line to spec §10, immediately after the "Acceptance before submission" bullet:

```markdown
  Acceptance run YYYY-MM-DD on build 2.0.0 (2): curated 35/35 with history, 35/35 shrink detected; kitchen scan NN/NN food items with history (NN%); live prices NN/30 at Kroger <store> Cincinnati. Full record: `scripts/acceptance.md`.
```

```bash
cd /Users/drao/Projects/shrunk
git add scripts/acceptance.md docs/superpowers/specs/2026-08-26-shrunk-v2-design.md
git commit -m "test: complete the device-dependent acceptance run on the 2.0.0 TestFlight build" -- \
  scripts/acceptance.md docs/superpowers/specs/2026-08-26-shrunk-v2-design.md
```

---

### Task 11: Open the PR, wait for CI, merge, tag `v2.0.0`

**Precondition:** Task 0 passed. If it did not, stop and land the missing phase before starting this task.

**Files:** none — this task only runs commands.

**Interfaces:**
- Consumes: the four status-check contexts from Task 1 (`backend`, `scripts`, `fixtures`, `ios`), the scripted acceptance result from Task 9 and the completed acceptance run and spec evidence line from Task 10 Step 10, and the version from Task 10.
- Produces: a merge commit on `main` and the annotated tag `v2.0.0`.

- [ ] **Step 1: Make sure the branch is clean and pushed**

```bash
cd /Users/drao/Projects/shrunk
git status --porcelain          # must be empty
git rev-parse --abbrev-ref HEAD # feat/v2-real-data
git push origin feat/v2-real-data
git log --oneline main..HEAD | wc -l
```
Expected: nothing uncommitted, and a commit count in the dozens. If `git status` is dirty, commit or discard deliberately — never `git stash` in a shared worktree.

- [ ] **Step 2: Collect the numbers the PR body claims**

```bash
cd /Users/drao/Projects/shrunk/backend && npx vitest run 2>&1 | tail -5
cd /Users/drao/Projects/shrunk/scripts && python3 -m pytest tests -q 2>&1 | tail -3
xcodegen generate >/dev/null && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' 2>&1 | grep -E "Test Suite .* passed|Executed .* tests"
tail -1 scripts/out/acceptance-hitrate.txt
```
Write down the three test counts and the hit-rate line — the PR body states them, and a stated number that nobody ran is worse than no number.

- [ ] **Step 3: Open the PR**

```bash
cd /Users/drao/Projects/shrunk
gh pr create --base main --head feat/v2-real-data \
  --title "Shrunk v2 — real data, real Pro" \
  --body "$(cat <<'BODY'
Rebuilds Shrunk on observed data. Every paid feature is now backed by something we can point at — a USDA record, a curated case with a published source, a shopper's label photo, or a live Kroger price — which is what makes a $2.99/mo subscription defensible.

Spec: `docs/superpowers/specs/2026-08-26-shrunk-v2-design.md`

## Phases

| Phase | Plan | What landed |
|---|---|---|
| 1 | `week1-data-backbone` | FDC importer (Python), shared normalizer fixtures, D1 schema, Worker scaffold, `GET /v1/product`, `ShrunkAPIClient`, kind-aware `ShrinkDetector`. Open Food Facts and UPCItemDB removed from the scan path. |
| 2 | `phase2-crowd-observations` | Label capture, on-device Vision OCR, `POST /v1/observations`, the confidence gate (spec §6.3), admin review page with R2 photos. |
| 3 | `phase3-kroger-live-layer` | KV-cached Kroger OAuth, three proxy routes, per-device rate limit, snapshots behind `KROGER_PERSIST`, `POST /v1/admin/purge-kroger`, store picker, live-price panel, alternatives rewritten over store search. |
| 4 | `phase4-push-devices-crons` | `POST /v1/devices`, `GET /v1/feed`, APNs/FCM sender behind one interface, the alert drain, Kroger sweep and weekly digest crons, new alert kinds, Browse on `/v1/feed`. |
| 5 | `phase5-subscription-onboarding-dashboard` | Self-contained App Store JWS verification against a pinned Apple Root CA - G3, `POST /v1/appstore/notifications`, subscription StoreKit service, paywall, four-screen onboarding, savings dashboard on observed data, Pro-gated history charts. |
| 6 | `phase6-release-readiness` | CI, monorepo docs, privacy policy and terms, in-app attribution, App Store paperwork, curated seeding into D1, the acceptance run, 2.0.0. |

## Product changes

- Pro is a subscription: `com.shrunk.pro.yearly` $14.99 (7-day trial) and `com.shrunk.pro.monthly` $2.99. The `com.shrunk.pro.lifetime` non-consumable is gone — no purchases existed.
- Free keeps unlimited scans, verdicts, size history, current price and cost-per-unit, the browse feed, contributions, and 3 alternatives per scan.
- Removed: the 10-screen quiz onboarding and its guessed "$/yr exposure", `SavingsForecast` and its category constants, `OpenFoodFactsService`, `UPCItemDBService`.

## Tests

- Worker: `npx vitest run` — NN tests across NN files
- Python: `python3 -m pytest tests -q` — NN tests
- iOS: `xcodebuild test` — NN tests
- CI runs all three plus a repo-data check on every push (`.github/workflows/ci.yml`)

## Acceptance (spec §10)

`scripts/acceptance.md` — curated 35/35 with history and 35/35 shrink detected; kitchen scan NN% of food items with history (needs ≥60%); live prices NN/30 at a Cincinnati Kroger (needs ≥25).

Hit rate: `found=NN/35 with_history=NN/35 shrink_detected=NN/35`

## Kroger terms (spec §9)

Snapshots are retained while a written-permission request is pending — sent YYYY-MM-DD, recorded in spec §9. Mitigations are built in and tested: every Kroger-derived row is tagged and removable with `POST /v1/admin/purge-kroger`, `KROGER_PERSIST="off"` stops new writes immediately, no cross-retailer comparison exists, attribution is shown wherever Kroger data appears, and every other feature works without Kroger.

## Docs

`README.md`, `CLAUDE.md`, `backend/README.md`, `data/README.md`, `docs/PRIVACY_POLICY.md`, `docs/TERMS.md`, `docs/APP_STORE_LISTING.md`, `docs/ASC_SETUP.md`, `docs/RELEASE_CHECKLIST.md`, `scripts/acceptance.md`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01CBomK7zqk1ojruHm5uTsum
BODY
)"
```

Then replace every `NN` and `YYYY-MM-DD` with the real numbers from Step 2 and the dates from Task 8 — either in the browser, or by editing a local copy of the body:

```bash
gh pr view --web     # edit the body in the browser, or:
gh pr view --json body -q .body > /tmp/pr-body.md   # dump the current body, then edit /tmp/pr-body.md by hand
gh pr edit --body-file /tmp/pr-body.md
```
A PR body with `NN` left in it is not done.

- [ ] **Step 4: Wait for CI**

```bash
cd /Users/drao/Projects/shrunk
gh pr checks --watch
```
Expected: `backend`, `scripts`, `fixtures` and `ios` all pass. If a job fails, fix it on the branch and push — never merge past a red check, and never disable a check to get green.

- [ ] **Step 5: Walk the pre-submission checklist one last time**

Open `docs/ASC_SETUP.md` and confirm every box is ticked, and that `scripts/acceptance.md` is filled in with all three thresholds met. Then confirm the recorded run actually matches this build, not an older one:

```bash
cd /Users/drao/Projects/shrunk
grep -n "^\*\*Build:\*\*" scripts/acceptance.md
grep -n "MARKETING_VERSION\|CURRENT_PROJECT_VERSION" project.yml
```
Expected: the `Build:` line in `scripts/acceptance.md` names the same version and build number as `project.yml` (`2.0.0 (2)`). A results file filled in against a different build is not evidence for this one — re-run Task 10 Step 10 against the current build before merging. This is the last point where stopping is cheap.

- [ ] **Step 6: Merge with a merge commit**

```bash
cd /Users/drao/Projects/shrunk
gh pr merge --merge --subject "Shrunk v2 — real data, real Pro"
```

`--merge`, not `--squash`: the branch is six phases and ~60 commits, each one a task with its own tests, and the phase plans reference those commits by hash (`.superpowers/sdd/*/review-<sha>..<sha>.diff`, the review ledgers). Squashing would collapse that history into one opaque commit and break every reference — the point of the ledger is that a future session can read why a line exists. A merge commit keeps the phase history and still marks the integration point.

- [ ] **Step 7: Tag the release**

```bash
cd /Users/drao/Projects/shrunk
git checkout main
git pull origin main
git log --oneline -1                       # the merge commit
git tag -a v2.0.0 -m "Shrunk 2.0.0 — real data, real Pro"
git push origin v2.0.0
gh release create v2.0.0 --title "Shrunk 2.0.0" --notes-file - <<'NOTES'
Shrunk v2 — every verdict now comes from real, dated observations.

- Size history from USDA FoodData Central, curated cases with published evidence, and shopper label photos
- Live prices and cost-per-unit at your Kroger store ("Prices from Kroger")
- Contribute a label photo: Vision reads the net weight on your phone
- Alternatives ranked by price per unit at your store
- Shrunk Pro is now a subscription — $2.99/month or $14.99/year with a 7-day free trial — covering watchlist alerts, the weekly digest, unlimited alternatives, full history charts, and a savings dashboard computed from observed data

Removed: the quiz onboarding and its guessed yearly-exposure figure, the invented savings forecast, and the lifetime IAP.
NOTES
```

- [ ] **Step 8: Confirm `main` is what you think it is**

```bash
cd /Users/drao/Projects/shrunk
git log --oneline -5
gh run list --branch main --limit 4
grep -n "MARKETING_VERSION" project.yml
python3 scripts/check_repo_data.py
```
Expected: the merge commit on top, CI green on `main`, `2.0.0`, `repo data OK`.

- [ ] **Step 9: Submit for review**

In App Store Connect: attach build 2.0.0 (2), submit the two subscriptions **with** the build, paste the reviewer note from `docs/ASC_SETUP.md` §7, and submit. Then record the submission date at the top of `docs/RELEASE_CHECKLIST.md` and, if anything about the process surprised you, add a line to `tasks/lessons.md`.

---

## Phase 6 exit criteria

- [ ] `.github/workflows/ci.yml` runs four jobs green on every push, and `main` requires them (or the 403 was recorded because the plan does not allow it).
- [ ] `python3 scripts/check_repo_data.py` prints `repo data OK`; the three copies of `trending.json` are identical.
- [ ] `cd backend && npx vitest run && npx tsc --noEmit && npm run check:trending` — green.
- [ ] `cd scripts && python3 -m pytest tests -q` — green, including `test_check_repo_data`, `test_seed_curated` and `test_hit_rate`.
- [ ] `xcodegen generate && xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=…'` — green.
- [ ] `README.md`, `CLAUDE.md`, `backend/README.md` and `data/README.md` describe the system as it is: `/v1/feed`, not jsDelivr; a subscription, not a lifetime IAP; twelve endpoints, not five.
- [ ] `docs/PRIVACY_POLICY.md` and `docs/TERMS.md` exist, match what the code actually stores, and are published at `stackcurious.com/shrunk/privacy` and `/terms`.
- [ ] `docs/ASC_SETUP.md` §4 answers **"yes, we collect data"** with five data types, all not-linked and not-for-tracking; §8 covers export compliance; the checklist is complete.
- [ ] The spec carries three evidence lines: the APNs spike result under §6.5, the Kroger permission email date under §9, the acceptance results under §10.
- [ ] `SELECT source, COUNT(*) FROM observations GROUP BY source` on production shows both `fdc` and `curated`.
- [ ] `scripts/acceptance.md` is filled in: 35/35 curated verdicts, ≥60% kitchen-scan history for food, ≥25/30 live prices at a Cincinnati Kroger.
- [ ] `project.yml` says `2.0.0` / `2`; build 2.0.0 (2) is processed in TestFlight.
- [ ] The PR is merged into `main` with a merge commit, `v2.0.0` is tagged and pushed, and the App Store submission is in review.
