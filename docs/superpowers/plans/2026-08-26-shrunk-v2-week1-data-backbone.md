# Shrunk v2 — Week 1: Data Backbone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the app's hollow Open Food Facts scan path with a Cloudflare Worker backed by a D1 database of USDA FoodData Central package-size history, so scanning a product returns real before/after observations and a verdict.

**Architecture:** A Python importer streams the FDC Branded Foods CSV release into normalized `products` + `observations` rows loaded into D1. A Hono-based Worker serves `GET /v1/product/{gtin}` (merged observations; creates unknown products from the FDC API → Open Food Facts). The iOS app gains a `ShrunkAPIClient` that replaces `OpenFoodFactsService`/`UPCItemDBService` in the scan and watchlist paths, and `ShrinkDetector` becomes unit-kind aware. Ends with a hit-rate report over the 35 curated products and a throwaway APNs-from-Workers spike.

**Tech Stack:** Python 3.14 (stdlib only) + pytest · TypeScript, Hono 4, Wrangler 4, Cloudflare D1, Vitest with `@cloudflare/vitest-pool-workers` · Swift 5.9 / SwiftUI / XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-26-shrunk-v2-design.md` (§4 Architecture, §5 Data model & normalization, §6.1 `/v1/product`, §6.4 FDC import, §6.5 Push spike, §7 iOS changes, §10 Testing, §11 Week 1).

## Global Constraints

- Barcodes are stored and exchanged as **13-digit zero-padded GTINs** (spec §2). 12-digit UPC-A → prefix `0`; 14-digit GTIN-14 with leading `0` → drop it.
- Quantities are normalized to **grams (mass), millilitres (volume), or count** with `unit_kind ∈ {mass, volume, count}`; observations of different kinds are never compared (spec §5.1).
- Normalizer tolerance: two observations within **1%** are the same size; multi-segment package weights whose segments disagree by more than **2%** are discarded as malformed (spec §5.1).
- Verdict thresholds unchanged: ≤ −10% significant, −10..−5 moderate, −5..−1 minor, ±1 unchanged, >1 grew.
- Sources and defaults for this week: `fdc` confidence 0.9 accepted; `curated` 1.0 accepted (spec §5.2).
- Cloudflare **Workers Paid** ($5/mo) — the import exceeds the free tier's 100k D1 writes/day (spec §6).
- iOS 17+, Swift 5.9, `project.yml` is the source of truth; regenerate with `xcodegen generate` after adding/removing Swift files.
- No Kroger, no crowd submissions, no push sending this week (weeks 2–4). `OpenFoodFactsService.swift` stays in the app only because `AlternativesEngine` depends on it until week 3.
- Commit after every task. Never commit `backend/node_modules`, `backend/.wrangler`, downloaded FDC zips, or generated SQL.

## File Structure

```
fixtures/
  package_weights.json            shared normalizer cases (Python + TS)
scripts/
  fdc/__init__.py
  fdc/normalize.py                parse_package_weight(raw) -> ParsedQuantity | None
  fdc/gtin.py                     normalize_gtin(raw) -> str | None
  fdc/importer.py                 stream zip -> rows -> SQL + report
  fdc_import.py                   CLI entry
  hit_rate.py                     curl-equivalent over the 35 curated GTINs
  tests/test_normalize.py
  tests/test_gtin.py
  tests/test_importer.py
backend/
  package.json, tsconfig.json, wrangler.toml, vitest.config.ts, .gitignore
  migrations/0001_init.sql
  src/env.ts                      Env interface
  src/index.ts                    Hono app, routes mounted
  src/normalize.ts                parsePackageWeight (mirror of Python)
  src/gtin.ts                     normalizeGTIN
  src/db.ts                       typed D1 queries
  src/lookup/fdc.ts               lookupFDC
  src/lookup/off.ts               lookupOFF
  src/routes/product.ts           GET /v1/product/:gtin
  test/apply-migrations.ts, test/env.d.ts
  test/normalize.test.ts, test/gtin.test.ts, test/product.test.ts
  spikes/apns-probe.ts            THROWAWAY — APNs HTTP/2 from Workers
Shrunk/
  Services/ShrunkAPIClient.swift  new
  Services/ShrinkDetector.swift   kind-aware selection
  Services/WatchlistService.swift OFF -> API
  Services/UPCItemDBService.swift deleted
  Features/Result/ResultViewModel.swift  OFF/UPC -> API
  Resources/Info.plist            NSAllowsLocalNetworking for wrangler dev
ShrunkTests/
  ShrunkAPIClientTests.swift      new
  ShrinkDetectorTests.swift       kind tests added
  UPCItemDBServiceTests.swift     deleted if present
```

---

### Task 1: Shared normalizer fixtures + Python `parse_package_weight`

**Files:**
- Create: `fixtures/package_weights.json`
- Create: `scripts/fdc/__init__.py` (empty)
- Create: `scripts/fdc/normalize.py`
- Test: `scripts/tests/test_normalize.py`

**Interfaces:**
- Produces: `parse_package_weight(raw: str) -> ParsedQuantity | None` where `ParsedQuantity = dataclass(quantity: float, unit_kind: str, raw: str)`; `unit_kind` is `"mass" | "volume" | "count"`. Quantity is grams / millilitres / count, rounded to 3 decimals.
- Produces: `fixtures/package_weights.json` — array of `{ "input": str, "quantity": number|null, "unit_kind": str|null, "note": str }`; `null` means "reject".

- [ ] **Step 1: Write the fixture file**

```json
[
  { "input": "12 oz/340 g", "quantity": 340.194, "unit_kind": "mass", "note": "LI format, oz and g agree" },
  { "input": "16 oz/1 lbs/454 g", "quantity": 453.592, "unit_kind": "mass", "note": "three agreeing segments" },
  { "input": "1 PT/473 mL", "quantity": 473.176, "unit_kind": "volume", "note": "pint" },
  { "input": "15.25 ONZ", "quantity": 432.33, "unit_kind": "mass", "note": "GS1 ounce code" },
  { "input": "6 LBR", "quantity": 2721.552, "unit_kind": "mass", "note": "GS1 pound code" },
  { "input": "64 OZA", "quantity": 1892.704, "unit_kind": "volume", "note": "GS1 fluid ounce code" },
  { "input": "170 GRM", "quantity": 170, "unit_kind": "mass", "note": "GS1 gram code" },
  { "input": "1 GLL", "quantity": 3785.41, "unit_kind": "volume", "note": "GS1 gallon code" },
  { "input": "1.53 LTR", "quantity": 1530, "unit_kind": "volume", "note": "GS1 litre code" },
  { "input": "500 MLT", "quantity": 500, "unit_kind": "volume", "note": "GS1 millilitre code" },
  { "input": "2 KGM", "quantity": 2000, "unit_kind": "mass", "note": "GS1 kilogram code" },
  { "input": "6 EA", "quantity": 6, "unit_kind": "count", "note": "GS1 each" },
  { "input": "12 ct", "quantity": 12, "unit_kind": "count", "note": "count" },
  { "input": "28 fl oz", "quantity": 828.058, "unit_kind": "volume", "note": "fluid ounce with space" },
  { "input": "28floz", "quantity": 828.058, "unit_kind": "volume", "note": "fluid ounce no space" },
  { "input": "500g", "quantity": 500, "unit_kind": "mass", "note": "no space" },
  { "input": "1.5L", "quantity": 1500, "unit_kind": "volume", "note": "litre" },
  { "input": "1,5 l", "quantity": 1500, "unit_kind": "volume", "note": "comma decimal" },
  { "input": "12 - 12 FL OZ CANS", "quantity": 4258.584, "unit_kind": "volume", "note": "multipack: 12 x 12 fl oz" },
  { "input": "6 x 330 ml", "quantity": 1980, "unit_kind": "volume", "note": "multipack with x" },
  { "input": "NET WT 12 OZ (340g)", "quantity": 340.194, "unit_kind": "mass", "note": "label text with parenthetical" },
  { "input": "12 oz/500 g", "quantity": null, "unit_kind": null, "note": "segments disagree by >2%: malformed" },
  { "input": "each", "quantity": null, "unit_kind": null, "note": "no number" },
  { "input": "", "quantity": null, "unit_kind": null, "note": "empty" },
  { "input": "12", "quantity": null, "unit_kind": null, "note": "number without unit" },
  { "input": "0 oz", "quantity": null, "unit_kind": null, "note": "zero quantity" },
  { "input": "300 g e", "quantity": 300, "unit_kind": "mass", "note": "EU estimated sign suffix" },
  { "input": "1 lb 4 oz", "quantity": 566.99, "unit_kind": "mass", "note": "compound imperial: 20 oz" }
]
```

- [ ] **Step 2: Write the failing tests**

`scripts/tests/test_normalize.py`:

```python
import json
import pathlib
import pytest

from fdc.normalize import parse_package_weight

FIXTURES = json.loads(
    (pathlib.Path(__file__).resolve().parents[2] / "fixtures" / "package_weights.json").read_text()
)


@pytest.mark.parametrize("case", FIXTURES, ids=[c["note"] for c in FIXTURES])
def test_fixture(case):
    result = parse_package_weight(case["input"])
    if case["quantity"] is None:
        assert result is None, f"expected reject for {case['input']!r}, got {result}"
    else:
        assert result is not None, f"expected parse for {case['input']!r}"
        assert result.unit_kind == case["unit_kind"]
        assert result.quantity == pytest.approx(case["quantity"], rel=0.001)
        assert result.raw == case["input"]
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd scripts && python3 -m pytest tests/test_normalize.py -q`
Expected: FAIL / ERROR with `ModuleNotFoundError: No module named 'fdc'` (install pytest first if missing: `python3 -m pip install pytest`).

- [ ] **Step 4: Implement the normalizer**

`scripts/fdc/__init__.py`: empty file.

`scripts/fdc/normalize.py`:

```python
"""Parse package-weight strings into (quantity, unit_kind).

Handles USDA FDC Label Insight strings ("12 oz/340 g"), GS1 GDSN unit codes
("15.25 ONZ"), multipacks ("12 - 12 FL OZ", "6 x 330 ml"), compound imperial
("1 lb 4 oz"), and free-form label text ("NET WT 12 OZ (340g)").

Mirror of backend/src/normalize.ts — both must pass fixtures/package_weights.json.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

MASS = "mass"
VOLUME = "volume"
COUNT = "count"

# unit token -> (kind, factor to base unit: g / mL / count)
UNITS: dict[str, tuple[str, float]] = {
    # mass
    "g": (MASS, 1.0), "gr": (MASS, 1.0), "gram": (MASS, 1.0), "grams": (MASS, 1.0), "grm": (MASS, 1.0),
    "kg": (MASS, 1000.0), "kgm": (MASS, 1000.0), "kilogram": (MASS, 1000.0), "kilograms": (MASS, 1000.0),
    "oz": (MASS, 28.3495), "onz": (MASS, 28.3495), "ounce": (MASS, 28.3495), "ounces": (MASS, 28.3495),
    "lb": (MASS, 453.592), "lbs": (MASS, 453.592), "lbr": (MASS, 453.592), "pound": (MASS, 453.592), "pounds": (MASS, 453.592),
    # volume
    "ml": (VOLUME, 1.0), "mlt": (VOLUME, 1.0), "milliliter": (VOLUME, 1.0), "milliliters": (VOLUME, 1.0), "millilitre": (VOLUME, 1.0),
    "l": (VOLUME, 1000.0), "ltr": (VOLUME, 1000.0), "liter": (VOLUME, 1000.0), "liters": (VOLUME, 1000.0), "litre": (VOLUME, 1000.0), "litres": (VOLUME, 1000.0),
    "floz": (VOLUME, 29.5735), "oza": (VOLUME, 29.5735),
    "pt": (VOLUME, 473.176), "ptl": (VOLUME, 473.176), "pint": (VOLUME, 473.176), "pints": (VOLUME, 473.176),
    "qt": (VOLUME, 946.353), "qtl": (VOLUME, 946.353), "quart": (VOLUME, 946.353), "quarts": (VOLUME, 946.353),
    "gal": (VOLUME, 3785.41), "gll": (VOLUME, 3785.41), "gallon": (VOLUME, 3785.41), "gallons": (VOLUME, 3785.41),
    # count
    "ct": (COUNT, 1.0), "count": (COUNT, 1.0), "pk": (COUNT, 1.0), "pack": (COUNT, 1.0),
    "ea": (COUNT, 1.0), "each": (COUNT, 1.0), "h87": (COUNT, 1.0), "pc": (COUNT, 1.0), "pcs": (COUNT, 1.0), "piece": (COUNT, 1.0), "pieces": (COUNT, 1.0),
}

_UNIT_ALTERNATION = "|".join(sorted((re.escape(u) for u in UNITS), key=len, reverse=True))
_NUM = r"(\d+(?:[.,]\d+)?)"
# "12 - 12 fl oz", "6 x 330 ml", "12/12 oz" -> multiplier, then quantity+unit
_MULTIPACK = re.compile(rf"{_NUM}\s*(?:[-–x×*]|pk\s+of|pack\s+of)\s*{_NUM}\s*(fl\s?oz|{_UNIT_ALTERNATION})\b")
_QTY_UNIT = re.compile(rf"{_NUM}\s*(fl\s?oz|{_UNIT_ALTERNATION})\b")
_SEGMENT_SPLIT = re.compile(r"\s*/\s*|\s*\(|\)\s*")
_TOLERANCE = 0.02


@dataclass(frozen=True)
class ParsedQuantity:
    quantity: float
    unit_kind: str
    raw: str


def _to_float(token: str) -> float:
    return float(token.replace(",", "."))


def _unit(token: str) -> tuple[str, float]:
    key = token.lower().replace(" ", "")
    return UNITS[key]


def _parse_segment(segment: str) -> tuple[float, str] | None:
    """One segment like '12 oz', '1 lb 4 oz', '12 - 12 fl oz'. Returns (base_qty, kind)."""
    text = segment.lower().strip()
    if not text:
        return None

    m = _MULTIPACK.search(text)
    if m:
        kind, factor = _unit(m.group(3))
        qty = _to_float(m.group(1)) * _to_float(m.group(2)) * factor
        return (qty, kind) if qty > 0 else None

    matches = list(_QTY_UNIT.finditer(text))
    if not matches:
        return None

    first_kind, first_factor = _unit(matches[0].group(2))
    total = _to_float(matches[0].group(1)) * first_factor
    # Compound imperial: "1 lb 4 oz" -> additional same-kind matches are added.
    for extra in matches[1:]:
        kind, factor = _unit(extra.group(2))
        if kind != first_kind:
            break
        total += _to_float(extra.group(1)) * factor
    return (total, first_kind) if total > 0 else None


def parse_package_weight(raw: str) -> ParsedQuantity | None:
    if raw is None:
        return None
    text = raw.strip()
    if not text:
        return None

    parsed = [p for p in (_parse_segment(s) for s in _SEGMENT_SPLIT.split(text)) if p]
    if not parsed:
        return None

    # Prefer mass/volume over count when both appear ("12 ct / 340 g").
    preferred = [p for p in parsed if p[1] != COUNT] or parsed
    qty, kind = preferred[0]

    # Segments of the same kind must agree within tolerance, else the row is malformed.
    for other_qty, other_kind in preferred[1:]:
        if other_kind == kind and abs(other_qty - qty) / qty > _TOLERANCE:
            return None

    return ParsedQuantity(quantity=round(qty, 3), unit_kind=kind, raw=raw)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd scripts && python3 -m pytest tests/test_normalize.py -q`
Expected: `28 passed`.

If `"12 oz/340 g"` fails on tolerance: 12 oz = 340.194 g vs 340 g is 0.06% apart — inside 2%. If `"NET WT 12 OZ (340g)"` fails, check `_SEGMENT_SPLIT` splits on `(`.

- [ ] **Step 6: Commit**

```bash
git add fixtures/package_weights.json scripts/fdc/__init__.py scripts/fdc/normalize.py scripts/tests/test_normalize.py
git commit -m "feat(fdc): package-weight normalizer with shared fixtures"
```

---

### Task 2: Python GTIN normalizer

**Files:**
- Create: `scripts/fdc/gtin.py`
- Test: `scripts/tests/test_gtin.py`

**Interfaces:**
- Produces: `normalize_gtin(raw: str) -> str | None` — returns a 13-digit string or `None`.

- [ ] **Step 1: Write the failing tests**

```python
import pytest
from fdc.gtin import normalize_gtin


@pytest.mark.parametrize("raw, expected", [
    ("028400642255", "0028400642255"),      # 12-digit UPC-A -> prefix 0
    ("0028400642255", "0028400642255"),     # already 13
    ("00027000612323", "0027000612323"),    # 14-digit GTIN-14 with leading 0
    (" 028400642255 ", "0028400642255"),    # whitespace
    ("028-400-642255", "0028400642255"),    # separators stripped
    ("10027000612323", None),               # 14-digit not starting with 0 (case level) -> reject
    ("12345678", None),                     # 8-digit (UPC-E/EAN-8) not supported this week
    ("", None),
    ("abc", None),
])
def test_normalize_gtin(raw, expected):
    assert normalize_gtin(raw) == expected
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd scripts && python3 -m pytest tests/test_gtin.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'fdc.gtin'`.

- [ ] **Step 3: Implement**

`scripts/fdc/gtin.py`:

```python
"""Canonical barcode form: 13-digit zero-padded GTIN with check digit.

Mirror of backend/src/gtin.ts.
"""
import re

_DIGITS = re.compile(r"\D")


def normalize_gtin(raw: str) -> str | None:
    if raw is None:
        return None
    digits = _DIGITS.sub("", raw)
    if len(digits) == 12:
        return "0" + digits
    if len(digits) == 13:
        return digits
    if len(digits) == 14 and digits.startswith("0"):
        return digits[1:]
    return None
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd scripts && python3 -m pytest tests/test_gtin.py -q`
Expected: `9 passed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/fdc/gtin.py scripts/tests/test_gtin.py
git commit -m "feat(fdc): GTIN-13 normalizer"
```

---

### Task 3: FDC importer (zip → SQL + report)

**Files:**
- Create: `scripts/fdc/importer.py`
- Create: `scripts/fdc_import.py`
- Test: `scripts/tests/test_importer.py`
- Modify: `.gitignore` (add `scripts/out/`, `*.zip`)

**Interfaces:**
- Consumes: `parse_package_weight`, `normalize_gtin` from Tasks 1–2.
- Produces: `build_rows(zip_path) -> ImportResult` with `products: dict[str, Product]`, `observations: list[Observation]`, `stats: dict`; `write_sql(result, out_path, batch=200)`; `write_report(result, curated_path, report_path)`.
- Produces: CLI `python3 scripts/fdc_import.py --zip <file> --out scripts/out/fdc.sql --report scripts/out/report.json --curated data/trending.json`.

FDC zip layout (verified 2026-04-30 release): `FoodData_Central_branded_food_csv_2026-04-30/branded_food.csv` and `.../food.csv`. `branded_food.csv` columns (21): `fdc_id, brand_owner, brand_name, subbrand_name, gtin_upc, ingredients, not_a_significant_source_of, serving_size, serving_size_unit, household_serving_fulltext, branded_food_category, data_source, package_weight, modified_date, available_date, market_country, discontinued_date, preparation_state_code, trade_channel, short_description, material_code`. `food.csv` columns: `fdc_id, data_type, description, food_category_id, publication_date`. Dates are ISO `YYYY-MM-DD`.

- [ ] **Step 1: Write the failing test with a synthetic zip**

`scripts/tests/test_importer.py`:

```python
import csv
import io
import json
import zipfile
from pathlib import Path

from fdc.importer import build_rows, write_sql, write_report

BRANDED_HEADER = [
    "fdc_id", "brand_owner", "brand_name", "subbrand_name", "gtin_upc", "ingredients",
    "not_a_significant_source_of", "serving_size", "serving_size_unit", "household_serving_fulltext",
    "branded_food_category", "data_source", "package_weight", "modified_date", "available_date",
    "market_country", "discontinued_date", "preparation_state_code", "trade_channel",
    "short_description", "material_code",
]
FOOD_HEADER = ["fdc_id", "data_type", "description", "food_category_id", "publication_date"]


def _branded(fdc_id, gtin, pw, modified, available, brand="Acme", category="Snacks", country="United States"):
    return [fdc_id, brand, "", "", gtin, "", "", "", "", "", category, "LI", pw, modified, available, country, "", "", "", "", ""]


def _make_zip(tmp_path: Path, branded_rows, food_rows) -> Path:
    zpath = tmp_path / "fdc.zip"
    with zipfile.ZipFile(zpath, "w") as z:
        for name, header, rows in (("branded_food.csv", BRANDED_HEADER, branded_rows), ("food.csv", FOOD_HEADER, food_rows)):
            buf = io.StringIO()
            w = csv.writer(buf, quoting=csv.QUOTE_ALL)
            w.writerow(header)
            w.writerows(rows)
            z.writestr(f"FoodData_Central_branded_food_csv_2026-04-30/{name}", buf.getvalue())
    return zpath


def test_build_rows_versions_and_dedupe(tmp_path):
    zpath = _make_zip(
        tmp_path,
        branded_rows=[
            _branded("1", "028400642255", "32 oz/907 g", "2018-01-01", "2018-02-01"),
            _branded("2", "028400642255", "32 oz/907 g", "2019-01-01", "2019-02-01"),   # same size -> deduped
            _branded("3", "028400642255", "28 oz/794 g", "2021-06-01", "2021-07-01"),   # shrink
            _branded("4", "028400642255", "", "2022-01-01", "2022-02-01"),              # no weight -> skipped
            _branded("5", "099999999999", "12 oz/500 g", "2020-01-01", "2020-02-01"),   # malformed -> skipped
            _branded("6", "077777777777", "6 EA", "2020-01-01", "2020-02-01", country="Canada"),  # not US -> skipped
        ],
        food_rows=[
            ["1", "branded_food", "Gatorade Thirst Quencher", "", "2019-04-01"],
            ["2", "branded_food", "Gatorade Thirst Quencher", "", "2019-04-01"],
            ["3", "branded_food", "Gatorade Thirst Quencher", "", "2021-10-28"],
            ["4", "branded_food", "Gatorade Thirst Quencher", "", "2022-04-28"],
            ["5", "branded_food", "Bad Row", "", "2020-04-29"],
            ["6", "branded_food", "Canadian", "", "2020-04-29"],
        ],
    )
    result = build_rows(zpath)

    assert set(result.products) == {"0028400642255"}
    p = result.products["0028400642255"]
    assert p.name == "Gatorade Thirst Quencher"
    assert p.brand == "Acme"
    assert p.category == "Snacks"
    assert p.unit_kind == "mass"

    obs = [o for o in result.observations if o.gtin == "0028400642255"]
    assert [o.quantity for o in obs] == [907.184, 793.786]
    assert [o.observed_at for o in obs] == [1517443200, 1625097600]   # 2018-02-01, 2021-07-01 UTC
    assert obs[0].source == "fdc" and obs[0].source_ref == "1" and obs[0].confidence == 0.9
    assert obs[1].raw_text == "28 oz/794 g"

    assert result.stats["rows_read"] == 6
    assert result.stats["rows_with_weight"] == 5
    assert result.stats["rows_malformed"] == 1
    assert result.stats["rows_non_us"] == 1
    assert result.stats["gtins_with_multiple_sizes"] == 1


def test_write_sql_batches_and_escapes(tmp_path):
    zpath = _make_zip(
        tmp_path,
        branded_rows=[_branded("1", "028400642255", "12 oz/340 g", "2020-01-01", "2020-02-01", brand="O'Brien's")],
        food_rows=[["1", "branded_food", "Chips \"Classic\"", "", "2020-04-29"]],
    )
    result = build_rows(zpath)
    out = tmp_path / "out.sql"
    write_sql(result, out, batch=1)
    sql = out.read_text()
    assert "INSERT OR IGNORE INTO products" in sql
    assert "'O''Brien''s'" in sql
    assert "INSERT INTO observations" in sql
    assert sql.count("INSERT INTO observations") == 1
    assert all(line.endswith(";") for line in sql.strip().splitlines())   # one statement per line


def test_write_report_crosschecks_curated(tmp_path):
    zpath = _make_zip(
        tmp_path,
        branded_rows=[
            _branded("1", "028400642255", "32 oz/907 g", "2018-01-01", "2018-02-01"),
            _branded("2", "028400642255", "28 oz/794 g", "2021-06-01", "2021-07-01"),
        ],
        food_rows=[["1", "branded_food", "G", "", "2019-04-01"], ["2", "branded_food", "G", "", "2021-10-28"]],
    )
    curated = tmp_path / "trending.json"
    curated.write_text(json.dumps({"trending": [
        {"barcode": "0028400642255", "name": "Gatorade", "history": [
            {"date": "2018-01-01", "quantity": 32, "unit": "fl oz"}, {"date": "2021-06-01", "quantity": 28, "unit": "fl oz"}]},
        {"barcode": "0052000133417", "name": "Missing", "history": []},
    ]}))
    report = tmp_path / "report.json"
    result = build_rows(zpath)
    write_report(result, curated, report)
    data = json.loads(report.read_text())
    assert data["stats"]["gtins_with_multiple_sizes"] == 1
    assert data["curated"]["found"] == 1
    assert data["curated"]["missing"] == ["0052000133417"]
    assert data["curated"]["with_multiple_sizes"] == 1
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd scripts && python3 -m pytest tests/test_importer.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'fdc.importer'`.

- [ ] **Step 3: Implement the importer**

`scripts/fdc/importer.py`:

```python
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


@dataclass
class Observation:
    gtin: str
    quantity: float
    unit_kind: str
    raw_text: str
    observed_at: int
    source: str
    source_ref: str
    confidence: float


@dataclass
class ImportResult:
    products: dict[str, Product] = field(default_factory=dict)
    observations: list[Observation] = field(default_factory=list)
    stats: dict = field(default_factory=dict)


def _open_member(z: zipfile.ZipFile, suffix: str) -> io.TextIOWrapper:
    name = next(n for n in z.namelist() if n.endswith(suffix))
    return io.TextIOWrapper(z.open(name), encoding="utf-8", newline="")


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
                f"({_q(p.gtin)}, {_q(p.name)}, {_q(p.brand)}, {_q(p.category)}, NULL, {_q(p.unit_kind)}, {now}, {now})"
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
```

`scripts/fdc_import.py`:

```python
#!/usr/bin/env python3
"""Usage:
  python3 scripts/fdc_import.py --zip FoodData_Central_branded_food_csv_2026-04-30.zip \
      --out scripts/out/fdc.sql --report scripts/out/report.json --curated data/trending.json
Download the zip from https://fdc.nal.usda.gov/download-datasets/ (Branded Foods, CSV).
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fdc.importer import build_rows, write_report, write_sql  # noqa: E402


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--report", required=True, type=Path)
    ap.add_argument("--curated", type=Path, default=None)
    args = ap.parse_args()

    result = build_rows(args.zip)
    write_sql(result, args.out)
    write_report(result, args.curated, args.report)
    print(f"products={len(result.products)} observations={len(result.observations)} stats={result.stats}")


if __name__ == "__main__":
    main()
```

Append to `.gitignore`:

```
# FDC import artifacts
scripts/out/
*.zip
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd scripts && python3 -m pytest tests -q`
Expected: `40 passed` (28 normalize + 9 gtin + 3 importer).

- [ ] **Step 5: Commit**

```bash
git add scripts/fdc/importer.py scripts/fdc_import.py scripts/tests/test_importer.py .gitignore
git commit -m "feat(fdc): importer streams release zip into D1 SQL + report"
```

---

### Task 4: Backend scaffold with D1 migration and health route

**Files:**
- Create: `backend/package.json`, `backend/tsconfig.json`, `backend/wrangler.toml`, `backend/vitest.config.ts`, `backend/.gitignore`
- Create: `backend/migrations/0001_init.sql`
- Create: `backend/src/env.ts`, `backend/src/index.ts`
- Create: `backend/test/apply-migrations.ts`, `backend/test/env.d.ts`, `backend/test/health.test.ts`

**Interfaces:**
- Produces: `Env { DB: D1Database; FDC_API_KEY: string; ENV: string }` in `src/env.ts`.
- Produces: default export Hono `app` from `src/index.ts`, typed `Hono<{ Bindings: Env }>`; tests call `app.request(path, init, env)`.
- Produces: tables `products`, `observations`, `price_snapshots` (schema from spec §5; the rest of the tables arrive with the weeks that use them).

- [ ] **Step 1: Scaffold the package**

```bash
mkdir -p backend/src backend/test backend/migrations
cd backend
npm init -y >/dev/null
npm pkg set type=module private=true name=shrunk-api
npm pkg set scripts.dev="wrangler dev" scripts.deploy="wrangler deploy" scripts.test="vitest run" \
  scripts.typecheck="tsc --noEmit" \
  scripts.migrate:local="wrangler d1 migrations apply shrunk --local" \
  scripts.migrate:remote="wrangler d1 migrations apply shrunk --remote"
npm install hono
npm install -D wrangler @cloudflare/vitest-pool-workers vitest typescript @cloudflare/workers-types
```

If npm reports a peer-dependency conflict between `@cloudflare/vitest-pool-workers` and `vitest`, install the vitest version the error names (e.g. `npm install -D vitest@3.2`).

`backend/.gitignore`:

```
node_modules/
.wrangler/
.dev.vars
dist/
```

`backend/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "lib": ["ES2022"],
    "types": ["@cloudflare/workers-types/2023-07-01", "@cloudflare/vitest-pool-workers"],
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true,
    "esModuleInterop": true
  },
  "include": ["src", "test", "spikes"]
}
```

`backend/wrangler.toml`:

```toml
name = "shrunk-api"
main = "src/index.ts"
compatibility_date = "2026-08-01"   # if wrangler says this is newer than it supports, use the date it suggests
compatibility_flags = ["nodejs_compat"]

[vars]
ENV = "dev"

[[d1_databases]]
binding = "DB"
database_name = "shrunk"
database_id = "00000000-0000-0000-0000-000000000000"   # replaced in Task 9 after `wrangler d1 create`
migrations_dir = "migrations"
```

`backend/vitest.config.ts`:

```ts
import path from "node:path";
import { defineWorkersConfig, readD1Migrations } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
  return {
    test: {
      setupFiles: ["./test/apply-migrations.ts"],
      poolOptions: {
        workers: {
          wrangler: { configPath: "./wrangler.toml" },
          miniflare: { bindings: { TEST_MIGRATIONS: migrations, FDC_API_KEY: "test-key" } },
        },
      },
    },
  };
});
```

`backend/test/apply-migrations.ts`:

```ts
import { applyD1Migrations, env } from "cloudflare:test";

await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
```

`backend/test/env.d.ts`:

```ts
import type { Env } from "../src/env";

declare module "cloudflare:test" {
  interface ProvidedEnv extends Env {
    TEST_MIGRATIONS: D1Migration[];
  }
}
```

- [ ] **Step 2: Write the migration**

`backend/migrations/0001_init.sql`:

```sql
CREATE TABLE products (
  gtin        TEXT PRIMARY KEY,
  name        TEXT NOT NULL DEFAULT '',
  brand       TEXT NOT NULL DEFAULT '',
  category    TEXT NOT NULL DEFAULT '',
  image_url   TEXT,
  unit_kind   TEXT,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);

CREATE TABLE observations (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  gtin        TEXT NOT NULL REFERENCES products(gtin),
  quantity    REAL NOT NULL,
  unit_kind   TEXT NOT NULL CHECK (unit_kind IN ('mass','volume','count')),
  raw_text    TEXT,
  observed_at INTEGER NOT NULL,
  source      TEXT NOT NULL CHECK (source IN ('fdc','curated','crowd','kroger')),
  source_ref  TEXT,
  confidence  REAL NOT NULL,
  status      TEXT NOT NULL CHECK (status IN ('accepted','pending','rejected')),
  created_at  INTEGER NOT NULL
);
CREATE INDEX obs_gtin ON observations(gtin, status, observed_at);

CREATE TABLE price_snapshots (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  gtin               TEXT NOT NULL,
  location_id        TEXT NOT NULL,
  regular            REAL,
  promo              REAL,
  per_unit_estimate  REAL,
  size_raw           TEXT,
  stock_level        TEXT,
  observed_at        INTEGER NOT NULL
);
CREATE INDEX ps_gtin_loc ON price_snapshots(gtin, location_id, observed_at);
```

- [ ] **Step 3: Write the failing health test**

`backend/test/health.test.ts`:

```ts
import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import app from "../src/index";

describe("GET /health", () => {
  it("returns ok and the migrated tables exist", async () => {
    const res = await app.request("/health", {}, env);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });

    const tables = await env.DB.prepare(
      "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('products','observations','price_snapshots') ORDER BY name"
    ).all<{ name: string }>();
    expect(tables.results.map((t) => t.name)).toEqual(["observations", "price_snapshots", "products"]);
  });
});
```

- [ ] **Step 4: Run test to verify it fails**

Run: `cd backend && npx vitest run test/health.test.ts`
Expected: FAIL — `Cannot find module '../src/index'`.

- [ ] **Step 5: Implement env + app**

`backend/src/env.ts`:

```ts
export interface Env {
  DB: D1Database;
  FDC_API_KEY: string;
  ENV: string;
}
```

`backend/src/index.ts`:

```ts
import { Hono } from "hono";
import type { Env } from "./env";

const app = new Hono<{ Bindings: Env }>();

app.get("/health", (c) => c.json({ ok: true }));

export default app;
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd backend && npx vitest run test/health.test.ts && npx tsc --noEmit`
Expected: `1 passed`; typecheck clean.

- [ ] **Step 7: Commit**

```bash
git add backend/package.json backend/package-lock.json backend/tsconfig.json backend/wrangler.toml backend/vitest.config.ts backend/.gitignore backend/migrations/0001_init.sql backend/src backend/test
git commit -m "feat(backend): Cloudflare Worker scaffold, D1 schema, health route"
```

---

### Task 5: TypeScript normalizer (same fixtures)

**Files:**
- Create: `backend/src/normalize.ts`
- Test: `backend/test/normalize.test.ts`

**Interfaces:**
- Produces: `parsePackageWeight(raw: string): ParsedQuantity | null` with `ParsedQuantity = { quantity: number; unitKind: UnitKind; raw: string }`, `UnitKind = "mass" | "volume" | "count"`.

- [ ] **Step 1: Write the failing test**

`backend/test/normalize.test.ts`:

```ts
import fixtures from "../../fixtures/package_weights.json";
import { describe, expect, it } from "vitest";
import { parsePackageWeight } from "../src/normalize";

describe("parsePackageWeight", () => {
  for (const c of fixtures) {
    it(c.note, () => {
      const result = parsePackageWeight(c.input);
      if (c.quantity === null) {
        expect(result).toBeNull();
      } else {
        expect(result).not.toBeNull();
        expect(result!.unitKind).toBe(c.unit_kind);
        expect(result!.quantity).toBeCloseTo(c.quantity, 1);
        expect(result!.raw).toBe(c.input);
      }
    });
  }
});
```

Add `"resolveJsonModule": true` to `compilerOptions` in `backend/tsconfig.json`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && npx vitest run test/normalize.test.ts`
Expected: FAIL — `Cannot find module '../src/normalize'`.

- [ ] **Step 3: Implement**

`backend/src/normalize.ts`:

```ts
// Mirror of scripts/fdc/normalize.py — both must pass fixtures/package_weights.json.
export type UnitKind = "mass" | "volume" | "count";
export interface ParsedQuantity { quantity: number; unitKind: UnitKind; raw: string }

const UNITS: Record<string, [UnitKind, number]> = {
  g: ["mass", 1], gr: ["mass", 1], gram: ["mass", 1], grams: ["mass", 1], grm: ["mass", 1],
  kg: ["mass", 1000], kgm: ["mass", 1000], kilogram: ["mass", 1000], kilograms: ["mass", 1000],
  oz: ["mass", 28.3495], onz: ["mass", 28.3495], ounce: ["mass", 28.3495], ounces: ["mass", 28.3495],
  lb: ["mass", 453.592], lbs: ["mass", 453.592], lbr: ["mass", 453.592], pound: ["mass", 453.592], pounds: ["mass", 453.592],
  ml: ["volume", 1], mlt: ["volume", 1], milliliter: ["volume", 1], milliliters: ["volume", 1], millilitre: ["volume", 1],
  l: ["volume", 1000], ltr: ["volume", 1000], liter: ["volume", 1000], liters: ["volume", 1000], litre: ["volume", 1000], litres: ["volume", 1000],
  floz: ["volume", 29.5735], oza: ["volume", 29.5735],
  pt: ["volume", 473.176], ptl: ["volume", 473.176], pint: ["volume", 473.176], pints: ["volume", 473.176],
  qt: ["volume", 946.353], qtl: ["volume", 946.353], quart: ["volume", 946.353], quarts: ["volume", 946.353],
  gal: ["volume", 3785.41], gll: ["volume", 3785.41], gallon: ["volume", 3785.41], gallons: ["volume", 3785.41],
  ct: ["count", 1], count: ["count", 1], pk: ["count", 1], pack: ["count", 1],
  ea: ["count", 1], each: ["count", 1], h87: ["count", 1], pc: ["count", 1], pcs: ["count", 1], piece: ["count", 1], pieces: ["count", 1],
};

const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const UNIT_ALT = Object.keys(UNITS).sort((a, b) => b.length - a.length).map(esc).join("|");
const NUM = "(\\d+(?:[.,]\\d+)?)";
const MULTIPACK = new RegExp(`${NUM}\\s*(?:[-–x×*]|pk\\s+of|pack\\s+of)\\s*${NUM}\\s*(fl\\s?oz|${UNIT_ALT})\\b`);
const QTY_UNIT = new RegExp(`${NUM}\\s*(fl\\s?oz|${UNIT_ALT})\\b`, "g");
const SEGMENT_SPLIT = /\s*\/\s*|\s*\(|\)\s*/;
const TOLERANCE = 0.02;

const toFloat = (t: string) => parseFloat(t.replace(",", "."));
const unit = (t: string) => UNITS[t.toLowerCase().replace(/\s/g, "")];

function parseSegment(segment: string): [number, UnitKind] | null {
  const text = segment.toLowerCase().trim();
  if (!text) return null;

  const m = MULTIPACK.exec(text);
  if (m) {
    const [kind, factor] = unit(m[3]);
    const qty = toFloat(m[1]) * toFloat(m[2]) * factor;
    return qty > 0 ? [qty, kind] : null;
  }

  const matches = [...text.matchAll(QTY_UNIT)];
  if (matches.length === 0) return null;

  const [firstKind, firstFactor] = unit(matches[0][2]);
  let total = toFloat(matches[0][1]) * firstFactor;
  for (const extra of matches.slice(1)) {
    const [kind, factor] = unit(extra[2]);
    if (kind !== firstKind) break;
    total += toFloat(extra[1]) * factor;
  }
  return total > 0 ? [total, firstKind] : null;
}

export function parsePackageWeight(raw: string | null | undefined): ParsedQuantity | null {
  if (!raw) return null;
  const text = raw.trim();
  if (!text) return null;

  const parsed = text.split(SEGMENT_SPLIT).map(parseSegment).filter((p): p is [number, UnitKind] => p !== null);
  if (parsed.length === 0) return null;

  const preferred = parsed.filter((p) => p[1] !== "count");
  const chosen = preferred.length > 0 ? preferred : parsed;
  const [qty, kind] = chosen[0];

  for (const [otherQty, otherKind] of chosen.slice(1)) {
    if (otherKind === kind && Math.abs(otherQty - qty) / qty > TOLERANCE) return null;
  }
  return { quantity: Math.round(qty * 1000) / 1000, unitKind: kind, raw };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && npx vitest run test/normalize.test.ts && npx tsc --noEmit`
Expected: `28 passed`.

- [ ] **Step 5: Commit**

```bash
git add backend/src/normalize.ts backend/test/normalize.test.ts backend/tsconfig.json
git commit -m "feat(backend): package-weight normalizer sharing Python fixtures"
```

---

### Task 6: TypeScript GTIN normalizer

**Files:**
- Create: `backend/src/gtin.ts`
- Test: `backend/test/gtin.test.ts`

**Interfaces:**
- Produces: `normalizeGTIN(raw: string): string | null` (13-digit or null).

- [ ] **Step 1: Write the failing test**

```ts
import { describe, expect, it } from "vitest";
import { normalizeGTIN } from "../src/gtin";

describe("normalizeGTIN", () => {
  it.each([
    ["028400642255", "0028400642255"],
    ["0028400642255", "0028400642255"],
    ["00027000612323", "0027000612323"],
    [" 028400642255 ", "0028400642255"],
    ["028-400-642255", "0028400642255"],
    ["10027000612323", null],
    ["12345678", null],
    ["", null],
    ["abc", null],
  ])("%s -> %s", (raw, expected) => {
    expect(normalizeGTIN(raw)).toBe(expected);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && npx vitest run test/gtin.test.ts`
Expected: FAIL — `Cannot find module '../src/gtin'`.

- [ ] **Step 3: Implement**

```ts
// Mirror of scripts/fdc/gtin.py. Canonical form: 13-digit zero-padded GTIN with check digit.
export function normalizeGTIN(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const digits = raw.replace(/\D/g, "");
  if (digits.length === 12) return "0" + digits;
  if (digits.length === 13) return digits;
  if (digits.length === 14 && digits.startsWith("0")) return digits.slice(1);
  return null;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && npx vitest run test/gtin.test.ts`
Expected: `9 passed`.

- [ ] **Step 5: Commit**

```bash
git add backend/src/gtin.ts backend/test/gtin.test.ts
git commit -m "feat(backend): GTIN-13 normalizer"
```

---

### Task 7: D1 helpers + `GET /v1/product/:gtin` for known products

**Files:**
- Create: `backend/src/db.ts`
- Create: `backend/src/routes/product.ts`
- Modify: `backend/src/index.ts`
- Test: `backend/test/product.test.ts`

**Interfaces:**
- Produces (`db.ts`):
  - `ProductRow { gtin; name; brand; category; image_url: string|null; unit_kind: string|null }`
  - `ObservationRow { quantity: number; unit_kind: string; raw_text: string|null; observed_at: number; source: string; source_ref: string|null; confidence: number }`
  - `PriceSnapshotRow { location_id; regular: number|null; promo: number|null; per_unit_estimate: number|null; size_raw: string|null; stock_level: string|null; observed_at: number }`
  - `getProduct(db, gtin): Promise<ProductRow | null>`
  - `getAcceptedObservations(db, gtin): Promise<ObservationRow[]>` ordered by `observed_at ASC`
  - `getRecentSnapshots(db, gtin, locationId, limit = 12): Promise<PriceSnapshotRow[]>` ordered by `observed_at DESC`
  - `insertProduct(db, row: Omit<ProductRow,'unit_kind'> & { unit_kind: string|null }): Promise<void>`
- Produces: response JSON shape (consumed by the iOS client in Task 11):

```json
{
  "gtin": "0028400642255", "name": "...", "brand": "...", "category": "...", "image_url": null, "unit_kind": "mass",
  "observations": [ { "quantity": 907.184, "unit_kind": "mass", "raw_text": "32 oz/907 g", "observed_at": 1517443200, "source": "fdc", "source_ref": "1", "confidence": 0.9 } ],
  "price_snapshots": []
}
```
  404 → `{ "error": "not_found" }`; 400 → `{ "error": "invalid_gtin" }`.

- [ ] **Step 1: Write the failing tests**

`backend/test/product.test.ts`:

```ts
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";

async function seedProduct(gtin: string) {
  await env.DB.prepare(
    "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, ?, ?, ?, NULL, 'mass', 1, 1)"
  ).bind(gtin, "Gatorade Thirst Quencher", "Gatorade", "Beverages").run();
  await env.DB.batch([
    env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 907.184, 'mass', '32 oz/907 g', 1517443200, 'fdc', '1', 0.9, 'accepted', 1)").bind(gtin),
    env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 793.786, 'mass', '28 oz/794 g', 1625097600, 'fdc', '3', 0.9, 'accepted', 1)").bind(gtin),
    env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 500, 'mass', '500 g', 1700000000, 'crowd', 'sub1', 0.5, 'pending', 1)").bind(gtin),
    env.DB.prepare("INSERT INTO price_snapshots (gtin, location_id, regular, promo, per_unit_estimate, size_raw, stock_level, observed_at) VALUES (?, '01400943', 1.89, 0, 0.07, '28 fl oz', 'HIGH', 1700000000)").bind(gtin),
  ]);
}

describe("GET /v1/product/:gtin", () => {
  beforeEach(async () => {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM observations"),
      env.DB.prepare("DELETE FROM price_snapshots"),
      env.DB.prepare("DELETE FROM products"),
    ]);
  });

  it("returns product with accepted observations in date order", async () => {
    await seedProduct("0028400642255");
    const res = await app.request("/v1/product/0028400642255", {}, env);
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("public, max-age=3600");
    const body = await res.json<any>();
    expect(body.gtin).toBe("0028400642255");
    expect(body.name).toBe("Gatorade Thirst Quencher");
    expect(body.unit_kind).toBe("mass");
    expect(body.observations.map((o: any) => o.quantity)).toEqual([907.184, 793.786]);
    expect(body.observations[0]).toMatchObject({ unit_kind: "mass", raw_text: "32 oz/907 g", observed_at: 1517443200, source: "fdc", source_ref: "1", confidence: 0.9 });
    expect(body.price_snapshots).toEqual([]);
  });

  it("normalizes a 12-digit UPC-A in the path", async () => {
    await seedProduct("0028400642255");
    const res = await app.request("/v1/product/028400642255", {}, env);
    expect(res.status).toBe(200);
    expect((await res.json<any>()).gtin).toBe("0028400642255");
  });

  it("includes price snapshots for the requested location only", async () => {
    await seedProduct("0028400642255");
    const res = await app.request("/v1/product/0028400642255?locationId=01400943", {}, env);
    const body = await res.json<any>();
    expect(body.price_snapshots).toHaveLength(1);
    expect(body.price_snapshots[0]).toMatchObject({ location_id: "01400943", regular: 1.89, per_unit_estimate: 0.07, observed_at: 1700000000 });

    const other = await app.request("/v1/product/0028400642255?locationId=99999999", {}, env);
    expect((await other.json<any>()).price_snapshots).toEqual([]);
  });

  it("rejects an invalid gtin", async () => {
    const res = await app.request("/v1/product/12345", {}, env);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_gtin" });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && npx vitest run test/product.test.ts`
Expected: FAIL — 404s from Hono's default not-found handler (`expected 404 to be 200`).

- [ ] **Step 3: Implement db helpers and the route**

`backend/src/db.ts`:

```ts
export interface ProductRow {
  gtin: string;
  name: string;
  brand: string;
  category: string;
  image_url: string | null;
  unit_kind: string | null;
}

export interface ObservationRow {
  quantity: number;
  unit_kind: string;
  raw_text: string | null;
  observed_at: number;
  source: string;
  source_ref: string | null;
  confidence: number;
}

export interface PriceSnapshotRow {
  location_id: string;
  regular: number | null;
  promo: number | null;
  per_unit_estimate: number | null;
  size_raw: string | null;
  stock_level: string | null;
  observed_at: number;
}

export async function getProduct(db: D1Database, gtin: string): Promise<ProductRow | null> {
  return db
    .prepare("SELECT gtin, name, brand, category, image_url, unit_kind FROM products WHERE gtin = ?")
    .bind(gtin)
    .first<ProductRow>();
}

export async function getAcceptedObservations(db: D1Database, gtin: string): Promise<ObservationRow[]> {
  const { results } = await db
    .prepare(
      "SELECT quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence FROM observations WHERE gtin = ? AND status = 'accepted' ORDER BY observed_at ASC, id ASC"
    )
    .bind(gtin)
    .all<ObservationRow>();
  return results;
}

export async function getRecentSnapshots(db: D1Database, gtin: string, locationId: string, limit = 12): Promise<PriceSnapshotRow[]> {
  const { results } = await db
    .prepare(
      "SELECT location_id, regular, promo, per_unit_estimate, size_raw, stock_level, observed_at FROM price_snapshots WHERE gtin = ? AND location_id = ? ORDER BY observed_at DESC LIMIT ?"
    )
    .bind(gtin, locationId, limit)
    .all<PriceSnapshotRow>();
  return results;
}

export async function insertProduct(db: D1Database, row: ProductRow): Promise<void> {
  const now = Math.floor(Date.now() / 1000);
  await db
    .prepare(
      "INSERT OR IGNORE INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
    )
    .bind(row.gtin, row.name, row.brand, row.category, row.image_url, row.unit_kind, now, now)
    .run();
}
```

`backend/src/routes/product.ts`:

```ts
import { Hono } from "hono";
import type { Env } from "../env";
import { getAcceptedObservations, getProduct, getRecentSnapshots, type ProductRow } from "../db";
import { normalizeGTIN } from "../gtin";

export const productRoute = new Hono<{ Bindings: Env }>();

export async function buildProductResponse(db: D1Database, product: ProductRow, locationId: string | null) {
  const observations = await getAcceptedObservations(db, product.gtin);
  const price_snapshots = locationId ? await getRecentSnapshots(db, product.gtin, locationId) : [];
  return { ...product, observations, price_snapshots };
}

productRoute.get("/v1/product/:gtin", async (c) => {
  const gtin = normalizeGTIN(c.req.param("gtin"));
  if (!gtin) return c.json({ error: "invalid_gtin" }, 400);

  const product = await getProduct(c.env.DB, gtin);
  if (!product) return c.json({ error: "not_found" }, 404);

  const locationId = c.req.query("locationId") ?? null;
  c.header("Cache-Control", "public, max-age=3600");
  return c.json(await buildProductResponse(c.env.DB, product, locationId));
});
```

`backend/src/index.ts` — add the route:

```ts
import { Hono } from "hono";
import type { Env } from "./env";
import { productRoute } from "./routes/product";

const app = new Hono<{ Bindings: Env }>();

app.get("/health", (c) => c.json({ ok: true }));
app.route("/", productRoute);

export default app;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && npx vitest run && npx tsc --noEmit`
Expected: all tests pass (health 1, normalize 28, gtin 9, product 4).

- [ ] **Step 5: Commit**

```bash
git add backend/src/db.ts backend/src/routes/product.ts backend/src/index.ts backend/test/product.test.ts
git commit -m "feat(backend): GET /v1/product returns merged observations and snapshots"
```

---

### Task 8: Unknown products — FDC API then Open Food Facts fallback

**Files:**
- Create: `backend/src/lookup/fdc.ts`, `backend/src/lookup/off.ts`
- Modify: `backend/src/routes/product.ts`
- Test: `backend/test/product.test.ts` (append), `backend/test/lookup.test.ts`

**Interfaces:**
- Produces: `lookupFDC(gtin: string, apiKey: string, fetchImpl = fetch): Promise<{ name: string; brand: string; category: string } | null>` — `GET https://api.nal.usda.gov/fdc/v1/foods/search?query=<gtin>&dataType=Branded&pageSize=1&api_key=<key>`; a hit is the first `foods[]` item whose `gtinUpc` normalizes to the same GTIN.
- Produces: `lookupOFF(gtin: string, fetchImpl = fetch): Promise<{ name: string; brand: string; imageUrl: string | null } | null>` — `GET https://world.openfoodfacts.org/api/v2/product/<gtin>.json?fields=product_name,brands,image_url` with `User-Agent: Shrunk/2.0 (stackcurious.com/shrunk)`.
- The route creates the product row (no observations) when either lookup hits; otherwise 404.

- [ ] **Step 1: Write the failing lookup tests**

`backend/test/lookup.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";
import { lookupFDC } from "../src/lookup/fdc";
import { lookupOFF } from "../src/lookup/off";

const jsonResponse = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

describe("lookupFDC", () => {
  it("returns name/brand/category when the gtin matches", async () => {
    const fetchImpl = vi.fn(async (url: string) => {
      expect(url).toContain("query=0028400642255");
      expect(url).toContain("api_key=k");
      return jsonResponse({ foods: [{ gtinUpc: "028400642255", description: "GATORADE THIRST QUENCHER", brandOwner: "Stokely-Van Camp", brandName: "Gatorade", foodCategory: "Sports Drinks" }] });
    });
    const hit = await lookupFDC("0028400642255", "k", fetchImpl as unknown as typeof fetch);
    expect(hit).toEqual({ name: "Gatorade Thirst Quencher", brand: "Gatorade", category: "Sports Drinks" });
  });

  it("returns null when the top hit is a different gtin or the request fails", async () => {
    const wrong = vi.fn(async () => jsonResponse({ foods: [{ gtinUpc: "011111111111", description: "X" }] }));
    expect(await lookupFDC("0028400642255", "k", wrong as unknown as typeof fetch)).toBeNull();
    const failing = vi.fn(async () => jsonResponse({}, 500));
    expect(await lookupFDC("0028400642255", "k", failing as unknown as typeof fetch)).toBeNull();
  });
});

describe("lookupOFF", () => {
  it("returns name/brand/image on status 1", async () => {
    const fetchImpl = vi.fn(async (_url: string, init?: RequestInit) => {
      expect((init?.headers as Record<string, string>)["User-Agent"]).toContain("Shrunk/2.0");
      return jsonResponse({ status: 1, product: { product_name: "Doritos Nacho Cheese", brands: "Doritos, Frito-Lay", image_url: "https://img/x.jpg" } });
    });
    expect(await lookupOFF("0028400642255", fetchImpl as unknown as typeof fetch)).toEqual({ name: "Doritos Nacho Cheese", brand: "Doritos", imageUrl: "https://img/x.jpg" });
  });

  it("returns null on status 0 or non-200", async () => {
    const miss = vi.fn(async () => jsonResponse({ status: 0 }));
    expect(await lookupOFF("0028400642255", miss as unknown as typeof fetch)).toBeNull();
    const notFound = vi.fn(async () => jsonResponse({}, 404));
    expect(await lookupOFF("0028400642255", notFound as unknown as typeof fetch)).toBeNull();
  });
});
```

Append to `backend/test/product.test.ts` (inside the `describe`):

```ts
  it("creates the product from FDC when unknown", async () => {
    const { fetchMock } = await import("cloudflare:test");
    fetchMock.activate();
    fetchMock.disableNetConnect();
    fetchMock.get("https://api.nal.usda.gov").intercept({ path: /\/fdc\/v1\/foods\/search.*/ }).reply(200, {
      foods: [{ gtinUpc: "028400642255", description: "GATORADE THIRST QUENCHER", brandName: "Gatorade", foodCategory: "Sports Drinks" }],
    });

    const res = await app.request("/v1/product/0028400642255", {}, env);
    expect(res.status).toBe(200);
    const body = await res.json<any>();
    expect(body).toMatchObject({ gtin: "0028400642255", name: "Gatorade Thirst Quencher", brand: "Gatorade", category: "Sports Drinks", observations: [] });

    const row = await env.DB.prepare("SELECT name FROM products WHERE gtin = ?").bind("0028400642255").first<{ name: string }>();
    expect(row?.name).toBe("Gatorade Thirst Quencher");
    fetchMock.deactivate();
  });

  it("falls back to Open Food Facts, then 404s", async () => {
    const { fetchMock } = await import("cloudflare:test");
    fetchMock.activate();
    fetchMock.disableNetConnect();
    fetchMock.get("https://api.nal.usda.gov").intercept({ path: /\/fdc\/v1\/foods\/search.*/ }).reply(200, { foods: [] }).persist();
    fetchMock.get("https://world.openfoodfacts.org").intercept({ path: "/api/v2/product/0028400642255.json", query: { fields: "product_name,brands,image_url" } }).reply(200, {
      status: 1, product: { product_name: "Doritos", brands: "Doritos", image_url: "https://img/x.jpg" },
    });
    fetchMock.get("https://world.openfoodfacts.org").intercept({ path: "/api/v2/product/0099999999999.json", query: { fields: "product_name,brands,image_url" } }).reply(200, { status: 0 });

    const hit = await app.request("/v1/product/0028400642255", {}, env);
    expect(hit.status).toBe(200);
    expect(await hit.json<any>()).toMatchObject({ name: "Doritos", brand: "Doritos", image_url: "https://img/x.jpg", observations: [] });

    const miss = await app.request("/v1/product/0099999999999", {}, env);
    expect(miss.status).toBe(404);
    expect(await miss.json()).toEqual({ error: "not_found" });
    fetchMock.deactivate();
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && npx vitest run test/lookup.test.ts test/product.test.ts`
Expected: lookup tests FAIL with `Cannot find module`; the two new product tests FAIL with 404.

- [ ] **Step 3: Implement lookups**

`backend/src/lookup/fdc.ts`:

```ts
import { normalizeGTIN } from "../gtin";

export interface FDCHit { name: string; brand: string; category: string }

function titleCase(s: string): string {
  return s.toLowerCase().replace(/(^|\s)\S/g, (m) => m.toUpperCase());
}

export async function lookupFDC(gtin: string, apiKey: string, fetchImpl: typeof fetch = fetch): Promise<FDCHit | null> {
  const url = `https://api.nal.usda.gov/fdc/v1/foods/search?query=${gtin}&dataType=Branded&pageSize=1&api_key=${encodeURIComponent(apiKey)}`;
  try {
    const res = await fetchImpl(url);
    if (!res.ok) return null;
    const body = (await res.json()) as { foods?: Array<{ gtinUpc?: string; description?: string; brandName?: string; brandOwner?: string; foodCategory?: string }> };
    const food = body.foods?.[0];
    if (!food || normalizeGTIN(food.gtinUpc ?? "") !== gtin) return null;
    return {
      name: titleCase((food.description ?? "").trim()),
      brand: (food.brandName ?? food.brandOwner ?? "").trim(),
      category: (food.foodCategory ?? "").trim(),
    };
  } catch {
    return null;
  }
}
```

`backend/src/lookup/off.ts`:

```ts
export interface OFFHit { name: string; brand: string; imageUrl: string | null }

export async function lookupOFF(gtin: string, fetchImpl: typeof fetch = fetch): Promise<OFFHit | null> {
  const url = `https://world.openfoodfacts.org/api/v2/product/${gtin}.json?fields=product_name,brands,image_url`;
  try {
    const res = await fetchImpl(url, { headers: { "User-Agent": "Shrunk/2.0 (stackcurious.com/shrunk)" } });
    if (!res.ok) return null;
    const body = (await res.json()) as { status?: number; product?: { product_name?: string; brands?: string; image_url?: string } };
    if (body.status !== 1 || !body.product) return null;
    const name = (body.product.product_name ?? "").trim();
    if (!name) return null;
    return {
      name,
      brand: (body.product.brands ?? "").split(",")[0].trim(),
      imageUrl: body.product.image_url ?? null,
    };
  } catch {
    return null;
  }
}
```

Update `backend/src/routes/product.ts` — replace the 404 branch:

```ts
import { getAcceptedObservations, getProduct, getRecentSnapshots, insertProduct, type ProductRow } from "../db";
import { lookupFDC } from "../lookup/fdc";
import { lookupOFF } from "../lookup/off";
// ...
  let product = await getProduct(c.env.DB, gtin);
  if (!product) {
    product = await createFromLookups(c.env, gtin);
    if (!product) return c.json({ error: "not_found" }, 404);
  }
// ...
async function createFromLookups(env: Env, gtin: string): Promise<ProductRow | null> {
  const fdc = await lookupFDC(gtin, env.FDC_API_KEY);
  let row: ProductRow | null = null;
  if (fdc) {
    row = { gtin, name: fdc.name, brand: fdc.brand, category: fdc.category, image_url: null, unit_kind: null };
  } else {
    const off = await lookupOFF(gtin);
    if (off) row = { gtin, name: off.name, brand: off.brand, category: "", image_url: off.imageUrl, unit_kind: null };
  }
  if (!row) return null;
  await insertProduct(env.DB, row);
  return row;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && npx vitest run && npx tsc --noEmit`
Expected: all pass (health 1, normalize 28, gtin 9, product 6, lookup 4).

- [ ] **Step 5: Commit**

```bash
git add backend/src/lookup backend/src/routes/product.ts backend/test/lookup.test.ts backend/test/product.test.ts
git commit -m "feat(backend): create unknown products from FDC API with OFF fallback"
```

---

### Task 9: Deploy the Worker and load the FDC data

**Files:**
- Modify: `backend/wrangler.toml` (real `database_id`)
- Create: `backend/README.md`

This task needs the user for two interactive steps (Cloudflare login, api.data.gov key). Everything else is scripted.

- [ ] **Step 1: Authenticate and create the database**

Ask the user to run in this session: `! cd backend && npx wrangler login` (opens a browser). Then:

```bash
cd backend && npx wrangler d1 create shrunk
```

Copy the printed `database_id` into `backend/wrangler.toml`, replacing the zero UUID. Confirm the account is on **Workers Paid** (dashboard → Workers & Pages → Plans); the import in Step 4 will fail the free tier's daily write cap otherwise.

- [ ] **Step 2: Set the FDC API key**

Get a free key at https://api.data.gov/signup/ (instant, emailed). Then:

```bash
cd backend && npx wrangler secret put FDC_API_KEY
```

For local dev create `backend/.dev.vars` (git-ignored): `FDC_API_KEY=<key>`.

- [ ] **Step 3: Migrate and deploy**

```bash
cd backend && npm run migrate:remote && npm run deploy
```

Expected: wrangler prints the Worker URL, e.g. `https://shrunk-api.<account>.workers.dev`. Verify:

```bash
curl -s https://shrunk-api.<account>.workers.dev/health
```
Expected: `{"ok":true}`.

- [ ] **Step 4: Download and import the FDC release**

```bash
cd /Users/drao/Projects/shrunk
curl -L -o /tmp/fdc_branded.zip "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_branded_food_csv_2026-04-30.zip"   # ~430 MB
python3 scripts/fdc_import.py --zip /tmp/fdc_branded.zip --out scripts/out/fdc.sql --report scripts/out/report.json --curated data/trending.json
cat scripts/out/report.json
```

Expected report shape: `products` in the ~400k range, `observations` ≥ products, `stats.gtins_with_multiple_sizes` in the tens of thousands, `curated.found` printed with `curated.missing` listed (non-food curated items such as Charmin and Tide are expected to be missing — FDC is food only).

Load it (this uploads the file and runs it server-side; several minutes):

```bash
cd backend && npx wrangler d1 execute shrunk --remote --file ../scripts/out/fdc.sql
```

If wrangler rejects the file for size, split it and load sequentially (every line is a complete statement, so line-based splitting is safe; 1,000 lines ≈ 200k rows):

```bash
split -l 1000 -d ../scripts/out/fdc.sql ../scripts/out/fdc_part_
for f in ../scripts/out/fdc_part_*; do npx wrangler d1 execute shrunk --remote --file "$f"; done
```

- [ ] **Step 5: Verify live**

```bash
npx wrangler d1 execute shrunk --remote --command "SELECT COUNT(*) AS products FROM products; "
npx wrangler d1 execute shrunk --remote --command "SELECT gtin, COUNT(*) n FROM observations GROUP BY gtin HAVING n > 1 ORDER BY n DESC LIMIT 5;"
curl -s "https://shrunk-api.<account>.workers.dev/v1/product/<one gtin from the query above>" | head -c 600
```

Expected: JSON with ≥2 observations of differing quantity.

- [ ] **Step 6: Write the README and commit**

`backend/README.md`:

```markdown
# shrunk-api

Cloudflare Worker + D1 behind the Shrunk iOS app.

- `npm run dev` — local server on http://localhost:8787 (needs `.dev.vars` with `FDC_API_KEY`)
- `npm test` — Vitest in the Workers runtime with migrations applied
- `npm run migrate:remote` / `npm run deploy`
- Reload FDC data: see `scripts/fdc_import.py` at the repo root, then `npx wrangler d1 execute shrunk --remote --file ../scripts/out/fdc.sql`

Endpoints: `GET /health`, `GET /v1/product/:gtin?locationId=`.
```

```bash
git add backend/wrangler.toml backend/README.md
git commit -m "chore(backend): production D1 binding and README"
```

---

### Task 10: iOS `ShrinkDetector` becomes unit-kind aware

**Files:**
- Modify: `Shrunk/Services/ShrinkDetector.swift`
- Modify: `Shrunk/Models/ShrunkProduct.swift` (add `SizeRecord.unitKind` computed property)
- Test: `ShrunkTests/ShrinkDetectorTests.swift`

**Interfaces:**
- Produces: `SizeRecord.unitKind: String` — `"mass" | "volume" | "count" | "unknown"` derived from `unit`.
- Produces: `ShrinkDetector.analyze` compares only the two most recent records whose `unitKind` equals the most recent record's kind; fewer than two → `.insufficientData`. `ShrinkDetector.normalize` is unchanged (still used by `AlternativesEngine` and `ShrinkHistoryChart`).

Run iOS tests with (substitute the simulator name from `xcrun simctl list devices available`):

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -only-testing:ShrunkTests/ShrinkDetectorTests -quiet 2>&1 | tail -20
```

- [ ] **Step 1: Write the failing tests**

Append to `ShrunkTests/ShrinkDetectorTests.swift` inside the class, after the cross-unit test:

```swift
    // MARK: - Unit kinds

    func test_unitKind_derivedFromUnit() {
        XCTAssertEqual(SizeRecord(date: Date(), quantity: 1, unit: "g", source: "x").unitKind, "mass")
        XCTAssertEqual(SizeRecord(date: Date(), quantity: 1, unit: "oz", source: "x").unitKind, "mass")
        XCTAssertEqual(SizeRecord(date: Date(), quantity: 1, unit: "fl oz", source: "x").unitKind, "volume")
        XCTAssertEqual(SizeRecord(date: Date(), quantity: 1, unit: "ml", source: "x").unitKind, "volume")
        XCTAssertEqual(SizeRecord(date: Date(), quantity: 1, unit: "count", source: "x").unitKind, "count")
        XCTAssertEqual(SizeRecord(date: Date(), quantity: 1, unit: "bananas", source: "x").unitKind, "unknown")
    }

    func test_mixedKinds_massThenVolume_isInsufficientData() {
        // 1000 g then 28 fl oz: different kinds must never be compared.
        let product = makeProduct(history: [
            .init(quantity: 1000, unit: "g"),
            .init(quantity: 28,   unit: "fl oz")
        ])
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .insufficientData)
    }

    func test_mixedKinds_usesMostRecentKindOnly() {
        // An old volume record is ignored; the two mass records give -10% -> moderate.
        let product = makeProduct(history: [
            .init(quantity: 28,   unit: "fl oz"),
            .init(quantity: 1000, unit: "g"),
            .init(quantity: 900,  unit: "g")
        ])
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .moderateShrink)
        XCTAssertEqual(record.shrinkPercent, -10, accuracy: 0.01)
        XCTAssertEqual(record.previousSize?.quantity, 1000)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command above.
Expected: compile error `value of type 'SizeRecord' has no member 'unitKind'`.

- [ ] **Step 3: Implement**

Append to `Shrunk/Models/ShrunkProduct.swift`:

```swift
extension SizeRecord {
    /// "mass" | "volume" | "count" | "unknown" — observations of different kinds are never compared.
    var unitKind: String {
        switch unit.lowercased().replacingOccurrences(of: " ", with: "") {
        case "g", "gram", "grams", "kg", "oz", "ounce", "ounces", "lb", "lbs":
            return "mass"
        case "ml", "l", "floz", "liter", "litre":
            return "volume"
        case "count", "ct", "pk", "pack", "each", "ea":
            return "count"
        default:
            return "unknown"
        }
    }
}
```

In `Shrunk/Services/ShrinkDetector.swift`, replace the whole `analyze(product:)` function with:

```swift
    func analyze(product: ShrunkProduct) -> ShrinkRecord {
        let sorted = product.sizeHistory.sorted { $0.date < $1.date }

        // Only compare records of the same kind as the most recent one —
        // grams vs fluid ounces must never produce a verdict.
        let sameKind: [SizeRecord] = {
            guard let latestKind = sorted.last?.unitKind else { return [] }
            return sorted.filter { $0.unitKind == latestKind }
        }()

        guard sameKind.count >= 2 else {
            return ShrinkRecord(
                product: product,
                previousSize: sorted.last,
                currentSize: sorted.last,
                shrinkPercent: 0,
                priceThen: nil,
                priceNow: product.currentPrice,
                costPerUnitThen: nil,
                costPerUnitNow: nil,
                verdict: .insufficientData
            )
        }

        let normalized = sameKind.map(Self.normalize)
        let current  = normalized.last!
        let previous = normalized.dropLast().last!

        // Guard against zero-quantity records that would explode the percentage math.
        guard previous.quantity > 0 else {
            return ShrinkRecord(
                product: product,
                previousSize: sameKind[sameKind.count - 2],
                currentSize: sameKind.last!,
                shrinkPercent: 0,
                priceThen: nil,
                priceNow: product.currentPrice,
                costPerUnitThen: nil,
                costPerUnitNow: product.currentPrice.map { $0 / max(current.quantity, 0.0001) },
                verdict: .insufficientData
            )
        }

        let percentChange = ((current.quantity - previous.quantity) / previous.quantity) * 100

        let costPerUnitNow: Double? = product.currentPrice.map { $0 / current.quantity }
        // Historical pricing arrives with Kroger snapshots in week 3 — nil until then.
        let costPerUnitThen: Double? = nil

        let verdict: ShrinkRecord.ShrinkVerdict = {
            switch percentChange {
            case ..<(-10):    return .significantShrink
            case -10 ..< -5:  return .moderateShrink
            case -5  ..< -1:  return .minorShrink
            case -1 ..< 1:    return .unchanged
            default:          return .grew
            }
        }()

        return ShrinkRecord(
            product: product,
            previousSize: sameKind[sameKind.count - 2],
            currentSize: sameKind.last!,
            shrinkPercent: percentChange,
            priceThen: nil,
            priceNow: product.currentPrice,
            costPerUnitThen: costPerUnitThen,
            costPerUnitNow: costPerUnitNow,
            verdict: verdict
        )
    }
```

Leave `normalize(_:)` untouched.

- [ ] **Step 4: Run tests to verify they pass**

Run the test command above.
Expected: `Test Suite 'ShrinkDetectorTests' passed` (all previous tests plus 3 new ones).

- [ ] **Step 5: Commit**

```bash
git add Shrunk/Models/ShrunkProduct.swift Shrunk/Services/ShrinkDetector.swift ShrunkTests/ShrinkDetectorTests.swift
git commit -m "fix(detector): compare only same-kind size records"
```

---

### Task 11: iOS `ShrunkAPIClient`

**Files:**
- Create: `Shrunk/Services/ShrunkAPIClient.swift`
- Test: `ShrunkTests/ShrunkAPIClientTests.swift`

**Interfaces:**
- Produces: `actor ShrunkAPIClient { static let shared; init(baseURL: URL = ShrunkAPIClient.defaultBaseURL, session: URLSession = .shared); func fetchProduct(barcode: String, locationId: String?) async throws -> ShrunkProduct }`.
- Throws `ShrunkError.productNotFound` on 404, `.invalidResponse` on other non-200, `.network` on transport errors, `.decoding` on bad JSON (all exist in `OpenFoodFactsService.swift`).
- `ShrunkProduct.sizeHistory` is built from `observations` with `unit` = `"g"` (mass), `"ml"` (volume), `"count"` (count), `date` from `observed_at`, `source` from `source`. `currentPrice` = most recent snapshot's `promo` if > 0 else `regular`, else nil.
- `defaultBaseURL`: `http://localhost:8787` under `#if DEBUG` when `UserDefaults.standard.bool(forKey: "useLocalAPI")` is true, otherwise `https://shrunk-api.<account>.workers.dev` (fill in the URL printed in Task 9).

- [ ] **Step 1: Write the failing tests**

`ShrunkTests/ShrunkAPIClientTests.swift`:

```swift
import XCTest
@testable import Shrunk

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler!(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ShrunkAPIClientTests: XCTestCase {
    private var client: ShrunkAPIClient!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        client = ShrunkAPIClient(baseURL: URL(string: "https://api.test")!, session: URLSession(configuration: config))
    }

    func test_fetchProduct_mapsObservationsAndPrice() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/product/0028400642255?locationId=01400943")
            let json = """
            {"gtin":"0028400642255","name":"Gatorade","brand":"Gatorade","category":"Beverages","image_url":"https://img/x.jpg","unit_kind":"volume",
             "observations":[
               {"quantity":946.353,"unit_kind":"volume","raw_text":"32 fl oz","observed_at":1517443200,"source":"fdc","source_ref":"1","confidence":0.9},
               {"quantity":828.058,"unit_kind":"volume","raw_text":"28 fl oz","observed_at":1625097600,"source":"kroger","source_ref":"01400943","confidence":0.8}],
             "price_snapshots":[{"location_id":"01400943","regular":1.89,"promo":0,"per_unit_estimate":0.07,"size_raw":"28 fl oz","stock_level":"HIGH","observed_at":1700000000}]}
            """
            return (200, Data(json.utf8))
        }

        let product = try await client.fetchProduct(barcode: "0028400642255", locationId: "01400943")

        XCTAssertEqual(product.id, "0028400642255")
        XCTAssertEqual(product.name, "Gatorade")
        XCTAssertEqual(product.category, "Beverages")
        XCTAssertEqual(product.imageURL?.absoluteString, "https://img/x.jpg")
        XCTAssertEqual(product.sizeHistory.count, 2)
        XCTAssertEqual(product.sizeHistory[0].quantity, 946.353, accuracy: 0.001)
        XCTAssertEqual(product.sizeHistory[0].unit, "ml")
        XCTAssertEqual(product.sizeHistory[0].source, "fdc")
        XCTAssertEqual(product.sizeHistory[0].date.timeIntervalSince1970, 1517443200)
        XCTAssertEqual(product.sizeHistory[1].source, "kroger")
        XCTAssertEqual(product.currentPrice, 1.89)
    }

    func test_fetchProduct_massUnitAndNoPrice() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/product/0028400642255")
            let json = """
            {"gtin":"0028400642255","name":"Doritos","brand":"Doritos","category":"","image_url":null,"unit_kind":"mass",
             "observations":[{"quantity":340.194,"unit_kind":"mass","raw_text":"12 oz","observed_at":1517443200,"source":"fdc","source_ref":"1","confidence":0.9}],
             "price_snapshots":[]}
            """
            return (200, Data(json.utf8))
        }
        let product = try await client.fetchProduct(barcode: "0028400642255", locationId: nil)
        XCTAssertEqual(product.sizeHistory[0].unit, "g")
        XCTAssertNil(product.currentPrice)
        XCTAssertNil(product.imageURL)
    }

    func test_fetchProduct_404_throwsNotFound() async {
        StubURLProtocol.handler = { _ in (404, Data(#"{"error":"not_found"}"#.utf8)) }
        do {
            _ = try await client.fetchProduct(barcode: "0099999999999", locationId: nil)
            XCTFail("expected throw")
        } catch ShrunkError.productNotFound {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_fetchProduct_500_throwsInvalidResponse() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        do {
            _ = try await client.fetchProduct(barcode: "0028400642255", locationId: nil)
            XCTFail("expected throw")
        } catch ShrunkError.invalidResponse {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -only-testing:ShrunkTests/ShrunkAPIClientTests -quiet 2>&1 | tail -20
```
Expected: compile error `cannot find 'ShrunkAPIClient' in scope`.

- [ ] **Step 3: Implement**

`Shrunk/Services/ShrunkAPIClient.swift`:

```swift
import Foundation

/// Client for the Shrunk Worker API. Single source of product identity and
/// size/price history for the scan and watchlist paths.
actor ShrunkAPIClient {
    static let shared = ShrunkAPIClient()

    static var defaultBaseURL: URL {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "useLocalAPI") {
            return URL(string: "http://localhost:8787")!
        }
        #endif
        return URL(string: "https://shrunk-api.REPLACE-ME.workers.dev")!   // set to the URL printed by `wrangler deploy`
    }

    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(baseURL: URL = ShrunkAPIClient.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func fetchProduct(barcode: String, locationId: String?) async throws -> ShrunkProduct {
        var components = URLComponents(url: baseURL.appending(path: "v1/product/\(barcode)"), resolvingAgainstBaseURL: false)!
        if let locationId {
            components.queryItems = [URLQueryItem(name: "locationId", value: locationId)]
        }

        let data: Data
        do {
            let (received, response) = try await session.data(from: components.url!)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: data = received
            case 404: throw ShrunkError.productNotFound
            default:  throw ShrunkError.invalidResponse
            }
        } catch let error as ShrunkError {
            throw error
        } catch {
            throw ShrunkError.network(error)
        }

        let dto: ProductDTO
        do {
            dto = try decoder.decode(ProductDTO.self, from: data)
        } catch {
            throw ShrunkError.decoding(error)
        }
        return dto.toProduct()
    }
}

// MARK: - Wire format

struct ProductDTO: Decodable {
    let gtin: String
    let name: String
    let brand: String
    let category: String
    let image_url: String?
    let unit_kind: String?
    let observations: [ObservationDTO]
    let price_snapshots: [PriceSnapshotDTO]

    struct ObservationDTO: Decodable {
        let quantity: Double
        let unit_kind: String
        let raw_text: String?
        let observed_at: Int
        let source: String
        let source_ref: String?
        let confidence: Double
    }

    struct PriceSnapshotDTO: Decodable {
        let location_id: String
        let regular: Double?
        let promo: Double?
        let per_unit_estimate: Double?
        let size_raw: String?
        let stock_level: String?
        let observed_at: Int
    }

    static func unit(forKind kind: String) -> String {
        switch kind {
        case "mass":   return "g"
        case "volume": return "ml"
        default:       return "count"
        }
    }

    func toProduct() -> ShrunkProduct {
        let history = observations.map {
            SizeRecord(
                date: Date(timeIntervalSince1970: TimeInterval($0.observed_at)),
                quantity: $0.quantity,
                unit: Self.unit(forKind: $0.unit_kind),
                source: $0.source
            )
        }
        let latestSnapshot = price_snapshots.max { $0.observed_at < $1.observed_at }
        let price: Double? = latestSnapshot.flatMap { snap in
            if let promo = snap.promo, promo > 0 { return promo }
            return snap.regular
        }
        return ShrunkProduct(
            id: gtin,
            name: name,
            brand: brand,
            category: category.isEmpty ? "Uncategorized" : category,
            imageURL: image_url.flatMap(URL.init),
            sizeHistory: history,
            currentPrice: price,
            currency: "USD"
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command from Step 2.
Expected: `Test Suite 'ShrunkAPIClientTests' passed`, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Shrunk/Services/ShrunkAPIClient.swift ShrunkTests/ShrunkAPIClientTests.swift
git commit -m "feat(ios): ShrunkAPIClient for the Worker product endpoint"
```

---

### Task 12: Wire the app to the API; retire the UPC fallback

**Files:**
- Modify: `Shrunk/Features/Result/ResultViewModel.swift:26-87`
- Modify: `Shrunk/Services/WatchlistService.swift:10-19,64-96`
- Delete: `Shrunk/Services/UPCItemDBService.swift` (and `ShrunkTests/UPCItemDBServiceTests.swift` if it exists)
- Modify: `Shrunk/Resources/Info.plist` (local networking for `wrangler dev`)
- Modify: `Shrunk/Services/ShrunkAPIClient.swift` (real base URL)

**Interfaces:**
- Consumes: `ShrunkAPIClient.fetchProduct(barcode:locationId:)` from Task 11.
- `ResultViewModel.init(api: ShrunkAPIClient = .shared, engine:, detector:)`; `WatchlistService.init(context:, api: ShrunkAPIClient = .shared, detector:)`.

- [ ] **Step 1: Update `ResultViewModel`**

Replace the two service properties and the initialiser:

```swift
    private let api: ShrunkAPIClient
    private let engine: AlternativesEngine
    private let detector: ShrinkDetector

    init(
        api: ShrunkAPIClient = .shared,
        engine: AlternativesEngine = AlternativesEngine(),
        detector: ShrinkDetector = ShrinkDetector()
    ) {
        self.api = api
        self.engine = engine
        self.detector = detector
    }
```

Replace `load(barcode:)` and delete `loadFromFallback` entirely:

```swift
    func load(barcode: String) async {
        if case .loaded = state { return }   // already prebaked — don't clobber
        state = .loading
        alternatives = []

        do {
            let product = try await api.fetchProduct(barcode: barcode, locationId: nil)
            let record = detector.analyze(product: product)
            state = .loaded(product, record)
            await loadAlternatives(for: product, record: record)
        } catch ShrunkError.productNotFound {
            state = .notFound(barcode: barcode)
        } catch let error as ShrunkError {
            state = .error(error.errorDescription ?? "Something went wrong.")
        } catch {
            state = .error(error.localizedDescription)
        }
    }
```

- [ ] **Step 2: Update `WatchlistService`**

```swift
    private let context: ModelContext
    private let api: ShrunkAPIClient
    private let detector: ShrinkDetector

    init(context: ModelContext,
         api: ShrunkAPIClient = .shared,
         detector: ShrinkDetector = ShrinkDetector()) {
        self.context = context
        self.api = api
        self.detector = detector
    }
```

In `refreshAll()`, replace `let product = try await off.fetchProduct(barcode: item.barcode)` with `let product = try await api.fetchProduct(barcode: item.barcode, locationId: nil)`, and delete the OFF throttle (`try? await Task.sleep(nanoseconds: 500_000_000)` and its comment). Update the doc comment above the method from "hits OFF" to "hits the Shrunk API".

- [ ] **Step 3: Delete the UPC service and allow local networking**

```bash
git rm -q Shrunk/Services/UPCItemDBService.swift
ls ShrunkTests | grep -i upc && git rm -q ShrunkTests/UPCItemDBServiceTests.swift || true
grep -rn "UPCItemDB" Shrunk ShrunkTests || echo "no remaining references"
```

Add to `Shrunk/Resources/Info.plist` inside the top-level `<dict>`:

```xml
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
```

In `Shrunk/Services/ShrunkAPIClient.swift` replace `https://shrunk-api.REPLACE-ME.workers.dev` with the URL printed in Task 9.

- [ ] **Step 4: Build and run the full iOS test suite**

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -30
```
Expected: build succeeds; `ShrinkDetectorTests`, `ShrunkAPIClientTests`, `OpenFoodFactsServiceTests` pass.

- [ ] **Step 5: Manual smoke test on the simulator**

Run the app, open a curated Browse card (still fed by `trending.json`) and then scan or enter one of the GTINs the Task 9 D1 query showed with ≥2 observations (the scanner accepts EAN-13). Expected: result view shows history from the API with a shrink verdict and `fdc` provenance in the chart annotations.

- [ ] **Step 6: Commit**

```bash
git add -A Shrunk ShrunkTests
git commit -m "feat(ios): scan and watchlist paths read from the Shrunk API"
```

---

### Task 13: Hit-rate report over the curated 35

**Files:**
- Create: `scripts/hit_rate.py`

**Interfaces:**
- CLI: `python3 scripts/hit_rate.py --api https://shrunk-api.<account>.workers.dev --curated data/trending.json` prints a table and a summary line `found=N/35 with_history=N/35 shrink_detected=N/35`.
- Detection logic mirrors `ShrinkDetector`: two most recent same-kind observations, shrink when `(cur - prev) / prev * 100 < -1`.

- [ ] **Step 1: Write the script**

```python
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
```

- [ ] **Step 2: Run it against the deployed Worker**

```bash
python3 scripts/hit_rate.py --api https://shrunk-api.<account>.workers.dev
```

Record the summary line in the commit message. Expected: `found` substantially above the pre-v2 baseline of 3/35 (products unknown to FDC are created via the FDC/OFF lookups, so `found` should be high; `with_history` is bounded by FDC's food-only coverage — paper, cleaning, and personal-care entries will show `no history` until weeks 2–3 add crowd and Kroger observations). If `found` is below 20/35, check that Task 9's import completed (`SELECT COUNT(*) FROM products`).

- [ ] **Step 3: Commit**

```bash
git add scripts/hit_rate.py
git commit -m "chore: hit-rate report over curated products (found=N/35 with_history=N/35 shrink_detected=N/35)"
```

---

### Task 14: APNs-from-Workers spike (throwaway)

**Files:**
- Create: `backend/spikes/apns-probe.ts`, `backend/spikes/wrangler.apns.toml`

This answers one question for week 4: can a Worker's outbound `fetch` deliver to `https://api.push.apple.com` (which requires HTTP/2)? Nothing here ships. Needs from the user: an APNs auth key (`.p8`) from developer.apple.com → Keys → "+" → Apple Push Notifications service, its Key ID, the Team ID `X4VJ56X38V`, and a device token (run the app on a real device with a temporary `UIApplication.shared.registerForRemoteNotifications()` + `didRegisterForRemoteNotificationsWithDeviceToken` print, or use any existing APNs-enabled test app).

- [ ] **Step 1: Write the probe**

`backend/spikes/wrangler.apns.toml`:

```toml
name = "shrunk-apns-probe"
main = "apns-probe.ts"
compatibility_date = "2026-08-01"
compatibility_flags = ["nodejs_compat"]
```

`backend/spikes/apns-probe.ts`:

```ts
// THROWAWAY SPIKE — proves/disproves APNs delivery from a Worker. Not shipped.
// Secrets: APNS_KEY_P8 (PEM contents), APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC (bundle id), DEVICE_TOKEN.
interface Env { APNS_KEY_P8: string; APNS_KEY_ID: string; APNS_TEAM_ID: string; APNS_TOPIC: string; DEVICE_TOKEN: string }

const b64url = (buf: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

function pemToPkcs8(pem: string): ArrayBuffer {
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0)).buffer;
}

async function apnsJWT(env: Env): Promise<string> {
  const key = await crypto.subtle.importKey("pkcs8", pemToPkcs8(env.APNS_KEY_P8), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = b64url(new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = b64url(new TextEncoder().encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) })));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`));
  return `${header}.${claims}.${b64url(sig)}`;
}

export default {
  async fetch(_req: Request, env: Env): Promise<Response> {
    const jwt = await apnsJWT(env);
    const res = await fetch(`https://api.sandbox.push.apple.com/3/device/${env.DEVICE_TOKEN}`, {
      method: "POST",
      headers: { authorization: `bearer ${jwt}`, "apns-topic": env.APNS_TOPIC, "apns-push-type": "alert", "content-type": "application/json" },
      body: JSON.stringify({ aps: { alert: { title: "Shrunk", body: "APNs from Workers works" } } }),
    });
    return new Response(`APNs status ${res.status}: ${await res.text()}`);
  },
};
```

- [ ] **Step 2: Run it**

```bash
cd backend/spikes
npx wrangler secret put APNS_KEY_P8 -c wrangler.apns.toml   # paste the .p8 file contents
npx wrangler secret put APNS_KEY_ID -c wrangler.apns.toml
npx wrangler secret put APNS_TEAM_ID -c wrangler.apns.toml  # X4VJ56X38V
npx wrangler secret put APNS_TOPIC -c wrangler.apns.toml    # com.shrunk.app
npx wrangler secret put DEVICE_TOKEN -c wrangler.apns.toml
npx wrangler deploy -c wrangler.apns.toml
curl -s https://shrunk-apns-probe.<account>.workers.dev
```

Outcomes:
- `APNs status 200` and the device shows the notification → **week 4 uses APNs directly from the Worker.**
- `400 BadDeviceToken` / `403 InvalidProviderToken` → credentials issue, fix and retry (a 4xx from Apple still proves HTTP/2 connectivity).
- Transport error / `421` / `HTTP/1.1 not supported` style failure → **week 4 uses Firebase Cloud Messaging HTTP v1** behind the same `PushSender` interface.

- [ ] **Step 3: Record the result and tear down**

Append the outcome to the spec under §6.5 as one line (`APNs spike result (YYYY-MM-DD): direct APNs works` or `... use FCM`). Then:

```bash
npx wrangler delete -c wrangler.apns.toml
cd /Users/drao/Projects/shrunk
git add backend/spikes docs/superpowers/specs/2026-08-26-shrunk-v2-design.md
git commit -m "spike: APNs delivery from Workers (result recorded in spec §6.5)"
```

---

### Task 15: Kroger developer account + permission email (user actions, no code)

- [ ] **Step 1:** Register at https://developer.kroger.com (self-serve). Create an application with the **Products** and **Locations** APIs; note the Client ID and Client Secret for week 3. Set a placeholder redirect URI (client-credentials flow doesn't use it).
- [ ] **Step 2:** Send the email in spec Appendix A to Kroger developer support (the support contact listed on developer.kroger.com/support), with the Client ID filled in. Record the send date in the spec under §9.
- [ ] **Step 3:** Commit the spec note:

```bash
git add docs/superpowers/specs/2026-08-26-shrunk-v2-design.md
git commit -m "docs: record Kroger permission request date"
```

---

## Week 1 exit criteria

- `cd scripts && python3 -m pytest tests -q` → all pass; `cd backend && npm test && npm run typecheck` → all pass; iOS test suite passes.
- Deployed Worker answers `/v1/product/{gtin}` with FDC-backed observations; `scripts/out/report.json` and the hit-rate summary are recorded in commit messages.
- The app's scan path no longer calls Open Food Facts or UPCItemDB.
- APNs spike outcome recorded in spec §6.5; Kroger client credentials in hand; permission email sent.

Week 2 plan (label capture + crowd observations + admin review) is written after these criteria are met, using the measured hit rate to size the crowd-contribution UX.
