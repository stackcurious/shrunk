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
