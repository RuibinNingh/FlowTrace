"""True PG unclaimed cancellation; original synthetic packages never move."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import replace
from datetime import timedelta
from threading import Event, current_thread
from time import sleep
from uuid import uuid4

import pytest
from pydantic import ValidationError
from sqlalchemy import delete, event, func, select, text
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import AdminRole, User, UserSession
from flowtrace_server.auth.service import PASSWORDS, issue_session, now
from flowtrace_server.backups import quarantine_cancel as cancel
from flowtrace_server.backups import quarantine_execution as execution
from flowtrace_server.backups import quarantine_submission as submission
from flowtrace_server.backups import retention
from flowtrace_server.backups.leases import BackupLeaseError, backup_read_lease
from flowtrace_server.backups.quarantine_cancel_schemas import UnclaimedQuarantineCancellation
from flowtrace_server.backups.quarantine_schemas import QuarantineSubmission
from flowtrace_server.backups.retention_models import BackupControl, BackupRetentionIntent
from flowtrace_server.configuration.runtime import read_runtime_configuration
from flowtrace_server.configuration.schemas import (
    ConfigurationSaveCommand,
    PublicConfigurationPatch,
)
from flowtrace_server.configuration.service import save_configuration
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob, JobAttempt
from flowtrace_server.persistence.models import ServerState

from .test_job_references_pg import PASSWORD
from .test_job_references_pg import reference_case as reference_case
from .test_quarantine_execution_pg import claim, controls, staged, target_root
from .test_retention_io import snapshot

pytestmark = pytest.mark.postgres


def command_for(case, target):
    with Session(case.engine) as session:
        intent = session.get(BackupRetentionIntent, target.intent_id)
        return UnclaimedQuarantineCancellation(
            job_id=target.job_id,
            intent_id=intent.id,
            selection_sha256=intent.selection_sha256,
            request_id=uuid4(),
        )


def prepare(case, target, command, principal=None):
    with Session(case.engine) as session:
        authority = cancel.precheck_unclaimed_cancel(
            session, principal or case.owner, case.settings, command=command, password=PASSWORD
        )
        session.commit()
    return cancel.prepare_unclaimed_cancel(case.settings, authority=authority)


def finish(case, command, handle, principal=None):
    with Session(case.engine) as session, session.begin():
        return cancel.cancel_unclaimed_quarantine(
            session,
            principal or case.owner,
            case.settings,
            prepared=handle,
            command=command,
            password=PASSWORD,
        )


def still_reserved(case, target):
    with Session(case.engine) as session:
        assert all(
            row.state == "reserved" and row.version == 2 for row in controls(session, target)
        )


def test_real_cancel_is_atomic_holds_ex_and_replays_metadata_without_file_work(
    reference_case, monkeypatch
):
    case = reference_case
    target = staged(case)
    command = command_for(case, target)
    frozen = [snapshot(item[1]) for item in target.selected]
    with Session(case.engine) as session:
        old_intent = dict(session.get(BackupRetentionIntent, target.intent_id).packages[0])
    actual_verify, hashed = retention._verify_stamp, []

    def unlocked_hash(*args, **kwargs):
        with case.engine.begin() as other:
            for table, column, identifier in (
                ("server_state", "singleton_id", 1),
                ("admin_control", "id", 1),
                ("users", "id", case.owner.user_id),
                ("sessions", "id", case.owner.session_id),
                ("background_jobs", "id", target.job_id),
                ("service_configuration", "id", 1),
            ):
                other.execute(
                    text(f"SELECT {column} FROM {table} WHERE {column}=:id FOR UPDATE NOWAIT"),
                    {"id": identifier},
                ).one()
        hashed.append(args[1])
        return actual_verify(*args, **kwargs)

    monkeypatch.setattr(retention, "_verify_stamp", unlocked_hash)
    with prepare(case, target, command) as handle:
        assert hashed == [item[0] for item in target.selected]
        with monkeypatch.context() as no_io:
            no_io.setattr(retention, "_verify_stamp", lambda *_a, **_k: pytest.fail("final hash"))
            no_io.setattr(cancel, "_no_intent_directory", lambda *_a: pytest.fail("final I/O"))
            with Session(case.engine) as session:
                result = cancel.cancel_unclaimed_quarantine(
                    session,
                    case.owner,
                    case.settings,
                    prepared=handle,
                    command=command,
                    password=PASSWORD,
                )
                still_reserved(case, target)
                with Session(case.engine) as other, other.begin():
                    assert store.claim(other, uuid4(), {"backup_quarantine"}) is None
                session.commit()
        with pytest.raises(BackupLeaseError, match="backup_busy"):
            with backup_read_lease(case.settings, target.selected[0][0], timeout_seconds=0):
                pytest.fail("EX ended before caller finally")
    assert result["status"] == "cancelled" and result["result"]["code"] == cancel.CODE
    assert not target_root(case, target).exists()
    assert [snapshot(item[1]) for item in target.selected] == frozen
    with Session(case.engine) as session:
        assert all(
            row.state == "available" and row.version == 3 and row.intent_id is None
            for row in controls(session, target)
        )
        assert session.get(BackupRetentionIntent, target.intent_id).packages[0] == old_intent
        assert (
            session.scalar(
                select(func.count())
                .select_from(JobAttempt)
                .where(JobAttempt.job_id == target.job_id)
            )
            == 0
        )
        assert (
            session.scalar(
                select(func.count())
                .select_from(AdminAudit)
                .where(
                    AdminAudit.target_id == target.intent_id,
                    AdminAudit.action == "backup.quarantine_cancel_unclaimed",
                )
            )
            == 1
        )
    with monkeypatch.context() as no_io:
        no_io.setattr(
            cancel, "prepare_unclaimed_cancel", lambda *_a, **_k: pytest.fail("reprepare")
        )
        no_io.setattr(retention, "_verify_stamp", lambda *_a, **_k: pytest.fail("replay hash"))
        with Session(case.engine) as session, session.begin():
            assert (
                cancel.replay_unclaimed_cancel(
                    session, case.owner, command=command, password=PASSWORD
                )
                == result
            )
        with Session(case.engine) as session:
            with pytest.raises(ApiError, match="backup_quarantine_cancel_conflict"):
                cancel.replay_unclaimed_cancel(
                    session,
                    case.owner,
                    command=command.model_copy(update={"request_id": uuid4()}),
                    password=PASSWORD,
                )
    # Replaying the original enqueue request cannot resurrect the cancelled
    # job or its reservations after the separate cancellation was committed.
    with Session(case.engine) as session, session.begin():
        intent = session.get(BackupRetentionIntent, target.intent_id)
        assert (
            submission.replay_quarantine_submission(
                session,
                case.owner,
                command=QuarantineSubmission(
                    preview_id=intent.preview_id,
                    request_id=intent.request_id,
                    selection_sha256=intent.selection_sha256,
                ),
                password=PASSWORD,
            )
            == result
        )


def test_rollback_preserves_job_reservations_audit_and_original_files(reference_case):
    case = reference_case
    target = staged(case)
    command = command_for(case, target)
    frozen = [snapshot(item[1]) for item in target.selected]
    with prepare(case, target, command) as handle:
        with Session(case.engine) as session:
            cancel.cancel_unclaimed_quarantine(
                session,
                case.owner,
                case.settings,
                prepared=handle,
                command=command,
                password=PASSWORD,
            )
            session.rollback()
        still_reserved(case, target)
        with Session(case.engine) as session:
            job = session.get(BackgroundJob, target.job_id)
            assert (job.status, job.error_code, job.result, job.attempt, job.lease_generation) == (
                "pending",
                None,
                None,
                0,
                0,
            )
            assert (
                session.scalar(
                    select(func.count())
                    .select_from(AdminAudit)
                    .where(
                        AdminAudit.target_id == target.intent_id,
                        AdminAudit.action == "backup.quarantine_cancel_unclaimed",
                    )
                )
                == 0
            )
    assert [snapshot(item[1]) for item in target.selected] == frozen
    assert not target_root(case, target).exists()


def test_claim_wins_real_job_lock_then_worker_waits_for_cancel_ex(reference_case, monkeypatch):
    case = reference_case
    target = staged(case)
    command = command_for(case, target)
    frozen = [snapshot(item[1]) for item in target.selected]
    attempted = Event()
    original = execution.quarantine.backup_exclusive_lease

    @contextmanager
    def observed(*args, **kwargs):
        if current_thread().name.startswith("claimed-worker"):
            attempted.set()
        with original(*args, **kwargs) as identities:
            yield identities

    monkeypatch.setattr(execution.quarantine, "backup_exclusive_lease", observed)
    with ThreadPoolExecutor(max_workers=1, thread_name_prefix="claimed-worker") as pool:
        with prepare(case, target, command) as handle:
            lease = claim(case, target)
            future = pool.submit(
                execution.prepare_quarantine_execution, case.engine, case.settings, lease
            )
            assert attempted.wait(2) and not future.done()
            with pytest.raises(ApiError, match="backup_quarantine_already_claimed"):
                finish(case, command, handle)
            still_reserved(case, target)
            assert not future.done()
        with future.result(timeout=5):
            pass  # Worker prepare can proceed only after cancelling caller exits EX.
    still_reserved(case, target)
    assert [snapshot(item[1]) for item in target.selected] == frozen


@pytest.mark.parametrize("shape", ["empty", "plan", "receipt", "target"])
def test_any_intent_directory_is_retained_and_refuses_unclaimed_release(reference_case, shape):
    case = reference_case
    target = staged(case)
    command = command_for(case, target)
    root = target_root(case, target)
    root.mkdir(parents=True)
    if shape == "plan":
        (root / "intent.json").write_bytes(b"partial-fixed-intent-keep")
    elif shape == "receipt":
        (root / "receipts").mkdir()
        (root / "receipts" / "partial.json").write_bytes(b"keep-partial-receipt")
    elif shape == "target":
        (root / "backups" / str(target.selected[0][0])).mkdir(parents=True)
    before = snapshot(root)
    with pytest.raises(ApiError, match="backup_quarantine_effect_not_absent"):
        prepare(case, target, command)
    still_reserved(case, target)
    assert root.is_dir() and snapshot(root) == before


def test_one_changed_original_hash_cannot_release_any_reservation(reference_case):
    case = reference_case
    target = staged(case)
    command = command_for(case, target)
    path = target.selected[1][1] / "database.dump"
    path.write_bytes(b"PGDMPnew-damage-must-remain")
    frozen = [snapshot(item[1]) for item in target.selected]
    with pytest.raises(ApiError, match="backup_package_unavailable"):
        prepare(case, target, command)
    still_reserved(case, target)
    assert [snapshot(item[1]) for item in target.selected] == frozen
    with backup_read_lease(case.settings, target.selected[0][0], timeout_seconds=0):
        pass  # Failed verification releases all previously acquired EX handles.


@pytest.mark.parametrize("field", ["attempt", "lease_generation", "manual_retries", "attempt_row"])
def test_attempt_zero_is_not_enough_to_prove_a_job_was_never_claimed(reference_case, field):
    case = reference_case
    target = staged(case)
    command = command_for(case, target)
    with Session(case.engine) as session, session.begin():
        if field == "attempt_row":
            session.add(
                JobAttempt(
                    job_id=target.job_id,
                    generation=1,
                    worker_id=uuid4(),
                    status="lease_expired",
                    started_at=now(),
                    finished_at=now(),
                )
            )
        else:
            setattr(session.get(BackgroundJob, target.job_id), field, 1)
    with pytest.raises(ApiError, match="backup_quarantine_already_claimed"):
        prepare(case, target, command)
    still_reserved(case, target)


def test_legacy_generic_cancelled_job_is_not_a_release_receipt(reference_case):
    case = reference_case
    target = staged(case)
    command = command_for(case, target)
    with Session(case.engine) as session, session.begin():
        store.cancel(session, target.job_id)
    with Session(case.engine) as session:
        with pytest.raises(ApiError, match="backup_quarantine_cancel_conflict"):
            cancel.replay_unclaimed_cancel(session, case.owner, command=command, password=PASSWORD)
    still_reserved(case, target)


def test_changed_control_cas_after_hash_does_not_partly_release_the_selection(reference_case):
    case = reference_case
    target = staged(case)
    command = command_for(case, target)
    with prepare(case, target, command) as handle:
        with Session(case.engine) as session, session.begin():
            session.get(BackupControl, target.selected[1][0]).version += 1
        with pytest.raises(ApiError, match="backup_control_conflict"):
            finish(case, command, handle)
    with Session(case.engine) as session:
        rows = controls(session, target)
        assert [row.state for row in rows] == ["reserved", "reserved"]
        assert [row.version for row in rows] == [2, 3]
        assert all(row.intent_id == target.intent_id for row in rows)


@pytest.mark.parametrize("change", ["authority", "guard", "command"])
def test_replaced_or_closed_prepared_cannot_cancel_other_authority(reference_case, change):
    case = reference_case
    target = staged(case)
    command = command_for(case, target)
    with prepare(case, target, command) as handle:
        altered = handle
        if change == "authority":
            altered = replace(
                handle,
                authority=replace(
                    handle.authority,
                    plan=handle.authority.plan.model_copy(update={"job_id": uuid4()}),
                ),
            )
        elif change == "guard":
            handle.guard.close()
        else:
            command = command.model_copy(update={"request_id": uuid4()})
        with pytest.raises(ApiError, match="backup_quarantine_cancel_binding_changed"):
            finish(case, command, altered)
    still_reserved(case, target)


@pytest.mark.parametrize("change", ["role", "password", "session"])
def test_late_current_authority_revocation_leaves_all_reservations(reference_case, change):
    case = reference_case
    target = staged(case)
    command = command_for(case, target)
    with prepare(case, target, command) as handle:
        with Session(case.engine) as session, session.begin():
            if change == "role":
                session.execute(
                    delete(AdminRole).where(
                        AdminRole.user_id == case.owner.user_id, AdminRole.role == "recovery_admin"
                    )
                )
            elif change == "password":
                session.get(User, case.owner.user_id).password_hash = PASSWORDS.hash(
                    "Synthetic-new-cancel-password-2026"
                )
            else:
                session.get(UserSession, case.owner.session_id).revoked_at = now()
        with pytest.raises(ApiError):
            finish(case, command, handle)
    still_reserved(case, target)


def test_new_current_session_can_cancel_an_old_revoked_origin(reference_case):
    case = reference_case
    target = staged(case)
    command = command_for(case, target)
    with Session(case.engine) as session, session.begin():
        session.get(UserSession, case.owner.session_id).revoked_at = now()
        user = session.get(User, case.owner.user_id)
        fresh, _ = issue_session(session, user, uuid4(), "新会话取消未领取隔离", "admin")
        principal = Principal(user.id, fresh.id, fresh.client_id, "admin", frozenset())
    with prepare(case, target, command, principal) as handle:
        assert finish(case, command, handle, principal)["status"] == "cancelled"
    with Session(case.engine) as session:
        assert session.get(BackupRetentionIntent, target.intent_id).origin_session_id == (
            case.owner.session_id
        )


def test_current_session_expiry_while_waiting_for_controls_cannot_release(reference_case):
    case = reference_case
    target = staged(case)
    command = command_for(case, target)
    waiting = Event()

    def observe(_conn, _cursor, statement, _params, _context, _many):
        if current_thread().name.startswith("late-cancel") and "backup_controls" in statement:
            waiting.set()

    with prepare(case, target, command) as handle:
        with Session(case.engine) as session, session.begin():
            session.get(UserSession, case.owner.session_id).access_expires_at = now() + timedelta(
                seconds=3
            )
        with ThreadPoolExecutor(max_workers=1, thread_name_prefix="late-cancel") as pool:
            with case.engine.begin() as blocker:
                blocker.execute(
                    text("SELECT backup_id FROM backup_controls WHERE backup_id=:id FOR UPDATE"),
                    {"id": target.selected[0][0]},
                ).one()
                event.listen(case.engine, "before_cursor_execute", observe)
                try:
                    future = pool.submit(finish, case, command, handle)
                    assert waiting.wait(2) and not future.done()
                    sleep(3.1)
                finally:
                    event.remove(case.engine, "before_cursor_execute", observe)
            with pytest.raises(ApiError, match="session_invalid"):
                future.result(timeout=5)
    still_reserved(case, target)


def test_changed_current_phase_requires_a_new_precheck_but_old_plan_config_can_cancel(
    reference_case,
):
    case = reference_case
    target = staged(case)
    command = command_for(case, target)

    def change_days(days):
        def validate_candidate(public, refs):
            assert public.backup_retention_days == days
            assert public.ocr_provider == public.ai_provider == "disabled"
            assert all(value is None for value in refs.model_dump().values())

        with Session(case.engine) as session, session.begin():
            current = read_runtime_configuration(session)
            save_configuration(
                session,
                case.owner,
                ConfigurationSaveCommand(
                    base_version=current.version,
                    request_id=uuid4(),
                    public_patch=PublicConfigurationPatch(backup_retention_days=days),
                ),
                password=PASSWORD,
                validate_candidate=validate_candidate,
            )

    try:
        with prepare(case, target, command) as handle:
            change_days(31)
            with pytest.raises(ApiError, match="backup_quarantine_cancel_phase_changed"):
                finish(case, command, handle)
        still_reserved(case, target)
        with prepare(case, target, command) as handle:
            assert finish(case, command, handle)["status"] == "cancelled"
    finally:
        change_days(30)


def test_dto_rejects_bool_generation_and_extra_path_without_coercion(reference_case):
    case = reference_case
    target = staged(case)
    command = command_for(case, target)
    data = command.model_dump()
    for changed in ({**data, "expected_generation": False}, {**data, "path": "C:/private"}):
        with pytest.raises(ValidationError):
            UnclaimedQuarantineCancellation.model_validate(changed)


def test_old_source_epoch_can_only_release_unclaimed_reservation_not_execute_it(reference_case):
    case = reference_case
    target = staged(case)
    command = command_for(case, target)
    frozen = [snapshot(item[1]) for item in target.selected]
    with Session(case.engine) as session, session.begin():
        # This last target advances only its new dedicated DB, never reverts it.
        session.get(ServerState, 1).sync_epoch = uuid4()
    with prepare(case, target, command) as handle:
        assert finish(case, command, handle)["status"] == "cancelled"
    assert [snapshot(item[1]) for item in target.selected] == frozen
    assert not target_root(case, target).exists()
