"""Explicit real-session binding for already published batches, only to undo."""

from sqlalchemy import update

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.jobs import store as jobs
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.sync.common import run_transaction

from .published_context import published_stage_context
from .staging import _current, _now, _stage, _status
from .staging_holds import release_stage_holds
from .staging_models import ImportStageRequirement, ImportStageRow
from .staging_publish import _current_batch_scopes
from .staging_schemas import StageReauthorize, StageUndoJob


def reauthorize_published_stage(session, principal, stage_id, body, *, check_budget):
    """Internal bounded formal metadata verification; no source/apply rebuild.

    Current authority is explicit. Original applied batch/receipts/metadata,
    source, mapping and original preview hash stay unchanged. The version only
    invalidates queued old-origin undo. Retained source rows may follow the new
    display version, but their presence/content never grants financial rights.
    """
    if not isinstance(body, StageReauthorize) or not callable(check_budget):
        raise TypeError("closed_published_reauthorization_and_budget_required")

    def bind():
        check_budget()
        state = _current(session, principal, epoch=body.sync_epoch, client_id=body.client_id)
        stage = _stage(
            session,
            principal,
            stage_id,
            state,
            version=body.stage_version,
            origin=False,
            allow_expired=True,
        )
        if stage.status not in {"applied", "undone"}:
            raise ApiError("import_stage_state_conflict", 409)
        if stage.stage_version >= 2**31 - 1:
            raise ApiError("import_stage_version_exhausted", 409)
        if stage.status == "applied":
            _current_batch_scopes(session, principal, stage)
        published_stage_context(session, principal, stage, check_budget=check_budget)
        if stage.undo_job_id is not None:
            old = session.get(BackgroundJob, stage.undo_job_id)
            expected = StageUndoJob(
                action="undo",
                stage_id=str(stage.id),
                stage_version=stage.stage_version,
                batch_id=str(stage.batch_id),
            )
            if (
                old is None
                or old.owner_user_id != principal.user_id
                or old.payload != expected.model_dump(mode="json")
            ):
                raise ApiError("import_stage_job_stale", 409)
            if old.status != "succeeded":
                jobs.cancel(session, old.id)
        release_stage_holds(session, stage, check_budget=check_budget)
        old_version = stage.stage_version
        if stage.status == "applied":
            session.execute(
                update(ImportStageRow)
                .where(
                    ImportStageRow.stage_id == stage.id,
                    ImportStageRow.parsed_version == old_version,
                )
                .values(parsed_version=old_version + 1)
            )
        adopt_requirements = stage.requirements_version == old_version
        if adopt_requirements:
            check_budget()
            session.execute(
                update(ImportStageRequirement)
                .where(
                    ImportStageRequirement.stage_id == stage.id,
                    ImportStageRequirement.parsed_version == old_version,
                )
                .values(parsed_version=old_version + 1)
            )
        _current(session, principal, epoch=body.sync_epoch, client_id=body.client_id)
        check_budget()
        stage.stage_version += 1
        if adopt_requirements:
            stage.requirements_version = stage.stage_version
        stage.origin_session_id, stage.client_id, stage.origin_purpose = (
            principal.session_id,
            principal.client_id,
            principal.purpose,
        )
        stage.undo_job_id, stage.updated_at = None, _now(session)
        session.flush()
        return _status(stage, _now(session))

    return run_transaction(session, bind)
