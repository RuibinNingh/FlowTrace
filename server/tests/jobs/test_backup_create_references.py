"""Actual pg_dump + real Worker provenance/registration, including lease loss."""

import hashlib
from datetime import timedelta
from uuid import uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from flowtrace_server.backups.leases import BackupLeaseError, backup_exclusive_lease
from flowtrace_server.backups.retention_models import BackupControl, BackupHold
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.worker import runtime

from .test_backup_create_worker import creation_settings as creation_settings
from .test_backup_create_worker import dump_calls as dump_calls
from .test_backup_create_worker import file_snapshot

pytestmark = pytest.mark.postgres


@pytest.mark.parametrize("lose_completion", [False, True])
def test_actual_created_package_gets_one_fenced_control_and_hold(
    queue_case, creation_settings, dump_calls, monkeypatch, lose_completion
):
    case, settings = queue_case, creation_settings
    identifier = uuid4()
    job_id = case.enqueue(kind="backup_create", payload={"backup_id": str(identifier)})
    actual_create = runtime.create_backup
    publications = []

    def publish(*args, **kwargs):
        result = actual_create(*args, **kwargs)
        publications.append(result)
        if lose_completion and len(publications) == 1:
            with Session(case.engine) as session, session.begin():
                session.get(BackgroundJob, job_id).lease_until = (
                    store.stamp(session) - timedelta(seconds=1)
                )
        return result

    actual_prepare = runtime.prepare_created_backup
    preparations = []

    def prepare(*args, **kwargs):
        prepared = actual_prepare(*args, **kwargs)
        assert prepared.completion.job_id == job_id
        assert prepared.completion.owner_user_id == case.owner_id
        preparations.append(prepared)
        return prepared

    actual_register = runtime.register_created_job_backup
    registrations = []

    def register(*args, **kwargs):
        prepared = kwargs["prepared"]
        assert not prepared.closed
        with pytest.raises(BackupLeaseError, match="backup_busy"):
            with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
                pytest.fail("actual worker completion did not retain source SH")
        result = actual_register(*args, **kwargs)
        registrations.append(result)
        return result

    monkeypatch.setattr(runtime, "create_backup", publish)
    monkeypatch.setattr(runtime, "prepare_created_backup", prepare)
    monkeypatch.setattr(runtime, "register_created_job_backup", register)
    first = runtime.Worker(case.engine, settings, worker_id=case.worker_id())
    try:
        assert first.run_once()
    finally:
        first.close()
    root = settings.data_directory / "backups" / str(identifier)
    package_snapshot = file_snapshot(root)
    assert (root / "database.dump").read_bytes()[:5] == b"PGDMP"
    assert b'"nonce"' not in (root / "manifest.json").read_bytes()
    proof_root = settings.data_directory / "backup-controls" / str(identifier)
    completion_snapshot = (proof_root / "creation-complete.json").read_bytes()
    if lose_completion:
        with Session(case.engine) as session:
            assert session.get(BackgroundJob, job_id).status == "running"
            assert session.get(BackupControl, identifier) is None
            assert session.scalar(select(func.count()).select_from(BackupHold).where(
                BackupHold.backup_id == identifier
            )) == 0
        assert preparations[0].closed
        second = runtime.Worker(case.engine, settings, worker_id=case.worker_id())
        try:
            assert second.run_once()
        finally:
            second.close()
    assert len(dump_calls) == len(publications) == 1
    assert registrations == [True]
    assert all(prepared.closed and prepared.package.closed for prepared in preparations)
    with Session(case.engine) as session:
        job = session.get(BackgroundJob, job_id)
        control = session.get(BackupControl, identifier)
        assert job.status == "succeeded" and job.result["code"] == "backup_created"
        assert job.lease_generation == (2 if lose_completion else 1)
        assert control.manifest_sha256 == hashlib.sha256(
            (root / "manifest.json").read_bytes()
        ).hexdigest()
        holds = list(session.scalars(select(BackupHold).where(BackupHold.backup_id == identifier)))
        assert len(holds) == 1
        assert (holds[0].job_id, holds[0].holder_id, holds[0].owner_user_id) == (
            job_id, job_id, case.owner_id
        )
        assert holds[0].version == 1 and holds[0].released_at is None
        assert control.version == 2 and control.state == "available"
    assert file_snapshot(root) == package_snapshot
    assert (proof_root / "creation-complete.json").read_bytes() == completion_snapshot
    with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
        pass
