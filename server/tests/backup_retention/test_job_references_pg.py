"""Real PG references and completion fences; synthetic files, no pg_restore."""

import hashlib
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout
from datetime import timedelta
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
from sqlalchemy import delete, func, select, update
from sqlalchemy.orm import Session

from flowtrace_server.admin.service import reauthenticate_admin
from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import AdminRole, User, UserSession
from flowtrace_server.auth.service import create_user, issue_session, now
from flowtrace_server.backups import job_references as refs
from flowtrace_server.backups import rehearsal, retention
from flowtrace_server.backups.leases import BackupLeaseError, backup_exclusive_lease
from flowtrace_server.backups.retention_models import BackupControl, BackupHold
from flowtrace_server.backups.retention_schemas import HoldReleaseCommand
from flowtrace_server.backups.service import verify_backup
from flowtrace_server.config import RestoreTargetConfig, Settings
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.jobs import administration as jobs_admin
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.persistence.models import ServerState

from . import test_retention_io as io_fixture
from .test_retention_service_pg import reservation_fixture

pytestmark = pytest.mark.postgres
PASSWORD = "Synthetic-backup-reference-password-2026"


@pytest.fixture
def reference_case(postgres_engine, tmp_path):
    with Session(postgres_engine) as session, session.begin():
        user = create_user(session, "backup_ref_" + uuid4().hex, PASSWORD)
        session.add_all([
            AdminRole(user_id=user.id, role="recovery_admin"),
            AdminRole(user_id=user.id, role="service_admin"),
        ])
        origin, _ = issue_session(session, user, uuid4(), "合成备份引用专项", "admin")
        principal = Principal(user.id, origin.id, origin.client_id, "admin", frozenset())
    result = SimpleNamespace(
        owner=principal, engine=postgres_engine,
        settings=Settings(
            _env_file=None, environment="test", diagnostics_enabled=False,
            database_url=postgres_engine.url.render_as_string(hide_password=False),
            data_directory=tmp_path,
        ),
    )
    try:
        yield result
    finally:
        with Session(postgres_engine) as session, session.begin():
            active = list(session.scalars(select(BackgroundJob.id).where(
                BackgroundJob.owner_user_id == principal.user_id,
                BackgroundJob.status.in_(("pending", "running", "retry_wait")),
            )))
            for identifier in active:
                store.cancel(session, identifier)
            session.execute(delete(AdminRole).where(AdminRole.user_id == principal.user_id))
            session.execute(update(UserSession).where(
                UserSession.user_id == principal.user_id, UserSession.revoked_at.is_(None)
            ).values(revoked_at=now()))


def registered(case):
    with Session(case.engine) as session:
        instance, epoch = retention._source(session)
    identifier, root, _ = io_fixture.package(case.settings, instance=instance, epoch=epoch)
    with retention.prepare_registration(case.settings, identifier) as prepared:
        with Session(case.engine) as session:
            retention.register_verified_backup(
                session, case.owner, case.settings, prepared=prepared, password=PASSWORD
            )
            session.commit()
    return identifier, root


def enqueue(session, case, backup_id, kind="backup_verify"):
    reauthenticate_admin(session, case.owner, PASSWORD, capability="recovery")
    return store.enqueue(
        session, kind=kind, occurrence_key="backup-ref:" + uuid4().hex,
        owner_user_id=case.owner.user_id, payload={"backup_id": str(backup_id)},
    )


def count(session, model, backup_id):
    return session.scalar(select(func.count()).select_from(model).where(
        model.backup_id == backup_id
    ))


def test_trusted_reference_is_real_unique_and_same_enqueue_transaction(reference_case):
    case = reference_case
    identifier, _ = registered(case)
    with Session(case.engine) as session:
        job = enqueue(session, case, identifier)
        first = refs.retain_job_backup(session, job.id)
        second = refs.retain_job_backup(session, job.id)
        assert first == second and first.registered and first.control_version == 2
        hold = session.get(BackupHold, first.hold_id)
        assert (hold.job_id, hold.holder_id, hold.owner_user_id) == (
            job.id, job.id, case.owner.user_id
        )
        assert hold.version == 1 and hold.holder_kind == "job"
        session.rollback()
    with Session(case.engine) as session:
        assert count(session, BackupHold, identifier) == 0
        assert session.get(BackupControl, identifier).version == 1


def test_unregistered_legacy_reference_is_never_automatically_registered(reference_case):
    case = reference_case
    identifier = uuid4()
    with Session(case.engine) as session:
        job = enqueue(session, case, identifier)
        reference = refs.retain_job_backup(session, job.id)
        session.commit()
        assert reference == refs.JobBackupReference(False, None, None)
        assert session.get(BackupControl, identifier) is None
        assert count(session, BackupHold, identifier) == 0


def test_restore_enqueue_permanent_hold_and_historical_replay_do_not_rebind(
    reference_case, monkeypatch, tmp_path
):
    case = reference_case
    identifier, root = registered(case)
    frozen = io_fixture.snapshot(root)
    tool = tmp_path / "target-probe-only-not-executed"
    tool.write_bytes(b"synthetic-target-registration")
    target_id = uuid4()
    settings = case.settings.model_copy(update={"restore_targets": {
        target_id: RestoreTargetConfig(
            label="合成引用目标", data_directory=tmp_path / "unused-target",
            database_url="postgresql+psycopg://fixture:fixture@127.0.0.1/flowtrace_test_unused",
            pg_restore_executable=tool,
        )
    }})
    monkeypatch.setattr(rehearsal, "_probe_empty", lambda *args: ("a" * 64, "b" * 64))
    with Session(case.engine) as session:
        authority = rehearsal.precheck_restore_request(session, case.owner, PASSWORD)
        session.commit()
        with rehearsal.build_restore_preview(
            settings, authority=authority, backup_id=identifier, target_id=target_id
        ) as preview:
            rehearsal.authorize_restore_preview(session, case.owner, settings, preview, PASSWORD)
            session.commit()
            preview_id = preview.record.preview_id
        with rehearsal.prepare_restore_submission(
            settings, owner_user_id=case.owner.user_id, session_id=case.owner.session_id,
            preview_id=preview_id,
        ) as prepared:
            first = rehearsal.enqueue_restore_rehearsal(
                session, case.owner, settings, prepared=prepared, password=PASSWORD
            )
            session.commit()
        job_id = UUID(first["job_id"])
        hold = session.scalar(select(BackupHold).where(BackupHold.job_id == job_id))
        assert hold.holder_kind == "restore_intent" and hold.version == 1
        version = session.get(BackupControl, identifier).version
        assert rehearsal.replay_restore_intent(
            session, case.owner, settings, preview_id=preview_id, password=PASSWORD
        ) == first
        assert count(session, BackupHold, identifier) == 1
        assert session.get(BackupControl, identifier).version == version
        session.commit()
        store.cancel(session, job_id)
        session.commit()
        # Historical replay is only already-committed metadata. It does not
        # reacquire/rebind a reference when the deployment epoch has changed.
        session.get(ServerState, 1).sync_epoch = uuid4()
        session.flush()
        replay = rehearsal.replay_restore_intent(
            session, case.owner, settings, preview_id=preview_id, password=PASSWORD
        )
        assert replay["job_id"] == first["job_id"] and replay["status"] == "cancelled"
        assert session.get(BackupControl, identifier).version == version
        session.rollback()
        with pytest.raises(ApiError, match="backup_restore_hold_protected"):
            retention.release_backup_hold(
                session, case.owner, password=PASSWORD,
                command=HoldReleaseCommand(
                    hold_id=hold.id, expected_hold_version=1,
                    expected_control_version=version, proof="job_terminal_verified",
                ),
            )
        session.rollback()
        assert session.get(BackupHold, hold.id).version == 1
    assert io_fixture.snapshot(root) == frozen


def test_explicit_release_then_retry_rejects_and_new_verify_gets_new_hold(reference_case):
    case = reference_case
    identifier, _ = registered(case)
    with Session(case.engine) as session:
        metadata = jobs_admin.enqueue_backup_verification(
            session, case.owner, backup_id=identifier, request_id=uuid4(), password=PASSWORD
        )
        job_id = UUID(metadata["job_id"])
        session.commit()
        lease = store.claim(session, uuid4(), {"backup_verify"})
        assert lease.job_id == job_id
        session.commit()
        store.fail(session, lease, "synthetic_verified_terminal_failure", transient=False)
        session.commit()
        hold = session.scalar(select(BackupHold).where(BackupHold.job_id == job_id))
        hold_id = hold.id
        control = session.get(BackupControl, identifier)
        release = retention.release_backup_hold(
            session, case.owner, password=PASSWORD,
            command=HoldReleaseCommand(
                hold_id=hold.id, expected_hold_version=1,
                expected_control_version=control.version, proof="job_terminal_verified",
            ),
        )
        session.commit()
        assert release["version"] == 2
    with Session(case.engine) as session, pytest.raises(ApiError) as denied:
        jobs_admin.control_job(
            session, case.owner, job_id=job_id, action="retry", password=PASSWORD,
            settings=case.settings,
        )
    assert denied.value.code == "backup_reference_released"
    with Session(case.engine) as session:
        assert session.get(BackupHold, hold_id).version == 2
        assert session.get(BackgroundJob, job_id).status == "failed"
        fresh = jobs_admin.enqueue_backup_verification(
            session, case.owner, backup_id=identifier, request_id=uuid4(), password=PASSWORD
        )
        session.commit()
        new_hold = session.scalar(select(BackupHold).where(
            BackupHold.job_id == UUID(fresh["job_id"])
        ))
        assert new_hold.id != hold_id and new_hold.version == 1
        assert count(session, BackupHold, identifier) == 2


def test_reservation_commits_before_competing_enqueue_reference(reference_case):
    case = reference_case
    identifier, root = registered(case)
    intent_id, _ = reservation_fixture(case, identifier)
    before = io_fixture.snapshot(root)
    with Session(case.engine) as session:
        pending = enqueue(session, case, identifier)
        job_id = pending.id
        session.commit()

    def new_reference():
        with Session(case.engine) as session:
            try:
                refs.retain_job_backup(session, job_id)
                session.commit()
                return "unexpected_success"
            except ApiError as error:
                return error.code

    with Session(case.engine) as reservation, ThreadPoolExecutor(max_workers=1) as executor:
        control = reservation.scalar(select(BackupControl).where(
            BackupControl.backup_id == identifier
        ).with_for_update())
        control.state, control.intent_id, control.version = "reserved", intent_id, 2
        reservation.flush()
        future = executor.submit(new_reference)
        with pytest.raises(FutureTimeout):
            future.result(timeout=0.15)
        reservation.commit()
        assert future.result(timeout=5) == "backup_control_conflict"
    with Session(case.engine) as session:
        assert count(session, BackupHold, identifier) == 0
    assert io_fixture.snapshot(root) == before


def created_preparation(case, monkeypatch, *, legacy=False, old_format=False):
    with Session(case.engine) as session:
        instance, epoch = retention._source(session)
        identifier = uuid4()
        job = enqueue(session, case, identifier, "backup_create")
        job_id = job.id
        session.commit()
        lease = store.claim(session, uuid4(), {"backup_create"})
        assert lease.job_id == job_id
        session.commit()
    monkeypatch.setattr(io_fixture, "uuid4", lambda: identifier)
    with backup_exclusive_lease(case.settings, (identifier,)):
        if legacy:
            _, root, manifest = io_fixture.package(case.settings, instance=instance, epoch=epoch)
            if old_format:
                del manifest["database_summary"]
                (root / "manifest.json").write_bytes(canonical(manifest))
                (root / "legacy-unlisted-file.bin").write_bytes(b"keep-protected-legacy")
        proof = refs.start_creation(
            case.settings, backup_id=identifier, job_id=job_id,
            owner_user_id=case.owner.user_id, instance_id=instance, epoch=epoch,
        )
        if not legacy:
            _, root, manifest = io_fixture.package(case.settings, instance=instance, epoch=epoch)
        verify_backup(root.parent, identifier)
        refs.complete_creation(case.settings, proof, manifest)
    prepared = refs.prepare_created_backup(
        case.settings, backup_id=identifier, job_id=job_id, owner_user_id=case.owner.user_id,
        manifest_sha256=hashlib.sha256(canonical(manifest)).hexdigest(),
    )
    return identifier, root, lease, prepared


def finish(case, session, lease, prepared):
    def effect(current, job):
        registered = refs.register_created_job_backup(
            current, case.settings, job=job, prepared=prepared
        )
        assert registered is (prepared.completion is not None)
        return {"code": "backup_created", "artifact_id": str(prepared.backup_id)}

    return store.complete(session, lease, effect)


def test_created_registration_is_inside_actual_completion_with_source_sh(
    reference_case, monkeypatch
):
    case = reference_case
    identifier, root, lease, prepared = created_preparation(case, monkeypatch)
    before = io_fixture.snapshot(root)
    with prepared:
        with pytest.raises(BackupLeaseError, match="backup_busy"):
            with backup_exclusive_lease(case.settings, (identifier,), timeout_seconds=0):
                pytest.fail("final commit was not protected by source SH")
        with Session(case.engine) as session:
            finish(case, session, lease, prepared)
            assert count(session, BackupControl, identifier) == 1
            assert count(session, BackupHold, identifier) == 1
            session.commit()
        with pytest.raises(BackupLeaseError, match="backup_busy"):
            with backup_exclusive_lease(case.settings, (identifier,), timeout_seconds=0):
                pytest.fail("source SH ended before caller context close")
    with Session(case.engine) as session:
        assert session.get(BackgroundJob, lease.job_id).status == "succeeded"
    assert io_fixture.snapshot(root) == before


def test_final_lease_loss_rolls_back_registration_then_same_package_replays(
    reference_case, monkeypatch
):
    case = reference_case
    identifier, root, lease, prepared = created_preparation(case, monkeypatch)
    before = io_fixture.snapshot(root)
    with prepared:
        with Session(case.engine) as session, pytest.raises(store.LeaseLost):
            def expired_after_effect(current, job):
                refs.register_created_job_backup(current, case.settings, job=job, prepared=prepared)
                job.lease_until = store.stamp(current) - timedelta(seconds=1)
                current.flush()
                return {"code": "backup_created"}

            store.complete(session, lease, expired_after_effect)
    with Session(case.engine) as session:
        assert count(session, BackupControl, identifier) == 0
        assert count(session, BackupHold, identifier) == 0
        job = session.get(BackgroundJob, lease.job_id)
        job.lease_until = store.stamp(session) - timedelta(seconds=1)
        session.commit()
        retry_lease = store.claim(session, uuid4(), {"backup_create"})
        session.commit()
        assert retry_lease.job_id == lease.job_id and retry_lease.generation == lease.generation + 1
    digest = hashlib.sha256((root / "manifest.json").read_bytes()).hexdigest()
    with refs.prepare_created_backup(
        case.settings, backup_id=identifier, job_id=lease.job_id,
        owner_user_id=case.owner.user_id, manifest_sha256=digest,
    ) as replay:
        with Session(case.engine) as session:
            finish(case, session, retry_lease, replay)
            session.commit()
            assert count(session, BackupControl, identifier) == 1
            assert count(session, BackupHold, identifier) == 1
    assert io_fixture.snapshot(root) == before


@pytest.mark.parametrize("old_format", [False, True])
def test_complete_legacy_package_success_never_claims_control(
    reference_case, monkeypatch, old_format
):
    case = reference_case
    identifier, root, lease, prepared = created_preparation(
        case, monkeypatch, legacy=True, old_format=old_format
    )
    before = io_fixture.snapshot(root)
    with prepared, Session(case.engine) as session:
        finish(case, session, lease, prepared)
        session.commit()
        assert session.get(BackupControl, identifier) is None
        assert count(session, BackupHold, identifier) == 0
    assert io_fixture.snapshot(root) == before


@pytest.mark.parametrize("changed", ["owner", "role", "epoch", "lease", "cancel"])
def test_current_completion_fence_refuses_registration_and_retains_files(
    reference_case, monkeypatch, changed
):
    case = reference_case
    identifier, root, lease, prepared = created_preparation(case, monkeypatch)
    before = io_fixture.snapshot(root)
    with prepared, Session(case.engine) as session:
        if changed == "owner":
            session.get(User, case.owner.user_id).enabled = False
        elif changed == "role":
            session.execute(delete(AdminRole).where(
                AdminRole.user_id == case.owner.user_id, AdminRole.role == "recovery_admin"
            ))
        elif changed == "epoch":
            session.get(ServerState, 1).sync_epoch = uuid4()
        elif changed == "lease":
            session.get(BackgroundJob, lease.job_id).lease_until = now() - timedelta(seconds=1)
        else:
            store.cancel(session, lease.job_id)
        session.flush()
        with pytest.raises((ApiError, store.LeaseLost)):
            finish(case, session, lease, prepared)
        session.rollback()
    with Session(case.engine) as session:
        assert count(session, BackupControl, identifier) == 0
        assert count(session, BackupHold, identifier) == 0
    assert io_fixture.snapshot(root) == before
