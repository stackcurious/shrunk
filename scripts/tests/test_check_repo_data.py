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
