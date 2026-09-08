"""Canonical barcode form: 13-digit zero-padded GTIN with check digit.

Mirror of backend/src/gtin.ts and ScannerViewModel.canonicalBarcode.
"""
import re

_SEPARATORS = re.compile(r"[\s-]")


def normalize_gtin(raw: str) -> str | None:
    if not raw:
        return None
    compact = _SEPARATORS.sub("", raw)
    if not compact.isascii() or not compact.isdigit():
        return None

    if len(compact) == 8:
        canonical = "00000" + compact
    elif len(compact) == 12:
        canonical = "0" + compact
    elif len(compact) == 13:
        canonical = compact
    elif len(compact) == 14 and compact.startswith("0"):
        canonical = compact[1:]
    else:
        return None

    digits = [int(value) for value in canonical]
    total = sum(value * (3 if index % 2 == 0 else 1)
                for index, value in enumerate(reversed(digits[:-1])))
    expected = (10 - total % 10) % 10
    return canonical if expected == digits[-1] else None
