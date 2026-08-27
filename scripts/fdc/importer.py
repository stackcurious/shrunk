"""Stream an FDC Branded Foods release zip into products/observations SQL for D1."""
from __future__ import annotations

import csv
import io
import json
import sys
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from .gtin import normalize_gtin
from .normalize import parse_package_weight

csv.field_size_limit(sys.maxsize)

SAME_SIZE_TOLERANCE = 0.01
US_COUNTRIES = {"United States", "US"}


@dataclass
class Product:
    gtin: str
    name: str
    brand: str
    category: str
    unit_kind: str
    image_url: str | None = None


@dataclass
class Observation:
    gtin: str
    quantity: float
    unit_kind: str
    raw_text: str
    observed_at: int
    source: str
    source_ref: str | None
    confidence: float


@dataclass
class ImportResult:
    products: dict[str, Product] = field(default_factory=dict)
    observations: list[Observation] = field(default_factory=list)
    stats: dict = field(default_factory=dict)


def _open_member(z: zipfile.ZipFile, suffix: str) -> io.TextIOWrapper:
    # Prefer directory-qualified match, fall back to exact basename match.
    # This handles both "dir/food.csv" and "food.csv" without matching "branded_food.csv".
    for n in z.namelist():
        if n.endswith("/" + suffix) or n == suffix:
            return io.TextIOWrapper(z.open(n), encoding="utf-8", newline="")
    raise FileNotFoundError(f"{suffix} not found in {z.filename}")


def _epoch(*candidates: str) -> int | None:
    for c in candidates:
        if c:
            try:
                return int(datetime.strptime(c, "%Y-%m-%d").replace(tzinfo=timezone.utc).timestamp())
            except ValueError:
                continue
    return None


def build_rows(zip_path: Path) -> ImportResult:
    result = ImportResult()
    stats = {"rows_read": 0, "rows_with_weight": 0, "rows_malformed": 0, "rows_non_us": 0,
             "rows_bad_gtin": 0, "versions_kept": 0, "gtins_with_multiple_sizes": 0}

    # Pass 1: branded_food.csv -> raw versions grouped by GTIN.
    versions: dict[str, list[dict]] = {}
    with zipfile.ZipFile(zip_path) as z:
        with _open_member(z, "branded_food.csv") as fh:
            for row in csv.DictReader(fh):
                stats["rows_read"] += 1
                if not row["package_weight"]:
                    continue
                stats["rows_with_weight"] += 1
                if row["market_country"] not in US_COUNTRIES:
                    stats["rows_non_us"] += 1
                    continue
                gtin = normalize_gtin(row["gtin_upc"])
                if not gtin:
                    stats["rows_bad_gtin"] += 1
                    continue
                parsed = parse_package_weight(row["package_weight"])
                if not parsed:
                    stats["rows_malformed"] += 1
                    continue
                versions.setdefault(gtin, []).append({
                    "fdc_id": row["fdc_id"],
                    "quantity": parsed.quantity,
                    "unit_kind": parsed.unit_kind,
                    "raw": row["package_weight"],
                    "brand": (row["brand_name"] or row["brand_owner"]).strip(),
                    "category": row["branded_food_category"].strip(),
                    "available": row["available_date"],
                    "modified": row["modified_date"],
                })

        # Pass 2: food.csv -> description + publication_date for the fdc_ids we kept.
        wanted = {v["fdc_id"] for vs in versions.values() for v in vs}
        names: dict[str, tuple[str, str]] = {}
        with _open_member(z, "food.csv") as fh:
            for row in csv.DictReader(fh):
                if row["fdc_id"] in wanted:
                    names[row["fdc_id"]] = (row["description"].strip(), row["publication_date"])

    for gtin, vs in versions.items():
        for v in vs:
            desc, pub = names.get(v["fdc_id"], ("", ""))
            v["name"] = desc
            v["observed_at"] = _epoch(v["available"], v["modified"], pub)
        vs = [v for v in vs if v["observed_at"] is not None]
        if not vs:
            continue
        vs.sort(key=lambda v: (v["observed_at"], int(v["fdc_id"])))

        # Dominant kind = kind of the most recent version; drop other kinds.
        kind = vs[-1]["unit_kind"]
        same_kind = [v for v in vs if v["unit_kind"] == kind]

        kept: list[dict] = []
        for v in same_kind:
            if kept and abs(v["quantity"] - kept[-1]["quantity"]) / kept[-1]["quantity"] <= SAME_SIZE_TOLERANCE:
                continue
            kept.append(v)

        latest = vs[-1]
        result.products[gtin] = Product(
            gtin=gtin, name=latest["name"], brand=latest["brand"], category=latest["category"], unit_kind=kind,
        )
        for v in kept:
            result.observations.append(Observation(
                gtin=gtin, quantity=v["quantity"], unit_kind=v["unit_kind"], raw_text=v["raw"],
                observed_at=v["observed_at"], source="fdc", source_ref=v["fdc_id"], confidence=0.9,
            ))
        stats["versions_kept"] += len(kept)
        if len(kept) > 1:
            stats["gtins_with_multiple_sizes"] += 1

    result.stats = stats
    return result


def _q(value: str | None) -> str:
    if value is None:
        return "NULL"
    return "'" + value.replace("'", "''") + "'"


def write_sql(result: ImportResult, out_path: Path, batch: int = 200) -> None:
    now = int(datetime.now(tz=timezone.utc).timestamp())
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as out:
        products = list(result.products.values())
        for i in range(0, len(products), batch):
            # One statement per line so the file can be split by line count for upload.
            values = ", ".join(
                f"({_q(p.gtin)}, {_q(p.name)}, {_q(p.brand)}, {_q(p.category)}, {_q(p.image_url)}, {_q(p.unit_kind)}, {now}, {now})"
                for p in products[i:i + batch]
            )
            out.write("INSERT OR IGNORE INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES "
                      + values + ";\n")
        obs = result.observations
        for i in range(0, len(obs), batch):
            values = ", ".join(
                f"({_q(o.gtin)}, {o.quantity}, {_q(o.unit_kind)}, {_q(o.raw_text)}, {o.observed_at}, {_q(o.source)}, {_q(o.source_ref)}, {o.confidence}, 'accepted', {now})"
                for o in obs[i:i + batch]
            )
            out.write("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES "
                      + values + ";\n")


def write_report(result: ImportResult, curated_path: Path | None, report_path: Path) -> None:
    report = {"stats": result.stats, "products": len(result.products), "observations": len(result.observations)}
    if curated_path and curated_path.exists():
        entries = json.loads(curated_path.read_text())["trending"]
        found, missing, multi = 0, [], 0
        multi_gtins = {o.gtin for o in result.observations}
        counts: dict[str, int] = {}
        for o in result.observations:
            counts[o.gtin] = counts.get(o.gtin, 0) + 1
        for e in entries:
            gtin = normalize_gtin(e["barcode"]) or e["barcode"]
            if gtin in result.products:
                found += 1
                if counts.get(gtin, 0) > 1:
                    multi += 1
            else:
                missing.append(gtin)
        report["curated"] = {"total": len(entries), "found": found, "missing": missing, "with_multiple_sizes": multi}
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2))
