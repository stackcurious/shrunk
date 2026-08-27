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
