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
