import json
from datetime import timedelta
from uuid import uuid4

import pytest
from pydantic import ValidationError

from flowtrace_server.backups import rehearsal
from flowtrace_server.backups.rehearsal_schemas import RestorePreviewRecord, RestoreRehearsalPayload
from flowtrace_server.config import RestoreTargetConfig, Settings


@pytest.fixture
def isolated_definition(tmp_path):
    tool = tmp_path / "registration-only-tool"
    tool.write_bytes(b"not-executed-by-boundary-tests")
    identity = uuid4()
    target = RestoreTargetConfig(
        label="合成隔离目标",
        database_url="postgresql+psycopg://fixture:fixture@127.0.0.1/flowtrace_test_rehearsal_target",
        data_directory=tmp_path / "target",
        pg_restore_executable=tool,
    )
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url="postgresql+psycopg://fixture:fixture@127.0.0.1/flowtrace_test_rehearsal_source",
        data_directory=tmp_path / "source",
        restore_targets={identity: target},
    )
    return settings, identity, target


@pytest.fixture
def prepared(isolated_definition, monkeypatch):
    settings, target_id, _ = isolated_definition
    authority = rehearsal.RestorePrecheck(uuid4(), uuid4(), 0, uuid4())
    monkeypatch.setattr(rehearsal, "_verified_manifest", lambda *args, **kwargs: ({}, "a" * 64))
    monkeypatch.setattr(rehearsal, "_probe_empty", lambda *args: ("b" * 64, "c" * 64))
    preview = rehearsal.build_restore_preview(
        settings, authority=authority, backup_id=uuid4(), target_id=target_id
    )
    try:
        yield settings, preview
    finally:
        preview.close()


def payload(record):
    return RestoreRehearsalPayload(
        **{key: getattr(record, key) for key in RestoreRehearsalPayload.model_fields}
    )


def test_private_preview_is_closed_bounded_and_contains_no_raw_connection(prepared):
    settings, preview = prepared
    record = rehearsal._find_preview(settings, preview.record.preview_id)
    assert record == preview.record
    assert "postgresql" not in record.model_dump_json()
    for key, value in (("endpoint", "http://private"), ("config_version", True)):
        with pytest.raises(ValidationError):
            RestoreRehearsalPayload.model_validate({**payload(record).model_dump(), key: value})
    with pytest.raises(ValidationError):
        RestorePreviewRecord.model_validate(
            {**record.model_dump(), "expires_at": record.issued_at + timedelta(seconds=301)}
        )


def test_private_record_extra_or_duplicate_fields_are_rejected(prepared):
    settings, preview = prepared
    root = rehearsal._control(settings, preview.record.target_id)
    path = root / f"preview-{preview.record.preview_id}.json"
    original = path.read_bytes()
    for content in (
        json.dumps({**json.loads(original), "extra": "private-value"}).encode(),
        original[:-1] + b',"config_version":0}',
    ):
        path.write_bytes(content)
        with pytest.raises(rehearsal.RehearsalError) as caught:
            rehearsal._find_preview(settings, preview.record.preview_id)
        assert caught.value.code == "restore_record_unavailable"


def test_submission_expiry_identity_and_manifest_fail_closed(prepared, monkeypatch):
    settings, preview = prepared
    record = preview.record
    with pytest.raises(rehearsal.RehearsalError) as caught:
        rehearsal.prepare_restore_submission(
            settings,
            owner_user_id=uuid4(),
            session_id=record.session_id,
            preview_id=record.preview_id,
        )
    assert caught.value.code == "restore_preview_identity_changed"
    monkeypatch.setattr(rehearsal, "now", lambda: record.expires_at)
    with pytest.raises(rehearsal.RehearsalError) as caught:
        rehearsal.prepare_restore_submission(
            settings,
            owner_user_id=record.actor_id,
            session_id=record.session_id,
            preview_id=record.preview_id,
        )
    assert caught.value.code == "restore_preview_expired"
    monkeypatch.setattr(rehearsal, "now", lambda: record.issued_at)
    monkeypatch.setattr(rehearsal, "_verified_manifest", lambda *args, **kwargs: ({}, "d" * 64))
    with pytest.raises(rehearsal.RehearsalError) as caught:
        rehearsal.prepare_restore_submission(
            settings,
            owner_user_id=record.actor_id,
            session_id=record.session_id,
            preview_id=record.preview_id,
        )
    assert caught.value.code == "restore_backup_changed"


def test_prepared_intent_keeps_actual_private_lock_until_close(prepared, monkeypatch):
    settings, preview = prepared
    record = preview.record
    with rehearsal.prepare_restore_submission(
        settings,
        owner_user_id=record.actor_id,
        session_id=record.session_id,
        preview_id=record.preview_id,
    ) as intent:
        ticks = iter((0, 6))
        monkeypatch.setattr(rehearsal, "monotonic", lambda: next(ticks))
        with (
            pytest.raises(rehearsal.RehearsalError) as caught,
            rehearsal._target_lock(settings, record.target_id),
        ):
            pytest.fail("Second private file lock must not enter")
        assert caught.value.code == "restore_target_busy"
        assert not intent.closed
    assert intent.closed
    intent.close()


def test_target_directory_existing_files_and_real_links_are_rejected(isolated_definition, tmp_path):
    _, _, target = isolated_definition
    target.data_directory.mkdir()
    (target.data_directory / "witness.txt").write_text("keep-this-partial")
    with pytest.raises(rehearsal.RehearsalError) as caught:
        rehearsal._empty_filesystem(target)
    assert caught.value.code == "restore_target_not_empty"
    linked = tmp_path / "linked"
    linked.symlink_to(target.data_directory, target_is_directory=True)
    with pytest.raises(OSError):
        rehearsal._empty_filesystem(target.model_copy(update={"data_directory": linked}))
    assert (target.data_directory / "witness.txt").read_text() == "keep-this-partial"


def test_completed_external_effect_is_reverified_not_repeated_and_job_bound(prepared, monkeypatch):
    settings, preview = prepared
    record = preview.record
    intent_payload, job_id = payload(record), uuid4()
    calls, checks = [], []
    actual = {
        "target_identity": record.target_identity,
        "restored_instance": uuid4(),
        "restored_epoch": uuid4(),
        "database_summary_sha256": "d" * 64,
        "object_summary_sha256": "e" * 64,
        "object_count": 2,
    }
    monkeypatch.setattr(
        rehearsal.backups, "restore_isolated", lambda *args, **kwargs: calls.append(1)
    )

    def verify(*args, **kwargs):
        checks.append(1)
        return actual

    monkeypatch.setattr(rehearsal, "_verify_target", verify)
    first = rehearsal.run_restore_rehearsal(
        settings, owner_user_id=record.actor_id, job_id=job_id, payload=intent_payload
    )
    repeated = rehearsal.run_restore_rehearsal(
        settings, owner_user_id=record.actor_id, job_id=job_id, payload=intent_payload
    )
    assert first == repeated and calls == [1] and checks == [1, 1]
    with pytest.raises(rehearsal.RehearsalError) as caught:
        rehearsal.run_restore_rehearsal(
            settings, owner_user_id=record.actor_id, job_id=uuid4(), payload=intent_payload
        )
    assert caught.value.code == "restore_receipt_binding_invalid"
    actual["database_summary_sha256"] = "f" * 64
    with pytest.raises(rehearsal.RehearsalError) as caught:
        rehearsal.run_restore_rehearsal(
            settings, owner_user_id=record.actor_id, job_id=job_id, payload=intent_payload
        )
    assert caught.value.code == "restore_receipt_verification_failed" and calls == [1]


def test_partial_without_receipt_and_trusted_budget_never_invoke_restore(prepared, monkeypatch):
    settings, preview = prepared
    record = preview.record
    calls = []
    monkeypatch.setattr(
        rehearsal.backups, "restore_isolated", lambda *args, **kwargs: calls.append(1)
    )

    def partial(*args):
        raise rehearsal.RehearsalError("restore_target_not_empty")

    monkeypatch.setattr(rehearsal, "_probe_empty", partial)
    with pytest.raises(rehearsal.RehearsalError) as caught:
        rehearsal.run_restore_rehearsal(
            settings, owner_user_id=record.actor_id, job_id=uuid4(), payload=payload(record)
        )
    assert caught.value.code == "restore_target_not_empty" and calls == []
    monkeypatch.setattr(
        rehearsal, "_probe_empty", lambda *args: (record.target_identity, record.empty_fingerprint)
    )

    def expired():
        raise rehearsal.RehearsalError("restore_execution_timeout")

    with pytest.raises(rehearsal.RehearsalError) as caught:
        rehearsal.run_restore_rehearsal(
            settings,
            owner_user_id=record.actor_id,
            job_id=uuid4(),
            payload=payload(record),
            check_budget=expired,
        )
    assert caught.value.code == "restore_execution_timeout" and calls == []
