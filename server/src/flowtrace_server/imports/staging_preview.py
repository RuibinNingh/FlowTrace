"""Version-bound durable preview, with rollback-only actual domain effects."""

from uuid import UUID

from pydantic import ValidationError
from sqlalchemy import select

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.books.permissions import authorize_scope
from flowtrace_server.jobs import store as jobs
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.sync.common import lock_scopes, run_transaction

from .attachment_sources import AttachmentSource
from .attachment_transfers import plan_transfers
from .parsers import ImportFormatError, digest
from .publication import (
    PublicationStageSnapshot,
    preview_publication_in_transaction,
    request_from_stage,
)
from .service import (
    REFERENCE_FIELDS,
    REFERENCE_LISTS,
    _import_source_hash,
    operations_for,
    target_ids,
)
from .staging import _current, _now, _stage, stage_work_context
from .staging_holds import acquire_stage_holds, release_stage_holds, validate_original_sources
from .staging_models import ImportStage, ImportStageRow
from .staging_parse import verified_stage_bytes
from .staging_parsers import open_stage_source
from .staging_schemas import (
    StageJobResponse,
    StageMapping,
    StagePreviewJob,
    StageScopeVersion,
    StageVersionInput,
)


def request_stage_preview(session, principal, stage_id, body):
    if not isinstance(body, StageVersionInput):
        raise TypeError("closed_stage_version_required")

    def request():
        state = _current(session, principal)
        stage = _stage(session, principal, stage_id, state, version=body.stage_version)
        if stage.status not in {"parsed", "previewing", "ready"}:
            raise ApiError("import_stage_state_conflict", 409)
        if stage.preview_job_id is not None:
            old = session.get(BackgroundJob, stage.preview_job_id)
            if (
                old is None
                or old.owner_user_id != principal.user_id
                or old.payload
                != StagePreviewJob(
                    action="preview",
                    stage_id=str(stage.id),
                    stage_version=stage.stage_version,
                    source_sha256=stage.source_sha256,
                    mapping_hash=digest(stage.mapping),
                ).model_dump(mode="json")
            ):
                raise ApiError("import_stage_job_stale", 409)
            return StageJobResponse(
                stage_id=str(stage.id),
                stage_version=stage.stage_version,
                job_id=str(old.id),
                status=stage.status,
            )
        if stage.error_count:
            raise ApiError("import_stage_has_errors", 409)
        parsed = session.get(BackgroundJob, stage.parse_job_id)
        if parsed is None or parsed.status != "succeeded":
            raise ApiError("import_stage_parse_incomplete", 409)
        acquire_stage_holds(session, principal, stage)
        intent = StagePreviewJob(
            action="preview",
            stage_id=str(stage.id),
            stage_version=stage.stage_version,
            source_sha256=stage.source_sha256,
            mapping_hash=digest(stage.mapping),
        )
        job = jobs.enqueue(
            session,
            kind="import_preview",
            occurrence_key=f"import:{stage.id}:v{stage.stage_version}:preview",
            owner_user_id=stage.owner_user_id,
            payload=intent.model_dump(mode="json"),
        )
        stage.preview_job_id, stage.updated_at = job.id, _now(session)
        session.flush()
        return StageJobResponse(
            stage_id=str(stage.id),
            stage_version=stage.stage_version,
            job_id=str(job.id),
            status=stage.status,
        )

    return run_transaction(session, request)


def snapshot_from_stage(session, context, *, check_budget):
    """Only verified durable source + matching parsed rows form publication input."""
    return snapshot_from_authorized_stage(session, context.stage, check_budget=check_budget)


def snapshot_from_authorized_stage(session, stage, *, check_budget):
    """Source integrity only; caller must already hold the authorized real stage.

    Explicit post-publication reauthorization uses this without inventing a
    worker or a queued job. No financial operation or permission is inferred.
    """
    if not isinstance(stage, ImportStage):
        raise TypeError("trusted_persistent_stage_required")
    mapping = StageMapping.model_validate(stage.mapping)
    if stage.error_count or not stage.row_count:
        raise ApiError("import_stage_has_errors", 409)
    content = verified_stage_bytes(session, stage, check_budget=check_budget)
    stored = iter(
        session.scalars(
            select(ImportStageRow)
            .where(ImportStageRow.stage_id == stage.id)
            .order_by(ImportStageRow.position)
            .execution_options(yield_per=500)
        )
    )
    rows = []
    try:
        with open_stage_source(content, stage.format, mapping, check_budget=check_budget) as source:
            for parsed in source.rows:
                check_budget()
                record = next(stored, None)
                if (
                    parsed.row is None
                    or parsed.errors
                    or record is None
                    or record.position != parsed.position
                    or record.source_line != parsed.source_line
                    or record.parsed_version != stage.stage_version
                    or record.raw_hash != parsed.raw_hash
                    or record.source_id != UUID(parsed.row.source_id)
                    or record.row_payload != parsed.row.model_dump(mode="json")
                ):
                    raise ApiError("import_stage_rows_changed", 409)
                rows.append(parsed.row)
            if next(stored, None) is not None or len(rows) != stage.row_count:
                raise ApiError("import_stage_rows_changed", 409)
            return PublicationStageSnapshot(
                stage_id=stage.id,
                batch_id=stage.batch_id,
                user_id=stage.owner_user_id,
                client_id=stage.client_id,
                sync_epoch=stage.sync_epoch,
                version=stage.stage_version,
                source_sha256=stage.source_sha256,
                source_namespace=source.source_namespace,
                rows=tuple(rows),
                posting_hints=source.posting_hints,
                scope_mapping=mapping.scope_mapping,
                resource_mapping=mapping.resource_mapping,
                attachment_transfers=mapping.attachment_transfers,
                attachment_sources=tuple(
                    AttachmentSource.model_validate(value) for value in source.attachment_sources
                ),
            )
    except ImportFormatError:
        raise ApiError("import_stage_rows_changed", 409) from None


def _dependencies(command, targets):
    wanted = set()

    def collect(value, key=None):
        if isinstance(value, dict):
            for name, item in value.items():
                collect(item, name)
        elif isinstance(value, list):
            for item in value:
                collect(item, key)
        elif key in REFERENCE_FIELDS | REFERENCE_LISTS and value in targets:
            wanted.add(targets[value])

    collect(command.payload.model_dump())
    if command.scope_id in targets:
        wanted.add(targets[command.scope_id])
    return sorted(wanted)


def preview_stage_in_transaction(session, actual_job_id, *, check_budget):
    """Root wraps this in jobs.complete; it publishes only versioned preview rows."""
    if not callable(check_budget):
        raise TypeError("trusted_budget_callback_required")
    check_budget()
    context = stage_work_context(session, actual_job_id)
    if not isinstance(context.intent, StagePreviewJob):
        raise ApiError("import_stage_job_stale", 409)
    stage = context.stage
    snapshot = snapshot_from_stage(session, context, check_budget=check_budget)
    validate_original_sources(session, context.principal, snapshot, check_budget=check_budget)
    stage.status = "previewing"
    hold_preview = session.begin_nested()
    try:
        release_stage_holds(session, stage, check_budget=check_budget)
        preview = preview_publication_in_transaction(
            session, context.principal, snapshot, check_budget=check_budget
        )
    finally:
        hold_preview.rollback()
    body = request_from_stage(snapshot, context.principal)
    commands = operations_for(context.principal, body, check_budget=check_budget)
    targets = target_ids(context.principal, body)
    transfers = plan_transfers(body, commands, targets)
    by_id = {command.entity_id: command for command in commands}
    source_by_target = {target: source for source, target in targets.items()}
    topology = {command.entity_id: position for position, command in enumerate(commands, 1)}
    errors = {}
    for error in preview.errors:
        errors.setdefault(error.row, []).append(error)
    stored = iter(
        session.scalars(
            select(ImportStageRow)
            .where(ImportStageRow.stage_id == stage.id)
            .order_by(ImportStageRow.position)
            .execution_options(yield_per=500)
        )
    )
    for row, original in zip(preview.rows, snapshot.rows, strict=True):
        check_budget()
        record = next(stored)
        command = by_id[row.entity_id]
        record.preview_version = stage.stage_version
        record.target_entity_id = UUID(row.entity_id)
        record.mapped_hash = _import_source_hash(original, command, body, transfers)
        record.dependencies = _dependencies(command, source_by_target)
        record.topological_position = topology[row.entity_id]
        record.errors = [
            error.model_copy(update={"row": record.source_line}).model_dump()
            for error in errors.get(record.position, [])
        ]
        record.preview_status = "invalid" if record.errors else row.status
        record.preview_warning = row.warning
        if record.position % 500 == 0:
            session.flush()
    # This is stage-only preflight state. Publication permission_versions and
    # final checkpoint use their own, different flat representations.
    stage.required_scopes = sorted(preview.scope_versions)
    stage.permission_versions = {
        identifier: version.model_dump(mode="json")
        for identifier, version in sorted(preview.scope_versions.items())
    }
    stage.preview_hash = digest(
        {
            "preview": preview.model_dump(mode="json"),
            "mapping_hash": digest(stage.mapping),
            "source_sha256": stage.source_sha256,
        }
    )
    stage.preview_version = stage.stage_version
    stage.error_count = len(preview.errors)
    # Still previewing while final current origin/version/expiry is checked.
    stage_work_context(session, actual_job_id)
    check_budget()
    stage.status = "ready" if preview.can_apply else "parsed"
    stage.updated_at = _now(session)
    session.flush()
    return {
        "code": "import_stage_ready" if preview.can_apply else "import_stage_preview_rejected",
        "created_count": len(preview.rows),
    }


def lock_preview_scope_versions(session, principal, stage, *, check_budget):
    """Final publish helper: lock/re-authorize existing scopes and compare both versions."""
    if not callable(check_budget):
        raise TypeError("trusted_budget_callback_required")
    try:
        versions = {
            identifier: StageScopeVersion.model_validate(value)
            for identifier, value in stage.permission_versions.items()
        }
        if set(versions) != set(stage.required_scopes) or str(principal.user_id) not in versions:
            raise ValueError
    except (ValidationError, ValueError, TypeError):
        raise ApiError("import_stage_preview_changed", 409) from None
    scopes = lock_scopes(session, {UUID(identifier) for identifier in versions})
    for identifier, wanted in versions.items():
        check_budget()
        grant = authorize_scope(session, principal, UUID(identifier), write=True)
        if wanted.permission_version != str(
            grant.scope.permission_version
        ) or wanted.revision != str(grant.scope.revision):
            raise ApiError("import_stage_preview_changed", 409)
    return scopes
