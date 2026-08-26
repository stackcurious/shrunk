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
