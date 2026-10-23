"""IANA conversion with explicit gap/overlap policy and pinned tzdata files."""

import re
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from importlib import resources
from zoneinfo import ZoneInfo

from .money import DomainError

_WALL = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?")
_INSTANT = re.compile(
    r"([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?)(Z|[+-][0-9]{2}:[0-9]{2})"
)


@lru_cache(maxsize=256)
def _location(name: str) -> ZoneInfo:
    if (
        not isinstance(name, str)
        or not re.fullmatch(r"[A-Za-z0-9_+.-]+(?:/[A-Za-z0-9_+.-]+)*", name)
        or any(part in {".", ".."} for part in name.split("/"))
    ):
        raise DomainError("date.invalid_timezone")
    try:
        # Use the explicitly locked database even on Linux, rather than silently
        # varying rules with the host's separately upgraded system tzdata.
        path = resources.files("tzdata.zoneinfo").joinpath(*name.split("/"))
        with path.open("rb") as stream:
            return ZoneInfo.from_file(stream, key=name)
    except ModuleNotFoundError as error:
        raise DomainError("date.timezone_data_unavailable") from error
    except (OSError, ValueError) as error:
        raise DomainError("date.invalid_timezone") from error


def _wall(value: str) -> datetime:
    if not isinstance(value, str) or not _WALL.fullmatch(value):
        raise DomainError("date.invalid")
    try:
        return datetime.fromisoformat(value)
    except ValueError as error:
        raise DomainError("date.invalid") from error


def _candidates(wall: datetime, zone: ZoneInfo) -> list[datetime]:
    by_utc = {}
    for fold in (0, 1):
        candidate = wall.replace(tzinfo=zone, fold=fold)
        utc = candidate.astimezone(timezone.utc)
        round_trip = utc.astimezone(zone)
        if round_trip.replace(tzinfo=None) == wall:
            by_utc[utc] = round_trip
    return [by_utc[key] for key in sorted(by_utc)]


def instant_business_date(occurred_at: str, timezone_name: str) -> str:
    match = _INSTANT.fullmatch(occurred_at) if isinstance(occurred_at, str) else None
    if match is None:
        raise DomainError("date.invalid")
    _wall(match.group(1))
    offset = match.group(2)
    if offset != "Z" and (int(offset[1:3]) > 23 or int(offset[4:6]) > 59):
        raise DomainError("date.invalid")
    location = _location(timezone_name)
    try:
        instant = datetime.fromisoformat(occurred_at.replace("Z", "+00:00"))
        return instant.astimezone(location).date().isoformat()
    except (ValueError, OverflowError) as error:
        raise DomainError("date.invalid") from error


def resolve_local_time(local_time: str, timezone_name: str) -> datetime:
    wall, zone = _wall(local_time), _location(timezone_name)
    candidates = _candidates(wall, zone)
    if candidates:
        return candidates[0]  # Earliest UTC instant is the first overlap.
    # Locate a valid minute after the gap, then refine to its first valid
    # second. This also handles non-hour and historical date-line jumps.
    cursor = wall.replace(second=0, microsecond=0)
    for _ in range(48 * 60):
        try:
            cursor += timedelta(minutes=1)
        except OverflowError as error:
            raise DomainError("date.out_of_range") from error
        if _candidates(cursor, zone):
            start = cursor - timedelta(minutes=1)
            for second in range(61):
                probe = start + timedelta(seconds=second)
                if probe >= wall:
                    candidates = _candidates(probe, zone)
                    if candidates:
                        return candidates[0]
    raise DomainError("date.unresolvable_local")


def format_local_time(value: datetime) -> str:
    return value.isoformat(timespec="seconds" if value.microsecond == 0 else "microseconds")
