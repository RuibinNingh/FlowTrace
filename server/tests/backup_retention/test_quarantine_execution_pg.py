"""Actual queue/PG/fixed UUID moves; synthetic dump headers, not pg_restore."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import replace
from datetime import timedelta
from threading import Event, current_thread
from time import monotonic
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
from sqlalchemy import delete, event, func, select, text
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.auth.models import AdminRole, User, UserSession
from flowtrace_server.auth.service import now
from flowtrace_server.backups import quarantine, retention
from flowtrace_server.backups import quarantine_execution as execution
from flowtrace_server.backups import quarantine_submission as submission
from flowtrace_server.backups.leases import BackupLeaseError, backup_read_lease
from flowtrace_server.backups.quarantine_schemas import QuarantineSubmission
from flowtrace_server.backups.retention_models import (
    BackupControl,
    BackupHold,
    BackupPin,
    BackupRetentionIntent,
)
from flowtrace_server.backups.retention_schemas import RetentionSelection
from flowtrace_server.configuration.runtime import read_runtime_configuration
from flowtrace_server.configuration.schemas import (
    ConfigurationSaveCommand,
    PublicConfigurationPatch,
)
from flowtrace_server.configuration.service import save_configuration
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.persistence.models import ServerState

from .test_job_references_pg import PASSWORD
from .test_job_references_pg import reference_case as reference_case
from .test_retention_io import package, snapshot

pytestmark = pytest.mark.postgres


def staged(case, count=2):
    with Session(case.engine) as session:
        instance, epoch = retention._source(session)
    selected = [
        package(
            case.settings,
            instance=instance,
            epoch=epoch,
            created_at=now() - timedelta(days=40),
        )
        for _ in range(count)
    ]
    selected.sort(key=lambda item: str(item[0]))
    witness = package(case.settings, instance=instance, epoch=epoch)
    for identifier, _, _ in (*selected, witness):
        with retention.prepare_registration(case.settings, identifier) as prepared:
            with Session(case.engine) as session:
                retention.register_verified_backup(
                    session, case.owner, case.settings, prepared=prepared, password=PASSWORD
                )
                session.commit()
    with Session(case.engine) as session:
        selection = RetentionSelection(
            backup_ids=tuple(item[0] for item in selected),
            request_id=uuid4(),
            expected_config_version=read_runtime_configuration(session).version,
        )
        authority = retention.precheck_retention_request(
            session, case.owner, selection=selection, password=PASSWORD
        )
        session.commit()
        with retention.build_retention_preview(case.settings, authority=authority) as prepared:
            record = retention.authorize_retention_preview(
                session, case.owner, case.settings, prepared=prepared, password=PASSWORD
            )
            session.commit()
        command = QuarantineSubmission(
            preview_id=record.preview_id,
            request_id=uuid4(),
            selection_sha256=record.selection_sha256,
        )
        authority = submission.precheck_quarantine_submission(
            session, case.owner, case.settings, command=command, record=record, password=PASSWORD
        )
        session.commit()
        with submission.prepare_quarantine_submission(
            case.settings, authority=authority
        ) as prepared:
            meta = submission.enqueue_quarantine_submission(
                session,
                case.owner,
                case.settings,
                prepared=prepared,
                command=command,
                password=PASSWORD,
            )
            session.commit()
        intent = session.scalar(
            select(BackupRetentionIntent).where(
                BackupRetentionIntent.job_id == UUID(meta["job_id"])
            )
        )
        intent_id = intent.id
    return SimpleNamespace(
        selected=selected, witness=witness, job_id=UUID(meta["job_id"]), intent_id=intent_id
    )


def claim(case, target):
    with Session(case.engine) as session, session.begin():
        lease = store.claim(session, uuid4(), {"backup_quarantine"})
        assert lease is not None and lease.job_id == target.job_id
        return lease


def complete(case, lease, handle):
    with Session(case.engine) as session, session.begin():
        return execution.complete_quarantine_execution(session, case.settings, lease, handle)


def target_root(case, target):
    return case.settings.data_directory / "backup-quarantine" / str(target.intent_id)


def controls(session, target):
    return [session.get(BackupControl, item[0], populate_existing=True) for item in target.selected]


def test_real_moves_and_final_cas_use_current_lease_and_no_files_in_completion(
    reference_case, monkeypatch
):
    case = reference_case
    target = staged(case)
    lease = claim(case, target)
    source = {item[0]: snapshot(item[1]) for item in target.selected}
    witness_before = snapshot(target.witness[1])
    with Session(case.engine) as session:
        idle_before = session.get(UserSession, case.owner.session_id).idle_expires_at
    actual, phases = retention._verify_stamp, []

    def hash_after_transaction_committed(*args, **kwargs):
        with case.engine.begin() as other:
            for statement, values in (
                (
                    "SELECT singleton_id FROM server_state WHERE singleton_id=1 FOR UPDATE NOWAIT",
                    {},
                ),
                ("SELECT id FROM users WHERE id=:id FOR UPDATE NOWAIT", {"id": case.owner.user_id}),
                (
                    "SELECT id FROM sessions WHERE id=:id FOR UPDATE NOWAIT",
                    {"id": case.owner.session_id},
                ),
                (
                    "SELECT id FROM background_jobs WHERE id=:id FOR UPDATE NOWAIT",
                    {"id": lease.job_id},
                ),
                ("SELECT id FROM service_configuration WHERE id=1 FOR UPDATE NOWAIT", {}),
            ):
                other.execute(text(statement), values).one()
        phases.append(args[1])
        return actual(*args, **kwargs)

    monkeypatch.setattr(retention, "_verify_stamp", hash_after_transaction_committed)
    with execution.prepare_quarantine_execution(case.engine, case.settings, lease) as handle:
        execution.run_quarantine_execution(handle)
        assert len(phases) >= 5 and handle.result is not None
        with monkeypatch.context() as blocked:

            def no_files(*args, **kwargs):
                pytest.fail("final DB completion performed filesystem work")

            blocked.setattr(retention, "_verify_stamp", no_files)
            blocked.setattr(quarantine, "_read_record", no_files)
            blocked.setattr(quarantine, "_rename_noreplace", no_files)
            result = complete(case, lease, handle)
        assert result["code"] == "backup_quarantined" and result["created_count"] == 2
        assert result["sha256"] == handle.result.sha256
        with Session(case.engine) as session:
            assert all(
                row.state == "quarantined" and row.version == 3 for row in controls(session, target)
            )
            assert session.get(BackgroundJob, target.job_id).status == "succeeded"
            assert session.get(UserSession, case.owner.session_id).idle_expires_at == idle_before
            assert (
                session.scalar(
                    select(func.count())
                    .select_from(AdminAudit)
                    .where(
                        AdminAudit.action == "backup.quarantine_complete",
                        AdminAudit.target_id == target.intent_id,
                    )
                )
                == 1
            )
        with pytest.raises(BackupLeaseError):
            with backup_read_lease(case.settings, target.selected[0][0], timeout_seconds=0):
                pytest.fail("EX closed before caller finalized handle")
    for identifier, original, _ in target.selected:
        assert not original.exists()
        assert (
            snapshot(target_root(case, target) / "backups" / str(identifier)) == source[identifier]
        )
    assert snapshot(target.witness[1]) == witness_before


def test_existing_target_is_not_overwritten_and_reservation_is_preserved(reference_case):
    case = reference_case
    target = staged(case)
    lease = claim(case, target)
    path = target_root(case, target) / "backups" / str(target.selected[0][0])
    path.mkdir(parents=True)
    (path / "sentinel").write_bytes(b"preserve preexisting UUID target")
    frozen = [snapshot(item[1]) for item in target.selected]
    with pytest.raises(execution.QuarantineExecutionError, match="backup_quarantine_partial"):
        execution.prepare_quarantine_execution(case.engine, case.settings, lease)
    assert [snapshot(item[1]) for item in target.selected] == frozen
    assert (path / "sentinel").read_bytes() == b"preserve preexisting UUID target"
    with Session(case.engine) as session:
        assert all(
            row.state == "reserved" and row.version == 2 for row in controls(session, target)
        )


def test_lost_source_completion_new_generation_reuses_bytes_and_never_moves_twice(
    reference_case, monkeypatch
):
    case = reference_case
    target = staged(case)
    lease = claim(case, target)
    actual, moved = quarantine._rename_noreplace, []

    def counted(source, destination):
        moved.append(source.name)
        return actual(source, destination)

    monkeypatch.setattr(quarantine, "_rename_noreplace", counted)
    with execution.prepare_quarantine_execution(case.engine, case.settings, lease) as first:
        execution.run_quarantine_execution(first)
        original_result = first.result
        frozen = snapshot(target_root(case, target))
        with Session(case.engine) as session:
            execution.complete_quarantine_execution(session, case.settings, lease, first)
            session.rollback()  # Real full result/control CAS rolls back; files/receipts remain.
        with Session(case.engine) as session, session.begin():
            job = session.get(BackgroundJob, lease.job_id)
            assert job.status == "running"
            assert all(
                row.state == "reserved" and row.version == 2 for row in controls(session, target)
            )
            job.lease_until = store.stamp(session) - timedelta(seconds=1)
        second_lease = claim(case, target)
        assert second_lease.generation == 2
        with pytest.raises(store.LeaseLost):
            complete(case, lease, first)
    with execution.prepare_quarantine_execution(case.engine, case.settings, second_lease) as second:
        execution.run_quarantine_execution(second)
        assert second.result == original_result
        result = complete(case, second_lease, second)
    assert len(moved) == 2 and snapshot(target_root(case, target)) == frozen
    assert result["sha256"] == original_result.sha256
    with Session(case.engine) as session:
        assert session.get(BackgroundJob, target.job_id).status == "succeeded"
        assert all(
            row.state == "quarantined" and row.version == 3 for row in controls(session, target)
        )


@pytest.mark.parametrize("change", ["role", "origin", "disabled", "cas", "partial", "lease"])
def test_late_fences_stop_before_move_and_keep_reserved_metadata(reference_case, change):
    case = reference_case
    target = staged(case)
    lease = claim(case, target)
    frozen = [snapshot(item[1]) for item in target.selected]
    with execution.prepare_quarantine_execution(case.engine, case.settings, lease) as handle:
        with Session(case.engine) as session, session.begin():
            if change == "role":
                session.execute(
                    delete(AdminRole).where(
                        AdminRole.user_id == case.owner.user_id, AdminRole.role == "recovery_admin"
                    )
                )
            elif change == "origin":
                session.get(UserSession, case.owner.session_id).revoked_at = store.stamp(session)
            elif change == "disabled":
                session.get(User, case.owner.user_id).enabled = False
            elif change == "cas":
                session.get(BackupControl, target.selected[0][0]).version += 1
            elif change == "partial":
                session.get(BackupControl, target.selected[0][0]).state = "partial"
            else:
                session.get(BackgroundJob, target.job_id).lease_until = store.stamp(
                    session
                ) - timedelta(seconds=1)
        with pytest.raises((execution.QuarantineExecutionError, store.LeaseLost)):
            execution.run_quarantine_execution(handle)
        assert handle.result is None
        if change != "lease":
            with Session(case.engine) as session, session.begin():
                store.fail(session, lease, "synthetic_fence_changed", transient=False)
            with pytest.raises(BackupLeaseError):
                with backup_read_lease(case.settings, target.selected[0][0], timeout_seconds=0):
                    pytest.fail("failure released EX before caller failure commit")
    assert [snapshot(item[1]) for item in target.selected] == frozen
    assert not list((target_root(case, target) / "receipts").glob("*.json"))


@pytest.mark.parametrize("tamper", ["not_run", "changed_result"])
def test_completion_never_trusts_a_missing_or_replaced_io_result(reference_case, tamper):
    case = reference_case
    target = staged(case)
    lease = claim(case, target)
    with execution.prepare_quarantine_execution(case.engine, case.settings, lease) as handle:
        if tamper == "changed_result":
            execution.run_quarantine_execution(handle)
            old = handle._state.completion
            handle._state.completion = replace(old, result=replace(old.result, sha256="0" * 64))
        with pytest.raises(
            execution.QuarantineExecutionError, match="backup_quarantine_result_unsealed"
        ):
            complete(case, lease, handle)
        with Session(case.engine) as session:
            assert all(
                row.state == "reserved" and row.version == 2 for row in controls(session, target)
            )
            assert session.get(BackgroundJob, target.job_id).status == "running"


def test_missing_receipt_after_move_remains_partial_across_crash_reclaim(
    reference_case, monkeypatch
):
    case = reference_case
    target = staged(case)
    lease = claim(case, target)
    actual = quarantine._write_record

    def failed_receipt(path, root, value):
        if isinstance(value, quarantine.QuarantineReceipt):
            raise OSError("synthetic crash after move before receipt")
        return actual(path, root, value)

    with execution.prepare_quarantine_execution(case.engine, case.settings, lease) as handle:
        with monkeypatch.context() as interrupted:
            interrupted.setattr(quarantine, "_write_record", failed_receipt)
            with pytest.raises(OSError):
                execution.run_quarantine_execution(handle)
        assert handle.result is None
    frozen = snapshot(target_root(case, target))
    with Session(case.engine) as session, session.begin():
        session.get(BackgroundJob, target.job_id).lease_until = store.stamp(session) - timedelta(
            seconds=1
        )
    second = claim(case, target)
    with pytest.raises(execution.QuarantineExecutionError, match="backup_quarantine_partial"):
        execution.prepare_quarantine_execution(case.engine, case.settings, second)
    assert snapshot(target_root(case, target)) == frozen
    assert sum(item[1].exists() for item in target.selected) == 1
    with Session(case.engine) as session:
        assert all(
            row.state == "reserved" and row.version == 2 for row in controls(session, target)
        )


def test_origin_expiring_while_waiting_for_controls_is_rechecked_with_fresh_db_clock(
    reference_case,
):
    case = reference_case
    target = staged(case)
    lease = claim(case, target)
    with Session(case.engine) as session, session.begin():
        expires = store.stamp(session) + timedelta(seconds=3)
        session.get(UserSession, case.owner.session_id).idle_expires_at = expires
    waiting = Event()

    def reached_control(connection, cursor, statement, parameters, context, executemany):
        if "backup_controls" in statement.lower() and "FOR UPDATE" in statement.upper():
            waiting.set()

    def inspect():
        with Session(case.engine) as session, session.begin():
            return execution._read_authority(session, case.settings, lease)

    frozen = [snapshot(item[1]) for item in target.selected]
    with Session(case.engine) as blocker:
        blocker.scalars(
            select(BackupControl)
            .where(
                BackupControl.backup_id.in_(
                    [item[0] for item in target.selected] + [target.witness[0]]
                )
            )
            .order_by(BackupControl.backup_id)
            .with_for_update()
        ).all()
        event.listen(case.engine, "before_cursor_execute", reached_control)
        with ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(inspect)
            try:
                assert waiting.wait(2), "authority never reached the actually blocked control lock"
                remaining = (expires - store.stamp(blocker)).total_seconds()
                assert remaining > 0, "origin expired before the intended control wait"
                Event().wait(remaining + 0.05)
            finally:
                blocker.rollback()
                event.remove(case.engine, "before_cursor_execute", reached_control)
            with pytest.raises(
                execution.QuarantineExecutionError, match="backup_quarantine_origin_inactive"
            ):
                future.result(timeout=5)
    assert [snapshot(item[1]) for item in target.selected] == frozen


def test_budget_is_capped_by_original_session_deadline_without_renewing_idle(reference_case):
    case = reference_case
    target = staged(case)
    lease = claim(case, target)
    with Session(case.engine) as session, session.begin():
        origin = session.get(UserSession, case.owner.session_id)
        deadline = store.stamp(session) + timedelta(seconds=20)
        origin.idle_expires_at = deadline
    with execution.prepare_quarantine_execution(case.engine, case.settings, lease) as handle:
        assert 0 < handle.deadline - monotonic() <= 15.1
    with Session(case.engine) as session:
        assert session.get(UserSession, case.owner.session_id).idle_expires_at == deadline


def test_newer_recovery_point_does_not_switch_the_held_witness(reference_case):
    case = reference_case
    target = staged(case)
    lease = claim(case, target)
    original_witness = snapshot(target.witness[1])
    with execution.prepare_quarantine_execution(case.engine, case.settings, lease) as handle:
        instance, epoch = (
            handle.authority.plan.source_instance_id,
            handle.authority.plan.source_epoch,
        )
        identifier, path, _ = package(case.settings, instance=instance, epoch=epoch)
        with retention.prepare_registration(case.settings, identifier) as prepared:
            with Session(case.engine) as session:
                retention.register_verified_backup(
                    session, case.owner, case.settings, prepared=prepared, password=PASSWORD
                )
                session.commit()
                assert retention._newest(session, (instance, epoch)) == identifier
        latest_before = snapshot(path)
        execution.run_quarantine_execution(handle)
        complete(case, lease, handle)
        assert handle.authority.witness.backup_id == target.witness[0]
    assert snapshot(target.witness[1]) == original_witness and snapshot(path) == latest_before


@pytest.mark.parametrize("protection", ["legacy_pin", "download_hold", "legacy_active_reader"])
def test_current_protection_is_checked_independently_of_control_version(reference_case, protection):
    case = reference_case
    target = staged(case)
    lease = claim(case, target)
    frozen = [snapshot(item[1]) for item in target.selected]
    with execution.prepare_quarantine_execution(case.engine, case.settings, lease) as handle:
        with Session(case.engine) as session, session.begin():
            # New synthetic legacy metadata bypasses modern reservation entry
            # adapters deliberately: the final reader must inspect actual pins,
            # holds/jobs, not infer their absence from an unchanged CAS version.
            identifier = target.selected[0][0]
            if protection == "legacy_pin":
                session.add(
                    BackupPin(
                        id=uuid4(),
                        backup_id=identifier,
                        created_by=case.owner.user_id,
                        create_request_id=uuid4(),
                        create_request_hash="a" * 64,
                    )
                )
            elif protection == "download_hold":
                session.add(
                    BackupHold(
                        id=uuid4(),
                        backup_id=identifier,
                        holder_kind="download",
                        holder_id=uuid4(),
                        job_id=None,
                        owner_user_id=case.owner.user_id,
                    )
                )
            else:
                store.enqueue(
                    session,
                    kind="backup_verify",
                    occurrence_key="legacy-reader:" + uuid4().hex,
                    owner_user_id=case.owner.user_id,
                    payload={"backup_id": str(identifier)},
                )
        with pytest.raises(execution.QuarantineExecutionError, match="backup_selection_protected"):
            execution.run_quarantine_execution(handle)
    assert [snapshot(item[1]) for item in target.selected] == frozen
    with Session(case.engine) as session:
        assert all(
            row.state == "reserved" and row.version == 2 for row in controls(session, target)
        )


def test_changed_runtime_configuration_stops_effect_and_preserves_reservations(reference_case):
    case = reference_case
    target = staged(case)
    lease = claim(case, target)
    frozen = [snapshot(item[1]) for item in target.selected]

    def save(days):
        with Session(case.engine) as session:
            runtime = read_runtime_configuration(session)
            save_configuration(
                session,
                case.owner,
                ConfigurationSaveCommand(
                    base_version=runtime.version,
                    request_id=uuid4(),
                    public_patch=PublicConfigurationPatch(backup_retention_days=days),
                ),
                password=PASSWORD,
                validate_candidate=lambda public, refs: None,
            )
            session.commit()

    with execution.prepare_quarantine_execution(case.engine, case.settings, lease) as handle:
        save(31)
        try:
            with pytest.raises(
                execution.QuarantineExecutionError, match="backup_configuration_changed"
            ):
                execution.run_quarantine_execution(handle)
        finally:
            save(30)
    assert [snapshot(item[1]) for item in target.selected] == frozen


def test_new_generation_waits_for_ex_and_old_generation_cannot_complete_after_last_check(
    reference_case, monkeypatch
):
    case = reference_case
    target = staged(case)
    lease = claim(case, target)
    attempted = Event()
    original_lock, original_move = quarantine.backup_exclusive_lease, quarantine._rename_noreplace
    main_thread, moved, next_lease, future = current_thread(), [], [], []

    @contextmanager
    def observed_lock(*args, **kwargs):
        if current_thread() is not main_thread:
            attempted.set()
        with original_lock(*args, **kwargs) as acquired:
            yield acquired

    with ThreadPoolExecutor(max_workers=1) as executor:
        with execution.prepare_quarantine_execution(case.engine, case.settings, lease) as first:

            def lose_between_check_and_move(source, destination):
                with Session(case.engine) as session, session.begin():
                    session.get(BackgroundJob, target.job_id).lease_until = store.stamp(
                        session
                    ) - timedelta(seconds=1)
                second = claim(case, target)
                next_lease.append(second)
                future.append(
                    executor.submit(
                        execution.prepare_quarantine_execution, case.engine, case.settings, second
                    )
                )
                assert attempted.wait(2) and not future[0].done()
                moved.append(source.name)
                return original_move(source, destination)

            monkeypatch.setattr(quarantine, "backup_exclusive_lease", observed_lock)
            monkeypatch.setattr(quarantine, "_rename_noreplace", lose_between_check_and_move)
            with pytest.raises(store.LeaseLost):
                execution.run_quarantine_execution(first)
            with Session(case.engine) as session:
                with pytest.raises(store.LeaseLost):
                    store.fail(session, lease, "stale_generation_must_not_write", transient=False)
                session.rollback()
                assert session.get(BackgroundJob, target.job_id).lease_generation == 2
        with pytest.raises(execution.QuarantineExecutionError, match="backup_quarantine_partial"):
            future[0].result(timeout=5)
    assert len(moved) == 1 and next_lease[0].generation == 2
    assert sum(item[1].exists() for item in target.selected) == 1
    assert not list((target_root(case, target) / "receipts").glob("*.json"))


def test_new_source_epoch_stops_old_job_without_moving_or_completing(reference_case):
    case = reference_case
    target = staged(case)
    lease = claim(case, target)
    frozen = [snapshot(item[1]) for item in target.selected]
    with execution.prepare_quarantine_execution(case.engine, case.settings, lease) as handle:
        # This dedicated new DB advances epoch once; it is never rolled back to
        # the old value and no historical test database is changed.
        with Session(case.engine) as session, session.begin():
            session.get(ServerState, 1).sync_epoch = uuid4()
        with pytest.raises(store.LeaseLost):
            execution.run_quarantine_execution(handle)
    assert [snapshot(item[1]) for item in target.selected] == frozen
    with Session(case.engine) as session:
        assert all(
            row.state == "reserved" and row.version == 2 for row in controls(session, target)
        )
