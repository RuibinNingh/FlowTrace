from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from configuration.conftest import PASSWORD
from configuration.conftest import config_system as config_system
from sqlalchemy import delete, func, select, text
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import AdminRole
from flowtrace_server.auth.service import now
from flowtrace_server.backups import rehearsal
from flowtrace_server.jobs.models import BackgroundJob

from .test_boundaries import isolated_definition as isolated_definition


def build(config_system, isolated_definition, monkeypatch):
    session, principal = config_system
    settings, target_id, _ = isolated_definition
    authority = rehearsal.precheck_restore_request(session, principal, PASSWORD)
    session.commit()  # The route owns this explicit read-only phase boundary.
    monkeypatch.setattr(rehearsal, "_verified_manifest", lambda *args, **kwargs: ({}, "a" * 64))
    monkeypatch.setattr(rehearsal, "_probe_empty", lambda *args: ("b" * 64, "c" * 64))
    prepared = rehearsal.build_restore_preview(
        settings, authority=authority, backup_id=uuid4(), target_id=target_id
    )
    return session, principal, settings, prepared


def test_public_preview_current_recovery_and_password_are_independent_of_private_preparation(
    config_system, isolated_definition, monkeypatch
):
    session, principal, settings, prepared = build(config_system, isolated_definition, monkeypatch)
    denied = "Incorrect-current-password-fixture"
    with pytest.raises(ApiError) as caught:
        rehearsal.authorize_restore_preview(session, principal, settings, prepared, denied)
    assert caught.value.code == "reauthentication_failed"
    result = rehearsal.authorize_restore_preview(session, principal, settings, prepared, PASSWORD)
    assert result.target_empty and "postgresql" not in result.model_dump_json()
    assert (
        "fingerprint" not in result.model_dump_json()
        and "directory" not in result.model_dump_json()
    )
    session.execute(
        delete(AdminRole).where(
            AdminRole.user_id == principal.user_id, AdminRole.role == "recovery_admin"
        )
    )
    with pytest.raises(ApiError) as caught:
        rehearsal.authorize_restore_preview(session, principal, settings, prepared, PASSWORD)
    assert caught.value.code == "admin_recovery_required"


def test_final_configuration_share_lock_lasts_until_caller_rollback(
    config_system, isolated_definition, monkeypatch, postgres_engine
):
    session, principal, settings, prepared = build(config_system, isolated_definition, monkeypatch)
    rehearsal.authorize_restore_preview(session, principal, settings, prepared, PASSWORD)
    with Session(postgres_engine) as competing:
        competing.execute(text("SET LOCAL lock_timeout='250ms'"))
        with pytest.raises(OperationalError) as caught:
            competing.execute(
                text("UPDATE service_configuration SET current_version=current_version")
            )
        assert caught.value.orig.sqlstate == "55P03"
        competing.rollback()
        session.rollback()
        competing.execute(text("SET LOCAL lock_timeout='250ms'"))
        competing.execute(text("UPDATE service_configuration SET current_version=current_version"))
        competing.rollback()


def test_enqueue_is_single_target_intent_current_authenticated_and_caller_owned(
    config_system, isolated_definition, monkeypatch
):
    session, principal, settings, preview = build(config_system, isolated_definition, monkeypatch)
    rehearsal.authorize_restore_preview(session, principal, settings, preview, PASSWORD)
    session.commit()
    with rehearsal.prepare_restore_submission(
        settings,
        owner_user_id=principal.user_id,
        session_id=principal.session_id,
        preview_id=preview.record.preview_id,
    ) as prepared:
        first = rehearsal.enqueue_restore_rehearsal(
            session, principal, settings, prepared=prepared, password=PASSWORD
        )
        repeated = rehearsal.enqueue_restore_rehearsal(
            session, principal, settings, prepared=prepared, password=PASSWORD
        )
        assert first == repeated
        own_jobs = select(func.count()).select_from(BackgroundJob).where(
            BackgroundJob.owner_user_id == principal.user_id
        )
        assert session.scalar(own_jobs) == 1
        assert (
            session.scalar(
                select(func.count())
                .select_from(AdminAudit)
                .where(
                    AdminAudit.action == "restore.enqueue",
                    AdminAudit.actor_id == principal.user_id,
                )
            )
            == 1
        )
        assert "postgresql" not in str(first) and "payload" not in first
        session.rollback()
        assert session.scalar(own_jobs) == 0
    assert prepared.closed


def test_replay_expired_exact_intent_reads_metadata_without_target_io(
    config_system, isolated_definition, monkeypatch
):
    session, principal, settings, preview = build(config_system, isolated_definition, monkeypatch)
    with rehearsal.prepare_restore_submission(
        settings,
        owner_user_id=principal.user_id,
        session_id=principal.session_id,
        preview_id=preview.record.preview_id,
    ) as prepared:
        first = rehearsal.enqueue_restore_rehearsal(
            session, principal, settings, prepared=prepared, password=PASSWORD
        )
        session.commit()
    monkeypatch.setattr(rehearsal, "now", lambda: now() + timedelta(minutes=10))
    monkeypatch.setattr(
        rehearsal, "_probe_empty", lambda *args: pytest.fail("replay touched target")
    )
    assert (
        rehearsal.replay_restore_intent(
            session, principal, settings, preview_id=preview.record.preview_id, password=PASSWORD
        )
        == first
    )
    assert (
        rehearsal.read_restore_preview(
            session, principal, settings, preview.record.preview_id
        ).preview_id
        == preview.record.preview_id
    )
    with pytest.raises(ApiError) as denied:
        rehearsal.replay_restore_intent(
            session,
            principal,
            settings,
            preview_id=preview.record.preview_id,
            password="Incorrect-current-password-fixture",
        )
    assert denied.value.code == "reauthentication_failed"
    job = session.get(BackgroundJob, UUID(first["job_id"]))
    job.payload = {**job.payload, "backup_id": str(uuid4())}
    session.flush()
    with pytest.raises(ApiError) as denied:
        rehearsal.replay_restore_intent(
            session, principal, settings, preview_id=preview.record.preview_id, password=PASSWORD
        )
    assert denied.value.code == "restore_target_intent_conflict"
