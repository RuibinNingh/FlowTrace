"""Real OS locks around consumers, without PostgreSQL or package cleanup."""

import hashlib
import io
import zipfile
from types import SimpleNamespace
from uuid import uuid4

import pytest
from backup_admin.conftest import package

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.backups import administration, service
from flowtrace_server.backups.leases import (
    BackupLeaseError,
    backup_exclusive_lease,
    backup_read_lease,
)
from flowtrace_server.config import Settings
from flowtrace_server.worker import runtime


def assert_read_owned(settings, identifier):
    with backup_read_lease(settings, identifier, timeout_seconds=0):
        pass
    with pytest.raises(BackupLeaseError, match="backup_busy"):
        with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
            pytest.fail("package was not protected by the consumer")


def test_archive_source_shared_lease_spans_hash_copy_and_manifest_recheck(tmp_path, monkeypatch):
    settings = SimpleNamespace(data_directory=tmp_path)
    identifier, _, _, contents = package(tmp_path / "backups")
    original = administration._open_checked
    observed = []

    def opening(path, root, **kwargs):
        if root == tmp_path / "backups":
            assert_read_owned(settings, identifier)
            observed.append(path.name)
        return original(path, root, **kwargs)

    monkeypatch.setattr(administration, "_open_checked", opening)
    prepared = administration.prepare_archive(settings, backup_id=identifier)
    try:
        assert {"manifest.json", "database.dump", "settings.json"}.issubset(observed)
        # The independent ZIP is complete: a slow HTTP consumer no longer reads
        # any source package and must not hold the original SH indefinitely.
        with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
            raw = b"".join(prepared.chunks())
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            assert all(
                archive.read(f"{identifier}/{name}") == data for name, data in contents.items()
            )
    finally:
        prepared.close()


def test_archive_failure_releases_source_shared_lease_and_retains_package(tmp_path, monkeypatch):
    settings = SimpleNamespace(data_directory=tmp_path)
    identifier, directory, _, contents = package(tmp_path / "backups")
    original = administration.verify_backup

    def checked_then_changed(*args, **kwargs):
        assert_read_owned(settings, identifier)
        result = original(*args, **kwargs)
        path = directory / "database.dump"
        path.write_bytes(path.read_bytes() + b"changed")
        return result

    monkeypatch.setattr(administration, "verify_backup", checked_then_changed)
    with pytest.raises(ApiError, match="backup_file_size_mismatch"):
        administration.prepare_archive(settings, backup_id=identifier)
    with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
        pass
    assert directory.is_dir()
    assert (directory / "settings.json").read_bytes() == contents["settings.json"]
    assert list((tmp_path / "admin-downloads").iterdir()) == []


def test_exclusive_owner_rejects_archive_before_reading_source(tmp_path, monkeypatch):
    settings = SimpleNamespace(data_directory=tmp_path)
    identifier, _, _, _ = package(tmp_path / "backups")
    reads = []
    original = administration._manifest

    def observed(*args, **kwargs):
        reads.append(True)
        return original(*args, **kwargs)

    monkeypatch.setattr(administration, "_manifest", observed)
    with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
        with pytest.raises(ApiError, match="backup_busy"):
            administration.prepare_archive(settings, backup_id=identifier)
    assert reads == []


def test_leased_verifier_takes_shared_before_control_gate_and_through_hash(tmp_path):
    settings = SimpleNamespace(data_directory=tmp_path)
    identifier, _, _, _ = package(tmp_path / "backups")
    stages = []

    def before_read():
        assert_read_owned(settings, identifier)
        stages.append("short_control_gate")

    def budget():
        # Acquisition calls the budget before owning the lock as well, so only
        # inspect later calls, after the short DB gate returned.
        if stages:
            assert_read_owned(settings, identifier)
            stages.append("hash")

    manifest = service.verify_backup_leased(
        settings, identifier, before_read=before_read, check_budget=budget
    )
    assert manifest["backup_id"] == str(identifier)
    assert stages[0] == "short_control_gate" and stages.count("hash") >= 3
    with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
        pass


def assert_exclusive_owned(settings, identifier):
    for lease in (
        backup_read_lease(settings, identifier, timeout_seconds=0),
        backup_exclusive_lease(settings, (identifier,), timeout_seconds=0),
    ):
        with pytest.raises(BackupLeaseError, match="backup_busy"):
            with lease:
                pytest.fail("creation did not retain one exclusive lease")


def creation_fixture(tmp_path, monkeypatch):
    tool = tmp_path / "synthetic-tool-not-executed"
    tool.write_bytes(b"fixture")
    settings = Settings(
        _env_file=None, environment="test", data_directory=tmp_path,
        pg_dump_executable=tool,
    )
    identifier, instance, epoch = uuid4(), uuid4(), uuid4()
    dumps = []

    class Result:
        def __init__(self, rows):
            self.rows = rows

        def __iter__(self):
            return iter(self.rows)

        def fetchone(self):
            return self.rows[0]

        def fetchall(self):
            return self.rows

    class Connection:
        def execute(self, query):
            assert_exclusive_owned(settings, identifier)
            if "alembic_version" in query:
                return Result([("0014_import_source_release",)])
            if "server_state" in query:
                return Result([(instance, epoch)])
            assert "FROM attachments" in query
            return Result([])

    class Maintenance:
        def __init__(self, _settings):
            pass

        def __enter__(self):
            assert_exclusive_owned(settings, identifier)
            return SimpleNamespace(connection=Connection())

        def __exit__(self, *args):
            assert_exclusive_owned(settings, identifier)

    def dump(_tool, _settings, target, _root, **_kwargs):
        assert_exclusive_owned(settings, identifier)
        raw = b"PGDMPsynthetic-lease-only-not-a-real-pg-dump"
        target.write_bytes(raw)
        dumps.append(target)
        return {
            "path": "database.dump", "size_bytes": len(raw),
            "sha256": hashlib.sha256(raw).hexdigest(),
        }

    monkeypatch.setattr(service, "_dump", dump)
    monkeypatch.setattr(service, "_database_summary", lambda *a, **k: {
        "algorithm": "sha256-length-framed-jsonb-utc-c-order-v1",
        "tables": {"fixture": {"count": 0, "sha256": hashlib.sha256(b"").hexdigest()}},
    })
    return settings, identifier, instance, epoch, Maintenance, dumps


def test_worker_creation_and_same_id_retry_have_one_ex_no_recursive_sh(tmp_path, monkeypatch):
    settings, identifier, instance, epoch, maintenance, dumps = creation_fixture(
        tmp_path, monkeypatch
    )
    actual = runtime.create_backup

    def create(*args, **kwargs):
        return actual(*args, **kwargs, lease_factory=maintenance)

    monkeypatch.setattr(runtime, "create_backup", create)
    worker = runtime.Worker.__new__(runtime.Worker)
    worker.settings = settings
    first = worker._create_backup_manifest(identifier, epoch, instance, remaining=300)
    root = tmp_path / "backups" / str(identifier)
    frozen = {p.name: p.read_bytes() for p in root.iterdir() if p.is_file()}
    second = worker._create_backup_manifest(identifier, epoch, instance, remaining=300)
    assert first == second and len(dumps) == 1
    assert {p.name: p.read_bytes() for p in root.iterdir() if p.is_file()} == frozen
    with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
        pass


def test_failed_creation_retains_partial_and_releases_exclusive(tmp_path, monkeypatch):
    settings, identifier, _, _, maintenance, _ = creation_fixture(tmp_path, monkeypatch)

    def fail(*args, **kwargs):
        assert_exclusive_owned(settings, identifier)
        raise service.BackupError("synthetic_dump_failure")

    monkeypatch.setattr(service, "_dump", fail)
    with pytest.raises(service.BackupError, match="synthetic_dump_failure"):
        service.create_backup(
            settings, tmp_path / "backups", pg_dump=settings.pg_dump_executable,
            backup_id=identifier, lease_factory=maintenance,
        )
    assert (tmp_path / "backups" / str(identifier)).is_dir()
    assert not (tmp_path / "backups" / str(identifier) / "manifest.json").exists()
    with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
        pass


def test_closed_creation_token_cannot_skip_a_new_exclusive_lease(tmp_path, monkeypatch):
    settings, identifier, _, _, maintenance, _ = creation_fixture(tmp_path, monkeypatch)
    root = tmp_path / "backups"
    with service._creation_lease(root, identifier) as token:
        pass
    with pytest.raises(service.BackupError, match="backup_creation_lease_invalid"):
        service.create_backup(
            settings, root, pg_dump=settings.pg_dump_executable, backup_id=identifier,
            lease_factory=maintenance, _package_lease=token,
        )
    assert not (root / str(identifier)).exists()


@pytest.mark.parametrize("changed", ["root", "backup_id"])
def test_creation_token_cannot_authorize_another_package(tmp_path, monkeypatch, changed):
    settings, identifier, _, _, maintenance, _ = creation_fixture(tmp_path, monkeypatch)
    root = tmp_path / "backups"
    with service._creation_lease(root, identifier) as token:
        other_root = tmp_path / "other" if changed == "root" else root
        other_id = uuid4() if changed == "backup_id" else identifier
        with pytest.raises(service.BackupError, match="backup_creation_lease_invalid"):
            service.create_backup(
                settings, other_root, pg_dump=settings.pg_dump_executable, backup_id=other_id,
                lease_factory=maintenance, _package_lease=token,
            )
        assert not (other_root / str(other_id)).exists()


def test_metadata_uses_nonwaiting_shared_lease_and_busy_is_unavailable(tmp_path, monkeypatch):
    settings = SimpleNamespace(data_directory=tmp_path)
    identifier, _, _, _ = package(tmp_path / "backups")
    original = administration._manifest
    observed = []

    def reading(*args, **kwargs):
        assert_read_owned(settings, identifier)
        observed.append(True)
        return original(*args, **kwargs)

    monkeypatch.setattr(administration, "_manifest", reading)
    with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
        busy = administration._metadata(tmp_path / "backups", identifier)
    assert busy["state"] == "unavailable" and busy["error_code"] == "backup_busy"
    assert observed == []
    with backup_read_lease(settings, identifier):
        available = administration._metadata(tmp_path / "backups", identifier)
    assert available["state"] == "manifest_available" and observed == [True]


def test_creation_control_gate_inside_ex_rejects_before_package_io(tmp_path, monkeypatch):
    settings, identifier, instance, epoch, _, dumps = creation_fixture(tmp_path, monkeypatch)
    worker = runtime.Worker.__new__(runtime.Worker)
    worker.settings = settings
    calls = []

    def denied(value):
        assert value == identifier
        assert_exclusive_owned(settings, identifier)
        assert not (tmp_path / "backups" / str(identifier)).exists()
        calls.append(value)
        raise ApiError("backup_control_conflict", 409)

    with pytest.raises(ApiError, match="backup_control_conflict"):
        worker._create_backup_manifest(
            identifier, epoch, instance, remaining=300, before_read=denied
        )
    assert calls == [identifier] and dumps == []
    with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
        pass
