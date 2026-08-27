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
