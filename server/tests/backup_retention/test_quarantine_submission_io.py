"""Submission file phases only; synthetic authority here makes no PG auth claim."""

import hashlib
from dataclasses import replace
from datetime import timedelta
from types import SimpleNamespace
from uuid import uuid4

import pytest

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import now
from flowtrace_server.backups import quarantine_submission as submission
from flowtrace_server.backups import retention
from flowtrace_server.backups.leases import (
    BackupLeaseError,
    backup_exclusive_lease,
    backup_read_lease,
)
from flowtrace_server.backups.quarantine_schemas import QuarantineSubmission
from flowtrace_server.backups.retention_schemas import RetentionPreviewRecord
from flowtrace_server.config import Settings
from flowtrace_server.imports.parsers import canonical

from .test_retention_io import package, snapshot


@pytest.fixture
def file_case(tmp_path):
    settings = Settings(_env_file=None, environment="test", data_directory=tmp_path)
    instance, epoch = uuid4(), uuid4()
    identifier, source, _ = package(
        settings, instance=instance, epoch=epoch, created_at=now() - timedelta(days=40)
    )
    witness_id, witness_path, _ = package(settings, instance=instance, epoch=epoch)
    selected = retention._verify_stamp(settings, identifier)
    witness = retention._verify_stamp(settings, witness_id)
    stamp = now()
    principal = SimpleNamespace(user_id=uuid4(), session_id=uuid4())
    record = RetentionPreviewRecord(
        preview_id=uuid4(),
        actor_id=principal.user_id,
        session_id=principal.session_id,
        request_id=uuid4(),
        config_version=0,
        source_instance_id=instance,
        source_epoch=epoch,
        retention_days=30,
        cutoff=stamp - timedelta(days=30),
        packages=(selected,),
        selection_sha256=hashlib.sha256(canonical([selected.model_dump(mode="json")])).hexdigest(),
        issued_at=stamp,
        expires_at=stamp + timedelta(seconds=300),
    )
    command = QuarantineSubmission(
        preview_id=record.preview_id, request_id=uuid4(), selection_sha256=record.selection_sha256
    )
    authority = submission.QuarantineAuthority(
        record,
        witness,
        submission._request_hash(principal.user_id, command),
        retention._settings_key(settings),
        submission._TRUST,
    )
    preview = tmp_path / "backup-retention-previews" / f"{record.preview_id}.json"
    preview.parent.mkdir()
    preview.write_bytes(record.model_dump_json().encode())
    return SimpleNamespace(
        settings=settings,
        principal=principal,
        record=record,
        command=command,
        authority=authority,
        source=source,
        witness_path=witness_path,
        preview=preview,
    )


def test_private_preview_roundtrip_keeps_canonical_digest_and_submission_has_no_job_id(file_case):
    case = file_case
    record = submission.load_quarantine_preview(case.settings, case.record.preview_id)
    assert record == case.record
    assert submission._record_hash(record) == submission._record_hash(case.record)
    before, witness_before = snapshot(case.source), snapshot(case.witness_path)
    with submission.prepare_quarantine_submission(
        case.settings, authority=case.authority
    ) as prepared:
        assert not hasattr(prepared, "job_id")
        assert (
            submission._prepared_record(case.settings, prepared, case.principal, case.command)
            == record
        )
        with pytest.raises(BackupLeaseError):
            with backup_read_lease(case.settings, record.packages[0].backup_id, timeout_seconds=0):
                pytest.fail("submission did not hold selected EX")
        with backup_read_lease(case.settings, case.authority.witness.backup_id, timeout_seconds=0):
            pass
    assert snapshot(case.source) == before and snapshot(case.witness_path) == witness_before
    assert not (case.settings.data_directory / "backup-quarantine").exists()


@pytest.mark.parametrize("mutation", ["oversize", "wrong_id", "selection", "extra", "corrupt"])
def test_bounded_preview_loader_rejects_nonclosed_or_changed_record(file_case, mutation):
    case = file_case
    data = case.record.model_dump(mode="json")
    if mutation == "oversize":
        raw = b" " * 32769
    elif mutation == "corrupt":
        raw = b"{incomplete"
    else:
        if mutation == "wrong_id":
            data["preview_id"] = str(uuid4())
        elif mutation == "selection":
            data["selection_sha256"] = "0" * 64
        else:
            data["url"] = "https://sentinel.invalid"
        raw = canonical(data)
    case.preview.write_bytes(raw)
    with pytest.raises(ApiError, match="backup_quarantine_preview_unavailable"):
        submission.load_quarantine_preview(case.settings, case.record.preview_id)
    assert case.preview.read_bytes() == raw and case.source.exists()


@pytest.mark.parametrize("change", ["record", "witness", "guard_close", "command"])
def test_submission_prepared_cannot_rebind_identity_or_use_released_locks(file_case, change):
    case = file_case
    before = snapshot(case.source)
    with submission.prepare_quarantine_submission(
        case.settings, authority=case.authority
    ) as prepared:
        command = case.command
        if change == "record":
            prepared.authority = replace(
                case.authority, record=case.record.model_copy(update={"actor_id": uuid4()})
            )
        elif change == "witness":
            prepared.authority = replace(
                case.authority,
                witness=case.authority.witness.model_copy(update={"backup_id": uuid4()}),
            )
        elif change == "guard_close":
            prepared.guard.close()
        else:
            command = command.model_copy(update={"request_id": uuid4()})
        with pytest.raises(ApiError, match="backup_quarantine_submission_invalid"):
            submission._prepared_record(case.settings, prepared, case.principal, command)
    assert snapshot(case.source) == before
    with backup_exclusive_lease(
        case.settings, (case.record.packages[0].backup_id,), timeout_seconds=0
    ):
        pass
