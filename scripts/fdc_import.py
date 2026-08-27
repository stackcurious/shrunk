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
