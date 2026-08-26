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
