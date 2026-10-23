"""Claim in PostgreSQL, delete private files, then acknowledge; crashes are retryable."""

from datetime import timedelta
from uuid import UUID

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from flowtrace_server.admin.service import audit
from flowtrace_server.auth.service import now
from flowtrace_server.books.models import SyncScope
from flowtrace_server.diagnostics import event

from .models import Attachment, AttachmentHold, AttachmentRef, UploadTicket
from .storage import AttachmentStore


def eligible(record: Attachment, *, orphan_days=7) -> bool:
    stamp = now()
    return (
        record.status == "deleting"
        or (record.status in {"pending", "uploaded"} and record.upload_expires_at <= stamp)
        or (
            record.status == "ready"
            and record.orphaned_at is not None
            and record.orphaned_at <= stamp - timedelta(days=orphan_days)
        )
    )


def claim(session: Session, identity: UUID) -> Attachment | None:
    from flowtrace_server.configuration.runtime import read_runtime_configuration

    orphan_days = read_runtime_configuration(session).values.orphan_retention_days
    scope_id = session.scalar(select(Attachment.scope_id).where(Attachment.id == identity))
    if scope_id is None:
        return None
    session.scalar(select(SyncScope).where(SyncScope.id == scope_id).with_for_update())
    record = session.scalar(
        select(Attachment)
        .where(Attachment.id == identity)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if record is None or not eligible(record, orphan_days=orphan_days):
        return None
    if session.scalar(
        select(AttachmentRef.bill_id).where(AttachmentRef.attachment_id == identity).limit(1)
    ):
        return None
    if session.scalar(
        select(AttachmentHold.hold_id).where(AttachmentHold.attachment_id == identity).limit(1)
    ):
        return None
    if record.status != "deleting":
        record.status = "deleting"
        audit(session, None, "attachment.gc_claim", record.id)
    return record


def collect(engine, store: AttachmentStore, limit: int = 100) -> dict[str, int]:
    if not 1 <= limit <= 1000:
        raise ValueError("attachment_gc_limit_invalid")
    stamp = now()
    with Session(engine, join_transaction_mode="create_savepoint") as session:
        from flowtrace_server.configuration.runtime import read_runtime_configuration

        orphan_days = read_runtime_configuration(session).values.orphan_retention_days
        identities = list(
            session.scalars(
                select(Attachment.id)
                .where(
                    or_(
                        Attachment.status == "deleting",
                        (Attachment.status.in_(["pending", "uploaded"]))
                        & (Attachment.upload_expires_at <= stamp),
                        (Attachment.status == "ready")
                        & (Attachment.orphaned_at <= stamp - timedelta(days=orphan_days)),
                    )
                )
                .order_by(Attachment.id)
                .limit(limit)
            )
        )
    result = {"deleted": 0, "retained": 0, "failed": 0}
    for identity in identities:
        with Session(
            engine, expire_on_commit=False, join_transaction_mode="create_savepoint"
        ) as session:
            record = claim(session, identity)
            if record is None:
                result["retained"] += 1
                continue
            session.commit()  # The committed deleting state refuses new references.
            key, upload_id = record.storage_key, record.upload_id
            tickets = list(
                session.scalars(
                    select(UploadTicket.upload_id).where(UploadTicket.attachment_id == identity)
                )
            )
        try:
            store.delete(key)
            for ticket in tickets or [upload_id]:
                store.delete_staging(ticket, key)
        except OSError:
            result["failed"] += 1
            break  # Stop reclamation on an unsafe or unreadable filesystem entry.
        with Session(engine, join_transaction_mode="create_savepoint") as session:
            record = claim(session, identity)
            if record is None:
                result["retained"] += 1
                continue
            record.status = "deleted"
            audit(session, None, "attachment.gc_complete", record.id)
            session.commit()
        result["deleted"] += 1
        event("attachment_gc", entity_id=str(identity))
    return result
