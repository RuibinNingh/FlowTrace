import json
from pathlib import Path

import pytest

from flowtrace_server.domain.calendar_rules import (
    business_date,
    period_bounds,
    recurrence_dates,
    saving_schedule,
)
from flowtrace_server.domain.money import (
    DomainError,
    Money,
    allocate_last,
    convert_money,
    cumulative_allocation_delta,
    parse_display,
    parse_minor,
    parse_rate,
    round_half_up,
)

ROOT = Path(__file__).resolve().parents[3]
VECTORS = json.loads(
    (ROOT / "contracts/fixtures/ledger/money-time-vectors.json").read_text(encoding="utf-8")
)


@pytest.mark.parametrize("vector", VECTORS["money_vectors"])
def test_money_contract_vectors(vector):
    if vector["accepted"]:
        assert (
            Money.from_json(vector["input"]).to_json()["amount_minor"] == vector["canonical_minor"]
        )
    else:
        with pytest.raises(DomainError) as error:
            Money.from_json(vector["input"])
        assert error.value.code == vector["error_code"]


@pytest.mark.parametrize("vector", VECTORS["display_vectors"])
def test_display_contract_vectors(vector):
    if "error_code" in vector:
        with pytest.raises(DomainError) as error:
            parse_display(vector["input"], vector["currency"], vector["scale"])
        assert error.value.code == vector["error_code"]
    else:
        money = parse_display(vector["input"], vector["currency"], vector["scale"])
        assert str(money.minor) == vector["expected_minor"]
        assert parse_display(money.display(), money.currency, money.currency_scale) == money


@pytest.mark.parametrize("vector", VECTORS["allocation_vectors"])
def test_allocation_contract_vectors(vector):
    assert allocate_last(vector["total_minor"], vector["count"]) == vector["expected_minor"]


@pytest.mark.parametrize("vector", VECTORS["fx_vectors"])
def test_fx_contract_vectors(vector):
    result = convert_money(
        Money.from_json(vector["source"]),
        vector["rate"],
        vector["report_currency"],
        vector["report_scale"],
    )
    assert str(result.minor) == vector["expected_minor"]


@pytest.mark.parametrize("vector", VECTORS["period_vectors"])
def test_business_period_vectors(vector):
    assert period_bounds(vector["date"], vector["month_start_day"]) == (
        vector["expected_start"],
        vector["expected_end_exclusive"],
    )


@pytest.mark.parametrize("vector", VECTORS["recurrence_vectors"])
def test_recurrence_vectors(vector):
    assert (
        recurrence_dates(vector["anchor_date"], vector["frequency"], vector["count"])
        == vector["expected_dates"]
    )


@pytest.mark.parametrize("vector", VECTORS["saving_vectors"])
def test_seven_saving_modes(vector):
    values = saving_schedule(vector["mode"], vector["base_minor"], vector["count"])
    assert str(sum(map(int, values))) == vector["expected_total_minor"]
    if "first_minor" in vector:
        assert values[0] == vector["first_minor"]
        assert values[-1] == vector["last_minor"]


@pytest.mark.parametrize(
    "value", ["-9223372036854775808", "9223372036854775807", "9007199254740993"]
)
def test_signed_int64_and_json_round_trip(value):
    source = {"currency": "CNY", "currency_scale": 2, "amount_minor": value}
    assert Money.from_json(json.loads(json.dumps(source))).to_json() == source


@pytest.mark.parametrize("value", ["+1", "-0", "1e3", " 1", "1\n", "١", True, 1, 1.0, None])
def test_minor_rejects_coercion_and_noncanonical_values(value):
    with pytest.raises(DomainError, match="money.format"):
        parse_minor(value)


@pytest.mark.parametrize("value", ["-9223372036854775809", "9223372036854775808", "9" * 10000])
def test_int64_overflow_is_rejected_before_conversion(value):
    with pytest.raises(DomainError, match="money.out_of_range"):
        parse_minor(value)


@pytest.mark.parametrize(
    "numerator,denominator,expected",
    [(1, 2, 1), (-1, 2, -1), (1, 3, 0), (-1, 3, 0), (5, 2, 3), (-5, 2, -3)],
)
def test_half_up_is_symmetric_and_exact(numerator, denominator, expected):
    assert round_half_up(numerator, denominator) == expected


def test_many_partial_allocations_keep_final_total_exact():
    first = cumulative_allocation_delta("7207", "1001", "0", "400")
    last = cumulative_allocation_delta("7207", "1001", "400", "1001")
    assert first == "2880"
    assert last == "4327"
    assert int(first) + int(last) == 7207


@pytest.mark.parametrize(
    "rate", ["0", "-1", "1e1", "01", "1.0000000000000000001", "100000000000000000000", 1.2]
)
def test_invalid_rates_do_not_become_binary_float(rate):
    with pytest.raises(DomainError, match="fx.rate_invalid"):
        parse_rate(rate)


def test_currency_precision_and_positive_amount_are_independent():
    assert Money("CNY", 2, 0).display() == "0.00"
    with pytest.raises(DomainError, match="money.must_be_positive"):
        Money.from_json(
            {"currency": "CNY", "currency_scale": 2, "amount_minor": "0"}, positive=True
        )
    with pytest.raises(DomainError, match="money.precision"):
        Money.from_json({"currency": "CNY", "currency_scale": True, "amount_minor": "1"})
    with pytest.raises(DomainError, match="money.currency_mismatch"):
        Money("CNY", 2, 1).plus(Money("JPY", 0, 1))


@pytest.mark.parametrize("value", ["2026-02-29", "2026-13-01", "2026-2-01", "0000-01-01"])
def test_invalid_business_dates(value):
    with pytest.raises(DomainError, match="date.invalid"):
        business_date(value)


def test_occurrence_limits_and_real_workday_calendar_requirement():
    with pytest.raises(DomainError, match="schedule.invalid_count"):
        allocate_last("1", 10001)
    with pytest.raises(DomainError, match="schedule.invalid_count"):
        recurrence_dates("2026-01-01", "monthly", 10001)
    with pytest.raises(DomainError, match="schedule.calendar_unavailable"):
        recurrence_dates("2026-01-01", "statutory_workday", 1)
