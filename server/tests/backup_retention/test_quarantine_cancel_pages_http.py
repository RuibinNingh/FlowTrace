"""Ordinary cookie/CSRF pages for the never-claimed cancellation only."""

from uuid import UUID, uuid4

import pytest
from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.auth.models import AdminRole
from flowtrace_server.backups import retention
from flowtrace_server.backups.quarantine_cancel import CODE
from flowtrace_server.backups.retention_models import BackupControl, BackupRetentionIntent
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob

from .test_pages_http import PASSWORD, form, post
from .test_pages_http import live_pages as live_pages
from .test_quarantine_pages_http import confirmation
from .test_retention_io import snapshot

pytestmark = pytest.mark.postgres


def pending(case):
    original_target, page, selected, witness = confirmation(case)
    original_fields = form(page, original_target)
    submitted = post(case.client, original_target, original_fields)
    assert submitted.status_code == 303, submitted.text
    job_id = UUID(submitted.headers["location"].split("#job-", 1)[1])
    target = f"/admin/backups/retention/jobs/{job_id}/cancel-unclaimed"
    listed = case.client.get("/admin/jobs?kind=backup_quarantine")
    assert listed.status_code == 200 and f'href="{target}"' in listed.text
    assert f'href="/admin/jobs/{job_id}/cancel"' not in listed.text
    page = case.client.get(target)
    assert page.status_code == 200 and "取消尚未领取的隔离" in page.text
    assert PASSWORD not in page.text
    return job_id, target, form(page, target), selected, witness, original_target, original_fields


def reserved(case, job_id, backup_id):
    with Session(case.engine) as session:
        job = session.get(BackgroundJob, job_id)
        control = session.get(BackupControl, backup_id)
        assert job.status == "pending" and job.attempt == 0 and job.lease_generation == 0
        assert job.result is None and job.error_code is None
        assert control.state == "reserved" and control.version == 2


def test_cookie_cancel_releases_only_reservation_and_exact_replay_has_no_file_work(
    live_pages, monkeypatch
):
    case = live_pages
    job_id, target, fields, selected, witness, original_target, original_fields = pending(case)
    original, witness_before = snapshot(selected[1]), snapshot(witness[1])
    with Session(case.engine) as session:
        intent_id = session.get(BackupControl, selected[0]).intent_id
        intent_bytes = dict(session.get(BackupRetentionIntent, intent_id).packages[0])
    response = post(case.client, target, fields)
    assert response.status_code == 303, response.text
    assert response.headers["location"] == f"/admin/jobs?kind=backup_quarantine#job-{job_id}"
    assert snapshot(selected[1]) == original and snapshot(witness[1]) == witness_before
    assert not (case.settings.data_directory / "backup-quarantine" / str(intent_id)).exists()
    with Session(case.engine) as session:
        job = session.get(BackgroundJob, job_id)
        result = dict(job.result)
        assert job.status == "cancelled" and job.error_code == CODE
        assert job.attempt == 0 and job.lease_generation == 0
        control = session.get(BackupControl, selected[0])
        assert control.state == "available" and control.version == 3 and control.intent_id is None
        assert session.get(BackupRetentionIntent, intent_id).packages[0] == intent_bytes

    def must_not_hash(*args, **kwargs):
        raise AssertionError("exact metadata replay performed file work")

    monkeypatch.setattr(retention, "_verify_stamp", must_not_hash)
    replay = post(case.client, target, fields)
    assert replay.status_code == 303 and replay.headers["location"] == response.headers["location"]
    # Finding the original submission after cancellation must not enqueue again.
    old_submission = post(case.client, original_target, original_fields)
    assert old_submission.status_code == 303
    assert old_submission.headers["location"] == response.headers["location"]
    with Session(case.engine) as session:
        assert session.get(BackgroundJob, job_id).result == result
        assert (
            session.scalar(
                select(func.count())
                .select_from(AdminAudit)
                .where(
                    AdminAudit.action == "backup.quarantine_cancel_unclaimed",
                    AdminAudit.target_id == intent_id,
                )
            )
            == 1
        )
    completed = case.client.get(response.headers["location"])
    assert CODE in completed.text and f'href="{target}"' not in completed.text


@pytest.mark.parametrize(
    "mutation", ["csrf", "origin", "password", "extra", "selection", "generation", "request"]
)
def test_closed_form_auth_and_original_binding_reject_without_release(live_pages, mutation):
    case = live_pages
    job_id, target, fields, selected, witness, *_ = pending(case)
    original, witness_before = snapshot(selected[1]), snapshot(witness[1])
    if mutation == "extra":
        fields.append(("directory", "private-sentinel"))
    elif mutation != "origin":
        key, value = {
            "csrf": ("csrf_token", "wrong-csrf"),
            "password": ("current_password", "Wrong-synthetic-password-2026"),
            "selection": ("selection_sha256", "f" * 64),
            "generation": ("expected_generation", "1"),
            "request": ("request_id", "not-an-id"),
        }[mutation]
        fields = [(name, value if name == key else item) for name, item in fields]
    response = (
        case.client.post(target, data=dict(fields), headers={"origin": "http://other.invalid"})
        if mutation == "origin"
        else post(case.client, target, fields)
    )
    assert response.status_code in {403, 409, 422}, response.text
    assert PASSWORD not in response.text and "private-sentinel" not in response.text
    reserved(case, job_id, selected[0])
    assert snapshot(selected[1]) == original and snapshot(witness[1]) == witness_before


@pytest.mark.parametrize("guard", ["claimed", "empty_intent_directory", "recovery_revoked"])
def test_changed_claim_file_effect_or_current_role_cannot_cancel(live_pages, guard):
    case = live_pages
    job_id, target, fields, selected, witness, *_ = pending(case)
    original, witness_before = snapshot(selected[1]), snapshot(witness[1])
    if guard == "claimed":
        # Hold unrelated pending rows so the actual SKIP LOCKED claim is exact.
        with Session(case.engine) as blockers, blockers.begin():
            list(
                blockers.scalars(
                    select(BackgroundJob).where(BackgroundJob.id != job_id).with_for_update()
                )
            )
            with Session(case.engine) as session, session.begin():
                lease = store.claim(session, uuid4(), {"backup_quarantine"})
                assert lease.job_id == job_id
    elif guard == "empty_intent_directory":
        with Session(case.engine) as session:
            intent = session.get(BackupControl, selected[0]).intent_id
        (case.settings.data_directory / "backup-quarantine" / str(intent)).mkdir(parents=True)
    else:
        with Session(case.engine) as session, session.begin():
            session.execute(
                delete(AdminRole).where(
                    AdminRole.user_id == case.owner_id, AdminRole.role == "recovery_admin"
                )
            )
    response = post(case.client, target, fields)
    assert response.status_code in {403, 409}, response.text
    with Session(case.engine) as session:
        control = session.get(BackupControl, selected[0])
        assert control.state == "reserved" and control.version == 2
        assert session.get(BackgroundJob, job_id).status != "cancelled"
    assert snapshot(selected[1]) == original and snapshot(witness[1]) == witness_before
    if guard == "claimed":
        listed = case.client.get("/admin/jobs?kind=backup_quarantine")
        assert f'href="{target}"' not in listed.text
