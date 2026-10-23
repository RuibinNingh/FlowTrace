"""Explicitly adopt private orphan uploads into an atomic import's destination.

The bytes already passed the ordinary authenticated upload/complete pipeline.
Only metadata moves here. Failed or preview transactions leave the private
orphan intact, and the old upload ticket is invalidated on every real move.
"""

from uuid import UUID, uuid4

from sqlalchemy import select

from flowtrace_server.attachments.models import Attachment, AttachmentHold, AttachmentRef
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import now
from flowtrace_server.books.permissions import authorize_scope


def plan_transfers(body, commands, targets, *, check_budget=None):
    planned = {}
    references_by_upload = {}
    for command in commands:
        if check_budget is not None:
            check_budget()
        if command.entity_type == "bill":
            for identifier in command.payload.attachment_ids:
                if identifier in body.attachment_transfers:
                    references_by_upload.setdefault(identifier, set()).add(command.scope_id)
    for upload_id, source_book in body.attachment_transfers.items():
        if check_budget is not None:
            check_budget()
        destination = targets.get(source_book, body.scope_mapping.get(source_book, source_book))
        references = references_by_upload.get(upload_id, set())
        if references != {destination}:
            raise ApiError("import_attachment_transfer_destination_mismatch", 422)
        planned[UUID(upload_id)] = UUID(destination)
    return planned


def _has_hold(session, identifier):
    return (
        session.scalar(
            select(AttachmentHold.hold_id)
            .where(AttachmentHold.attachment_id == identifier)
            .limit(1)
        )
        is not None
    )


def _references(session, identifier):
    return set(
        session.scalars(
            select(AttachmentRef.bill_id).where(AttachmentRef.attachment_id == identifier)
        )
    )


def lock_private_orphans(session, principal, planned, required_ids, *, check_budget=None):
    wanted = set(planned) & {UUID(identifier) for identifier in required_ids}
    records = (
        list(
            session.scalars(
                select(Attachment)
                .where(Attachment.id.in_(wanted))
                .order_by(Attachment.id)
                .with_for_update()
                .execution_options(populate_existing=True)
            )
        )
        if wanted
        else []
    )
    if len(records) != len(wanted):
        raise ApiError("import_attachment_transfer_conflict", 409)
    for record in records:
        if check_budget is not None:
            check_budget()
        if (
            record.scope_id != principal.user_id
            or record.created_by != principal.user_id
            or record.status != "ready"
            or _references(session, record.id)
            or _has_hold(session, record.id)
        ):
            raise ApiError("import_attachment_transfer_conflict", 409)
    return {record.id: record for record in records}


def move_available(session, principal, planned, pending, scopes, receipts, *, check_budget=None):
    for identifier in sorted(tuple(pending)):
        if check_budget is not None:
            check_budget()
        destination = planned[identifier]
        if destination not in scopes:
            continue  # A same-batch book has not been created yet.
        scope = scopes[destination]
        if scope.kind != "book":
            raise ApiError("import_attachment_book_required", 422)
        authorize_scope(session, principal, destination, write=True)
        record = pending.pop(identifier)
        record.scope_id = destination
        record.upload_id, record.upload_expires_at = uuid4(), now()
        receipts.append(
            {
                "attachment_id": str(identifier),
                "from_scope_id": str(principal.user_id),
                "to_scope_id": str(destination),
                "permission_version": str(scope.permission_version),
                "sha256": record.sha256,
                "size_bytes": record.size_bytes,
                "media_type": record.media_type,
            }
        )
    session.flush()


def undo_conflicts(
    session, principal, receipts, scopes, allowed_bill_ids, *, lock=False, check_budget=None
):
    if not receipts:
        return [], {}
    by_id = {UUID(item["attachment_id"]): item for item in receipts}
    statement = select(Attachment).where(Attachment.id.in_(by_id)).order_by(Attachment.id)
    if lock:
        statement = statement.with_for_update().execution_options(populate_existing=True)
    records = {record.id: record for record in session.scalars(statement)}
    conflicts = []
    for identifier, item in by_id.items():
        if check_budget is not None:
            check_budget()
        record, destination = records.get(identifier), UUID(item["to_scope_id"])
        if (
            record is None
            or record.scope_id != destination
            or record.created_by != principal.user_id
            or record.status != "ready"
            or record.sha256 != item["sha256"]
            or record.size_bytes != item["size_bytes"]
            or record.media_type != item["media_type"]
            or item["from_scope_id"] != str(principal.user_id)
            or destination not in scopes
            or str(scopes[destination].permission_version) != item["permission_version"]
            or _has_hold(session, identifier)
            or not _references(session, identifier).issubset(allowed_bill_ids)
        ):
            conflicts.append({"attachment_id": str(identifier), "code": "attachment_modified"})
    return conflicts, records


def restore_private_orphans(session, principal, records, *, check_budget=None):
    for identifier in sorted(records):
        if check_budget is not None:
            check_budget()
        record = records[identifier]
        if _references(session, identifier) or _has_hold(session, identifier):
            raise ApiError("import_undo_conflict", 409)
        record.scope_id = principal.user_id
        record.upload_id, record.upload_expires_at = uuid4(), now()
        record.orphaned_at = now()
    session.flush()
