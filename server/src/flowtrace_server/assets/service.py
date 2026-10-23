"""Read only an authorized account set; revoked books never supply bill details."""

from datetime import date, timedelta
from uuid import UUID

from sqlalchemy import select

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal
from flowtrace_server.books.permissions import authorize_scope
from flowtrace_server.currencies.catalog import CURRENCY_SCALES
from flowtrace_server.domain.calendar_rules import business_date
from flowtrace_server.domain.money import DomainError, Money, checked_minor
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.sync.common import lock_scopes, run_transaction, visible_scopes
from flowtrace_server.sync.models import LedgerEntry, SyncEntity
from flowtrace_server.sync.schemas import management_payload

from .calculations import RateIndex, balance_on, credit_calendar, value_accounts
from .configuration import preferences, rates, revision

MAX_ACCOUNTS, MAX_ENTRIES = 5000, 50000


def _range(start, end):
    try:
        first, stop = business_date(start), business_date(end)
        if not 0 < (stop - first).days <= 366:
            raise DomainError("date.invalid")
        return first, stop
    except (DomainError, ValueError):
        raise ApiError("validation_error", 422) from None


def _context(session, principal, scope_id):
    assert_active_principal(session, principal, lock=True)
    if principal.purpose not in {"api_native", "api_web"}:
        raise ApiError("session_purpose_invalid", 403)
    locked = lock_scopes(session, {principal.user_id, scope_id})
    authorize_scope(session, principal, scope_id)
    state = session.get(ServerState, 1)
    return {
        "instance_id": str(state.instance_id),
        "sync_epoch": str(state.sync_epoch),
        "scope_id": str(scope_id),
        "scope_revision": str(locked[scope_id].revision),
        "config_revision": str(revision(session, principal.user_id)),
    }


def _final(session, principal, scope_id):
    assert_active_principal(session, principal, lock=False)
    authorize_scope(session, principal, scope_id)


def _records(session, scope_id, identifier=None):
    query = select(SyncEntity).where(
        SyncEntity.scope_id == scope_id,
        SyncEntity.entity_type == "account",
        SyncEntity.deleted.is_(False),
    )
    if identifier is not None:
        query = query.where(SyncEntity.id == identifier)
    rows = list(session.scalars(query.order_by(SyncEntity.id).limit(MAX_ACCOUNTS + 1)))
    if len(rows) > MAX_ACCOUNTS:
        raise ApiError("asset.limit_exceeded", 409)
    entries = list(
        session.scalars(
            select(LedgerEntry)
            .where(LedgerEntry.account_id.in_([row.id for row in rows]))
            .order_by(
                LedgerEntry.business_date,
                LedgerEntry.bill_id,
                LedgerEntry.component,
                LedgerEntry.id,
            )
            .limit(MAX_ENTRIES + 1)
        )
    )
    if len(entries) > MAX_ENTRIES:
        raise ApiError("asset.limit_exceeded", 409)
    by_account = {row.id: [] for row in rows}
    for row in entries:
        by_account[row.account_id].append(
            {
                "entry_id": str(row.id),
                "bill_id": str(row.bill_id),
                "book_id": str(row.book_id),
                "business_date": row.business_date.isoformat(),
                "component": row.component,
                "amount_minor": row.amount_minor,
                "currency": row.currency,
                "currency_scale": row.currency_scale,
            }
        )
    accounts = [
        {
            "id": str(row.id),
            "revision": str(row.revision),
            "payload": management_payload("account", row.payload),
            "balance_minor": row.balance_minor,
            "entries": by_account[row.id],
        }
        for row in rows
    ]
    for account in accounts:
        opening = account["payload"]["opening"]
        if any(
            (item["currency"], item["currency_scale"])
            != (opening["currency"], opening["currency_scale"])
            for item in account["entries"]
        ):
            raise ApiError("asset.balance_unavailable", 409)
    return accounts


def _valuation(session, principal, base, policy):
    preference = preferences(session, principal.user_id)["preferences"]
    base = base or preference["base_currency"]
    policy = policy or preference["valuation_policy"]
    if base not in CURRENCY_SCALES or policy not in {"exact_date", "latest_on_or_before"}:
        raise ApiError("validation_error", 422)
    return base, policy, rates(session, principal.user_id)["rates"]


def read_overview(session, principal, scope_id, as_of, base=None, policy=None, mode="current"):
    def read():
        envelope = _context(session, principal, scope_id)
        try:
            business_date(as_of)
            if mode not in {"current", "as_of"}:
                raise DomainError("date.invalid")
        except DomainError:
            raise ApiError("validation_error", 422) from None
        base_code, strategy, valuations = _valuation(session, principal, base, policy)
        result = value_accounts(
            _records(session, scope_id), valuations, as_of, base_code, strategy, mode
        )
        _final(session, principal, scope_id)
        return {
            **envelope,
            "as_of": as_of,
            "balance_mode": mode,
            "base_currency": base_code,
            "base_scale": CURRENCY_SCALES[base_code],
            "valuation_policy": strategy,
            **result,
        }

    return run_transaction(session, read, repeatable=True)


def read_history(session, principal, scope_id, start, end, base=None, policy=None):
    first, stop = _range(start, end)

    def read():
        envelope = _context(session, principal, scope_id)
        accounts = _records(session, scope_id)
        # Bound work as well as SQL/output. A large account set must use shorter
        # intervals; never silently return a partial net worth curve.
        if (len(accounts) + sum(len(a["entries"]) for a in accounts)) * (
            stop - first
        ).days > 2000000:
            raise ApiError("asset.limit_exceeded", 409)
        base_code, strategy, valuations = _valuation(session, principal, base, policy)
        valuations = RateIndex(valuations)
        points = []
        for index in range((stop - first).days):
            day = (first + timedelta(days=index)).isoformat()
            result = value_accounts(accounts, valuations, day, base_code, strategy, "as_of")
            points.append(
                {"date": day, **{k: result[k] for k in ("available", "issues", "totals")}}
            )
        _final(session, principal, scope_id)
        return {
            **envelope,
            "base_currency": base_code,
            "base_scale": CURRENCY_SCALES[base_code],
            "valuation_policy": strategy,
            "start_date": start,
            "end_date_exclusive": end,
            "points": points,
        }

    return run_transaction(session, read, repeatable=True)


def _account_read(session, principal, identifier, callback):
    def read():
        assert_active_principal(session, principal, lock=True)
        # The scope is discovered in this fresh RR transaction, never trusted
        # from a caller's cache. Ownership is checked before reading postings.
        entity = session.get(SyncEntity, identifier)
        if entity is None or entity.deleted or entity.entity_type != "account":
            raise ApiError("not_found", 404)
        scope_id = entity.scope_id
        envelope = _context(session, principal, scope_id)
        records = _records(session, scope_id, identifier)
        result = callback(envelope, records[0])
        _final(session, principal, scope_id)
        return result

    return run_transaction(session, read, repeatable=True)


def read_entries(session, principal, identifier, start, end, offset, limit):
    _range(start, end)

    def read(envelope, account):
        payload, entries = account["payload"], account["entries"]
        opening = Money.from_json(payload["opening"])
        if (
            checked_minor(opening.minor + sum(row["amount_minor"] for row in entries))
            != (account["balance_minor"])
        ):
            raise ApiError("asset.balance_unavailable", 409)
        visible_books = {
            scope.book_id for scope in visible_scopes(session, principal) if scope.kind == "book"
        }
        chosen = [row for row in entries if start <= row["business_date"] < end]
        page = chosen[offset : offset + limit]
        accessible = {UUID(row["bill_id"]) for row in page if UUID(row["book_id"]) in visible_books}
        details = {
            str(row.id): row
            for row in session.scalars(
                select(SyncEntity).where(
                    SyncEntity.id.in_(accessible),
                    SyncEntity.scope_id.in_(visible_books),
                    SyncEntity.entity_type == "bill",
                    SyncEntity.deleted.is_(False),
                )
            )
        }
        result, issues = [], []
        for row in page:
            bill = details.get(row["bill_id"])
            public = bill.payload if bill is not None else None
            result.append(
                {
                    "entry_id": row["entry_id"],
                    "business_date": row["business_date"],
                    "component": row["component"],
                    "money": Money(
                        opening.currency, opening.currency_scale, row["amount_minor"]
                    ).to_json(),
                    "detail_available": public is not None,
                    "bill_id": row["bill_id"] if public is not None else None,
                    "book_id": row["book_id"] if public is not None else None,
                    "bill_type": public["bill_type"] if public is not None else None,
                    "note": public["note"] if public is not None else None,
                    "category_id": public["category_id"] if public is not None else None,
                    "tag_ids": public["tag_ids"] if public is not None else [],
                    "attachment_ids": public["attachment_ids"] if public is not None else [],
                }
            )
        before, after = None, None
        try:
            anchor = payload.get("opening_date")
            if anchor is None:
                raise DomainError("asset.opening_date_required")
            # Validate all facts before deriving period balances.
            balance_on(payload, entries, end)
            if anchor <= start:
                before = Money(
                    opening.currency,
                    opening.currency_scale,
                    checked_minor(
                        opening.minor
                        + sum(
                            row["amount_minor"] for row in entries if row["business_date"] < start
                        )
                    ),
                ).to_json()
            last = (date.fromisoformat(end) - timedelta(days=1)).isoformat()
            amount = balance_on(payload, entries, last)
            if amount is not None:
                after = Money(opening.currency, opening.currency_scale, amount).to_json()
        except DomainError as error:
            issues.append(error.code)
        return {
            **envelope,
            "account_id": str(identifier),
            "currency": opening.currency,
            "currency_scale": opening.currency_scale,
            "start_date": start,
            "end_date_exclusive": end,
            "total_count": len(chosen),
            "offset": offset,
            "limit": limit,
            "entries": result,
            "opening_balance": before,
            "closing_balance": after,
            "issues": issues,
        }

    return _account_read(session, principal, identifier, read)


def read_credit_calendar(session, principal, identifier, start, end):
    _range(start, end)

    def read(envelope, account):
        payload = account["payload"]
        opening = Money.from_json(payload["opening"])
        try:
            if (
                checked_minor(
                    opening.minor + sum(row["amount_minor"] for row in account["entries"])
                )
                != (account["balance_minor"])
            ):
                raise DomainError("asset.balance_unavailable")
            result = credit_calendar(
                payload, account["balance_minor"], account["entries"], start, end
            )
        except DomainError as error:
            raise ApiError(error.code, 422) from None
        return {
            **envelope,
            "account_id": str(identifier),
            "currency": opening.currency,
            "currency_scale": opening.currency_scale,
            **result,
        }

    return _account_read(session, principal, identifier, read)
