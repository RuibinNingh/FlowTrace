"""Current real admin authority, CAS and competing metadata transactions.

Only fresh UUID fixtures are created. Reservation setup below is explicit SQL
metadata for a race test, not a quarantine handler or a backup file operation.
"""

from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout
from datetime import timedelta
from types import SimpleNamespace
from uuid import uuid4

import pytest
from sqlalchemy import delete, func, select, text, update
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.admin.service import bootstrap_admin
from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import AdminRole, User, UserSession
from flowtrace_server.auth.service import create_user, issue_session, now
from flowtrace_server.backups import retention
from flowtrace_server.backups.retention_models import (
    BackupControl,
    BackupHold,
    BackupPin,
    BackupRetentionIntent,
)
from flowtrace_server.backups.retention_schemas import (
    HoldCreateCommand,
    HoldReleaseCommand,
    PinCreateCommand,
    PinReleaseCommand,
    RetentionSelection,
)
from flowtrace_server.config import Settings
from flowtrace_server.configuration.runtime import read_runtime_configuration
from flowtrace_server.jobs import store as jobs
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.persistence.models import ServerState

from .test_retention_io import package, snapshot

pytestmark = pytest.mark.postgres
PASSWORD = "Synthetic-retention-password-2026"


def principal(session, user, purpose="admin"):
    record, _ = issue_session(session, user, uuid4(), "隔离保留策略测试", purpose)
    return Principal(user.id, record.id, record.client_id, record.purpose, frozenset())


@pytest.fixture(scope="module")
def system(postgres_engine, tmp_path_factory):
    with Session(postgres_engine, expire_on_commit=False) as session:
        owner = bootstrap_admin(session, "retention_" + uuid4().hex, PASSWORD)
        service = create_user(session, "service_" + uuid4().hex, PASSWORD)
        recovery = create_user(session, "recovery_" + uuid4().hex, PASSWORD)
        session.add_all(
            [
                AdminRole(user_id=service.id, role="service_admin"),
                AdminRole(user_id=recovery.id, role="recovery_admin"),
            ]
        )
        result = SimpleNamespace(
            owner=principal(session, owner),
            service=principal(session, service),
            recovery=principal(session, recovery),
            engine=postgres_engine,
        )
        session.commit()
    result.settings = Settings(
        _env_file=None,
        environment="test",
        diagnostics_enabled=False,
        database_url=postgres_engine.url.render_as_string(hide_password=False),
        data_directory=tmp_path_factory.mktemp("retention-service-uuid-"),
    )
    try:
        yield result
    finally:
        owned = [result.owner.user_id, result.service.user_id, result.recovery.user_id]
        with Session(postgres_engine) as session, session.begin():
            # Keep immutable control/hold/intent FKs and actual actors. End only
            # this fixture's authority so another module may bootstrap cleanly.
            active = list(session.scalars(select(BackgroundJob.id).where(
                BackgroundJob.owner_user_id.in_(owned),
                BackgroundJob.status.in_(("pending", "running", "retry_wait")),
            )))
            for identifier in active:
                jobs.cancel(session, identifier)
            session.execute(delete(AdminRole).where(AdminRole.user_id.in_(owned)))
            session.execute(update(UserSession).where(
                UserSession.user_id.in_(owned), UserSession.revoked_at.is_(None),
            ).values(revoked_at=now()))


def registered(system, *, old=True):
    with Session(system.engine) as session:
        instance, epoch = retention._source(session)
    identifier, root, _ = package(
        system.settings,
        instance=instance,
        epoch=epoch,
        created_at=now() - timedelta(days=40) if old else now(),
    )
    with retention.prepare_registration(system.settings, identifier) as prepared:
        with Session(system.engine) as session:
            stamp = retention.register_verified_backup(
                session, system.owner, system.settings, prepared=prepared, password=PASSWORD
            )
            session.commit()
    return identifier, root, stamp


def count_audit(session, action, target):
    return session.scalar(
        select(func.count())
        .select_from(AdminAudit)
        .where(AdminAudit.action == action, AdminAudit.target_id == target)
    )


def new_job(session, owner, backup_id, *, kind="backup_verify"):
    return jobs.enqueue(
        session,
        kind=kind,
        occurrence_key="retention-service:" + uuid4().hex,
        owner_user_id=owner.user_id,
        payload={"backup_id": str(backup_id)},
    )


def test_current_registration_replays_without_replacing_control_or_audit(system):
    identifier, root, original = registered(system)
    before = snapshot(root)
    with retention.prepare_registration(system.settings, identifier) as prepared:
        with Session(system.engine) as session:
            assert (
                retention.register_verified_backup(
                    session, system.owner, system.settings, prepared=prepared, password=PASSWORD
                )
                == original
            )
            session.commit()
            assert count_audit(session, "backup.register", identifier) == 1
        prepared.close()
        with Session(system.engine) as session, pytest.raises(ApiError) as caught:
            retention.register_verified_backup(
                session, system.owner, system.settings, prepared=prepared, password=PASSWORD
            )
        assert caught.value.code == "backup_registration_invalid"
    assert snapshot(root) == before


@pytest.mark.parametrize(
    "actor,password,code",
    (
        ("service", PASSWORD, "admin_recovery_required"),
        ("owner", "wrong-synthetic-password", "reauthentication_failed"),
    ),
)
def test_registration_replay_requires_current_role_and_current_password(
    system, actor, password, code
):
    identifier, _, _ = registered(system)
    with retention.prepare_registration(system.settings, identifier) as prepared:
        with Session(system.engine) as session, pytest.raises(ApiError) as caught:
            retention.register_verified_backup(
                session,
                getattr(system, actor),
                system.settings,
                prepared=prepared,
                password=password,
            )
        assert caught.value.code == code


def test_pin_create_release_exact_replay_and_changed_request_hash(system):
    identifier, _, _ = registered(system)
    create = PinCreateCommand(
        pin_id=uuid4(), backup_id=identifier, expected_control_version=1, request_id=uuid4()
    )
    with Session(system.engine, expire_on_commit=False) as session:
        first = retention.create_backup_pin(
            session, system.owner, command=create, password=PASSWORD
        )
        session.commit()
        assert first["control_version"] == 2 and first["active"]
        assert (
            retention.create_backup_pin(session, system.owner, command=create, password=PASSWORD)
            == first
        )
        session.commit()
        assert count_audit(session, "backup.pin_create", create.pin_id) == 1
    with Session(system.engine) as session, pytest.raises(ApiError) as caught:
        retention.create_backup_pin(
            session,
            system.owner,
            command=create.model_copy(update={"expected_control_version": 2}),
            password=PASSWORD,
        )
    assert caught.value.code == "backup_request_conflict"
    release = PinReleaseCommand(
        pin_id=create.pin_id, expected_pin_version=1, expected_control_version=2, request_id=uuid4()
    )
    with Session(system.engine) as session:
        result = retention.release_backup_pin(
            session, system.owner, command=release, password=PASSWORD
        )
        session.commit()
        assert result["version"] == 2 and result["control_version"] == 3 and not result["active"]
        assert (
            retention.release_backup_pin(session, system.owner, command=release, password=PASSWORD)
            == result
        )
        session.commit()
        assert count_audit(session, "backup.pin_release", create.pin_id) == 1


def test_long_session_replay_observes_another_connection_release_without_resurrection(system):
    identifier, _, _ = registered(system)
    create = PinCreateCommand(
        pin_id=uuid4(), backup_id=identifier, expected_control_version=1, request_id=uuid4()
    )
    with Session(system.engine, expire_on_commit=False) as original:
        retention.create_backup_pin(original, system.owner, command=create, password=PASSWORD)
        original.commit()
        loaded = original.get(BackupPin, create.pin_id)
        assert loaded.version == 1
        original.commit()
        with Session(system.engine) as second:
            retention.release_backup_pin(
                second,
                system.owner,
                command=PinReleaseCommand(
                    pin_id=create.pin_id,
                    expected_pin_version=1,
                    expected_control_version=2,
                    request_id=uuid4(),
                ),
                password=PASSWORD,
            )
            second.commit()
        result = retention.create_backup_pin(
            original, system.owner, command=create, password=PASSWORD
        )
        original.commit()
        assert result["version"] == 2 and result["control_version"] == 3 and not result["active"]
        assert loaded.version == 2
        assert count_audit(original, "backup.pin_create", create.pin_id) == 1


def test_current_expired_session_and_removed_role_cannot_replay_existing_pin(system):
    identifier, _, _ = registered(system)
    create = PinCreateCommand(
        pin_id=uuid4(), backup_id=identifier, expected_control_version=1, request_id=uuid4()
    )
    with Session(system.engine) as session:
        retention.create_backup_pin(session, system.owner, command=create, password=PASSWORD)
        session.commit()
    # A real independent session record is explicitly expired, not a forged Principal.
    with Session(system.engine) as session:
        user = session.get(User, system.owner.user_id)
        expired = principal(session, user)
        session.flush()
        session.get(UserSession, expired.session_id).access_expires_at = now() - timedelta(
            seconds=1
        )
        session.commit()
    with Session(system.engine) as session, pytest.raises(ApiError) as caught:
        retention.create_backup_pin(session, expired, command=create, password=PASSWORD)
    assert caught.value.code == "session_invalid"
    with Session(system.engine) as session:
        role = session.get(AdminRole, (system.owner.user_id, "recovery_admin"))
        session.delete(role)
        session.commit()
    try:
        with Session(system.engine) as session, pytest.raises(ApiError) as caught:
            retention.create_backup_pin(session, system.owner, command=create, password=PASSWORD)
        assert caught.value.code == "admin_recovery_required"
    finally:
        with Session(system.engine) as session:
            session.add(AdminRole(user_id=system.owner.user_id, role="recovery_admin"))
            session.commit()


def test_job_hold_requires_actual_job_binding_terminal_proof_and_replays_once(system):
    identifier, _, _ = registered(system)
    with Session(system.engine) as session:
        job = new_job(session, system.owner, identifier)
        job_id = job.id
        session.commit()
    create = HoldCreateCommand(
        hold_id=uuid4(),
        backup_id=identifier,
        expected_control_version=1,
        holder_kind="job",
        holder_id=job_id,
        job_id=job_id,
    )
    with Session(system.engine) as session:
        result = retention.create_backup_hold(
            session, system.owner, command=create, password=PASSWORD
        )
        session.commit()
        assert result["version"] == 1 and result["control_version"] == 2
        assert (
            retention.create_backup_hold(session, system.owner, command=create, password=PASSWORD)
            == result
        )
        session.commit()
    release = HoldReleaseCommand(
        hold_id=create.hold_id,
        expected_hold_version=1,
        expected_control_version=2,
        proof="job_terminal_verified",
    )
    with Session(system.engine) as session, pytest.raises(ApiError) as caught:
        retention.release_backup_hold(session, system.owner, command=release, password=PASSWORD)
    assert caught.value.code == "backup_hold_job_active"
    with Session(system.engine) as session:
        jobs.cancel(session, job_id)
        session.commit()
    with Session(system.engine, expire_on_commit=False) as session:
        result = retention.release_backup_hold(
            session, system.owner, command=release, password=PASSWORD
        )
        session.commit()
        assert result["version"] == 2 and result["control_version"] == 3
        assert (
            retention.release_backup_hold(session, system.owner, command=release, password=PASSWORD)
            == result
        )
        session.commit()
        assert count_audit(session, "backup.hold_create", create.hold_id) == 1
        assert count_audit(session, "backup.hold_release", create.hold_id) == 1


def test_download_proof_string_and_restore_intent_are_not_released_as_user_assertions(system):
    identifier, _, _ = registered(system)
    create = HoldCreateCommand(
        hold_id=uuid4(),
        backup_id=identifier,
        expected_control_version=1,
        holder_kind="download",
        holder_id=uuid4(),
    )
    with Session(system.engine) as session:
        retention.create_backup_hold(session, system.owner, command=create, password=PASSWORD)
        session.commit()
    for proof in ("archive_built", "explicit_reconcile"):
        with Session(system.engine) as session, pytest.raises(ApiError) as caught:
            retention.release_backup_hold(
                session,
                system.owner,
                command=HoldReleaseCommand(
                    hold_id=create.hold_id,
                    expected_hold_version=1,
                    expected_control_version=2,
                    proof=proof,
                ),
                password=PASSWORD,
            )
        assert caught.value.code == "backup_hold_proof_unavailable"


def test_registered_old_epoch_backup_remains_readable_and_source_bytes_are_not_rewritten(system):
    identifier, root, stamp = registered(system)
    before = snapshot(root)
    with Session(system.engine) as session:
        original = session.get(ServerState, 1).sync_epoch
        session.get(ServerState, 1).sync_epoch = uuid4()
        session.commit()
    try:
        with Session(system.engine) as session:
            guarded = retention.require_backup_readable(session, identifier)
            session.commit()
            assert guarded.registered and guarded.stamp.sync_epoch == stamp.sync_epoch
            assert retention.require_backup_readable(session, uuid4()) == retention.BackupReadGuard(
                False, None
            )
    finally:
        with Session(system.engine) as session:
            session.get(ServerState, 1).sync_epoch = original
            session.commit()
    assert snapshot(root) == before


def test_zero_delete_preview_binds_real_configuration_and_rejects_late_new_pin(system):
    selected, root, _ = registered(system)
    registered(system, old=False)  # Fresh unselected recovery witness.
    before = snapshot(root)
    with Session(system.engine, expire_on_commit=False) as session:
        version = read_runtime_configuration(session).version
        selection = RetentionSelection(
            backup_ids=(selected,), request_id=uuid4(), expected_config_version=version
        )
        authority = retention.precheck_retention_request(
            session, system.owner, selection=selection, password=PASSWORD
        )
        session.commit()
        with retention.build_retention_preview(system.settings, authority=authority) as prepared:
            with Session(system.engine) as second:
                second.execute(text("SET LOCAL statement_timeout='2000ms'"))
                retention.create_backup_pin(
                    second,
                    system.owner,
                    command=PinCreateCommand(
                        pin_id=uuid4(),
                        backup_id=selected,
                        expected_control_version=1,
                        request_id=uuid4(),
                    ),
                    password=PASSWORD,
                )
                second.commit()
            with pytest.raises(ApiError) as caught:
                retention.authorize_retention_preview(
                    session, system.owner, system.settings, prepared=prepared, password=PASSWORD
                )
            assert caught.value.code == "backup_control_conflict"
            session.rollback()
            assert count_audit(session, "backup.retention_preview", prepared.record.preview_id) == 0
    assert snapshot(root) == before


def test_zero_delete_preview_succeeds_with_private_record_and_one_audit_only(system):
    selected, root, _ = registered(system)
    registered(system, old=False)
    before = snapshot(root)
    with Session(system.engine) as session:
        selection = RetentionSelection(
            backup_ids=(selected,),
            request_id=uuid4(),
            expected_config_version=read_runtime_configuration(session).version,
        )
        authority = retention.precheck_retention_request(
            session, system.owner, selection=selection, password=PASSWORD
        )
        session.commit()
        with retention.build_retention_preview(system.settings, authority=authority) as prepared:
            result = retention.authorize_retention_preview(
                session, system.owner, system.settings, prepared=prepared, password=PASSWORD
            )
            session.commit()
            assert result.config_version == selection.expected_config_version
            assert (
                retention.authorize_retention_preview(
                    session, system.owner, system.settings, prepared=prepared, password=PASSWORD
                )
                == result
            )
            session.commit()
            assert count_audit(session, "backup.retention_preview", result.preview_id) == 1
    assert snapshot(root) == before


def test_unregistered_catalog_is_protected_and_does_not_silently_register(system):
    with Session(system.engine) as session:
        instance, epoch = retention._source(session)
    identifier, root, _ = package(system.settings, instance=instance, epoch=epoch)
    before, cursor, found = snapshot(root), None, None
    with Session(system.engine) as session:
        for _ in range(100):
            result = retention.list_retention_candidates(
                session, system.owner, system.settings, before=cursor
            )
            found = next((item for item in result["items"] if item.backup_id == identifier), found)
            if not result["has_more"]:
                break
            cursor = result["next_cursor"]
        assert (
            found is not None
            and not found.eligible
            and found.protection_reasons == ("unregistered",)
        )
        assert session.get(BackupControl, identifier) is None
    assert snapshot(root) == before


def reservation_fixture(system, backup_id):
    with Session(system.engine) as session:
        control = session.get(BackupControl, backup_id)
        job = new_job(session, system.owner, backup_id)
        intent = BackupRetentionIntent(
            id=uuid4(),
            preview_id=uuid4(),
            actor_id=system.owner.user_id,
            origin_session_id=system.owner.session_id,
            request_id=uuid4(),
            request_hash="a" * 64,
            selection_sha256="b" * 64,
            config_version=read_runtime_configuration(session).version,
            source_instance_id=control.instance_id,
            source_epoch=control.sync_epoch,
            packages=[retention._stamp(control).model_dump(mode="json")],
            job_id=job.id,
        )
        session.add(intent)
        session.commit()
        return intent.id, job.id


def test_two_connections_reservation_closes_new_hold_and_read_gate_without_file_effect(system):
    identifier, root, _ = registered(system)
    intent_id, job_id = reservation_fixture(system, identifier)
    before = snapshot(root)
    command = HoldCreateCommand(
        hold_id=uuid4(),
        backup_id=identifier,
        expected_control_version=1,
        holder_kind="job",
        holder_id=job_id,
        job_id=job_id,
    )

    def create_competing_hold():
        with Session(system.engine) as session:
            try:
                retention.create_backup_hold(
                    session, system.owner, command=command, password=PASSWORD
                )
                session.commit()
                return "unexpected_success"
            except ApiError as error:
                return error.code

    with Session(system.engine) as reservation, ThreadPoolExecutor(max_workers=1) as executor:
        row = reservation.scalar(
            select(BackupControl).where(BackupControl.backup_id == identifier).with_for_update()
        )
        row.state, row.intent_id, row.version = "reserved", intent_id, 2
        reservation.flush()
        future = executor.submit(create_competing_hold)
        with pytest.raises(FutureTimeout):
            future.result(timeout=0.2)
        reservation.commit()
        assert future.result(timeout=5) == "backup_control_conflict"
    with Session(system.engine) as session:
        assert session.get(BackupHold, command.hold_id) is None
        with pytest.raises(ApiError) as caught:
            retention.require_backup_readable(session, identifier)
        assert caught.value.code == "backup_control_conflict"
    assert snapshot(root) == before


@pytest.mark.parametrize("change", ("settings", "source"))
def test_prepared_registration_cannot_cross_settings_or_source_fence(system, change):
    identifier, root, _ = registered(system)
    before = snapshot(root)
    with retention.prepare_registration(system.settings, identifier) as prepared:
        with Session(system.engine) as session, pytest.raises(ApiError) as caught:
            settings = system.settings
            if change == "settings":
                settings = settings.model_copy(
                    update={"data_directory": settings.data_directory / "other"}
                )
            else:
                session.get(ServerState, 1).sync_epoch = uuid4()
                session.flush()
            retention.register_verified_backup(
                session, system.owner, settings, prepared=prepared, password=PASSWORD
            )
        assert caught.value.code == (
            "backup_registration_invalid" if change == "settings" else "backup_source_changed"
        )
    assert snapshot(root) == before


def test_hold_cannot_bind_a_real_job_for_a_different_backup(system):
    identifier, _, _ = registered(system)
    other, _, _ = registered(system)
    with Session(system.engine) as session:
        job = new_job(session, system.owner, other)
        job_id = job.id
        session.commit()
    command = HoldCreateCommand(
        hold_id=uuid4(),
        backup_id=identifier,
        expected_control_version=1,
        holder_kind="job",
        holder_id=job_id,
        job_id=job_id,
    )
    with Session(system.engine) as session, pytest.raises(ApiError) as caught:
        retention.create_backup_hold(session, system.owner, command=command, password=PASSWORD)
    assert caught.value.code == "backup_hold_job_invalid"
    with Session(system.engine) as session:
        assert session.get(BackupHold, command.hold_id) is None
        assert session.get(BackupControl, identifier).version == 1


def test_long_session_hold_release_observes_existing_release_without_updating_version_two(system):
    identifier, _, _ = registered(system)
    with Session(system.engine) as session:
        job = new_job(session, system.owner, identifier)
        job_id = job.id
        command = HoldCreateCommand(
            hold_id=uuid4(),
            backup_id=identifier,
            expected_control_version=1,
            holder_kind="job",
            holder_id=job_id,
            job_id=job_id,
        )
        retention.create_backup_hold(session, system.owner, command=command, password=PASSWORD)
        session.commit()
        jobs.cancel(session, job_id)
        session.commit()
    release = HoldReleaseCommand(
        hold_id=command.hold_id,
        expected_hold_version=1,
        expected_control_version=2,
        proof="job_terminal_verified",
    )
    with Session(system.engine, expire_on_commit=False) as original:
        cached = original.get(BackupHold, command.hold_id)
        assert cached.version == 1
        original.commit()
        with Session(system.engine) as second:
            retention.release_backup_hold(second, system.owner, command=release, password=PASSWORD)
            second.commit()
        result = retention.release_backup_hold(
            original, system.owner, command=release, password=PASSWORD
        )
        original.commit()
        assert result["version"] == cached.version == 2
        assert result["control_version"] == 3
        assert count_audit(original, "backup.hold_release", command.hold_id) == 1


def test_preview_precheck_rejects_wrong_configuration_and_latest_recovery_point(system):
    latest, _, _ = registered(system, old=False)
    with Session(system.engine) as session:
        version = read_runtime_configuration(session).version
        with pytest.raises(ApiError) as caught:
            retention.precheck_retention_request(
                session,
                system.owner,
                selection=RetentionSelection(
                    backup_ids=(latest,), request_id=uuid4(), expected_config_version=version + 1
                ),
                password=PASSWORD,
            )
        assert caught.value.code == "backup_configuration_changed"
        with pytest.raises(ApiError) as caught:
            retention.precheck_retention_request(
                session,
                system.owner,
                selection=RetentionSelection(
                    backup_ids=(latest,), request_id=uuid4(), expected_config_version=version
                ),
                password=PASSWORD,
            )
        assert caught.value.code == "backup_selection_protected"
