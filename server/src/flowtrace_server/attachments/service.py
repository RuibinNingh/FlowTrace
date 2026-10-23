"""All callers must lock user/session then scopes before attachment rows."""

import secrets
from datetime import timedelta
from uuid import UUID, uuid4

from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from flowtrace_server.admin.service import audit
from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal, now
from flowtrace_server.books.permissions import authorize_scope
from flowtrace_server.sync.models import SyncEntity

from .models import Attachment, AttachmentHold, AttachmentRef, UploadTicket
from .storage import AttachmentStore


def declare_upload(
    session: Session, principal: Principal, body, store: AttachmentStore
) -> tuple[Attachment, bool]:
    # Serializes per-uploader reservations across different shared book scopes.
    assert_active_principal(session, principal)
    authorize_scope(session, principal, body.scope_id, write=True, lock=True)
    existing = session.scalar(
        select(Attachment)
        .where(Attachment.id == body.attachment_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if existing is not None:
        if (
            existing.scope_id != body.scope_id
            or existing.created_by != principal.user_id
            or existing.sha256 != body.sha256
            or existing.size_bytes != body.size_bytes
            or existing.media_type != body.media_type
        ):
            raise ApiError("upload_mismatch", 409)
        if existing.status == "deleting":
            raise ApiError("attachment_not_ready", 409)
        if existing.status == "deleted" or existing.upload_expires_at <= now():
            referenced = session.scalar(
                select(AttachmentRef.bill_id)
                .where(AttachmentRef.attachment_id == existing.id)
                .limit(1)
            )
            held = session.scalar(
                select(AttachmentHold.hold_id)
                .where(AttachmentHold.attachment_id == existing.id)
                .limit(1)
            )
            if existing.status == "deleted" and (referenced is not None or held is not None):
                raise ApiError("attachment_not_ready", 409)
            if existing.status == "deleted":
                from flowtrace_server.configuration.runtime import enforce_attachment_reservation

                enforce_attachment_reservation(session, principal, body.size_bytes)
            store.delete_staging(existing.upload_id, existing.storage_key)
            existing.upload_id = uuid4()
            existing.upload_expires_at = now() + timedelta(hours=24)
            if existing.status == "deleted":
                existing.status = "pending"
                existing.ready_at = existing.orphaned_at = None
                existing.width = existing.height = None
            elif existing.status == "ready" and referenced is None:
                existing.orphaned_at = now()
            session.add(
                UploadTicket(
                    upload_id=existing.upload_id,
                    attachment_id=existing.id,
                    created_by=principal.user_id,
                    created_at=now(),
                    expires_at=existing.upload_expires_at,
                )
            )
            audit(session, principal.user_id, "attachment.renew", existing.id)
        return existing, True
    from flowtrace_server.configuration.runtime import enforce_attachment_reservation

    enforce_attachment_reservation(session, principal, body.size_bytes)
    stamp = now()
    record = Attachment(
        id=body.attachment_id,
        upload_id=uuid4(),
        scope_id=body.scope_id,
        created_by=principal.user_id,
        sha256=body.sha256,
        size_bytes=body.size_bytes,
        media_type=body.media_type,
        storage_key=secrets.token_hex(32),
        status="pending",
        created_at=stamp,
        upload_expires_at=stamp + timedelta(hours=24),
        ready_at=None,
        orphaned_at=None,
        width=None,
        height=None,
    )
    try:
        with session.begin_nested():
            session.add(record)
            session.flush()
    except IntegrityError:
        raise ApiError("upload_mismatch", 409) from None
    session.add(
        UploadTicket(
            upload_id=record.upload_id,
            attachment_id=record.id,
            created_by=principal.user_id,
            created_at=stamp,
            expires_at=record.upload_expires_at,
        )
    )
    return record, False


def usable_upload(record: Attachment, upload_id: UUID | None = None) -> None:
    if upload_id is not None and record.upload_id != upload_id:
        raise ApiError("upload_expired", 410)
    if record.status in {"deleting", "deleted"}:
        raise ApiError("attachment_not_ready", 409)
    if record.upload_expires_at <= now():
        raise ApiError("upload_expired", 410)


def upload_for_write(session: Session, principal: Principal, upload_id: UUID) -> Attachment:
    ticket = session.get(UploadTicket, upload_id)
    if ticket is None or ticket.created_by != principal.user_id:
        raise ApiError("not_found", 404)
    identity = session.get(Attachment, ticket.attachment_id)
    authorize_scope(session, principal, identity.scope_id, write=True, lock=True)
    record = session.scalar(
        select(Attachment)
        .where(Attachment.id == identity.id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    usable_upload(record, upload_id)
    return record


def attachment_for_read(session: Session, principal: Principal, attachment_id: UUID) -> Attachment:
    record = session.get(Attachment, attachment_id)
    if record is None:
        raise ApiError("not_found", 404)
    authorize_scope(session, principal, record.scope_id)
    if record.status != "ready":
        raise ApiError("attachment_not_ready", 409)
    return record


def reconcile_bill_attachments(
    session: Session,
    principal: Principal,
    bill_id: UUID,
    scope_id: UUID,
    previous_ids: list[UUID],
    new_ids: list[UUID],
) -> None:
    """No commit or user locks: sync already owns scope/account locks."""
    authorize_scope(session, principal, scope_id, write=True)
    old, desired = set(previous_ids), set(new_ids)
    if len(desired) > 20:
        raise ApiError("attachment_limit", 422)
    bill = session.get(SyncEntity, bill_id)
    if bill is None or bill.entity_type != "bill" or bill.scope_id != scope_id:
        raise ApiError("attachment_scope_mismatch", 403)
    if (
        session.scalar(
            select(Attachment.id)
            .where(Attachment.id.in_(old | desired), Attachment.scope_id != scope_id)
            .limit(1)
        )
        is not None
    ):
        raise ApiError("attachment_scope_mismatch", 403)
    rows = list(
        session.scalars(
            select(Attachment)
            .where(Attachment.id.in_(old | desired), Attachment.scope_id == scope_id)
            .order_by(Attachment.id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
    )
    if len(rows) != len(old | desired):
        raise ApiError("attachment_not_ready", 409)
    by_id = {item.id: item for item in rows}
    for identity in desired:
        record = by_id[identity]
        if record.scope_id != scope_id:
            raise ApiError("attachment_scope_mismatch", 403)
        if record.status != "ready":
            raise ApiError("attachment_not_ready", 409)
    actual = set(
        session.scalars(select(AttachmentRef.attachment_id).where(AttachmentRef.bill_id == bill_id))
    )
    if actual != old:
        raise ApiError("attachment_reference_conflict", 409)
    for identity in old - desired:
        session.execute(
            delete(AttachmentRef).where(
                AttachmentRef.bill_id == bill_id, AttachmentRef.attachment_id == identity
            )
        )
    for identity in desired - old:
        session.add(AttachmentRef(bill_id=bill_id, attachment_id=identity))
    session.flush()
    for record in rows:
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
        elif record.id in old - desired:
            record.orphaned_at = now()


def hold_attachments(session: Session, hold_id: UUID, identities: list[UUID], kind: str) -> None:
    """Backup/job coordinator must already own all relevant scope locks.

    Holds deliberately have no automatic expiry: a crashed backup retains files
    until the operator or resumed job explicitly releases its hold.
    """
    if kind not in {"job", "backup"}:
        raise ValueError("attachment_hold_kind_invalid")
    rows = list(
        session.scalars(
            select(Attachment)
            .where(Attachment.id.in_(set(identities)))
            .order_by(Attachment.id)
            .with_for_update()
        )
    )
    if len(rows) != len(set(identities)) or any(row.status != "ready" for row in rows):
        raise ApiError("attachment_not_ready", 409)
    for row in rows:
        if session.get(AttachmentHold, (hold_id, row.id)) is None:
            session.add(
                AttachmentHold(hold_id=hold_id, attachment_id=row.id, kind=kind, created_at=now())
            )


def release_hold(session: Session, hold_id: UUID) -> None:
    session.execute(delete(AttachmentHold).where(AttachmentHold.hold_id == hold_id))


def complete_record(
    session: Session, principal: Principal, record: Attachment, width: int, height: int
) -> None:
    if record.status == "ready":
        return
    record.status = "ready"
    record.ready_at = now()
    record.orphaned_at = now()
    record.width, record.height = width, height
    audit(session, principal.user_id, "attachment.complete", record.id)
