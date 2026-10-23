"""Run the independent worker against real PostgreSQL and real pg_dump files."""

import hashlib
import os
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from flowtrace_server.auth.models import AdminRole
from flowtrace_server.backups.service import create_backup, verify_backup
from flowtrace_server.config import Settings
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob, JobAttempt, WorkerState
from flowtrace_server.worker import runtime


@pytest.fixture
def real_backup(queue_case, tmp_path):
    executable = (
        Path(__file__).resolve().parents[3] / "work/flowtrace-dev/postgresql/pgsql/bin/pg_dump.exe"
    )
    if not executable.is_file():
        pytest.skip("explicit local pg_dump unavailable: real worker backup not verified")
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url=os.environ["FLOWTRACE_TEST_DATABASE_URL"],
        data_directory=tmp_path,
    )
    with Session(queue_case.engine) as session, session.begin():
        session.add(AdminRole(user_id=queue_case.owner_id, role="recovery_admin"))
    receipt = create_backup(settings, tmp_path / "backups", pg_dump=executable)
    assert receipt["status"] == "verified"
    return settings, UUID(receipt["backup_id"])


def test_actual_worker_verifies_real_dump_and_persists_only_metadata(queue_case, real_backup):
    case = queue_case
    settings, backup_id = real_backup
    job_id = case.enqueue(kind="backup_verify", payload={"backup_id": str(backup_id)})
    worker = runtime.Worker(case.engine, settings, worker_id=case.worker_id())
    assert worker.run_once()
    assert not worker.run_once()
    manifest = verify_backup(settings.data_directory / "backups", backup_id)
    with Session(case.engine) as session:
        job = session.get(BackgroundJob, job_id)
        assert job.status == "succeeded" and job.attempt == 1
        assert job.result == {
            "code": "backup_verified",
            "artifact_id": str(backup_id),
            "file_count": len(manifest["files"]) + 2,
            "bytes": manifest["database"]["size_bytes"]
            + sum(item["size_bytes"] for item in manifest["files"])
            + len(canonical(manifest)),
            "sha256": hashlib.sha256(canonical(manifest)).hexdigest(),
        }
        assert job.lease_until is None and job.lease_owner is None
        assert session.get(JobAttempt, (job_id, 1)).status == "succeeded"
        heartbeat = session.get(WorkerState, worker.id)
        assert heartbeat.active_job_id is None
        assert heartbeat.supported_kinds == [
            "backup_quarantine",
            "backup_verify",
            "import_apply",
            "import_preview",
        ]
        assert str(settings.data_directory) not in str(store.metadata(job))


def test_corrupt_backup_is_a_permanent_safe_failure(queue_case, real_backup):
    case = queue_case
    settings, backup_id = real_backup
    dump = settings.data_directory / "backups" / str(backup_id) / "database.dump"
    original = dump.read_bytes()
    dump.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
    job_id = case.enqueue(kind="backup_verify", payload={"backup_id": str(backup_id)})
    assert runtime.Worker(case.engine, settings, worker_id=case.worker_id()).run_once()
    with Session(case.engine) as session:
        job = session.get(BackgroundJob, job_id)
        assert job.status == "failed" and job.result is None
        assert job.error_code == "backup_file_hash_mismatch"
        assert str(dump) not in str(store.metadata(job))


@pytest.mark.parametrize("after_file_validation", [False, True])
def test_current_recovery_role_is_required_before_and_after_io(
    queue_case, real_backup, monkeypatch, after_file_validation
):
    case = queue_case
    settings, backup_id = real_backup
    job_id = case.enqueue(kind="backup_verify", payload={"backup_id": str(backup_id)})
    calls = []

    def revoke():
        with Session(case.engine) as session, session.begin():
            session.execute(delete(AdminRole).where(AdminRole.user_id == case.owner_id))

    actual_verify = runtime.verify_backup

    def verify_then_revoke(root, identifier):
        result = actual_verify(root, identifier)
        calls.append(identifier)
        revoke()
        return result

    if after_file_validation:
        monkeypatch.setattr(runtime, "verify_backup", verify_then_revoke)
    else:
        revoke()
    assert runtime.Worker(case.engine, settings, worker_id=case.worker_id()).run_once()
    assert len(calls) == int(after_file_validation)
    with Session(case.engine) as session:
        job = session.get(BackgroundJob, job_id)
        assert job.status == "failed" and job.error_code == "job_permission_changed"
        assert job.result is None
        assert session.get(JobAttempt, (job_id, 1)).status == "failed"


def test_unimplemented_kind_is_never_claimed_by_worker(queue_case, tmp_path):
    case = queue_case
    job_id = case.enqueue(kind="export", payload={"private": "fixture_hidden"})
    settings = Settings(_env_file=None, environment="test", data_directory=tmp_path)
    worker = runtime.Worker(case.engine, settings, worker_id=case.worker_id())
    assert not worker.run_once()
    with Session(case.engine) as session:
        job = session.get(BackgroundJob, job_id)
        assert job.status == "pending" and job.attempt == 0 and job.lease_generation == 0
        assert list(session.scalars(select(JobAttempt).where(JobAttempt.job_id == job_id))) == []
        assert session.get(WorkerState, worker.id).supported_kinds == [
            "backup_quarantine",
            "backup_verify",
            "import_apply",
            "import_preview",
        ]


def test_missing_registered_tool_is_not_advertised_or_claimed(queue_case, tmp_path):
    case = queue_case
    job_id = case.enqueue(kind="backup_create", payload={"backup_id": str(uuid4())})
    settings = Settings(
        _env_file=None,
        environment="test",
        data_directory=tmp_path,
        pg_dump_executable=tmp_path / "missing-trusted-pg-dump.exe",
    )
    worker = runtime.Worker(case.engine, settings, worker_id=case.worker_id())
    assert not worker.run_once()
    with Session(case.engine) as session:
        assert session.get(BackgroundJob, job_id).status == "pending"
        assert session.get(WorkerState, worker.id).supported_kinds == [
            "backup_quarantine",
            "backup_verify",
            "import_apply",
            "import_preview",
        ]


def test_sensitive_or_extra_payload_is_rejected_without_echo(queue_case, real_backup):
    case = queue_case
    settings, backup_id = real_backup
    sentinel = "fixture_secret_payload_not_for_metadata"
    job_id = case.enqueue(
        kind="backup_verify", payload={"backup_id": str(backup_id), "private": sentinel}
    )
    assert runtime.Worker(case.engine, settings, worker_id=case.worker_id()).run_once()
    with Session(case.engine) as session:
        job = session.get(BackgroundJob, job_id)
        assert job.status == "failed" and job.error_code == "job_payload_invalid"
        assert job.result is None
        public = store.metadata(job)
        assert sentinel not in str(public) and "private" not in str(public)
