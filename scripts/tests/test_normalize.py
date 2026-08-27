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
