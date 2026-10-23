"""Real private-file/lease preparation; synthetic dump header, no pg_restore claim."""

import hashlib
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.backups import retention
from flowtrace_server.backups.leases import BackupLeaseError, backup_exclusive_lease
from flowtrace_server.backups.retention_schemas import RetentionSelection
from flowtrace_server.config import Settings
from flowtrace_server.imports.parsers import canonical


def package(settings, *, created_at=None, instance=None, epoch=None):
    identifier = uuid4()
    root = settings.data_directory / "backups" / str(identifier)
    root.mkdir(parents=True)
    records = []
    for name, data in (
        ("database.dump", b"PGDMPsynthetic-not-real-restore"),
        ("settings.json", b'{"environment":"test"}'),
    ):
        (root / name).write_bytes(data)
        records.append(
            {"path": name, "size_bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        )
    manifest = {
        "format": "flowtrace-backup-v1",
        "backup_id": str(identifier),
        "created_at": (created_at or datetime.now(UTC)).isoformat(),
        "server_version": "0.1.0",
        "schema_versions": ["0013_backup_retention"],
        "instance_id": str(instance or uuid4()),
        "sync_epoch": str(epoch or uuid4()),
        "database": records[0],
        "files": records[1:],
        "database_summary": {
            "algorithm": "sha256-length-framed-jsonb-utc-c-order-v1",
            "tables": {"synthetic": {"count": 0, "sha256": "0" * 64}},
        },
    }
    (root / "manifest.json").write_bytes(canonical(manifest))
    return identifier, root, manifest


def snapshot(root):
    return {
        str(path.relative_to(root)): path.read_bytes() for path in root.rglob("*") if path.is_file()
    }


def test_registration_accepts_known_empty_objects_directory(tmp_path):
    settings = Settings(_env_file=None, environment="test", data_directory=tmp_path)
    identifier, root, _ = package(settings)
    (root / "objects").mkdir()
    with retention.prepare_registration(settings, identifier) as prepared:
        assert prepared.stamp.file_count == 3
    assert (root / "objects").is_dir()


def test_registration_context_verifies_complete_package_and_holds_shared_lease_until_close(
    tmp_path,
):
    settings = Settings(_env_file=None, environment="test", data_directory=tmp_path)
    identifier, root, _ = package(settings)
    before = snapshot(root)
    with retention.prepare_registration(settings, identifier) as prepared:
        assert prepared.stamp.backup_id == identifier
        assert prepared.stamp.file_count == 3
        assert prepared.stamp.size_bytes == sum(map(len, before.values()))
        assert prepared.stamp.control_version == 1
        with pytest.raises(BackupLeaseError):
            with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
                pytest.fail("an exclusive lease crossed the live registration reader")
    assert prepared.closed
    with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
        pass
    assert snapshot(root) == before


@pytest.mark.parametrize("mutation", ("extra_file", "extra_directory", "corrupt", "bad_identity"))
def test_registration_rejects_incomplete_or_unknown_package_without_altering_files(
    tmp_path, mutation
):
    settings = Settings(_env_file=None, environment="test", data_directory=tmp_path)
    identifier, root, manifest = package(settings)
    if mutation == "extra_file":
        (root / "private-sentinel.txt").write_bytes(b"preserve this synthetic sentinel")
    elif mutation == "extra_directory":
        (root / "unknown-empty").mkdir()
    elif mutation == "corrupt":
        (root / "database.dump").write_bytes(b"PGDMPprivate-sentinel-corrupt")
    else:
        manifest["instance_id"] = "private-sentinel-not-uuid"
        (root / "manifest.json").write_bytes(canonical(manifest))
    before = snapshot(root)
    with pytest.raises(ApiError) as caught:
        retention.prepare_registration(settings, identifier)
    assert "private-sentinel" not in str(caught.value)
    assert snapshot(root) == before
    with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
        pass


def test_failed_budget_releases_registration_lease_without_rewriting_package(tmp_path):
    settings = Settings(_env_file=None, environment="test", data_directory=tmp_path)
    identifier, root, _ = package(settings)
    before = snapshot(root)

    def stop():
        raise RuntimeError("trusted budget exhausted")

    with pytest.raises(RuntimeError):
        retention.prepare_registration(settings, identifier, check_budget=stop)
    with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
        pass
    assert snapshot(root) == before


def authority(settings):
    source, epoch = uuid4(), uuid4()
    selected, _, _ = package(
        settings, created_at=datetime.now(UTC) - timedelta(days=31), instance=source, epoch=epoch
    )
    witness, _, _ = package(settings, instance=source, epoch=epoch)
    with retention.prepare_registration(settings, selected) as first:
        stamp = first.stamp
    with retention.prepare_registration(settings, witness) as latest:
        last = latest.stamp
    selection = RetentionSelection(
        backup_ids=(selected,), request_id=uuid4(), expected_config_version=3
    )
    return retention.RetentionAuthority(
        uuid4(),
        uuid4(),
        selection,
        3,
        30,
        source,
        epoch,
        datetime.now(UTC) - timedelta(days=30),
        (stamp,),
        last,
        retention._TRUST,
    )


def test_zero_delete_preview_freshly_checks_selected_and_unselected_recovery_point(tmp_path):
    settings = Settings(_env_file=None, environment="test", data_directory=tmp_path)
    request = authority(settings)
    root = settings.data_directory / "backups"
    before = snapshot(root)
    with retention.build_retention_preview(settings, authority=request) as prepared:
        record = prepared.record
        assert record.config_version == 3 and record.retention_days == 30
        assert record.packages == request.stamps
        assert (record.expires_at - record.issued_at).total_seconds() == 300
        assert prepared.witness == request.witness
        for identifier in (request.stamps[0].backup_id, request.witness.backup_id):
            with pytest.raises(BackupLeaseError):
                with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
                    pytest.fail("preview lost its source reader lease")
        saved = settings.data_directory / "backup-retention-previews" / f"{record.preview_id}.json"
        assert saved.read_bytes() == record.model_dump_json().encode()
        assert b"database_url" not in saved.read_bytes()
        assert snapshot(root) == before
    assert prepared.closed
    assert snapshot(root) == before


def test_changed_recovery_witness_blocks_preview_and_releases_every_acquired_reader(tmp_path):
    settings = Settings(_env_file=None, environment="test", data_directory=tmp_path)
    request = authority(settings)
    root = settings.data_directory / "backups"
    (root / str(request.witness.backup_id) / "database.dump").write_bytes(b"PGDMPdamaged-witness")
    before = snapshot(root)
    with pytest.raises(ApiError):
        retention.build_retention_preview(settings, authority=request)
    for identifier in (request.stamps[0].backup_id, request.witness.backup_id):
        with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
            pass
    assert snapshot(root) == before
    assert not (settings.data_directory / "backup-retention-previews").exists()


def test_preview_rejects_public_dict_instead_of_a_trusted_authority(tmp_path):
    settings = Settings(_env_file=None, environment="test", data_directory=tmp_path)
    with pytest.raises(ApiError) as caught:
        retention.build_retention_preview(settings, authority={"backup_ids": [str(uuid4())]})
    assert caught.value.status == 422
    assert not (tmp_path / "backups").exists()
