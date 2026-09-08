import pytest
from fdc.gtin import normalize_gtin


@pytest.mark.parametrize("raw, expected", [
    ("96385074", "0000096385074"),          # EAN-8 -> canonical zero padding
    ("028400642255", "0028400642255"),      # 12-digit UPC-A -> prefix 0
    ("0028400642255", "0028400642255"),     # already 13
    ("00027000612323", "0027000612323"),    # 14-digit GTIN-14 with leading 0
    (" 028400642255 ", "0028400642255"),    # whitespace
    ("028-400-642255", "0028400642255"),    # separators stripped
    ("10027000612323", None),               # 14-digit not starting with 0 (case level) -> reject
    ("96385075", None),                     # invalid EAN-8 check digit
    ("028400642256", None),                 # invalid UPC-A check digit
    ("", None),
    ("0284x00642255", None),                # arbitrary characters are rejected
    ("abc", None),
])
def test_normalize_gtin(raw, expected):
    assert normalize_gtin(raw) == expected
