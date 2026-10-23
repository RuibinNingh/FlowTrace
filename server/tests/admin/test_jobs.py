import re
from uuid import UUID, uuid4

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob, WorkerState

from .conftest import ORIGIN, PASSWORD, login
from .test_management import add_user


def enqueue(connection, owner_id, *, kind="backup_verify", payload=None, failed=False):
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        job = store.enqueue(
            session,
            kind=kind,
            occurrence_key=f"admin-fixture:{uuid4()}",
            owner_user_id=owner_id,
            payload=payload or {"backup_id": str(uuid4())},
        )
        job_id = job.id
        if failed:
            lease = store.claim(session, uuid4(), {kind})
            assert lease.job_id == job_id
            store.fail(session, lease, "fixture_failed", transient=False)
        session.commit()
    return job_id


def test_job_list_and_workers_only_display_real_safe_metadata(admin_system):
    client, connection, owner_id = admin_system
    secret = "fixture_private_job_payload"
    job_id = enqueue(connection, owner_id, payload={"private": secret})
    login(client)
    listing = client.get("/admin/jobs")
    assert listing.status_code == 200
    assert str(job_id) in listing.text and secret not in listing.text
    assert "当前可执行：" in listing.text and "备份校验" in listing.text
    assert "备份隔离" in listing.text and "导入预览" in listing.text and "导入执行" in listing.text
    assert "任务正文" in listing.text
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        worker_ids = list(
            session.scalars(
                select(WorkerState.id).order_by(WorkerState.heartbeat_at.desc()).limit(50)
            )
        )
    workers = client.get("/admin/workers")
    assert workers.status_code == 200 and secret not in workers.text
    overview = client.get("/admin/overview")
    assert overview.status_code == 200 and secret not in overview.text
    if worker_ids:
        assert all(str(identifier) in workers.text for identifier in worker_ids)
        assert f"最近最多{len(worker_ids)}个记录" in overview.text
    else:
        assert "尚无执行器记录" in workers.text and "尚无执行器记录" in overview.text
    for query in ("kind=command", "status=unknown", "before=not-a-uuid"):
        assert client.get("/admin/jobs?" + query).status_code == 422


def test_cancel_requires_csrf_target_confirmation_and_reauthentication(admin_system):
    client, connection, owner_id = admin_system
    job_id = enqueue(connection, owner_id)
    csrf = login(client)
    url = f"/admin/jobs/{job_id}/cancel"
    assert client.get(url).status_code == 200
    data = {"csrf_token": csrf, "confirm_target": str(job_id), "current_password": PASSWORD}
    assert client.post(url, data={**data, "csrf_token": "wrong"}, headers=ORIGIN).status_code == 403
    assert (
        client.post(url, data={**data, "confirm_target": str(uuid4())}, headers=ORIGIN).status_code
        == 403
    )
    denied = client.post(
        url, data={**data, "current_password": "wrong-password-fixture"}, headers=ORIGIN
    )
    assert denied.status_code == 403 and "当前管理密码验证失败" in denied.text
    assert 'value="wrong-password-fixture"' not in denied.text
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert session.get(BackgroundJob, job_id).status == "pending"
        failure = session.scalar(
            select(AdminAudit).where(
                AdminAudit.action == "job.cancel", AdminAudit.target_id == job_id
            )
        )
        assert failure.summary == {"succeeded": False, "status": 403}
    accepted = client.post(url, data=data, headers=ORIGIN, follow_redirects=False)
    assert accepted.status_code == 303
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert session.get(BackgroundJob, job_id).status == "cancelled"
    assert client.get(url).status_code == 409


def test_retry_uses_same_intent_and_cannot_repeat_from_pending(admin_system):
    client, connection, owner_id = admin_system
    job_id = enqueue(connection, owner_id, failed=True)
    csrf = login(client)
    url = f"/admin/jobs/{job_id}/retry"
    assert client.get(url).status_code == 200
    data = {"csrf_token": csrf, "confirm_target": str(job_id), "current_password": PASSWORD}
    assert client.post(url, data=data, headers=ORIGIN, follow_redirects=False).status_code == 303
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        job = session.get(BackgroundJob, job_id)
        assert job.status == "pending" and job.attempt == 0 and job.manual_retries == 1
        assert job.lease_generation == 1 and job.payload["backup_id"]
    assert client.post(url, data=data, headers=ORIGIN).status_code == 409


def test_recovery_portal_has_no_general_job_control_and_service_has_no_backup_control(admin_system):
    client, connection, owner_id = admin_system
    general_id = enqueue(connection, owner_id, kind="export")
    recovery_id = enqueue(connection, owner_id)
    add_user(connection, "job_recovery", ["recovery_admin"])
    csrf = login(client, "job_recovery")
    listing = client.get("/admin/jobs")
    assert str(recovery_id) in listing.text and str(general_id) not in listing.text
    assert client.get(f"/admin/jobs/{general_id}/cancel").status_code == 404
    assert client.get("/admin/jobs/backup-verify").status_code == 200
    add_user(connection, "job_service", ["service_admin"])
    csrf = login(client, "job_service")
    assert client.get("/admin/jobs/backup-verify").status_code == 403
    assert client.get(f"/admin/jobs/{recovery_id}/cancel").status_code == 409
    assert (
        client.post(
            f"/admin/jobs/{recovery_id}/cancel",
            data={
                "csrf_token": csrf,
                "confirm_target": str(recovery_id),
                "current_password": PASSWORD,
            },
            headers=ORIGIN,
        ).status_code
        == 403
    )


def test_backup_verification_preview_reauth_and_repeated_request_are_safe(admin_system):
    client, connection, owner_id = admin_system
    csrf = login(client)
    backup_id = uuid4()
    url = "/admin/jobs/backup-verify"
    preview = client.post(
        url, data={"csrf_token": csrf, "backup_id": str(backup_id)}, headers=ORIGIN
    )
    assert preview.status_code == 200 and "确认校验备份" in preview.text
    request_id = UUID(re.search(r'name="request_id" value="([^"]+)"', preview.text).group(1))
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert (
            session.scalar(
                select(func.count())
                .select_from(BackgroundJob)
                .where(BackgroundJob.owner_user_id == owner_id)
            )
            == 0
        )
    data = {
        "csrf_token": csrf,
        "backup_id": str(backup_id),
        "confirm_target": str(backup_id),
        "request_id": str(request_id),
        "current_password": "wrong-password-fixture",
    }
    assert client.post(url, data=data, headers=ORIGIN).status_code == 403
    data["current_password"] = PASSWORD
    for _ in range(2):
        assert (
            client.post(url, data=data, headers=ORIGIN, follow_redirects=False).status_code == 303
        )
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        jobs = list(
            session.scalars(select(BackgroundJob).where(BackgroundJob.owner_user_id == owner_id))
        )
        assert len(jobs) == 1 and jobs[0].owner_user_id == owner_id
        assert jobs[0].payload == {"backup_id": str(backup_id)} and jobs[0].status == "pending"
    other = uuid4()
    assert (
        client.post(
            url,
            data={**data, "backup_id": str(other), "confirm_target": str(other)},
            headers=ORIGIN,
        ).status_code
        == 409
    )
