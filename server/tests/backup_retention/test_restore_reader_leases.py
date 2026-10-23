"""Source lock lifetime through trusted restore phases; no target DB effects."""

from contextlib import contextmanager
from uuid import uuid4

import pytest
from backup_rehearsal.test_boundaries import isolated_definition as isolated_definition

from flowtrace_server.backups import rehearsal, service
from flowtrace_server.backups.leases import backup_exclusive_lease

from .test_reader_leases import assert_read_owned


def make_preview(settings, target_id, monkeypatch):
    backup_id = uuid4()
    authority = rehearsal.RestorePrecheck(uuid4(), uuid4(), 0, uuid4())

    def manifest(*args, **kwargs):
        assert_read_owned(settings, backup_id)
        return {}, "a" * 64

    def probe(*args):
        assert_read_owned(settings, backup_id)
        return "b" * 64, "c" * 64

    monkeypatch.setattr(rehearsal, "_verified_manifest", manifest)
    monkeypatch.setattr(rehearsal, "_probe_empty", probe)
    return rehearsal.build_restore_preview(
        settings, authority=authority, backup_id=backup_id, target_id=target_id
    )


def test_preview_source_precedes_target_and_lasts_until_caller_close(
    isolated_definition, monkeypatch
):
    settings, target_id, _ = isolated_definition
    original = rehearsal._target_lock
    selected = []

    @contextmanager
    def target(*args):
        # _verified_manifest runs after target acquisition. Inspect the lock
        # before waiting on that target as well, which proves lock ordering.
        backup_id = selected[0]
        assert_read_owned(settings, backup_id)
        with original(*args) as value:
            yield value

    backup_id = uuid4()
    selected.append(backup_id)
    monkeypatch.setattr(rehearsal, "_target_lock", target)
    monkeypatch.setattr(rehearsal, "_verified_manifest", lambda *a, **k: ({}, "a" * 64))
    monkeypatch.setattr(rehearsal, "_probe_empty", lambda *a: ("b" * 64, "c" * 64))

    def gate(identifier):
        assert identifier == backup_id
        assert_read_owned(settings, backup_id)

    preview = rehearsal.build_restore_preview(
        settings, authority=rehearsal.RestorePrecheck(uuid4(), uuid4(), 0, uuid4()),
        backup_id=backup_id, target_id=target_id, before_read=gate,
    )
    try:
        assert_read_owned(settings, backup_id)
        # Preview retains the source while final authority/commit is pending;
        # the temporary target inspection is already finished.
        with original(settings, target_id):
            pass
        assert not preview.closed
    finally:
        preview.close()
    assert preview.closed
    preview.close()
    with backup_exclusive_lease(settings, (backup_id,), timeout_seconds=0):
        pass


def test_submission_source_precedes_target_and_survives_enqueue_commit_boundary(
    isolated_definition, monkeypatch
):
    settings, target_id, _ = isolated_definition
    preview = make_preview(settings, target_id, monkeypatch)
    record = preview.record
    preview.close()
    original = rehearsal._target_lock
    calls = []

    @contextmanager
    def target(*args):
        assert_read_owned(settings, record.backup_id)
        calls.append("target")
        with original(*args) as value:
            yield value

    def gate(identifier):
        assert identifier == record.backup_id
        assert_read_owned(settings, record.backup_id)
        calls.append("short_control_commit")

    monkeypatch.setattr(rehearsal, "_target_lock", target)
    with rehearsal.prepare_restore_submission(
        settings, owner_user_id=record.actor_id, session_id=record.session_id,
        preview_id=record.preview_id, before_read=gate,
    ) as prepared:
        assert calls == ["short_control_commit", "target"]
        # This prepared context is what the route keeps alive through its final
        # enqueue transaction/commit. This pure target does not fake a DB commit.
        assert_read_owned(settings, record.backup_id)
        assert not prepared.closed
    assert prepared.closed
    with backup_exclusive_lease(settings, (record.backup_id,), timeout_seconds=0):
        pass
    with original(settings, target_id):
        pass


def test_failed_submission_releases_both_source_and_target(isolated_definition, monkeypatch):
    settings, target_id, _ = isolated_definition
    preview = make_preview(settings, target_id, monkeypatch)
    record = preview.record
    preview.close()

    def changed(*args, **kwargs):
        assert_read_owned(settings, record.backup_id)
        return {}, "d" * 64

    monkeypatch.setattr(rehearsal, "_verified_manifest", changed)
    with pytest.raises(rehearsal.RehearsalError, match="restore_backup_changed"):
        rehearsal.prepare_restore_submission(
            settings, owner_user_id=record.actor_id, session_id=record.session_id,
            preview_id=record.preview_id,
        )
    with backup_exclusive_lease(settings, (record.backup_id,), timeout_seconds=0):
        pass
    with rehearsal._target_lock(settings, target_id):
        pass


@pytest.mark.parametrize("fail_validation", [False, True])
def test_run_holds_source_through_restore_target_recheck_and_receipt(
    isolated_definition, monkeypatch, fail_validation
):
    settings, target_id, _ = isolated_definition
    preview = make_preview(settings, target_id, monkeypatch)
    record = preview.record
    preview.close()
    phases = []

    def gate(identifier):
        assert identifier == record.backup_id
        assert_read_owned(settings, record.backup_id)
        phases.append("short_control_commit")

    def restore(*args, **kwargs):
        assert_read_owned(settings, record.backup_id)
        phases.append("restore")

    def verify(*args, **kwargs):
        assert_read_owned(settings, record.backup_id)
        phases.append("target_reverified")
        if fail_validation:
            raise rehearsal.RehearsalError("synthetic_target_failure")
        return {
            "target_identity": record.target_identity, "restored_instance": uuid4(),
            "restored_epoch": uuid4(), "database_summary_sha256": "d" * 64,
            "object_summary_sha256": "e" * 64, "object_count": 0,
        }

    original = rehearsal._write_record

    def receipt(*args):
        assert_read_owned(settings, record.backup_id)
        phases.append("receipt")
        return original(*args)

    monkeypatch.setattr(rehearsal.backups, "restore_isolated", restore)
    monkeypatch.setattr(rehearsal, "_verify_target", verify)
    monkeypatch.setattr(rehearsal, "_write_record", receipt)
    payload = rehearsal.RestoreRehearsalPayload(
        **{key: getattr(record, key) for key in rehearsal.RestoreRehearsalPayload.model_fields}
    )
    arguments = dict(
        owner_user_id=record.actor_id, job_id=uuid4(), payload=payload, before_read=gate
    )
    if fail_validation:
        with pytest.raises(rehearsal.RehearsalError, match="synthetic_target_failure"):
            rehearsal.run_restore_rehearsal(settings, **arguments)
        assert phases == ["short_control_commit", "restore", "target_reverified"]
    else:
        result = rehearsal.run_restore_rehearsal(settings, **arguments)
        assert result["code"] == "restore_rehearsal_verified"
        assert phases == ["short_control_commit", "restore", "target_reverified", "receipt"]
    with backup_exclusive_lease(settings, (record.backup_id,), timeout_seconds=0):
        pass
    with rehearsal._target_lock(settings, target_id):
        pass


def test_operator_restore_source_lease_released_on_internal_failure(tmp_path, monkeypatch):
    root, identifier = tmp_path / "backups", uuid4()
    settings = service._package_settings(root)

    def restoring(*args, **kwargs):
        assert_read_owned(settings, identifier)
        raise service.BackupError("synthetic_failure_before_target_io")

    monkeypatch.setattr(service, "_restore_isolated", restoring)
    with pytest.raises(service.BackupError, match="synthetic_failure_before_target_io"):
        service.restore_isolated(
            root, identifier, None, pg_restore=tmp_path / "unused", attachment_directory=tmp_path
        )
    with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
        pass
