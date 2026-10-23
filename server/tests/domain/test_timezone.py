import json
from datetime import datetime, timezone
from pathlib import Path

import pytest

from flowtrace_server.domain.money import DomainError
from flowtrace_server.domain.timezone_rules import (
    format_local_time,
    instant_business_date,
    resolve_local_time,
)

ROOT = Path(__file__).resolve().parents[3]
VECTORS = json.loads(
    (ROOT / "contracts/fixtures/ledger/money-time-vectors.json").read_text(encoding="utf-8")
)["timezone_vectors"]


@pytest.mark.parametrize("vector", VECTORS)
def test_real_iana_contract_vectors(vector):
    if "occurred_at" in vector:
        assert (
            instant_business_date(vector["occurred_at"], vector["timezone"])
            == vector["expected_business_date"]
        )
    else:
        resolved = resolve_local_time(vector["local_time"], vector["timezone"])
        if "expected_resolved_local" in vector:
            assert format_local_time(resolved) == vector["expected_resolved_local"]
        if "expected_utc" in vector:
            assert resolved.astimezone(timezone.utc) == datetime.fromisoformat(
                vector["expected_utc"].replace("Z", "+00:00")
            )


@pytest.mark.parametrize(
    "value",
    [
        "2026-02-30T00:00:00Z",
        "2026-01-01T24:00:00Z",
        "2026-01-01T00:00:00",
        "2026-01-01T00:00:00+99:00",
    ],
)
def test_invalid_instants_are_not_normalized_into_valid_business_dates(value):
    with pytest.raises(DomainError, match="date.invalid"):
        instant_business_date(value, "Asia/Shanghai")


def test_invalid_zone_is_explicit_and_not_host_timezone():
    with pytest.raises(DomainError, match="date.invalid_timezone"):
        instant_business_date("2026-01-01T00:00:00Z", "Mars/Unknown")
