"""Exact money primitives. No floating point enters an accounting operation."""

from __future__ import annotations

import re
from dataclasses import dataclass
from fractions import Fraction
from typing import Mapping

INT64_MIN = -(2**63)
INT64_MAX = 2**63 - 1
MAX_REFERENCE_OCCURRENCES = 10000
_MINOR = re.compile(r"(?:0|-?[1-9][0-9]*)", re.ASCII)
_DISPLAY = re.compile(r"(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?", re.ASCII)
_RATE = re.compile(r"(?:0|[1-9][0-9]*)(?:\.[0-9]{1,18})?", re.ASCII)
_CURRENCY = re.compile(r"[A-Z]{3}", re.ASCII)


class DomainError(ValueError):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def checked_minor(value: int) -> int:
    if type(value) is not int or not INT64_MIN <= value <= INT64_MAX:
        raise DomainError("money.out_of_range")
    return value


def parse_minor(value: object, *, positive: bool = False) -> int:
    if not isinstance(value, str) or not _MINOR.fullmatch(value):
        raise DomainError("money.format")
    # Bound the input before asking int() to parse an arbitrarily long string.
    if len(value.lstrip("-")) > 19:
        raise DomainError("money.out_of_range")
    amount = checked_minor(int(value))
    if positive and amount <= 0:
        raise DomainError("money.must_be_positive")
    return amount


def validate_scale(scale: object) -> int:
    if type(scale) is not int or not 0 <= scale <= 6:
        raise DomainError("money.precision")
    return scale


@dataclass(frozen=True)
class Money:
    currency: str
    currency_scale: int
    minor: int

    def __post_init__(self) -> None:
        if not isinstance(self.currency, str) or not _CURRENCY.fullmatch(self.currency):
            raise DomainError("money.currency_mismatch")
        validate_scale(self.currency_scale)
        checked_minor(self.minor)

    @classmethod
    def from_json(cls, value: Mapping, *, positive: bool = False) -> "Money":
        if not isinstance(value, Mapping) or set(value) != {
            "currency",
            "currency_scale",
            "amount_minor",
        }:
            raise DomainError("money.format")
        return cls(
            value["currency"],
            value["currency_scale"],
            parse_minor(value["amount_minor"], positive=positive),
        )

    def to_json(self) -> dict:
        return {
            "currency": self.currency,
            "currency_scale": self.currency_scale,
            "amount_minor": str(self.minor),
        }

    def plus(self, other: "Money") -> "Money":
        if (self.currency, self.currency_scale) != (other.currency, other.currency_scale):
            raise DomainError("money.currency_mismatch")
        return Money(self.currency, self.currency_scale, checked_minor(self.minor + other.minor))

    def display(self) -> str:
        sign = "-" if self.minor < 0 else ""
        digits = str(abs(self.minor)).zfill(self.currency_scale + 1)
        if self.currency_scale == 0:
            return sign + digits
        return f"{sign}{digits[: -self.currency_scale]}.{digits[-self.currency_scale :]}"


def parse_display(value: object, currency: str, scale: int) -> Money:
    validate_scale(scale)
    match = _DISPLAY.fullmatch(value) if isinstance(value, str) else None
    if match is None:
        raise DomainError("money.format")
    sign, whole, decimals = match.groups()
    decimals = decimals or ""
    if any(digit != "0" for digit in decimals[scale:]):
        raise DomainError("money.precision")
    digits = whole + decimals[:scale].ljust(scale, "0")
    canonical = digits.lstrip("0") or "0"
    if sign and canonical != "0":
        canonical = "-" + canonical
    return Money(currency, scale, parse_minor(canonical))


def parse_rate(value: object) -> Fraction:
    if not isinstance(value, str) or not _RATE.fullmatch(value) or len(value.split(".")[0]) > 20:
        raise DomainError("fx.rate_invalid")
    whole, _, decimals = value.partition(".")
    rate = Fraction(int(whole + decimals), 10 ** len(decimals))
    if rate <= 0 or rate >= 10**20:
        raise DomainError("fx.rate_invalid")
    return rate


def round_half_up(numerator: int, denominator: int) -> int:
    if type(numerator) is not int or type(denominator) is not int or denominator <= 0:
        raise DomainError("money.format")
    magnitude = (abs(numerator) * 2 + denominator) // (2 * denominator)
    return -magnitude if numerator < 0 else magnitude


def convert_money(source: Money, rate: str, report_currency: str, report_scale: int) -> Money:
    validate_scale(report_scale)
    fraction = parse_rate(rate)
    numerator = source.minor * fraction.numerator * (10**report_scale)
    denominator = fraction.denominator * (10**source.currency_scale)
    return Money(
        report_currency, report_scale, checked_minor(round_half_up(numerator, denominator))
    )


def allocate_last(total_minor: str, count: int) -> list[str]:
    total = parse_minor(total_minor, positive=True)
    if type(count) is not int or not 1 <= count <= MAX_REFERENCE_OCCURRENCES:
        raise DomainError("schedule.invalid_count")
    base = total // count
    return [str(base)] * (count - 1) + [str(total - (count - 1) * base)]


def cumulative_allocation_delta(
    report_total: str, original_total: str, previous: str, current: str
) -> str:
    report = parse_minor(report_total)
    original = parse_minor(original_total, positive=True)
    before, after = parse_minor(previous), parse_minor(current)
    if not 0 <= before <= after <= original:
        raise DomainError("allocation.exceeds_remaining")
    return str(
        checked_minor(
            round_half_up(report * after, original) - round_half_up(report * before, original)
        )
    )
