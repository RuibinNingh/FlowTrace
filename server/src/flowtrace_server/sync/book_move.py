"""Same-UUID, no-money-change moves under caller-held scope/account locks."""

from copy import deepcopy
from uuid import UUID

from sqlalchemy import delete, select

from flowtrace_server.attachments.models import Attachment, AttachmentRef
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import now
from flowtrace_server.books.models import Book, SyncScope
from flowtrace_server.books.permissions import authorize_scope

from .common import CommandRejected, PendingEvent, RetryScopeSet, visible_entity
from .models import LedgerEntry
from .projections import account_links, allocated_to, entity_event, private_finance
from .schemas import bill_storage_payload

_MUTABLE_METADATA = {
    "book_id",
    "note",
    "flags",
    "category_id",
    "tag_ids",
    "attachment_ids",
    "fee",
    "reimbursement_tracking",
}


def _prepare_attachments(session, principal, entity, source_scope, target_scope, old, new, marker):
    source_ids = [UUID(value) for value in old.get("attachment_ids", [])]
    target_ids = [UUID(value) for value in new["attachment_ids"]]
    replacements = marker.attachment_replacements
    if source_ids != [UUID(item.source_id) for item in replacements] or target_ids != [
        UUID(item.target_id) for item in replacements
    ]:
        raise CommandRejected("move_attachment_mapping")
    identities = set(source_ids) | set(target_ids)
    # Reject a guessed foreign attachment before taking its row lock. Both
    # legitimate scopes are already locked in the global UUID order.
    if (
        session.scalar(
            select(Attachment.id)
            .where(
                Attachment.id.in_(identities),
                Attachment.scope_id.not_in([source_scope, target_scope]),
            )
            .limit(1)
        )
        is not None
    ):
        raise ApiError("attachment_scope_mismatch", 403)
    records = list(
        session.scalars(
            select(Attachment)
            .where(Attachment.id.in_(identities))
            .order_by(Attachment.id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
    )
    if len(records) != len(identities):
        raise ApiError("attachment_not_ready", 409)
    by_id = {record.id: record for record in records}
    actual = set(
        session.scalars(
            select(AttachmentRef.attachment_id).where(AttachmentRef.bill_id == entity.id)
        )
    )
    if actual != set(source_ids):
        raise CommandRejected("attachment_reference_conflict", 409)
    for source_id, target_id in zip(source_ids, target_ids, strict=True):
        source, target = by_id[source_id], by_id[target_id]
        if source.scope_id != source_scope or target.scope_id != target_scope:
            raise ApiError("attachment_scope_mismatch", 403)
        if source.status != "ready" or target.status != "ready":
            # Upload preparation can finish after a transient first attempt.
            # Do not freeze a rejected receipt for that unchanged move intent.
            raise ApiError("attachment_not_ready", 409)
        if (source.sha256, source.size_bytes, source.media_type) != (
            target.sha256,
            target.size_bytes,
            target.media_type,
        ):
            raise CommandRejected("move_attachment_mismatch")
    return records, source_ids, target_ids


def move_bill_command(session, principal, operation, entity, scopes):
    from .commands import (
        _new_reference_is_active,
        _same_book_reference,
        _touch,
        _validate_reporting,
    )

    source_id, target_id = UUID(operation.scope_id), UUID(operation.move.target_scope_id)
    if entity is None or entity.deleted or entity.scope_id != source_id:
        raise ApiError("not_found", 404)
    if source_id not in scopes or target_id not in scopes:
        raise RetryScopeSet
    for identifier in [source_id, target_id]:
        grant = authorize_scope(session, principal, identifier, write=True)
        if grant.scope.kind != "book" or grant.scope.book_id != identifier:
            raise CommandRejected("move_target_mismatch")
    source_book, target_book = session.get(Book, source_id), session.get(Book, target_id)
    if source_book.currency != target_book.currency:
        raise CommandRejected("move_currency_mismatch")
    old = deepcopy(entity.payload)
    new = bill_storage_payload(operation.payload, previous=old)
    old.setdefault("transfer_fx", None)
    if "transfer_fx" not in operation.payload.model_fields_set:
        new["transfer_fx"] = old["transfer_fx"]
    if new["book_id"] != str(target_id):
        raise CommandRejected("move_target_mismatch")
    if (
        old["bill_type"] in {"refund", "reimbursement"}
        or old.get("allocations")
        or allocated_to(session, entity.id)
    ):
        raise CommandRejected("move_has_allocations", 409)
    for account_id in set(account_links(old).values()):
        account = visible_entity(session, principal, account_id, "account")
        scope = session.get(SyncScope, account.scope_id)
        if scope.kind != "user":
            raise CommandRejected("move_shared_account", 409)
        if scope.owner_user_id != principal.user_id:
            raise ApiError("move_private_finance_forbidden", 403)
        if scope.id not in scopes:
            raise RetryScopeSet
        authorize_scope(session, principal, scope.id, write=True)
    if {key: value for key, value in old.items() if key not in _MUTABLE_METADATA} != {
        key: value for key, value in new.items() if key not in _MUTABLE_METADATA
    }:
        raise CommandRejected("move_financial_fields_changed")
    old_fee, new_fee = old.get("fee"), new.get("fee")
    if (None if old_fee is None else {k: v for k, v in old_fee.items() if k != "category_id"}) != (
        None if new_fee is None else {k: v for k, v in new_fee.items() if k != "category_id"}
    ):
        raise CommandRejected("move_financial_fields_changed")
    category = _same_book_reference(session, principal, new["category_id"], "category", target_id)
    _new_reference_is_active(session, category, None)
    if (
        category is not None
        and new["bill_type"] in {"income", "expense"}
        and category.payload["kind"] != new["bill_type"]
    ):
        raise CommandRejected("category.kind_mismatch")
    for tag_id in new["tag_ids"]:
        tag = _same_book_reference(session, principal, tag_id, "tag", target_id)
        if tag.payload.get("kind", "tag") != "tag":
            raise CommandRejected("tag.group_not_selectable")
        _new_reference_is_active(session, tag, None)
    _validate_reporting(new, target_book)
    if new_fee is not None:
        _validate_reporting(new_fee, target_book)
        fee_category = _same_book_reference(
            session, principal, new_fee["category_id"], "category", target_id
        )
        _new_reference_is_active(session, fee_category, None)
        if fee_category is not None and fee_category.payload["kind"] != "expense":
            raise CommandRejected("category.kind_mismatch")
    entries = list(session.scalars(select(LedgerEntry).where(LedgerEntry.bill_id == entity.id)))
    account_ids = set(account_links(old).values())
    if any(row.account_id not in account_ids or row.book_id != source_id for row in entries):
        raise CommandRejected("move_financial_fields_changed")
    records, old_images, new_images = _prepare_attachments(
        session, principal, entity, source_id, target_id, old, new, operation.move
    )
    session.execute(delete(AttachmentRef).where(AttachmentRef.bill_id == entity.id))
    for identifier in new_images:
        session.add(AttachmentRef(bill_id=entity.id, attachment_id=identifier))
    entity.scope_id, entity.payload = target_id, new
    _touch(entity)
    for row in entries:
        row.book_id = target_id
    session.flush()
    for record in records:
        referenced = (
            session.scalar(
                select(AttachmentRef.bill_id)
                .where(AttachmentRef.attachment_id == record.id)
                .limit(1)
            )
            is not None
        )
        if referenced:
            record.orphaned_at = None
        elif record.id in old_images:
            record.orphaned_at = now()
    events = [
        PendingEvent(source_id, "bill", entity.id, entity.revision, True, None),
        entity_event(session, entity),
    ]
    if entries:
        data = private_finance(session, entity, principal.user_id)
        events.append(
            PendingEvent(principal.user_id, "bill", entity.id, entity.revision, data is None, data)
        )
    return entity, events
