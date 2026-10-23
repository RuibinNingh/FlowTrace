"""Actual large domain previews persist metadata, never ordinary ledger effects."""

from datetime import timedelta
from uuid import UUID

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from sync.helpers import account, actor, expense, revoke, share

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.imports.models import ImportBatch
from flowtrace_server.imports.staging_models import ImportStage, ImportStageRow
from flowtrace_server.imports.staging_preview import (
    lock_preview_scope_versions,
    preview_stage_in_transaction,
    request_stage_preview,
)
from flowtrace_server.imports.staging_rows import stage_rows
from flowtrace_server.imports.staging_schemas import StageVersionInput
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.jobs.store import LeaseLost, claim, complete
from flowtrace_server.sync.models import SyncEntity

from .test_publication import staged_snapshot
from .test_staging_parse import complete_parse, prepared
from .test_staging_parsers import native_row, source_file

pytestmark = pytest.mark.postgres


def claim_exact(engine, job_id):
    from uuid import uuid4

    with Session(engine) as session:
        earliest = session.scalar(select(func.min(BackgroundJob.available_at)))
        session.get(BackgroundJob, UUID(job_id)).available_at = earliest - timedelta(seconds=1)
        session.commit()
    with Session(engine) as session:
        lease = claim(session, uuid4(), ["import_preview"])
        session.commit()
    assert str(lease.job_id) == job_id
    return lease


def prepare_preview(engine, owner, content, format_name="flowtrace_json"):
    stage, parse_lease = prepared(engine, owner, content, format_name)
    complete_parse(engine, parse_lease)
    with Session(engine) as session:
        job = request_stage_preview(
            session, owner.principal, UUID(stage.stage_id), StageVersionInput(stage_version=1)
        )
    return stage, job, claim_exact(engine, job.job_id)


def complete_preview(engine, lease, budget=lambda: None):
    with Session(engine) as session:
        result = complete(
            session,
            lease,
            lambda current, job: preview_stage_in_transaction(current, job.id, check_budget=budget),
        )
        session.commit()
        return result


def categories(owner, count):
    rows = [native_row() for _ in range(count)]
    for row in rows:
        row["scope_id"] = str(owner.book_id)
    return rows


def test_large_preview_is_ready_versioned_and_has_no_domain_residue(postgres_engine):
    owner = actor(postgres_engine)
    rows = categories(owner, 75)
    stage, job, lease = prepare_preview(postgres_engine, owner, source_file("flowtrace_json", rows))
    assert complete_preview(postgres_engine, lease) == {
        "code": "import_stage_ready",
        "created_count": 75,
    }
    with Session(postgres_engine) as session:
        stored = session.get(ImportStage, UUID(stage.stage_id))
        assert (
            stored.status == "ready"
            and stored.preview_version == 1
            and len(stored.preview_hash) == 64
        )
        assert stored.error_count == 0 and stored.required_scopes == sorted(
            [str(owner.book_id), str(owner.principal.user_id)]
        )
        assert all(
            set(value) == {"permission_version", "revision"}
            for value in stored.permission_versions.values()
        )
        assert (
            session.scalar(
                select(func.count())
                .select_from(SyncEntity)
                .where(SyncEntity.scope_id == owner.book_id)
            )
            == 1
        )
        assert not session.get(ImportBatch, UUID(stage.batch_id))
        page = stage_rows(session, owner.principal, stored.id, stage_version=1)
        assert len(page.rows) == 75 and all(
            row.status == "new" and row.target_entity_id for row in page.rows
        )
        replay = request_stage_preview(
            session, owner.principal, stored.id, StageVersionInput(stage_version=1)
        )
        assert replay.job_id == job.job_id and replay.status == "ready"
        lock_preview_scope_versions(session, owner.principal, stored, check_budget=lambda: None)


def test_cross_chunk_receipt_graph_is_real_domain_validated_and_rolled_back(postgres_engine):
    owner = actor(postgres_engine)
    cash = account(postgres_engine, owner, opening="1000000")
    original = staged_snapshot(postgres_engine, owner, cash)
    rows = [row.model_dump() for row in original.rows]
    stage, _, lease = prepare_preview(postgres_engine, owner, source_file("flowtrace_json", rows))
    assert complete_preview(postgres_engine, lease)["code"] == "import_stage_ready"
    with Session(postgres_engine) as session:
        stored = session.get(ImportStage, UUID(stage.stage_id))
        refund = session.get(ImportStageRow, (stored.id, 1))
        assert refund.dependencies == [rows[1]["source_id"]]
        assert (
            refund.topological_position
            > session.get(ImportStageRow, (stored.id, 2)).topological_position
        )
        assert stored.row_count == 202 and stored.status == "ready"
        assert session.get(SyncEntity, cash).balance_minor == 1000000
        assert not session.get(ImportBatch, UUID(stage.batch_id))
        assert (
            session.scalar(
                select(func.count())
                .select_from(SyncEntity)
                .where(SyncEntity.scope_id == owner.book_id)
            )
            == 1
        )


def test_domain_error_uses_original_csv_line_and_keeps_later_classifications(postgres_engine):
    owner = actor(postgres_engine)
    cash = account(postgres_engine, owner)
    rows = categories(owner, 60)
    bad = {
        "source_id": native_row()["source_id"],
        "scope_id": str(owner.book_id),
        "entity_type": "bill",
        "payload": expense(owner.book_id, cash, "125"),
    }
    bad["payload"]["money"]["currency"] = "USD"
    rows.insert(55, bad)
    stage, _, lease = prepare_preview(
        postgres_engine, owner, source_file("flowtrace_csv", rows), "flowtrace_csv"
    )
    assert complete_preview(postgres_engine, lease)["code"] == "import_stage_preview_rejected"
    with Session(postgres_engine) as session:
        stored = session.get(ImportStage, UUID(stage.stage_id))
        assert stored.status == "parsed" and stored.error_count == 1
        invalid = session.get(ImportStageRow, (stored.id, 56))
        assert invalid.preview_status == "invalid" and invalid.errors[0]["row"] == 57
        assert session.get(ImportStageRow, (stored.id, 61)).preview_status == "new"
        assert session.get(SyncEntity, cash).balance_minor == 100000
        assert (
            session.scalar(
                select(func.count())
                .select_from(SyncEntity)
                .where(SyncEntity.scope_id == owner.book_id)
            )
            == 1
        )


def test_budget_failure_inside_actual_domain_savepoint_rolls_back_all_preview_metadata(
    postgres_engine,
):
    owner = actor(postgres_engine)
    stage, _, lease = prepare_preview(
        postgres_engine, owner, source_file("flowtrace_json", categories(owner, 75))
    )
    with Session(postgres_engine) as session:

        def budget():
            visible = session.scalar(
                select(func.count())
                .select_from(SyncEntity)
                .where(SyncEntity.scope_id == owner.book_id)
            )
            if visible > 1:
                raise TimeoutError("budget_expired_after_actual_domain_write")

        with pytest.raises(TimeoutError, match="budget_expired_after_actual_domain_write"):
            complete(
                session,
                lease,
                lambda current, job: preview_stage_in_transaction(
                    current, job.id, check_budget=budget
                ),
            )
        session.commit()
    with Session(postgres_engine) as session:
        stored = session.get(ImportStage, UUID(stage.stage_id))
        assert stored.status == "parsed" and stored.preview_hash is None
        assert session.get(ImportStageRow, (stored.id, 1)).target_entity_id is None
        assert (
            session.scalar(
                select(func.count())
                .select_from(SyncEntity)
                .where(SyncEntity.scope_id == owner.book_id)
            )
            == 1
        )


def test_preview_final_lease_fence_and_source_row_integrity_are_not_success(postgres_engine):
    owner = actor(postgres_engine)
    stage, _, lease = prepare_preview(
        postgres_engine, owner, source_file("flowtrace_json", categories(owner, 3))
    )
    with Session(postgres_engine) as session:

        def effect(current, job):
            result = preview_stage_in_transaction(current, job.id, check_budget=lambda: None)
            job.lease_until = current.scalar(select(func.clock_timestamp())) - timedelta(seconds=1)
            current.flush()
            return result

        with pytest.raises(LeaseLost):
            complete(session, lease, effect)
        session.commit()
    with Session(postgres_engine) as session:
        stored = session.get(ImportStage, UUID(stage.stage_id))
        assert stored.status == "parsed" and stored.preview_hash is None
        row = session.get(ImportStageRow, (stored.id, 1))
        row.row_payload = {
            **row.row_payload,
            "payload": {**row.row_payload["payload"], "name": "tampered"},
        }
        session.commit()
    with pytest.raises(ApiError, match="import_stage_rows_changed"):
        complete_preview(postgres_engine, lease)


def test_current_scope_rights_and_preflight_revisions_are_rechecked(postgres_engine):
    owner, member = actor(postgres_engine), actor(postgres_engine)
    share(postgres_engine, owner, member)
    stage, _, lease = prepare_preview(
        postgres_engine, member, source_file("flowtrace_json", categories(owner, 3))
    )
    revoke(postgres_engine, owner, member)
    with pytest.raises(ApiError, match="scope_forbidden"):
        complete_preview(postgres_engine, lease)
    own_stage, _, own_lease = prepare_preview(
        postgres_engine, owner, source_file("flowtrace_json", categories(owner, 3))
    )
    complete_preview(postgres_engine, own_lease)
    account(postgres_engine, owner)  # A real financial write advances the control scope.
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_preview_changed"),
    ):
        lock_preview_scope_versions(
            session,
            owner.principal,
            session.get(ImportStage, UUID(own_stage.stage_id)),
            check_budget=lambda: None,
        )
