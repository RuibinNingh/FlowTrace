"""Real submission SQL/auth/reservations; synthetic packages, no execution."""

from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import delete, func, select, text
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import AdminRole, User, UserSession
from flowtrace_server.auth.service import PASSWORDS, issue_session, now
from flowtrace_server.backups import quarantine_submission as submission
from flowtrace_server.backups import retention
from flowtrace_server.backups.leases import BackupLeaseError, backup_read_lease
from flowtrace_server.backups.quarantine_schemas import QuarantineSubmission
from flowtrace_server.backups.retention_models import BackupControl, BackupRetentionIntent
from flowtrace_server.backups.retention_schemas import PinCreateCommand, RetentionSelection
from flowtrace_server.configuration.runtime import read_runtime_configuration
from flowtrace_server.configuration.schemas import (
    ConfigurationSaveCommand,
    PublicConfigurationPatch,
)
from flowtrace_server.configuration.service import save_configuration
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.jobs.models import BackgroundJob

from .test_job_references_pg import PASSWORD
from .test_job_references_pg import reference_case as reference_case
from .test_retention_io import package, snapshot

pytestmark = pytest.mark.postgres


def preview(case):
    with Session(case.engine) as session:
        instance, epoch = retention._source(session)
    selected, source, _ = package(
        case.settings, instance=instance, epoch=epoch, created_at=now() - timedelta(days=40)
    )
    witness, _, _ = package(case.settings, instance=instance, epoch=epoch)
    for identifier in (selected, witness):
        with retention.prepare_registration(case.settings, identifier) as prepared:
            with Session(case.engine) as session:
                retention.register_verified_backup(
                    session, case.owner, case.settings, prepared=prepared, password=PASSWORD
                )
                session.commit()
    with Session(case.engine) as session:
        selection = RetentionSelection(
            backup_ids=(selected,),
            request_id=uuid4(),
            expected_config_version=read_runtime_configuration(session).version,
        )
        authority = retention.precheck_retention_request(
            session, case.owner, selection=selection, password=PASSWORD
        )
        session.commit()
        with retention.build_retention_preview(case.settings, authority=authority) as prepared:
            record = retention.authorize_retention_preview(
                session, case.owner, case.settings, prepared=prepared, password=PASSWORD
            )
            session.commit()
    command = QuarantineSubmission(
        preview_id=record.preview_id, request_id=uuid4(), selection_sha256=record.selection_sha256
    )
    return record, command, source


def prepare(case, record, command):
    with Session(case.engine) as session:
        authority = submission.precheck_quarantine_submission(
            session, case.owner, case.settings, command=command, record=record, password=PASSWORD
        )
        session.commit()
    return submission.prepare_quarantine_submission(case.settings, authority=authority)


def own_count(session, case, model):
    field = model.actor_id if model is BackupRetentionIntent else model.owner_user_id
    return session.scalar(
        select(func.count()).select_from(model).where(field == case.owner.user_id)
    )


def submit(case, record, command):
    with prepare(case, record, command) as prepared:
        with Session(case.engine) as session:
            result = submission.enqueue_quarantine_submission(
                session,
                case.owner,
                case.settings,
                prepared=prepared,
                command=command,
                password=PASSWORD,
            )
            session.commit()
    return result


def test_new_preview_digest_and_real_job_reservations_share_one_commit(reference_case, monkeypatch):
    case = reference_case
    record, command, source = preview(case)
    frozen = snapshot(source)
    loaded = submission.load_quarantine_preview(case.settings, record.preview_id)
    with Session(case.engine) as session:
        audit = session.scalar(
            select(AdminAudit).where(
                AdminAudit.target_id == record.preview_id,
                AdminAudit.action == "backup.retention_preview",
            )
        )
        assert audit.summary["preview_sha256"] == submission._record_hash(loaded)
    actual, phases = retention._verify_stamp, []

    def verify_without_business_locks(*args, **kwargs):
        with case.engine.begin() as other:
            other.execute(
                text("SELECT id FROM users WHERE id=:id FOR UPDATE NOWAIT"),
                {
                    "id": case.owner.user_id,
                },
            ).one()
            other.execute(text("SELECT id FROM admin_control WHERE id=1 FOR UPDATE NOWAIT")).one()
            other.execute(
                text("SELECT id FROM service_configuration WHERE id=1 FOR UPDATE NOWAIT")
            ).one()
        phases.append(args[1])
        return actual(*args, **kwargs)

    monkeypatch.setattr(retention, "_verify_stamp", verify_without_business_locks)
    with prepare(case, loaded, command) as prepared:
        assert not hasattr(prepared, "job_id") and len(phases) == 2
        with Session(case.engine) as session:
            result = submission.enqueue_quarantine_submission(
                session,
                case.owner,
                case.settings,
                prepared=prepared,
                command=command,
                password=PASSWORD,
            )
            with Session(case.engine) as other:
                assert other.get(BackupControl, record.packages[0].backup_id).state == "available"
                assert own_count(other, case, BackgroundJob) == 0
            session.commit()
            intent = session.scalar(
                select(BackupRetentionIntent).where(
                    BackupRetentionIntent.actor_id == case.owner.user_id
                )
            )
            control = session.get(
                BackupControl, record.packages[0].backup_id, populate_existing=True
            )
            assert intent.job_id == UUID(result["job_id"])
            assert control.intent_id == intent.id and control.state == "reserved"
            assert control.version == record.packages[0].control_version + 1
            assert (
                own_count(session, case, BackgroundJob)
                == own_count(session, case, BackupRetentionIntent)
                == 1
            )
        with pytest.raises(BackupLeaseError):
            with backup_read_lease(case.settings, record.packages[0].backup_id, timeout_seconds=0):
                pytest.fail("submission EX was released before caller completion")
    assert snapshot(source) == frozen
    assert not (case.settings.data_directory / "backup-quarantine").exists()


@pytest.mark.parametrize("mutation", ["legacy_without_digest", "changed_private_record"])
def test_original_preview_digest_is_required_without_backfilling_old_audit(
    reference_case, mutation
):
    case = reference_case
    record, command, source = preview(case)
    with Session(case.engine) as session:
        item = session.scalar(select(AdminAudit).where(AdminAudit.target_id == record.preview_id))
        if mutation == "legacy_without_digest":
            # Only this new synthetic fixture models an already-existing old audit.
            item.summary = {
                key: value for key, value in item.summary.items() if key != "preview_sha256"
            }
            session.commit()
        original = dict(item.summary)
    if mutation == "changed_private_record":
        record = record.model_copy(update={"cutoff": record.cutoff - timedelta(seconds=1)})
        path = (
            case.settings.data_directory / "backup-retention-previews" / f"{record.preview_id}.json"
        )
        path.write_bytes(canonical(record.model_dump(mode="json")))
        record = submission.load_quarantine_preview(case.settings, record.preview_id)
    frozen = snapshot(source)
    with Session(case.engine) as session:
        with pytest.raises(ApiError, match="backup_quarantine_new_preview_required"):
            submission.precheck_quarantine_submission(
                session,
                case.owner,
                case.settings,
                command=command,
                record=record,
                password=PASSWORD,
            )
        session.rollback()
        assert (
            session.scalar(
                select(AdminAudit).where(AdminAudit.target_id == record.preview_id)
            ).summary
            == original
        )
        assert (
            own_count(session, case, BackgroundJob)
            == own_count(session, case, BackupRetentionIntent)
            == 0
        )
    assert snapshot(source) == frozen


def test_enqueue_rollback_restores_available_control_and_leaves_no_intent_or_job(reference_case):
    case = reference_case
    record, command, source = preview(case)
    frozen = snapshot(source)
    with prepare(case, record, command) as prepared:
        with Session(case.engine) as session:
            submission.enqueue_quarantine_submission(
                session,
                case.owner,
                case.settings,
                prepared=prepared,
                command=command,
                password=PASSWORD,
            )
            session.rollback()
    with Session(case.engine) as session:
        control = session.get(BackupControl, record.packages[0].backup_id)
        assert control.state == "available" and control.intent_id is None and control.version == 1
        assert (
            own_count(session, case, BackupRetentionIntent)
            == own_count(session, case, BackgroundJob)
            == 0
        )
    assert snapshot(source) == frozen


@pytest.mark.parametrize("late_change", ["pin", "role", "password", "configuration"])
def test_late_current_protection_or_role_change_rolls_back_job_and_reservation(
    reference_case, late_change
):
    case = reference_case
    record, command, source = preview(case)
    frozen = snapshot(source)
    prior_days = None
    with prepare(case, record, command) as prepared:
        with Session(case.engine) as other:
            if late_change == "pin":
                retention.create_backup_pin(
                    other,
                    case.owner,
                    command=PinCreateCommand(
                        pin_id=uuid4(),
                        backup_id=record.packages[0].backup_id,
                        expected_control_version=1,
                        request_id=uuid4(),
                    ),
                    password=PASSWORD,
                )
            elif late_change == "role":
                other.execute(
                    delete(AdminRole).where(
                        AdminRole.user_id == case.owner.user_id, AdminRole.role == "recovery_admin"
                    )
                )
            elif late_change == "password":
                other.get(User, case.owner.user_id).password_hash = PASSWORDS.hash(
                    "Changed-current-synthetic-password-2026"
                )
            else:
                runtime = read_runtime_configuration(other)
                prior_days = runtime.values.backup_retention_days
                save_configuration(
                    other,
                    case.owner,
                    ConfigurationSaveCommand(
                        base_version=runtime.version,
                        request_id=uuid4(),
                        public_patch=PublicConfigurationPatch(backup_retention_days=prior_days + 1),
                    ),
                    password=PASSWORD,
                    validate_candidate=lambda public, refs: None,
                )
            other.commit()
        with Session(case.engine) as session:
            with pytest.raises(ApiError):
                submission.enqueue_quarantine_submission(
                    session,
                    case.owner,
                    case.settings,
                    prepared=prepared,
                    command=command,
                    password=PASSWORD,
                )
            session.rollback()
            assert (
                own_count(session, case, BackupRetentionIntent)
                == own_count(session, case, BackgroundJob)
                == 0
            )
            control = session.get(BackupControl, record.packages[0].backup_id)
            assert control.state == "available" and control.intent_id is None
        if prior_days is not None:
            with Session(case.engine) as session:
                runtime = read_runtime_configuration(session)
                save_configuration(
                    session,
                    case.owner,
                    ConfigurationSaveCommand(
                        base_version=runtime.version,
                        request_id=uuid4(),
                        public_patch=PublicConfigurationPatch(backup_retention_days=prior_days),
                    ),
                    password=PASSWORD,
                    validate_candidate=lambda public, refs: None,
                )
                session.commit()
    assert snapshot(source) == frozen


def test_lost_enqueue_response_replays_with_new_current_session_after_old_preview_ttl(
    reference_case, monkeypatch
):
    case = reference_case
    record, command, source = preview(case)
    first = submit(case, record, command)
    frozen = snapshot(source)
    with Session(case.engine) as session, session.begin():
        old = session.get(UserSession, case.owner.session_id)
        old.revoked_at = now()
        origin, _ = issue_session(
            session,
            session.get(User, case.owner.user_id),
            uuid4(),
            "same actor fresh admin",
            "admin",
        )
        current = Principal(origin.user_id, origin.id, origin.client_id, "admin", frozenset())
    monkeypatch.setattr(submission, "now", lambda: record.expires_at + timedelta(seconds=1))
    with Session(case.engine) as session:
        result = submission.replay_quarantine_submission(
            session, current, command=command, password=PASSWORD
        )
        session.commit()
        assert result["job_id"] == first["job_id"] and result["generation"] == "0"
        assert (
            own_count(session, case, BackupRetentionIntent)
            == own_count(session, case, BackgroundJob)
            == 1
        )
        intent = session.scalar(
            select(BackupRetentionIntent).where(
                BackupRetentionIntent.actor_id == case.owner.user_id
            )
        )
        assert intent.origin_session_id == case.owner.session_id
        control = session.get(BackupControl, record.packages[0].backup_id)
        assert control.state == "reserved" and control.version == 2
    assert (
        snapshot(source) == frozen
        and not (case.settings.data_directory / "backup-quarantine").exists()
    )


@pytest.mark.parametrize("changed", ["request", "selection"])
def test_replay_rejects_changed_command_instead_of_adopting_an_existing_intent(
    reference_case, changed
):
    case = reference_case
    record, command, source = preview(case)
    submit(case, record, command)
    command = command.model_copy(
        update={"request_id": uuid4()} if changed == "request" else {"selection_sha256": "0" * 64}
    )
    before = snapshot(source)
    with Session(case.engine) as session:
        with pytest.raises(ApiError, match="backup_quarantine_request_conflict"):
            submission.replay_quarantine_submission(
                session, case.owner, command=command, password=PASSWORD
            )
        session.rollback()
        assert (
            own_count(session, case, BackupRetentionIntent)
            == own_count(session, case, BackgroundJob)
            == 1
        )
    assert snapshot(source) == before


def test_actual_enqueue_rejects_a_closed_guard_without_creating_durable_work(reference_case):
    case = reference_case
    record, command, source = preview(case)
    frozen = snapshot(source)
    with prepare(case, record, command) as prepared:
        prepared.guard.close()
        with Session(case.engine) as session:
            with pytest.raises(ApiError, match="backup_quarantine_submission_invalid"):
                submission.enqueue_quarantine_submission(
                    session,
                    case.owner,
                    case.settings,
                    prepared=prepared,
                    command=command,
                    password=PASSWORD,
                )
            session.rollback()
            assert (
                own_count(session, case, BackupRetentionIntent)
                == own_count(session, case, BackgroundJob)
                == 0
            )
            assert session.get(BackupControl, record.packages[0].backup_id).state == "available"
    assert snapshot(source) == frozen


def test_preview_expiring_during_final_control_checks_cannot_be_enqueued(
    reference_case, monkeypatch
):
    case = reference_case
    record, command, source = preview(case)
    frozen = snapshot(source)
    with prepare(case, record, command) as prepared:
        actual = submission._selection

        def expired_after_current_controls(*args, **kwargs):
            result = actual(*args, **kwargs)
            if kwargs.get("lock"):
                monkeypatch.setattr(
                    submission, "now", lambda: record.expires_at + timedelta(seconds=1)
                )
            return result

        monkeypatch.setattr(submission, "_selection", expired_after_current_controls)
        with Session(case.engine) as session:
            with pytest.raises(ApiError, match="backup_preview_expired"):
                submission.enqueue_quarantine_submission(
                    session,
                    case.owner,
                    case.settings,
                    prepared=prepared,
                    command=command,
                    password=PASSWORD,
                )
            session.rollback()
            assert (
                own_count(session, case, BackupRetentionIntent)
                == own_count(session, case, BackgroundJob)
                == 0
            )
    assert snapshot(source) == frozen
