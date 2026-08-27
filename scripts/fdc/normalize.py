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

# "1/2 Gallon" is a fraction; "12/12 fl oz" is a 12-pack of 12 fl oz. Only a
# proper fraction with a household denominator is expanded, and only when it
# leads the string — everything else stays a "/"-separated segment list.
_LEADING_FRACTION = re.compile(r"^\s*(\d+)\s*/\s*(\d+)\s+([a-zA-Z].*)$")
_FRACTION_DENOMINATORS = {2, 3, 4, 8}

# R45 — a bare integer segment ("12/12 fl oz") or a count-unit segment
# ("12 ct / 12 fl oz") that *leads* a "/"-separated list is a multipack
# count, not an independent quantity: Kroger's items[].size spells a 12-pack
# of 12 fl oz cans as "12/12 FL OZ", where the second segment is the size of
# *one* unit, not the pack total. The old code discarded the leading count
# (a bare "12" fails to parse at all; "12 ct" was filtered out by the
# count-vs-mass preference below) and returned the per-unit size as if it
# were the whole package — a silent 12x-too-small reading.
_BARE_COUNT = re.compile(r"^\d+(?:[.,]\d+)?$")


def _expand_leading_fraction(text: str) -> str:
    match = _LEADING_FRACTION.match(text)
    if not match:
        return text
    numerator, denominator = int(match.group(1)), int(match.group(2))
    if denominator not in _FRACTION_DENOMINATORS or numerator == 0 or numerator >= denominator:
        return text
    return f"{numerator / denominator} {match.group(3)}"


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


def _leading_count_factor(segment: str) -> float | None:
    """The multiplier a leading segment contributes, or None if it isn't one."""
    text = segment.strip()
    if not text:
        return None
    if _BARE_COUNT.match(text):
        return _to_float(text)
    parsed = _parse_segment(text)
    return parsed[0] if parsed and parsed[1] == COUNT else None


def parse_package_weight(raw: str) -> ParsedQuantity | None:
    if raw is None:
        return None
    text = raw.strip()
    if not text:
        return None
    text = _expand_leading_fraction(text)

    raw_segments = _SEGMENT_SPLIT.split(text)

    if len(raw_segments) > 1:
        factor = _leading_count_factor(raw_segments[0])
        if factor is not None and factor > 0:
            # A leading count multiplies whichever per-unit size follows it —
            # but only a real one. If nothing after it parses to a
            # mass/volume quantity ("12/", a dangling "12 ct" with no size
            # after it, or a second count with no size at all), the count
            # alone is not a package weight — R45 says unparseable, not "12
            # of an unknown unit".
            rest = [p for p in (_parse_segment(s) for s in raw_segments[1:]) if p]
            per_unit = [p for p in rest if p[1] != COUNT]
            if not per_unit:
                return None

            unit_qty, kind = per_unit[0]
            for other_qty, other_kind in per_unit[1:]:
                if other_kind == kind and abs(other_qty - unit_qty) / unit_qty > _TOLERANCE:
                    return None
            total = unit_qty * factor
            return ParsedQuantity(quantity=round(total, 3), unit_kind=kind, raw=raw) if total > 0 else None

    parsed = [p for p in (_parse_segment(s) for s in raw_segments) if p]
    if not parsed:
        return None

    # Prefer mass/volume over count when both appear, e.g. a trailing count
    # that isn't leading the segment list ("340 g / 12 ct").
    preferred = [p for p in parsed if p[1] != COUNT] or parsed
    qty, kind = preferred[0]

    # Segments of the same kind must agree within tolerance, else the row is malformed.
    for other_qty, other_kind in preferred[1:]:
        if other_kind == kind and abs(other_qty - qty) / qty > _TOLERANCE:
            return None

    return ParsedQuantity(quantity=round(qty, 3), unit_kind=kind, raw=raw)
