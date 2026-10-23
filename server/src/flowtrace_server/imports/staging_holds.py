"""Stage/version-owned private original holds; never a financial permission."""

from uuid import UUID, uuid5

from sqlalchemy import delete, select

from flowtrace_server.attachments.models import Attachment, AttachmentHold, AttachmentRef
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.books.permissions import authorize_scope
from flowtrace_server.sync.common import lock_scopes

from .staging_schemas import StageMapping


def stage_hold_id(stage):
    return uuid5(stage.id, f"attachment-hold:v{stage.stage_version}")


def _references(session, identifier):
    return (
        session.scalar(
            select(AttachmentRef.bill_id).where(AttachmentRef.attachment_id == identifier).limit(1)
        )
        is not None
    )


def _attachments(session, identifiers, budget):
    ordered = sorted(set(identifiers))
    records = []
    for offset in range(0, len(ordered), 500):
        budget()
        records.extend(
            session.scalars(
                select(Attachment)
                .where(Attachment.id.in_(ordered[offset : offset + 500]))
                .order_by(Attachment.id)
                .with_for_update()
                .execution_options(populate_existing=True)
            )
        )
    return records


def acquire_stage_holds(session, principal, stage, *, check_budget=lambda: None):
    mapping = StageMapping.model_validate(stage.mapping)
    identities = {UUID(identifier) for identifier in mapping.attachment_transfers}
    if not identities:
        return
    lock_scopes(session, {principal.user_id})
    authorize_scope(session, principal, principal.user_id, write=True)
    own = stage_hold_id(stage)
    for record in _attachments(session, identities, check_budget):
        check_budget()
        # Already-book records can be legitimate duplicates. Their actual
        # domain preview must decide; this path neither moves nor holds them.
        if (
            record.scope_id != principal.user_id
            or record.created_by != principal.user_id
            or record.status != "ready"
            or _references(session, record.id)
        ):
            continue
        holds = list(
            session.scalars(select(AttachmentHold).where(AttachmentHold.attachment_id == record.id))
        )
        if any(hold.hold_id != own or hold.kind != "job" for hold in holds):
            raise ApiError("import_stage_attachment_held", 409)
        if not holds:
            session.add(
                AttachmentHold(
                    hold_id=own, attachment_id=record.id, kind="job", created_at=stage.updated_at
                )
            )
    session.flush()


def release_stage_holds(session, stage, *, check_budget=lambda: None):
    """Release only this version's kind=job rows after exact orphan validation.

    Cleanup callers also use this after origin expiry: it authorizes no read or
    move, verifies the immutable stage owner and preserves the original bytes.
    """
    own = stage_hold_id(stage)
    holds = list(session.scalars(select(AttachmentHold).where(AttachmentHold.hold_id == own)))
    if not holds:
        return
    allowed = {
        UUID(identifier)
        for identifier in StageMapping.model_validate(stage.mapping).attachment_transfers
    }
    identities = {hold.attachment_id for hold in holds}
    if any(hold.kind != "job" for hold in holds) or not identities.issubset(allowed):
        raise ApiError("import_stage_attachment_hold_conflict", 409)
    records = _attachments(session, identities, check_budget)
    if len(records) != len(identities):
        raise ApiError("import_stage_attachment_hold_conflict", 409)
    for record in records:
        check_budget()
        if (
            record.created_by != stage.owner_user_id
            or record.scope_id != stage.owner_user_id
            or record.status != "ready"
            or _references(session, record.id)
        ):
            raise ApiError("import_stage_attachment_hold_conflict", 409)
    ordered = sorted(identities)
    for offset in range(0, len(ordered), 500):
        check_budget()
        session.execute(
            delete(AttachmentHold).where(
                AttachmentHold.hold_id == own,
                AttachmentHold.kind == "job",
                AttachmentHold.attachment_id.in_(ordered[offset : offset + 500]),
            )
        )
    session.flush()


def validate_original_sources(session, principal, snapshot, *, check_budget):
    """Native manifest hashes remain bound to the original source file SHA."""
    for source in snapshot.attachment_sources:
        check_budget()
        identifier = UUID(snapshot.resource_mapping.get(source.source_id, source.source_id))
        record = session.get(Attachment, identifier)
        if record is None:
            raise ApiError("import_stage_original_mismatch", 409)
        authorize_scope(session, principal, record.scope_id)
        if (
            record.status != "ready"
            or record.sha256 != source.sha256
            or record.size_bytes != source.size_bytes
            or record.media_type != source.media_type
        ):
            raise ApiError("import_stage_original_mismatch", 409)
