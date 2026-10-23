from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import delete, update
from sqlalchemy.orm import Session

from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import AdminRole, UserSession
from flowtrace_server.auth.service import issue_session
from flowtrace_server.jobs import administration, store
from flowtrace_server.jobs.models import WorkerState


def test_quarantine_metadata_requires_recovery_and_refuses_generic_queue_controls(queue_case):
    from flowtrace_server.auth.models import User
    from flowtrace_server.auth.service import PASSWORDS
    from flowtrace_server.jobs.models import BackgroundJob

    case = queue_case
    password = "Synthetic-quarantine-control-password"
    job_id = case.enqueue(kind="backup_quarantine", payload={"fixture": True})
    with Session(case.engine) as session, session.begin():
        user = session.get(User, case.owner_id)
        user.password_hash = PASSWORDS.hash(password)
        session.add(AdminRole(user_id=user.id, role="recovery_admin"))
        record, _ = issue_session(session, user, uuid4(), "Quarantine fixture", "admin")
        principal = Principal(user.id, record.id, record.client_id, "admin", frozenset())
    with Session(case.engine) as session:
        metadata = administration.get_job(session, principal, job_id)
        assert metadata["allowed_actions"] == []
        assert "payload" not in metadata and "fixture" not in str(metadata)
        assert "backup_quarantine" in administration.executable_kinds()
        assert [
            item["job_id"]
            for item in administration.list_jobs(session, principal)["items"]
            if item["owner_user_id"] == str(case.owner_id)
        ] == [str(job_id)]
        for action in ("retry", "cancel"):
            with pytest.raises(ApiError, match="backup_quarantine_control_required"):
                administration.control_job(
                    session, principal, job_id=job_id, action=action, password=password
                )
            assert session.get(BackgroundJob, job_id, populate_existing=True).status == "pending"
        session.execute(delete(AdminRole).where(AdminRole.user_id == case.owner_id))
        session.add(AdminRole(user_id=case.owner_id, role="service_admin"))
        session.flush()
        assert administration.get_job(session, principal, job_id)["allowed_actions"] == []
        with pytest.raises(ApiError, match="admin_recovery_required"):
            administration.control_job(
                session, principal, job_id=job_id, action="cancel", password=password
            )
        session.rollback()


def test_management_projection_uses_current_role_and_omits_payload(queue_case):
    case = queue_case
    secret = "fixture_job_body_not_a_management_field"
    export_id = case.enqueue(kind="export", payload={"private": secret})
    verification_id = case.enqueue(kind="backup_verify", payload={"backup_id": str(uuid4())})
    with Session(case.engine) as session, session.begin():
        from flowtrace_server.auth.models import User

        user = session.get(User, case.owner_id)
        session.add(AdminRole(user_id=user.id, role="recovery_admin"))
        record, _ = issue_session(session, user, uuid4(), "Queue fixture", "admin")
        principal = Principal(
            user.id, record.id, record.client_id, "admin", frozenset({"server_owner"})
        )
    with Session(case.engine) as session:
        result = administration.list_jobs(session, principal)
        assert [
            row["job_id"] for row in result["items"] if row["owner_user_id"] == str(case.owner_id)
        ] == [str(verification_id)]
        assert str(export_id) not in {row["job_id"] for row in result["items"]}
        assert all(row["kind"] in administration.RECOVERY_KINDS for row in result["items"])
        assert result["executable_kinds"] == [
            "backup_quarantine",
            "backup_verify",
            "import_apply",
            "import_preview",
        ]
        assert secret not in str(result)
        assert administration.get_job(session, principal, verification_id)["allowed_actions"] == [
            "cancel"
        ]
        for hidden_id in (export_id, uuid4()):
            with pytest.raises(ApiError) as error:
                administration.get_job(session, principal, hidden_id)
            assert error.value.status == 404
        session.add(AdminRole(user_id=case.owner_id, role="service_admin"))
        session.flush()
        result = administration.list_jobs(session, principal)
        assert {
            row["job_id"] for row in result["items"] if row["owner_user_id"] == str(case.owner_id)
        } == {str(verification_id), str(export_id)}
        assert administration.get_job(session, principal, export_id)["allowed_actions"] == [
            "cancel"
        ]
        with pytest.raises(ApiError) as error:
            administration.list_jobs(session, principal, kind="arbitrary_command")
        assert error.value.status == 422
        session.rollback()


def test_job_controls_are_current_capability_state_and_handler_aware(queue_case):
    case = queue_case
    verification_id = case.enqueue(kind="backup_verify", payload={"backup_id": str(uuid4())})
    export_id = case.enqueue(kind="export")
    with Session(case.engine) as session, session.begin():
        from flowtrace_server.auth.models import User

        user = session.get(User, case.owner_id)
        session.add(AdminRole(user_id=user.id, role="server_owner"))
        record, _ = issue_session(session, user, uuid4(), "Queue fixture", "admin")
        principal = Principal(
            user.id, record.id, record.client_id, "admin", frozenset({"recovery_admin"})
        )
    with Session(case.engine) as session:
        assert administration.get_job(session, principal, verification_id)["allowed_actions"] == []
        session.add(AdminRole(user_id=case.owner_id, role="recovery_admin"))
        session.flush()
        assert administration.get_job(session, principal, verification_id)["allowed_actions"] == [
            "cancel"
        ]
        from flowtrace_server.jobs.models import BackgroundJob

        for identifier in (verification_id, export_id):
            session.get(BackgroundJob, identifier).status = "failed"
        session.flush()
        assert administration.get_job(session, principal, verification_id)["allowed_actions"] == [
            "retry",
            "cancel",
        ]
        assert administration.get_job(session, principal, export_id)["allowed_actions"] == [
            "cancel"
        ]
        session.get(BackgroundJob, verification_id).status = "succeeded"
        session.flush()
        assert administration.get_job(session, principal, verification_id)["allowed_actions"] == []
        session.get(UserSession, principal.session_id).access_expires_at = store.stamp(
            session
        ) - timedelta(seconds=1)
        session.flush()
        with pytest.raises(ApiError) as error:
            administration.get_job(session, principal, verification_id)
        assert error.value.status == 401
    with Session(case.engine) as session:
        session.execute(delete(AdminRole).where(AdminRole.user_id == case.owner_id))
        with pytest.raises(ApiError) as error:
            administration.list_jobs(session, principal)
        assert error.value.status == 403
        session.rollback()


def test_worker_projection_is_actual_freshness_not_a_fake_online_flag(queue_case):
    case = queue_case
    with Session(case.engine) as session, session.begin():
        from flowtrace_server.auth.models import User

        user = session.get(User, case.owner_id)
        session.add(AdminRole(user_id=user.id, role="recovery_admin"))
        record, _ = issue_session(session, user, uuid4(), "Queue fixture", "admin")
        principal = Principal(user.id, record.id, record.client_id, "admin", frozenset())
        fresh_id, stale_id = case.worker_id(), case.worker_id()
        for identifier in (fresh_id, stale_id):
            store.heartbeat(session, identifier, version="0.1.0", supported_kinds={"backup_verify"})
        session.execute(
            update(WorkerState)
            .where(WorkerState.id == stale_id)
            .values(heartbeat_at=store.stamp(session) - timedelta(seconds=61))
        )
    with Session(case.engine) as session:
        projection = administration.list_workers(session, principal)
        records = {row["worker_id"]: row for row in projection}
        assert records[str(fresh_id)]["fresh"] is True
        assert records[str(stale_id)]["fresh"] is False
        assert all(
            set(row)
            == {
                "worker_id",
                "version",
                "supported_kinds",
                "started_at",
                "heartbeat_at",
                "fresh",
                "active_job_id",
            }
            for row in projection
        )
        session.get(UserSession, principal.session_id).revoked_at = store.stamp(session)
        session.flush()
        with pytest.raises(ApiError) as error:
            administration.list_workers(session, principal)
        assert error.value.status == 401


def test_backup_create_command_is_current_recovery_idempotent_and_caller_owned(
    queue_case, tmp_path
):
    from sqlalchemy import func, select
    from sqlalchemy.dialects.postgresql import insert

    from flowtrace_server.admin.models import AdminAudit, AdminControl
    from flowtrace_server.auth.models import User
    from flowtrace_server.auth.service import PASSWORDS
    from flowtrace_server.config import Settings
    from flowtrace_server.jobs.models import BackgroundJob

    case = queue_case
    executable = tmp_path / "trusted-test-tool-not-executed.exe"
    executable.write_bytes(b"test existence only; never execute")
    settings = Settings(_env_file=None, pg_dump_executable=executable)
    password = "Backup-creation-test-password-2026"
    request_id = uuid4()
    with Session(case.engine) as session:
        session.execute(insert(AdminControl).values(id=1).on_conflict_do_nothing())
        user = session.get(User, case.owner_id)
        user.password_hash = PASSWORDS.hash(password)
        session.add(AdminRole(user_id=user.id, role="recovery_admin"))
        record, _ = issue_session(session, user, uuid4(), "backup creation fixture", "admin")
        principal = Principal(user.id, record.id, record.client_id, "admin", frozenset())
        first = administration.enqueue_backup_creation(
            session, principal, settings, request_id=request_id, password=password
        )
        repeated = administration.enqueue_backup_creation(
            session, principal, settings, request_id=request_id, password=password
        )
        assert first == repeated and first["kind"] == "backup_create"
        job_id = first["job_id"]
        job = session.get(BackgroundJob, UUID(job_id))
        assert set(job.payload) == {"backup_id"}
        assert str(executable) not in str(first)
        assert administration.list_jobs(session, principal, settings=settings)[
            "executable_kinds"
        ] == [
            "backup_create",
            "backup_quarantine",
            "backup_verify",
            "import_apply",
            "import_preview",
        ]
        job.status = "failed"
        session.flush()
        assert administration.get_job(session, principal, UUID(job_id))["allowed_actions"] == [
            "cancel"
        ]
        assert administration.get_job(session, principal, UUID(job_id), settings=settings)[
            "allowed_actions"
        ] == ["retry", "cancel"]
        with pytest.raises(ApiError) as error:
            administration.control_job(
                session, principal, job_id=UUID(job_id), action="retry", password=password
            )
        assert error.value.code == "job_handler_unavailable"
        assert (
            session.scalar(
                select(func.count())
                .select_from(AdminAudit)
                .where(
                    AdminAudit.actor_id == principal.user_id,
                    AdminAudit.action == "job.backup_create_enqueue",
                )
            )
            == 1
        )
        for actual_settings, actual_password, expected in (
            (settings, "wrong-password-123", "reauthentication_failed"),
            (Settings(_env_file=None), password, "backup_tool_unavailable"),
        ):
            with pytest.raises(ApiError) as error:
                administration.enqueue_backup_creation(
                    session,
                    principal,
                    actual_settings,
                    request_id=uuid4(),
                    password=actual_password,
                )
            assert error.value.code == expected
        session.execute(delete(AdminRole).where(AdminRole.user_id == principal.user_id))
        with pytest.raises(ApiError) as error:
            administration.enqueue_backup_creation(
                session, principal, settings, request_id=uuid4(), password=password
            )
        assert error.value.code == "admin_forbidden"
        session.add(AdminRole(user_id=principal.user_id, role="service_admin"))
        session.flush()
        with pytest.raises(ApiError) as error:
            administration.enqueue_backup_creation(
                session, principal, settings, request_id=uuid4(), password=password
            )
        assert error.value.code == "admin_recovery_required"
        session.rollback()
    with Session(case.engine) as session:
        assert session.get(BackgroundJob, UUID(job_id)) is None
