"""Real source-DB fences with a substituted external target operation.

These tests do not claim a real pg_restore. The rehearsal module's isolated
target tests cover target bytes, receipts and recovery after lost completion.
"""

import hashlib
import os
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from sqlalchemy import delete, select
from sqlalchemy.engine import make_url
from sqlalchemy.orm import Session

from flowtrace_server.auth.models import AdminRole, User
from flowtrace_server.backups import retention
from flowtrace_server.backups.job_references import retain_job_backup
from flowtrace_server.backups.leases import (
    BackupLeaseError,
    backup_exclusive_lease,
    backup_read_lease,
)
from flowtrace_server.backups.rehearsal import RehearsalError
from flowtrace_server.backups.retention_models import BackupControl, BackupHold
from flowtrace_server.config import RestoreTargetConfig, Settings
from flowtrace_server.configuration.models import ConfigurationHead
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.jobs import store
from flowtrace_server.jobs.administration import executable_kinds
from flowtrace_server.jobs.models import BackgroundJob, JobAttempt, WorkerState
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.worker import runtime

pytestmark = pytest.mark.postgres


@pytest.fixture
def restore_case(queue_case, tmp_path, monkeypatch):
    case = queue_case
    tool = (
        Path(__file__).resolve().parents[3]
        / "work/flowtrace-dev/postgresql/pgsql/bin/pg_restore.exe"
    )
    if not tool.is_file():
        pytest.skip("explicit trusted pg_restore unavailable")
    target_id = uuid4()
    url = os.environ["FLOWTRACE_TEST_DATABASE_URL"]
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url=url,
        data_directory=tmp_path / "source",
        restore_targets={
            target_id: RestoreTargetConfig(
                label="Synthetic worker target; no connection made",
                database_url=make_url(url)
                .set(database=f"flowtrace_test_worker_{uuid4().hex}")
                .render_as_string(hide_password=False),
                data_directory=tmp_path / "target",
                pg_restore_executable=tool,
            )
        },
    )
    with Session(case.engine) as session, session.begin():
        session.add(AdminRole(user_id=case.owner_id, role="recovery_admin"))
        head = session.get(ConfigurationHead, 1)
        version = head.current_version
    payload = {
        "target_id": str(target_id),
        "backup_id": str(uuid4()),
        "preview_id": str(uuid4()),
        "manifest_sha256": "a" * 64,
        "target_fingerprint": "b" * 64,
        "config_version": version,
    }
    result = {
        "code": "restore_rehearsal_verified",
        "artifact_id": str(target_id),
        "file_count": 1,
        "sha256": "c" * 64,
    }
    calls = []

    def substitute(settings_arg, *, owner_user_id, job_id, payload, check_budget, before_read):
        assert settings_arg is settings and owner_user_id == case.owner_id
        check_budget()
        # Substitute only the external target, preserving the real source gate
        # inside its source SH lifetime. A rejected gate never reaches the target.
        assert callable(before_read)
        with backup_read_lease(settings, payload.backup_id, check_budget=check_budget):
            before_read(payload.backup_id)
            calls.append(job_id)
            # External work must not hold source user/job/configuration locks.
            with Session(case.engine) as session, session.begin():
                session.execute(
                    select(User).where(User.id == case.owner_id).with_for_update(nowait=True)
                )
                job = session.scalar(
                    select(BackgroundJob)
                    .where(BackgroundJob.id == job_id)
                    .with_for_update(nowait=True)
                )
                assert (job.lease_until - job.updated_at).total_seconds() == 900
                session.execute(select(ConfigurationHead).with_for_update(nowait=True))
        return dict(result)

    monkeypatch.setattr(runtime, "run_restore_rehearsal", substitute)
    yield case, settings, payload, result, calls
    with Session(case.engine) as session, session.begin():
        session.get(ConfigurationHead, 1).current_version = version


def enqueue(bundle, **extra):
    case, _, payload, _, _ = bundle
    return case.enqueue(kind="restore_rehearsal", payload={**payload, **extra})


def worker(bundle):
    case, settings, _, _, _ = bundle
    return runtime.Worker(case.engine, settings, worker_id=case.worker_id())


def current_job(bundle, job_id):
    with Session(bundle[0].engine) as session:
        job = session.get(BackgroundJob, job_id)
        return job.status, job.error_code, job.result


def registered_source(bundle):
    """New synthetic package/control fixture; no actual pg_restore is claimed."""
    case, settings, payload, _, _ = bundle
    identifier = UUID(payload["backup_id"])
    root = settings.data_directory / "backups" / str(identifier)
    root.mkdir(parents=True)
    records = []
    for name, data in (
        ("database.dump", b"PGDMPsynthetic-source-gate-not-real-restore"),
        ("settings.json", b'{"environment":"test"}'),
    ):
        (root / name).write_bytes(data)
        records.append(
            {"path": name, "size_bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        )
    with Session(case.engine) as session:
        source = session.get(ServerState, 1)
        manifest = {
            "format": "flowtrace-backup-v1",
            "backup_id": str(identifier),
            "created_at": datetime.now(UTC).isoformat(),
            "server_version": "0.1.0",
            "schema_versions": ["0016_backup_quarantine"],
            "instance_id": str(source.instance_id),
            "sync_epoch": str(source.sync_epoch),
            "database": records[0],
            "files": records[1:],
            "database_summary": {
                "algorithm": "sha256-length-framed-jsonb-utc-c-order-v1",
                "tables": {"synthetic": {"count": 0, "sha256": "0" * 64}},
            },
        }
    (root / "manifest.json").write_bytes(canonical(manifest))
    with retention.prepare_registration(settings, identifier) as prepared:
        stamp = prepared.stamp
        # Explicit fixture metadata after real full package verification. This
        # does not invent an authenticated registration request or auto-claim it.
        with Session(case.engine) as session, session.begin():
            session.add(
                BackupControl(
                    **stamp.model_dump(exclude={"control_version"}),
                    version=1,
                )
            )
    payload["manifest_sha256"] = stamp.manifest_sha256
    return root, stamp


@pytest.mark.parametrize("wrong_manifest", [False, True])
def test_registered_source_gate_and_permanent_restore_hold_are_not_substituted(
    restore_case, monkeypatch, wrong_manifest
):
    case, settings, payload, expected, calls = restore_case
    root, stamp = registered_source(restore_case)
    before = {path.name: path.read_bytes() for path in root.iterdir()}
    if wrong_manifest:
        payload["manifest_sha256"] = "d" * 64
    with Session(case.engine) as session, session.begin():
        job = store.enqueue(
            session,
            kind="restore_rehearsal",
            occurrence_key=f"{case.prefix}:registered",
            owner_user_id=case.owner_id,
            payload=dict(payload),
        )
        reference = retain_job_backup(session, job.id)
        job_id = job.id
        assert reference.registered and reference.hold_id is not None
        assert reference.control_version == 2

    actual_readable = runtime.require_backup_readable
    gates = []

    def readable(session, identifier):
        with pytest.raises(BackupLeaseError, match="backup_busy"):
            with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
                pytest.fail("source gate must run under the real shared package lease")
        guard = actual_readable(session, identifier)
        assert guard.registered and guard.stamp == stamp.model_copy(update={"control_version": 2})
        gates.append(identifier)
        return guard

    monkeypatch.setattr(runtime, "require_backup_readable", readable)
    assert worker(restore_case).run_once()
    assert gates == [stamp.backup_id]
    assert calls == ([] if wrong_manifest else [job_id])
    assert current_job(restore_case, job_id) == (
        ("failed", "backup_package_changed", None)
        if wrong_manifest
        else ("succeeded", None, expected)
    )
    assert {path.name: path.read_bytes() for path in root.iterdir()} == before
    with backup_exclusive_lease(settings, (stamp.backup_id,), timeout_seconds=0):
        pass  # Both the success and gate-error paths release the real source SH.
    with Session(case.engine) as session:
        hold = session.get(BackupHold, reference.hold_id)
        assert (hold.backup_id, hold.holder_kind, hold.holder_id, hold.job_id) == (
            stamp.backup_id,
            "restore_intent",
            job_id,
            job_id,
        )
        assert (hold.owner_user_id, hold.version, hold.released_at, hold.release_proof) == (
            case.owner_id,
            1,
            None,
            None,
        )
        control = session.get(BackupControl, stamp.backup_id)
        assert (control.state, control.version) == ("available", 2)


def test_registered_target_handler_uses_fixed_budget_and_only_safe_result(
    restore_case, monkeypatch
):
    case, settings, _, expected, calls = restore_case
    job_id = enqueue(restore_case)
    renewals = []
    monkeypatch.setattr(runtime.Worker, "_renew_loop", lambda *_: renewals.append(True))
    assert worker(restore_case).run_once()
    assert current_job(restore_case, job_id) == ("succeeded", None, expected)
    assert calls == [job_id] and not renewals
    assert executable_kinds(settings) == {
        "backup_quarantine",
        "backup_verify",
        "import_apply",
        "import_preview",
        "restore_rehearsal",
    }
    with Session(case.engine) as session:
        assert session.get(JobAttempt, (job_id, 1)).status == "succeeded"
        state = session.get(WorkerState, case.worker_ids[-1])
        assert state.supported_kinds == [
            "backup_quarantine",
            "backup_verify",
            "import_apply",
            "import_preview",
            "restore_rehearsal",
        ]


@pytest.mark.parametrize("after_io", [False, True])
def test_current_recovery_before_and_after_external_operation(restore_case, monkeypatch, after_io):
    case = restore_case[0]
    job_id = enqueue(restore_case)
    original = runtime.run_restore_rehearsal

    def revoke():
        with Session(case.engine) as session, session.begin():
            session.execute(delete(AdminRole).where(AdminRole.user_id == case.owner_id))

    def operate(*args, **kwargs):
        result = original(*args, **kwargs)
        revoke()
        return result

    if after_io:
        monkeypatch.setattr(runtime, "run_restore_rehearsal", operate)
    else:
        revoke()
    assert worker(restore_case).run_once()
    assert current_job(restore_case, job_id) == ("failed", "job_permission_changed", None)
    assert len(restore_case[-1]) == int(after_io)


@pytest.mark.parametrize("after_io", [False, True])
def test_configuration_revision_before_and_after_external_operation(
    restore_case, monkeypatch, after_io
):
    case = restore_case[0]
    job_id = enqueue(restore_case)
    original = runtime.run_restore_rehearsal

    def change():
        with Session(case.engine) as session, session.begin():
            session.get(ConfigurationHead, 1).current_version += 1

    def operate(*args, **kwargs):
        result = original(*args, **kwargs)
        change()
        return result

    if after_io:
        monkeypatch.setattr(runtime, "run_restore_rehearsal", operate)
    else:
        change()
    assert worker(restore_case).run_once()
    assert current_job(restore_case, job_id) == ("failed", "restore_configuration_changed", None)
    assert len(restore_case[-1]) == int(after_io)


def test_lost_final_lease_keeps_no_success_then_new_generation_reverifies(
    restore_case, monkeypatch
):
    case = restore_case[0]
    job_id = enqueue(restore_case)
    original = runtime.run_restore_rehearsal

    def expire(*args, **kwargs):
        result = original(*args, **kwargs)
        with Session(case.engine) as session, session.begin():
            session.get(BackgroundJob, job_id).lease_until = store.stamp(session) - timedelta(
                seconds=1
            )
        return result

    monkeypatch.setattr(runtime, "run_restore_rehearsal", expire)
    assert worker(restore_case).run_once()
    assert current_job(restore_case, job_id) == ("running", None, None)
    monkeypatch.setattr(runtime, "run_restore_rehearsal", original)
    assert worker(restore_case).run_once()
    assert current_job(restore_case, job_id) == ("succeeded", None, restore_case[3])
    assert restore_case[-1] == [job_id, job_id]
    with Session(case.engine) as session:
        assert session.get(JobAttempt, (job_id, 1)).status == "lease_expired"
        assert session.get(JobAttempt, (job_id, 2)).status == "succeeded"


def test_closed_payload_rejected_without_target_operation_or_private_echo(restore_case):
    job_id = enqueue(restore_case, private="synthetic_private_not_public")
    assert worker(restore_case).run_once()
    assert current_job(restore_case, job_id) == ("failed", "job_payload_invalid", None)
    assert restore_case[-1] == []


def test_typed_target_busy_is_retryable_without_a_success_receipt(restore_case, monkeypatch):
    job_id = enqueue(restore_case)

    def busy(*args, **kwargs):
        raise RehearsalError("restore_target_busy", transient=True)

    monkeypatch.setattr(runtime, "run_restore_rehearsal", busy)
    assert worker(restore_case).run_once()
    assert current_job(restore_case, job_id) == ("retry_wait", "restore_target_busy", None)


@pytest.mark.parametrize("field", ["instance_id", "sync_epoch"])
def test_source_identity_change_during_external_work_has_no_success(
    restore_case, monkeypatch, field
):
    case = restore_case[0]
    job_id = enqueue(restore_case)
    original = runtime.run_restore_rehearsal
    with Session(case.engine) as session:
        previous = getattr(session.get(ServerState, 1), field)

    def operate(*args, **kwargs):
        result = original(*args, **kwargs)
        with Session(case.engine) as session, session.begin():
            setattr(session.get(ServerState, 1), field, uuid4())
        return result

    monkeypatch.setattr(runtime, "run_restore_rehearsal", operate)
    try:
        assert worker(restore_case).run_once()
        status, code, result = current_job(restore_case, job_id)
        assert result is None
        if field == "instance_id":
            assert (status, code) == ("failed", "restore_source_changed")
        else:
            assert (status, code) == ("running", None)
    finally:
        with Session(case.engine) as session, session.begin():
            setattr(session.get(ServerState, 1), field, previous)


def test_unregistered_target_capability_is_not_advertised_or_claimed(queue_case, tmp_path):
    job_id = queue_case.enqueue(kind="restore_rehearsal")
    settings = Settings(_env_file=None, environment="test", data_directory=tmp_path)
    instance = runtime.Worker(queue_case.engine, settings, worker_id=queue_case.worker_id())
    assert not instance.run_once()
    with Session(queue_case.engine) as session:
        assert session.get(BackgroundJob, job_id).status == "pending"
        assert session.get(WorkerState, instance.id).supported_kinds == [
            "backup_quarantine",
            "backup_verify",
            "import_apply",
            "import_preview",
        ]
