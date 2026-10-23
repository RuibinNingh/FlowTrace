"""Immutable least-privilege projections shared by changes and snapshots."""

from copy import deepcopy
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session

from flowtrace_server.books.models import SyncScope
from flowtrace_server.domain.money import checked_minor, parse_minor

from .common import PendingEvent
from .models import LedgerEntry, SyncEntity
from .responses import BillPrivateFinance, BillPublic
from .schemas import MANAGEMENT_NEW_FIELDS, management_payload

NONFINANCIAL_FIELDS = {
    "note",
    "category_id",
    "tag_ids",
    "attachment_ids",
    "flags",
    "reimbursement_tracking",
}


def account_links(payload: dict) -> dict[str, UUID]:
    links = {
        key: UUID(payload[key])
        for key in ("account_id", "from_account_id", "to_account_id")
        if payload.get(key) is not None
    }
    if payload.get("fee") and payload["fee"].get("account_id"):
        links["fee.account_id"] = UUID(payload["fee"]["account_id"])
    return links


def allocated_by_type(session: Session, source_id: UUID, *, exclude: UUID | None = None) -> dict:
    result = {"refund": 0, "reimbursement": 0}
    bills = session.scalars(
        select(SyncEntity).where(SyncEntity.entity_type == "bill", SyncEntity.deleted.is_(False))
    )
    for bill in bills:
        if bill.id == exclude:
            continue
        for item in bill.payload.get("allocations", []):
            if item["source_bill_id"] == str(source_id):
                kind = bill.payload["bill_type"]
                if kind not in result:
                    raise ValueError("invalid_receipt_allocation")
                result[kind] = checked_minor(
                    result[kind] + parse_minor(item["source_amount_minor"])
                )
    return result


def allocated_to(session: Session, source_id: UUID, *, exclude: UUID | None = None) -> int:
    return checked_minor(sum(allocated_by_type(session, source_id, exclude=exclude).values()))


def public_bill(session: Session, entity: SyncEntity) -> dict:
    payload = deepcopy(entity.payload)
    payload.pop("preserve_hidden_financial_links", None)
    hidden, payers = [], set()
    for field, account_id in account_links(payload).items():
        account = session.get(SyncEntity, account_id)
        scope = session.get(SyncScope, account.scope_id) if account else None
        if scope is not None and scope.kind == "user":
            hidden.append(field)
            payers.add(str(scope.owner_user_id))
            if field == "fee.account_id":
                payload["fee"]["account_id"] = None
            else:
                payload[field] = None
    allocations, redacted = [], 0
    for item in payload["allocations"]:
        source = session.get(SyncEntity, UUID(item["source_bill_id"]))
        if source is not None and source.scope_id == entity.scope_id:
            allocations.append(item)
        else:
            redacted += 1
    payload["allocations"] = allocations
    remaining, summary = None, None
    if payload["bill_type"] == "expense":
        allocated = allocated_by_type(session, entity.id)
        refunded, reimbursed = allocated["refund"], allocated["reimbursement"]
        remaining = str(
            checked_minor(parse_minor(payload["money"]["amount_minor"]) - refunded - reimbursed)
        )
        summary = {
            "refund_source_minor": str(refunded),
            "reimbursement_source_minor": str(reimbursed),
            "remaining_source_minor": remaining,
            "settlement_reason": (
                "open"
                if remaining != "0"
                else "refunded"
                if reimbursed == 0
                else "reimbursed"
                if refunded == 0
                else "mixed"
            ),
        }
    data = {
        "projection_kind": "bill_public",
        "payload": payload,
        "hidden_account_fields": sorted(hidden),
        "hidden_allocation_count": redacted,
        "paid_by_user_ids": sorted(payers),
        "nonfinancial_editable_fields": sorted(
            NONFINANCIAL_FIELDS
            if payload["bill_type"] == "expense"
            else NONFINANCIAL_FIELDS - {"reimbursement_tracking"}
        ),
        "remaining_allocatable_minor": remaining,
    }
    if summary is not None:
        data["source_summary"] = summary
    return BillPublic.model_validate(data).model_dump(exclude_unset=True)


def private_finance(session: Session, entity: SyncEntity, user_id: UUID) -> dict | None:
    links = {
        key: None for key in ("account_id", "from_account_id", "to_account_id", "fee_account_id")
    }
    owned = set()
    for field, identifier in account_links(entity.payload).items():
        account = session.get(SyncEntity, identifier)
        scope = session.get(SyncScope, account.scope_id) if account else None
        if scope is not None and scope.kind == "user" and scope.owner_user_id == user_id:
            links["fee_account_id" if field == "fee.account_id" else field] = str(identifier)
            owned.add(identifier)
    if not owned:
        return None
    entries = list(
        session.scalars(
            select(LedgerEntry)
            .where(LedgerEntry.bill_id == entity.id, LedgerEntry.account_id.in_(owned))
            .order_by(LedgerEntry.account_id, LedgerEntry.component)
        )
    )
    data = {
        "projection_kind": "bill_private_finance",
        "book_id": entity.payload["book_id"],
        "bill_type": entity.payload["bill_type"],
        "business_date": entity.payload["business_date"],
        "business_timezone": entity.payload["business_timezone"],
        "occurred_at": entity.payload["occurred_at"],
        "account_links": links,
        "entries": [
            {
                "account_id": str(row.account_id),
                "component": row.component,
                "money": {
                    "currency": row.currency,
                    "currency_scale": row.currency_scale,
                    "amount_minor": str(row.amount_minor),
                },
            }
            for row in entries
        ],
    }
    return BillPrivateFinance.model_validate(data).model_dump()


def entity_data(session: Session, entity: SyncEntity) -> dict:
    if entity.entity_type == "bill":
        return public_bill(session, entity)
    payload = (
        management_payload(entity.entity_type, entity.payload)
        if entity.entity_type in MANAGEMENT_NEW_FIELDS
        else deepcopy(entity.payload)
    )
    data = {"projection_kind": entity.entity_type, "payload": payload}
    if entity.entity_type == "account":
        data["balance"] = {**entity.payload["opening"], "amount_minor": str(entity.balance_minor)}
    return data


def entity_event(session: Session, entity: SyncEntity) -> PendingEvent:
    return PendingEvent(
        entity.scope_id,
        entity.entity_type,
        entity.id,
        entity.revision,
        entity.deleted,
        None if entity.deleted else entity_data(session, entity),
    )


def event_dict(event: PendingEvent, scope_revision: int, event_index: int = 0) -> dict:
    return {
        "scope_id": str(event.scope_id),
        "scope_revision": str(scope_revision),
        "event_index": event_index,
        "entity_type": event.entity_type,
        "entity_id": str(event.entity_id),
        "revision": str(event.revision),
        "deleted": event.deleted,
        "data": deepcopy(event.data),
    }
