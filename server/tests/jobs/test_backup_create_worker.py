"""Actual pg_dump publication, replay and authority fences for backup_create."""

import hashlib
import json
import os
from datetime import timedelta
from pathlib import Path
from uuid import uuid4

import pytest
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from flowtrace_server.auth.models import AdminRole
from flowtrace_server.backups import service as backups
from flowtrace_server.config import Settings
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob, JobAttempt, WorkerState
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.worker import runtime

pytestmark = pytest.mark.postgres


@pytest.fixture
def creation_settings(queue_case, tmp_path):
    executable = (
        Path(__file__).resolve().parents[3] / "work/flowtrace-dev/postgresql/pgsql/bin/pg_dump.exe"
    )
    if not executable.is_file():
        pytest.skip("explicit pg_dump unavailable: actual backup_create not verified")
    with Session(queue_case.engine) as session, session.begin():
        session.add(AdminRole(user_id=queue_case.owner_id, role="recovery_admin"))
    return Settings(
        _env_file=None,
        environment="test",
        database_url=os.environ["FLOWTRACE_TEST_DATABASE_URL"],
        data_directory=tmp_path,
        pg_dump_executable=executable.resolve(),
    )


@pytest.fixture
def dump_calls(monkeypatch):
    calls = []
    actual = backups._dump

    def observed(*args, **kwargs):
        calls.append(Path(args[2]))
        return actual(*args, **kwargs)

    monkeypatch.setattr(backups, "_dump", observed)
    return calls


def enqueue(case, backup_id, **extra):
    return case.enqueue(kind="backup_create", payload={"backup_id": str(backup_id), **extra})


def worker(case, settings):
    return runtime.Worker(case.engine, settings, worker_id=case.worker_id())


def file_snapshot(target):
    return {
        path.relative_to(target).as_posix(): (
            path.stat().st_size,
            hashlib.sha256(path.read_bytes()).hexdigest(),
        )
        for path in target.rglob("*")
        if path.is_file()
    }


def expected_result(backup_id, manifest):
    return {
        "code": "backup_created",
        "artifact_id": str(backup_id),
        "file_count": len(manifest["files"]) + 2,
        "bytes": manifest["database"]["size_bytes"]
        + sum(item["size_bytes"] for item in manifest["files"])
        + len(canonical(manifest)),
        "sha256": hashlib.sha256(canonical(manifest)).hexdigest(),
    }


def test_actual_dump_becomes_complete_package_and_fenced_job_success(
    queue_case, creation_settings, dump_calls, monkeypatch
):
    case, settings = queue_case, creation_settings
    backup_id = uuid4()
    job_id = enqueue(case, backup_id)
    renew_calls = []
    monkeypatch.setattr(runtime.Worker, "_renew_loop", lambda *_: renew_calls.append(True))
    actual_create = runtime.create_backup
    budgets = []

    def observe_budget(*args, **kwargs):
        with Session(case.engine) as session:
            job = session.get(BackgroundJob, job_id)
            budgets.append((job.lease_until - job.updated_at).total_seconds())
        assert kwargs["backup_id"] == backup_id
        assert callable(kwargs["check_budget"])
        return actual_create(*args, **kwargs)

    monkeypatch.setattr(runtime, "create_backup", observe_budget)
    current = worker(case, settings)
    assert current.run_once()
    assert not current.run_once()
    assert budgets == [300] and not renew_calls and len(dump_calls) == 1
    manifest = backups.verify_backup(settings.data_directory / "backups", backup_id)
    assert (settings.data_directory / "backups" / str(backup_id) / "database.dump").read_bytes()[
        :5
    ] == b"PGDMP"
    assert "pg_dump_executable" not in settings.model_dump()
    assert str(settings.pg_dump_executable) not in repr(settings)
    exported_settings = json.loads(
        (settings.data_directory / "backups" / str(backup_id) / "settings.json").read_bytes()
    )
    assert "pg_dump_executable" not in exported_settings
    with Session(case.engine) as session:
        state = session.get(ServerState, 1)
        assert manifest["instance_id"] == str(state.instance_id)
        assert manifest["sync_epoch"] == str(state.sync_epoch)
        job = session.get(BackgroundJob, job_id)
        assert job.status == "succeeded" and job.attempt == 1
        assert job.result == expected_result(backup_id, manifest)
        assert job.lease_owner is None and job.lease_until is None
        assert session.get(JobAttempt, (job_id, 1)).status == "succeeded"
        heartbeat = session.get(WorkerState, current.id)
        assert heartbeat.supported_kinds == [
            "backup_create",
            "backup_quarantine",
            "backup_verify",
            "import_apply",
            "import_preview",
        ]
        assert heartbeat.active_job_id is None
        assert str(settings.data_directory) not in str(store.metadata(job))


def test_lost_completion_reuses_same_package_without_second_dump(
    queue_case, creation_settings, dump_calls, monkeypatch
):
    case, settings = queue_case, creation_settings
    backup_id = uuid4()
    job_id = enqueue(case, backup_id)
    actual_create = runtime.create_backup
    lost_completion = []

    def publish_then_expire(*args, **kwargs):
        receipt = actual_create(*args, **kwargs)
        with Session(case.engine) as session, session.begin():
            job = session.get(BackgroundJob, job_id)
            job.lease_until = store.stamp(session) - timedelta(seconds=1)
        lost_completion.append(True)
        return receipt

    monkeypatch.setattr(runtime, "create_backup", publish_then_expire)
    assert worker(case, settings).run_once()
    target = settings.data_directory / "backups" / str(backup_id)
    original_files = file_snapshot(target)
    original_manifest = backups.verify_backup(target.parent, backup_id)
    with Session(case.engine) as session:
        job = session.get(BackgroundJob, job_id)
        original_payload_hash = job.payload_hash
        assert job.status == "running" and job.result is None
        assert job.attempt == job.lease_generation == 1
    assert worker(case, settings).run_once()
    assert lost_completion == [True] and len(dump_calls) == 1
    assert file_snapshot(target) == original_files
    with Session(case.engine) as session:
        job = session.get(BackgroundJob, job_id)
        assert job.status == "succeeded" and job.attempt == job.lease_generation == 2
        assert job.payload == {"backup_id": str(backup_id)}
        assert job.payload_hash == original_payload_hash
        assert job.result == expected_result(backup_id, original_manifest)
        attempts = list(
            session.scalars(
                select(JobAttempt)
                .where(JobAttempt.job_id == job_id)
                .order_by(JobAttempt.generation)
            )
        )
        assert [attempt.status for attempt in attempts] == ["lease_expired", "succeeded"]


def test_partial_package_is_retained_and_permanently_failed(
    queue_case, creation_settings, dump_calls
):
    case, settings = queue_case, creation_settings
    backup_id = uuid4()
    target = settings.data_directory / "backups" / str(backup_id)
    target.mkdir(parents=True)
    (target / "database.dump").write_bytes(b"synthetic interrupted pg_dump output")
    (target / "operator-note.txt").write_text(
        "synthetic partial retention marker", encoding="utf-8"
    )
    original = file_snapshot(target)
    job_id = enqueue(case, backup_id)
    current = worker(case, settings)
    assert current.run_once()
    assert not current.run_once()
    assert not dump_calls and file_snapshot(target) == original
    assert not (target / "manifest.json").exists()
    with Session(case.engine) as session:
        job = session.get(BackgroundJob, job_id)
        assert job.status == "failed" and job.attempt == 1 and job.result is None
        assert job.error_code == "backup_incomplete_retained"
        assert "operator-note" not in str(store.metadata(job))


@pytest.mark.parametrize("after_creation", [False, True])
def test_current_recovery_role_is_required_before_and_after_publication(
    queue_case, creation_settings, dump_calls, monkeypatch, after_creation
):
    case, settings = queue_case, creation_settings
    backup_id = uuid4()
    job_id = enqueue(case, backup_id)

    def revoke():
        with Session(case.engine) as session, session.begin():
            session.execute(delete(AdminRole).where(AdminRole.user_id == case.owner_id))

    actual_create = runtime.create_backup

    def publish_then_revoke(*args, **kwargs):
        result = actual_create(*args, **kwargs)
        revoke()
        return result

    if after_creation:
        monkeypatch.setattr(runtime, "create_backup", publish_then_revoke)
    else:
        revoke()
    assert worker(case, settings).run_once()
    assert len(dump_calls) == int(after_creation)
    target = settings.data_directory / "backups" / str(backup_id)
    if after_creation:
        assert backups.verify_backup(target.parent, backup_id)["backup_id"] == str(backup_id)
    else:
        assert not target.exists()
    with Session(case.engine) as session:
        job = session.get(BackgroundJob, job_id)
        assert job.status == "failed" and job.result is None
        assert job.error_code == "job_permission_changed"


def test_unconfigured_tool_never_claims_creation(queue_case, tmp_path, dump_calls):
    case = queue_case
    settings = Settings(
        _env_file=None,
        environment="test",
        data_directory=tmp_path,
        database_url=os.environ["FLOWTRACE_TEST_DATABASE_URL"],
        pg_dump_executable=None,
    )
    job_id = enqueue(case, uuid4())
    current = worker(case, settings)
    assert not current.run_once()
    assert not dump_calls and not (tmp_path / "backups").exists()
    with Session(case.engine) as session:
        job = session.get(BackgroundJob, job_id)
        assert job.status == "pending" and job.attempt == job.lease_generation == 0
        assert session.get(WorkerState, current.id).supported_kinds == [
            "backup_quarantine",
            "backup_verify",
            "import_apply",
            "import_preview",
        ]


@pytest.mark.parametrize("extra", ["path", "url", "noncanonical-id"])
def test_paths_urls_and_noncanonical_ids_never_execute(
    queue_case, creation_settings, dump_calls, extra
):
    case, settings = queue_case, creation_settings
    backup_id = uuid4()
    payload = {"backup_id": str(backup_id)}
    if extra == "noncanonical-id":
        payload["backup_id"] = backup_id.hex
    else:
        payload[extra] = "https://synthetic.invalid/private" if extra == "url" else "../private"
    job_id = case.enqueue(kind="backup_create", payload=payload)
    assert worker(case, settings).run_once()
    assert not dump_calls and not (settings.data_directory / "backups").exists()
    with Session(case.engine) as session:
        job = session.get(BackgroundJob, job_id)
        assert job.status == "failed" and job.error_code == "job_payload_invalid"
        assert job.result is None
        assert "synthetic.invalid" not in str(store.metadata(job))
        assert "../private" not in str(store.metadata(job))


@pytest.mark.parametrize("changed", ["instance_id", "sync_epoch"])
def test_replay_rejects_package_from_different_source(
    queue_case, creation_settings, dump_calls, changed
):
    case, settings = queue_case, creation_settings
    backup_id = uuid4()
    backups.create_backup(
        settings,
        settings.data_directory / "backups",
        pg_dump=settings.pg_dump_executable,
        backup_id=backup_id,
    )
    target = settings.data_directory / "backups" / str(backup_id)
    path = target / "manifest.json"
    manifest = json.loads(path.read_bytes())
    manifest[changed] = str(uuid4())
    path.write_bytes(canonical(manifest))
    assert backups.verify_backup(target.parent, backup_id)[changed] == manifest[changed]
    original = file_snapshot(target)
    job_id = enqueue(case, backup_id)
    assert worker(case, settings).run_once()
    assert len(dump_calls) == 1 and file_snapshot(target) == original
    with Session(case.engine) as session:
        job = session.get(BackgroundJob, job_id)
        assert job.status == "failed" and job.error_code == "backup_source_changed"
        assert job.result is None


def test_epoch_changed_after_creation_cannot_record_success(
    queue_case, creation_settings, dump_calls, monkeypatch
):
    case, settings = queue_case, creation_settings
    backup_id = uuid4()
    job_id = enqueue(case, backup_id)
    with Session(case.engine) as session:
        original_epoch = session.get(ServerState, 1).sync_epoch
    actual_create = runtime.create_backup

    def publish_then_rotate(*args, **kwargs):
        receipt = actual_create(*args, **kwargs)
        with Session(case.engine) as session, session.begin():
            session.get(ServerState, 1).sync_epoch = uuid4()
        return receipt

    monkeypatch.setattr(runtime, "create_backup", publish_then_rotate)
    try:
        assert worker(case, settings).run_once()
        assert len(dump_calls) == 1
        with Session(case.engine) as session, session.begin():
            job = session.get(BackgroundJob, job_id)
            assert job.status != "succeeded" and job.result is None
            job.lease_until = store.stamp(session) - timedelta(seconds=1)
        assert not worker(case, settings).run_once()
        with Session(case.engine) as session:
            job = session.get(BackgroundJob, job_id)
            assert job.status == "cancelled" and job.error_code == "epoch_changed"
            assert job.result is None
    finally:
        with Session(case.engine) as session, session.begin():
            session.get(ServerState, 1).sync_epoch = original_epoch
