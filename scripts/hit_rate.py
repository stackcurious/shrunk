#!/usr/bin/env python3
"""Measure scan coverage of the deployed API over the curated product list."""
import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fdc.gtin import normalize_gtin  # noqa: E402


def fetch(api: str, gtin: str) -> tuple[int, dict | None]:
    try:
        req = urllib.request.Request(f"{api}/v1/product/{gtin}", headers={"User-Agent": "shrunk-hit-rate/1.0"})
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, None


SAME_SIZE_TOLERANCE = 0.01  # spec §5.1: within 1% is the same size


def _same_size(reference: float, quantity: float) -> bool:
    """Within SAME_SIZE_TOLERANCE of `reference`.

    A zero (or negative) reference has no meaningful percentage, so only an
    exact match counts — which keeps a `0 -> 28` history two runs, not one.
    """
    if reference <= 0:
        return quantity == reference
    return abs(quantity - reference) / reference <= SAME_SIZE_TOLERANCE


def collapse_runs(observations: list[dict]) -> list[dict]:
    """Collapse same-kind observations, oldest first, into size runs (spec §5.1).

    Without this a *confirmation* reads as a *change of nothing*: when a second
    source reports exactly the size the last observation already recorded, the
    last-two-observations pair is `450 -> 450`, `+0.0%`, "no shrink" — erasing
    the documented `500 -> 450` behind it. Eight of the 25 verified curated
    entries scored that way (.curated-verify-report.md §5).

    Each observation is compared against the value that *opened* the current
    run rather than its immediate predecessor, so a slow drift of
    within-tolerance steps cannot accumulate into one run spanning a real
    change.

    Parity: `Shrunk/Services/ShrinkDetector.swift` (`collapseRuns`) and
    `backend/src/runs.ts` (`collapseRuns`) implement the same rule.
    """
    runs: list[dict] = []
    for o in observations:
        if runs and _same_size(runs[-1]["quantity"], o["quantity"]):
            runs[-1]["observed_at"] = o.get("observed_at")
            if o.get("source") not in runs[-1]["sources"]:
                runs[-1]["sources"].append(o.get("source"))
        else:
            runs.append({
                "quantity": o["quantity"],
                "source": o.get("source"),
                "opened_at": o.get("observed_at"),
                "observed_at": o.get("observed_at"),
                "sources": [o.get("source")],
            })
    return runs


def verdict(observations: list[dict]) -> str:
    if not observations:
        return "no history"
    kind = observations[-1]["unit_kind"]
    same = [o for o in observations if o["unit_kind"] == kind]
    runs = collapse_runs(same)
    if len(runs) < 2:
        return "1 size on record"
    prev, cur = runs[-2]["quantity"], runs[-1]["quantity"]
    if prev <= 0:
        return "1 size on record"
    pct = (cur - prev) / prev * 100
    return f"shrink {pct:.1f}%" if pct < -1 else f"no shrink ({pct:+.1f}%)"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", required=True)
    ap.add_argument("--curated", type=Path, default=Path("data/trending.json"))
    args = ap.parse_args()

    entries = json.loads(args.curated.read_text())["trending"]
    found = with_history = detected = 0
    for e in entries:
        gtin = normalize_gtin(e["barcode"]) or e["barcode"]
        status, body = fetch(args.api.rstrip("/"), gtin)
        if status != 200 or body is None:
            print(f"{e['name'][:34]:34} | {gtin} | HTTP {status}")
            continue
        found += 1
        v = verdict(body["observations"])
        if body["observations"]:
            with_history += 1
        if v.startswith("shrink"):
            detected += 1
        print(f"{e['name'][:34]:34} | {gtin} | {len(body['observations'])} obs | {v}")
    n = len(entries)
    print(f"\nfound={found}/{n} with_history={with_history}/{n} shrink_detected={detected}/{n}")


if __name__ == "__main__":
    main()
