"""Business-date calculations, independent of the execution host's clock."""

from __future__ import annotations

import calendar
import re
from datetime import date, timedelta

from .money import MAX_REFERENCE_OCCURRENCES, DomainError


def business_date(value: object) -> date:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value):
        raise DomainError("date.invalid")
    try:
        return date.fromisoformat(value)
    except ValueError as error:
        raise DomainError("date.invalid") from error


def _month(year: int, month: int, delta: int) -> tuple[int, int]:
    ordinal = year * 12 + month - 1 + delta
    result = divmod(ordinal, 12)
    if not 1 <= result[0] <= 9999:
        raise DomainError("date.out_of_range")
    return result[0], result[1] + 1


def _clamped(year: int, month: int, day: int) -> date:
    return date(year, month, min(day, calendar.monthrange(year, month)[1]))


def period_bounds(value: str, month_start_day: int) -> tuple[str, str]:
    day = business_date(value)
    if type(month_start_day) is not int or not 1 <= month_start_day <= 31:
        raise DomainError("date.invalid_month_start")
    start = _clamped(day.year, day.month, month_start_day)
    if day < start:
        year, month = _month(day.year, day.month, -1)
        start = _clamped(year, month, month_start_day)
    next_year, next_month = _month(start.year, start.month, 1)
    end = _clamped(next_year, next_month, month_start_day)
    return start.isoformat(), end.isoformat()


def recurrence_dates(anchor: str, frequency: str, count: int) -> list[str]:
    day = business_date(anchor)
    if type(count) is not int or not 1 <= count <= MAX_REFERENCE_OCCURRENCES:
        raise DomainError("schedule.invalid_count")
    values = []
    for index in range(count):
        if frequency == "monthly":
            year, month = _month(day.year, day.month, index)
            occurrence = _clamped(year, month, day.day)
        elif frequency == "yearly":
            if day.year + index > 9999:
                raise DomainError("date.out_of_range")
            occurrence = _clamped(day.year + index, day.month, day.day)
        elif frequency in {"daily", "weekly"}:
            try:
                occurrence = day + timedelta(days=index * (7 if frequency == "weekly" else 1))
            except OverflowError as error:
                raise DomainError("date.out_of_range") from error
        elif frequency == "statutory_workday":
            raise DomainError("schedule.calendar_unavailable")
        else:
            raise DomainError("schedule.unsupported_frequency")
        values.append(occurrence.isoformat())
    return values


def saving_schedule(mode: str, base_minor: str, count: int) -> list[str]:
    from .money import checked_minor, parse_minor

    base = parse_minor(base_minor, positive=True)
    if type(count) is not int or not 0 <= count <= MAX_REFERENCE_OCCURRENCES:
        raise DomainError("schedule.invalid_count")
    if mode == "flexible":
        if count != 0:
            raise DomainError("schedule.invalid_count")
        return []
    fixed_counts = {
        "365": 365,
        "52_week": 52,
        "52_week_reverse": 52,
        "12_deposit": 12,
        "36_deposit": 36,
    }
    if mode in fixed_counts and count != fixed_counts[mode]:
        raise DomainError("schedule.invalid_count")
    if count <= 0 or mode not in {*fixed_counts, "fixed"}:
        raise DomainError("schedule.unsupported_mode")
    multipliers = (
        range(1, count + 1)
        if mode in {"365", "52_week"}
        else range(count, 0, -1)
        if mode == "52_week_reverse"
        else [1] * count
    )
    values = [checked_minor(base * multiplier) for multiplier in multipliers]
    checked_minor(sum(values))
    return list(map(str, values))
