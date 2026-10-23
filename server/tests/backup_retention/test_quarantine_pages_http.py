"""Ordinary management routes, real cookie/CSRF/PG and new temporary packages."""

import re
from uuid import UUID

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.backups.retention_models import BackupControl, BackupRetentionIntent
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.worker.runtime import Worker

from .test_pages_http import PASSWORD, form, make_package, post
from .test_pages_http import live_pages as live_pages
from .test_retention_io import snapshot

pytestmark = pytest.mark.postgres


def confirmation(case):
    selected = make_package(case, register=True)
    witness = make_package(case, age_days=0, register=True)
    catalog = case.client.get("/admin/backups/retention")
    fields = form(catalog, "/admin/backups/retention/preview")
    fields.append(("backup_ids", str(selected[0])))
    preview = post(case.client, "/admin/backups/retention/preview", fields)
    assert preview.status_code == 200, preview.text
    match = re.search(r'href="(/admin/backups/retention/[0-9a-f-]+/quarantine)"', preview.text)
    assert match is not None
    target = match.group(1)
    page = case.client.get(target)
    assert page.status_code == 200, page.text
    assert "确认隔离所选备份" in page.text and str(selected[0]) in page.text
    assert PASSWORD not in page.text
    return target, page, selected, witness


def counts(case):
    with Session(case.engine) as session:
        return (
            session.scalar(select(func.count()).select_from(BackupRetentionIntent)),
            session.scalar(
                select(func.count())
                .select_from(BackgroundJob)
                .where(
                    BackgroundJob.owner_user_id == case.owner_id,
                    BackgroundJob.kind == "backup_quarantine",
                )
            ),
        )


def test_explicit_real_cookie_submission_worker_completion_and_exact_post_replay(live_pages):
    case = live_pages
    target, page, selected, witness = confirmation(case)
    backup_id, root, _ = selected
    original, witness_before = snapshot(root), snapshot(witness[1])
    fields = form(page, target)
    response = post(case.client, target, fields)
    assert response.status_code == 303, response.text
    job_id = UUID(response.headers["location"].split("#job-", 1)[1])
    assert snapshot(root) == original  # Enqueue is not a file effect.
    with Session(case.engine) as session:
        row = session.get(BackupControl, backup_id)
        assert row.state == "reserved" and row.version == 2
        intent_id = row.intent_id
        assert session.get(BackgroundJob, job_id).status == "pending"
    worker = Worker(case.engine, case.settings)
    try:
        # Other test cases deliberately retain pending jobs and their files.
        # Exercise the real queue without accidentally claiming those cases.
        with Session(case.engine) as blockers, blockers.begin():
            list(
                blockers.scalars(
                    select(BackgroundJob).where(BackgroundJob.id != job_id).with_for_update()
                )
            )
            assert worker.run_once()
    finally:
        worker.close()
    destination = case.settings.data_directory / "backup-quarantine" / str(intent_id)
    assert not root.exists()
    assert snapshot(destination / "backups" / str(backup_id)) == original
    assert snapshot(witness[1]) == witness_before
    with Session(case.engine) as session:
        row = session.get(BackupControl, backup_id)
        assert row.state == "quarantined" and row.version == 3
        assert session.get(BackgroundJob, job_id).status == "succeeded"
        assert (
            session.scalar(
                select(func.count())
                .select_from(AdminAudit)
                .where(
                    AdminAudit.action == "backup.quarantine_complete",
                    AdminAudit.target_id == intent_id,
                )
            )
            == 1
        )
    before = counts(case)
    replay = post(case.client, target, fields)
    assert replay.status_code == 303 and replay.headers["location"] == response.headers["location"]
    assert counts(case) == before
    detail = case.client.get(response.headers["location"])
    assert detail.status_code == 200 and "备份隔离" in detail.text
    assert str(job_id) in detail.text
    assert f"/admin/jobs/{job_id}/cancel" not in detail.text
    assert f"/admin/jobs/{job_id}/retry" not in detail.text
    assert "backup-quarantine" not in detail.text and PASSWORD not in detail.text


@pytest.mark.parametrize("mutation", ["csrf", "origin", "password", "extra", "selection"])
def test_changed_confirmation_or_session_form_never_reserves_or_moves(live_pages, mutation):
    case = live_pages
    target, page, selected, witness = confirmation(case)
    original, witness_before = snapshot(selected[1]), snapshot(witness[1])
    before = counts(case)
    fields = form(page, target)
    if mutation == "extra":
        fields.append(("directory", "private-sentinel"))
    elif mutation in {"csrf", "password", "selection"}:
        key, value = {
            "csrf": ("csrf_token", "wrong-csrf"),
            "password": ("current_password", "Wrong-synthetic-password-2026"),
            "selection": ("selection_sha256", "f" * 64),
        }[mutation]
        fields = [(name, value if name == key else item) for name, item in fields]
    if mutation == "origin":
        response = case.client.post(
            target, data=dict(fields), headers={"origin": "http://other.invalid"}
        )
    else:
        response = post(case.client, target, fields)
    assert response.status_code in {403, 422}, response.text
    assert counts(case) == before
    assert snapshot(selected[1]) == original and snapshot(witness[1]) == witness_before
    assert PASSWORD not in response.text and "private-sentinel" not in response.text
    with Session(case.engine) as session:
        control = session.get(BackupControl, selected[0])
        assert control.state == "available" and control.version == 1 and control.intent_id is None
