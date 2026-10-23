"""Member-bound reports from one consistent PostgreSQL snapshot.

The global allocation query emits only sums keyed by already-authorized source
IDs. It never materializes another book's receipt IDs, notes or account links.
"""

import json
from copy import deepcopy
from time import monotonic
from uuid import UUID

from sqlalchemy import select, text
from sqlalchemy.orm import Session

from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal
from flowtrace_server.books.models import Book
from flowtrace_server.books.permissions import authorize_scope
from flowtrace_server.domain.money import DomainError, Money, checked_minor, parse_minor
from flowtrace_server.domain.reporting import ReportBill, ReportBudget, ReportQuery, build_report
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.sync.common import CURRENCY_SCALES, lock_scopes, run_transaction
from flowtrace_server.sync.models import SyncEntity

from .schemas import BookReportResponse, ReportResponse

MAX_REPORT_ENTITIES = 50000
MAX_REPORT_INPUT_BYTES = 8 * 1024 * 1024
MAX_REPORT_OUTPUT_BYTES = 1024 * 1024
REPORT_SECONDS = 10
_BILL_FIELDS = {
    "book_id",
    "bill_type",
    "money",
    "business_date",
    "category_id",
    "flags",
    "reporting",
    "allocations",
    "income_component_minor",
    "fee",
}
_FEE_FIELDS = {"money", "category_id", "flags", "reporting"}
_ALLOCATED = text("""
    SELECT allocation.item ->> 'source_bill_id' AS source_id,
           sum((allocation.item ->> 'source_amount_minor')::numeric) AS allocated
    FROM sync_entities AS receipt
    CROSS JOIN LATERAL jsonb_array_elements(receipt.payload -> 'allocations') AS allocation(item)
    WHERE receipt.entity_type = 'bill' AND NOT receipt.deleted
      AND receipt.payload ->> 'bill_type' IN ('refund', 'reimbursement')
      AND allocation.item ->> 'source_bill_id' = ANY(CAST(:source_ids AS text[]))
    GROUP BY allocation.item ->> 'source_bill_id'
""")


def _allocated_to_sources(session: Session, identifiers: set[str]) -> dict[str, int]:
    if not identifiers:
        return {}
    return {
        row.source_id: parse_minor(str(row.allocated))
        for row in session.execute(_ALLOCATED, {"source_ids": sorted(identifiers)})
    }


def _unavailable(query: ReportQuery, code: str) -> ReportResponse:
    return ReportResponse(
        version=1,
        book_id=query.book_id,
        report_currency=query.report_currency,
        report_scale=query.report_scale,
        start_date=query.start_date,
        end_date_exclusive=query.end_date_exclusive,
        available=False,
        issues=[code],
        allocation_breakdown_available=False,
    )


def _budget_config(rows, query, identifier):
    budgets = [row for row in rows if row.entity_type == "budget"]
    if identifier is not None:
        selected = next((row for row in budgets if row.id == identifier), None)
        if selected is None:
            raise ApiError("not_found", 404)
        candidates = [selected]
    else:
        candidates = [
            row
            for row in budgets
            if (row.payload["period_start"], row.payload["period_end_exclusive"])
            == (query.start_date, query.end_date_exclusive)
        ]
    if len(candidates) > 1:
        raise DomainError("report.budget_ambiguous")
    if not candidates:
        return None
    payload = candidates[0].payload
    total, categories = payload["total"], payload["categories"]
    for value in ([total] if total is not None else []) + [item["limit"] for item in categories]:
        money = Money.from_json(value)
        if (money.currency, money.currency_scale) != (query.report_currency, query.report_scale):
            raise DomainError("budget.currency_mismatch")
    return ReportBudget(
        payload["period_start"],
        payload["period_end_exclusive"],
        total["amount_minor"] if total is not None else None,
        {item["category_id"]: item["limit"]["amount_minor"] for item in categories},
    )


def read_book_report(
    session: Session,
    principal: Principal,
    book_id: UUID,
    start_date: str,
    end_date_exclusive: str,
    budget_id: UUID | None = None,
) -> dict:
    def read():
        started = monotonic()
        assert_active_principal(session, principal, lock=True)
        if principal.purpose not in {"api_native", "api_web"}:
            raise ApiError("session_purpose_invalid", 403)
        scopes = lock_scopes(session, {principal.user_id, book_id})
        grant = authorize_scope(session, principal, book_id)
        if grant.scope.kind != "book" or grant.scope.book_id != book_id:
            raise ApiError("scope_forbidden", 403)
        book = session.get(Book, book_id)
        if book is None or book.deleted:
            raise ApiError("scope_forbidden", 403)
        scale = CURRENCY_SCALES.get(book.currency)
        if scale is None:
            raise ApiError("currency_unsupported", 422)
        try:
            query = ReportQuery(str(book_id), book.currency, scale, start_date, end_date_exclusive)
        except DomainError:
            raise ApiError("validation_error", 422) from None
        statement = (
            select(SyncEntity)
            .where(
                SyncEntity.scope_id == book_id,
                SyncEntity.deleted.is_(False),
                SyncEntity.entity_type.in_(["bill", "category", "budget"]),
            )
            .order_by(SyncEntity.id)
            .limit(MAX_REPORT_ENTITIES + 1)
            .execution_options(yield_per=1000)
        )
        rows, input_bytes = [], 0
        for row in session.scalars(statement):
            input_bytes += len(json.dumps(row.payload, ensure_ascii=False).encode("utf-8"))
            rows.append(row)
            if len(rows) > MAX_REPORT_ENTITIES or input_bytes > MAX_REPORT_INPUT_BYTES:
                raise ApiError("report_limit", 413)
            if monotonic() - started > REPORT_SECONDS:
                raise ApiError("report_limit", 413)
        visible_bills = {str(row.id): row for row in rows if row.entity_type == "bill"}
        try:
            expense_ids = {
                key for key, row in visible_bills.items() if row.payload["bill_type"] == "expense"
            }
            allocated = _allocated_to_sources(session, expense_ids)
            projected = []
            for identifier, row in visible_bills.items():
                payload = {
                    key: deepcopy(value)
                    for key, value in row.payload.items()
                    if key in _BILL_FIELDS
                }
                if payload.get("fee"):
                    payload["fee"] = {
                        key: value for key, value in payload["fee"].items() if key in _FEE_FIELDS
                    }
                allocations = payload.get("allocations", [])
                public_allocations = [
                    item for item in allocations if item["source_bill_id"] in visible_bills
                ]
                payload["allocations"] = public_allocations
                remaining = None
                if payload["bill_type"] == "expense":
                    remaining = str(
                        checked_minor(
                            parse_minor(payload["money"]["amount_minor"])
                            - allocated.get(identifier, 0)
                        )
                    )
                projected.append(
                    ReportBill(
                        identifier,
                        payload,
                        remaining,
                        hidden_allocation_count=len(allocations) - len(public_allocations),
                    )
                )
            parents = {
                str(row.id): row.payload["parent_id"]
                for row in rows
                if row.entity_type == "category"
            }
            config = _budget_config(rows, query, budget_id)
            report = ReportResponse.model_validate(
                build_report(projected, query, category_parents=parents, budget=config)
            )
        except DomainError as error:
            report = _unavailable(query, error.code)
        except (KeyError, TypeError):
            report = _unavailable(query, "report.invalid_data")
        # These checks intentionally happen again after materialization. Current
        # user/session and control/book locks remain held until serialization.
        assert_active_principal(session, principal, lock=True)
        authorize_scope(session, principal, book_id)
        state = session.get(ServerState, 1)
        if state is None:
            raise ApiError("service_unavailable", 503)
        result = BookReportResponse(
            sync_epoch=str(state.sync_epoch),
            scope_revision=str(scopes[book_id].revision),
            permission_version=str(scopes[book_id].permission_version),
            report=report,
        ).model_dump()
        if (
            monotonic() - started > REPORT_SECONDS
            or len(json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
            > MAX_REPORT_OUTPUT_BYTES
        ):
            raise ApiError("report_limit", 413)
        return result

    return run_transaction(session, read, repeatable=True)
