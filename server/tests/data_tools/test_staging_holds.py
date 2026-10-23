"""Ready original bytes survive waiting, conflicts, invalidation and expiry."""

import hashlib
from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from sync.helpers import actor

from flowtrace_server.attachments.models import Attachment, AttachmentHold
from flowtrace_server.attachments.service import hold_attachments
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.imports.staging import cancel_stage, update_stage_mapping
from flowtrace_server.imports.staging_cleanup import expire_owned_stages_in_transaction
from flowtrace_server.imports.staging_holds import stage_hold_id
from flowtrace_server.imports.staging_models import (
    ImportPublication,
    ImportStage,
    ImportStageUploadChunk,
)
from flowtrace_server.imports.staging_preview import request_stage_preview
from flowtrace_server.imports.staging_publish import apply_stage_in_transaction, request_stage_apply
from flowtrace_server.imports.staging_schemas import (
    StageApply,
    StageMappingUpdate,
    StageVersionInput,
)
from flowtrace_server.jobs.store import LeaseLost, complete

from .test_import_attachments import new_book_request, ready_image
from .test_staging_parse import complete_parse, prepared
from .test_staging_preview import claim_exact, complete_preview
from .test_staging_publish import apply, claim_apply, queued_undo, undo

pytestmark = pytest.mark.postgres


def image_stage(engine, owner, uploaded, original, *, bad_hash=False):
    body, _, _ = new_book_request(engine, owner, uploaded)
    source_image = next(iter(body.resource_mapping))
    envelope = {
        "format": "flowtrace-export-v1",
        "document": body.document.model_dump(mode="json"),
        "attachments": [
            {
                "attachment_id": source_image,
                "sha256": "0" * 64 if bad_hash else hashlib.sha256(original).hexdigest(),
                "size_bytes": len(original),
                "media_type": "image/png",
                "href": f"/api/v1/attachments/{source_image}/content",
            }
        ],
    }
    mapping = {
        "resource_mapping": body.resource_mapping,
        "attachment_transfers": body.attachment_transfers,
    }
    stage, parse_lease = prepared(engine, owner, canonical(envelope), mapping=mapping)
    complete_parse(engine, parse_lease)
    return stage, mapping


def queue_preview(engine, owner, stage):
    with Session(engine) as session:
        return request_stage_preview(
            session, owner.principal, UUID(stage.stage_id), StageVersionInput(stage_version=1)
        )


def holds(session, uploaded):
    return {
        row.hold_id: row.kind
        for row in session.scalars(
            select(AttachmentHold).where(AttachmentHold.attachment_id == uploaded)
        )
    }


def test_preview_wait_hold_survives_rollback_and_apply_then_undo_preserve_original(
    postgres_engine, tmp_path
):
    owner = actor(postgres_engine)
    uploaded, _, original, store = ready_image(postgres_engine, owner, tmp_path / "files")
    stage, _ = image_stage(postgres_engine, owner, uploaded, original)
    job = queue_preview(postgres_engine, owner, stage)
    with Session(postgres_engine) as session:
        own = stage_hold_id(session.get(ImportStage, UUID(stage.stage_id)))
        assert holds(session, uploaded) == {own: "job"}
    complete_preview(postgres_engine, claim_exact(postgres_engine, job.job_id))
    with Session(postgres_engine) as session:
        row = session.get(ImportStage, UUID(stage.stage_id))
        assert row.status == "ready" and holds(session, uploaded) == {own: "job"}
        assert session.get(Attachment, uploaded).scope_id == owner.principal.user_id
        job = request_stage_apply(
            session,
            owner.principal,
            row.id,
            StageApply(stage_version=1, batch_id=stage.batch_id, preview_hash=row.preview_hash),
        )
    lease = claim_apply(postgres_engine, job.job_id)
    with Session(postgres_engine) as session:

        def effect(current, actual):
            result = apply_stage_in_transaction(current, actual.id, check_budget=lambda: None)
            assert current.get(Attachment, uploaded).scope_id != owner.principal.user_id
            actual.lease_until = current.scalar(select(func.clock_timestamp())) - timedelta(
                seconds=1
            )
            current.flush()
            return result

        with pytest.raises(LeaseLost):
            complete(session, lease, effect)
        session.commit()
    with Session(postgres_engine) as session:
        assert session.get(Attachment, uploaded).scope_id == owner.principal.user_id
        assert holds(session, uploaded) == {own: "job"}
        assert session.get(ImportPublication, UUID(stage.stage_id)) is None
    apply(postgres_engine, lease)
    with Session(postgres_engine) as session:
        image = session.get(Attachment, uploaded)
        assert image.scope_id != owner.principal.user_id and not holds(session, uploaded)
        assert store.content(image.storage_key) == original
        row = session.get(ImportStage, UUID(stage.stage_id))
        # Published source TTL cannot reset the financial stage or remove bytes.
        row.created_at -= timedelta(days=10)
        row.expires_at = session.scalar(select(func.clock_timestamp())) - timedelta(seconds=1)
        session.commit()
    with Session(postgres_engine) as session:
        assert (
            expire_owned_stages_in_transaction(
                session, owner.principal.user_id, check_budget=lambda: None
            )
            == ()
        )
        session.commit()
    _, lease = queued_undo(postgres_engine, owner, stage)
    assert undo(postgres_engine, lease)["code"] == "import_stage_undone"
    with Session(postgres_engine) as session:
        image = session.get(Attachment, uploaded)
        assert (
            image.scope_id == owner.principal.user_id
            and store.content(image.storage_key) == original
        )
        assert not holds(session, uploaded)


def test_another_stage_and_backup_hold_are_never_bypassed_or_released(postgres_engine, tmp_path):
    owner, foreign = actor(postgres_engine), actor(postgres_engine)
    uploaded, _, original, store = ready_image(postgres_engine, owner, tmp_path / "files")
    first, _ = image_stage(postgres_engine, owner, uploaded, original)
    queue_preview(postgres_engine, owner, first)
    second, _ = image_stage(postgres_engine, owner, uploaded, original)
    with pytest.raises(ApiError, match="import_stage_attachment_held"):
        queue_preview(postgres_engine, owner, second)
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_not_found"),
    ):
        cancel_stage(session, foreign.principal, UUID(first.stage_id), 1)
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_version_changed"),
    ):
        cancel_stage(session, owner.principal, UUID(first.stage_id), 2)
    with Session(postgres_engine) as session:
        assert holds(session, uploaded) == {
            stage_hold_id(session.get(ImportStage, UUID(first.stage_id))): "job"
        }
    with Session(postgres_engine) as session:
        cancel_stage(session, owner.principal, UUID(first.stage_id), 1)
    preview_job = queue_preview(postgres_engine, owner, second)
    complete_preview(postgres_engine, claim_exact(postgres_engine, preview_job.job_id))
    backup = uuid4()
    with Session(postgres_engine) as session:
        hold_attachments(session, backup, [uploaded], "backup")
        row = session.get(ImportStage, UUID(second.stage_id))
        own = stage_hold_id(row)
        session.commit()
        job = request_stage_apply(
            session,
            owner.principal,
            row.id,
            StageApply(stage_version=1, batch_id=second.batch_id, preview_hash=row.preview_hash),
        )
    with pytest.raises(ApiError, match="import_attachment_transfer_conflict"):
        apply(postgres_engine, claim_apply(postgres_engine, job.job_id))
    with Session(postgres_engine) as session:
        assert holds(session, uploaded) == {backup: "backup", own: "job"}
        assert session.get(ImportPublication, UUID(second.stage_id)) is None
        row = session.get(ImportStage, UUID(second.stage_id))
        row.created_at -= timedelta(days=10)
        row.expires_at = session.scalar(select(func.clock_timestamp())) - timedelta(seconds=1)
        session.commit()
    with Session(postgres_engine) as session:
        assert expire_owned_stages_in_transaction(
            session, owner.principal.user_id, check_budget=lambda: None
        ) == (UUID(second.stage_id),)
        session.commit()
        assert holds(session, uploaded) == {backup: "backup"}
        assert (
            session.scalar(
                select(func.count())
                .select_from(ImportStageUploadChunk)
                .where(ImportStageUploadChunk.stage_id == UUID(second.stage_id))
            )
            == 0
        )
        image = session.get(Attachment, uploaded)
        assert (
            image.scope_id == owner.principal.user_id
            and store.content(image.storage_key) == original
        )


def test_mapping_change_releases_only_old_version_and_manifest_mismatch_cannot_preview(
    postgres_engine, tmp_path
):
    owner = actor(postgres_engine)
    uploaded, _, original, _ = ready_image(postgres_engine, owner, tmp_path / "files")
    stage, mapping = image_stage(postgres_engine, owner, uploaded, original, bad_hash=True)
    job = queue_preview(postgres_engine, owner, stage)
    with pytest.raises(ApiError, match="import_stage_original_mismatch"):
        complete_preview(postgres_engine, claim_exact(postgres_engine, job.job_id))
    with Session(postgres_engine) as session:
        assert len(holds(session, uploaded)) == 1
        result = update_stage_mapping(
            session,
            owner.principal,
            UUID(stage.stage_id),
            StageMappingUpdate(stage_version=1, mapping=mapping),
        )
        assert result.stage_version == 2 and not holds(session, uploaded)
