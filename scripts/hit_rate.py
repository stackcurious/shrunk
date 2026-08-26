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
        with urllib.request.urlopen(f"{api}/v1/product/{gtin}", timeout=20) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, None


def verdict(observations: list[dict]) -> str:
    if not observations:
        return "no history"
    kind = observations[-1]["unit_kind"]
    same = [o for o in observations if o["unit_kind"] == kind]
    if len(same) < 2:
        return "1 point"
    prev, cur = same[-2]["quantity"], same[-1]["quantity"]
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
