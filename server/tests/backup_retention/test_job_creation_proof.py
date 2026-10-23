"""Private creation-journal recovery and typed SH contexts; no DB or pg_dump."""

import hashlib
from uuid import uuid4

import pytest

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.backups import job_references as refs
from flowtrace_server.backups.leases import BackupLeaseError, backup_exclusive_lease
from flowtrace_server.backups.service import verify_backup
from flowtrace_server.config import Settings
from flowtrace_server.imports.parsers import canonical

from . import test_retention_io as io_fixture


def setup(tmp_path):
    settings = Settings(_env_file=None, environment="test", data_directory=tmp_path)
    binding = dict(
        backup_id=uuid4(), job_id=uuid4(), owner_user_id=uuid4(), instance_id=uuid4(), epoch=uuid4()
    )
    return settings, binding


def write_package(settings, binding, monkeypatch):
    monkeypatch.setattr(io_fixture, "uuid4", lambda: binding["backup_id"])
    return io_fixture.package(settings, instance=binding["instance_id"], epoch=binding["epoch"])


def prepare(settings, binding, manifest):
    return refs.prepare_created_backup(
        settings, backup_id=binding["backup_id"], job_id=binding["job_id"],
        owner_user_id=binding["owner_user_id"],
        manifest_sha256=hashlib.sha256(canonical(manifest)).hexdigest(),
    )


def journal_snapshot(root):
    # LockFileEx also protects the lock byte from unrelated file reads on
    # Windows. Snapshot the two journals, never read the live lock handle.
    return {path.name: path.read_bytes() for path in root.glob("creation-*.json")}


def test_new_start_and_completion_are_no_overwrite_exact_replay(tmp_path, monkeypatch):
    settings, binding = setup(tmp_path)
    identifier = binding["backup_id"]
    with backup_exclusive_lease(settings, (identifier,)):
        start = refs.start_creation(settings, **binding)
        _, root, manifest = write_package(settings, binding, monkeypatch)
        before = io_fixture.snapshot(root)
        assert verify_backup(root.parent, identifier) == manifest
        refs.complete_creation(settings, start, manifest)
        controls = settings.data_directory / "backup-controls" / str(identifier)
        frozen = journal_snapshot(controls)
        assert refs.start_creation(settings, **binding) == start
        refs.complete_creation(settings, start, manifest)
        assert journal_snapshot(controls) == frozen
        assert io_fixture.snapshot(root) == before
    with prepare(settings, binding, manifest) as prepared:
        assert prepared.completion.nonce == start.nonce
        with pytest.raises(BackupLeaseError, match="backup_busy"):
            with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
                pytest.fail("registration preparation released source early")
    assert prepared.closed and prepared.package.closed
    prepared.close()
    with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
        pass


def test_lost_completion_full_existing_package_finishes_same_start(tmp_path, monkeypatch):
    settings, binding = setup(tmp_path)
    identifier = binding["backup_id"]
    with backup_exclusive_lease(settings, (identifier,)):
        start = refs.start_creation(settings, **binding)
        _, root, _ = write_package(settings, binding, monkeypatch)
        frozen = io_fixture.snapshot(root)
    # Simulate a different process turn reopening the private start and doing a
    # fresh whole-package verify, with no new dump or replacement of old bytes.
    with backup_exclusive_lease(settings, (identifier,)):
        reopened = refs.start_creation(settings, **binding)
        assert reopened == start
        manifest = verify_backup(root.parent, identifier)
        refs.complete_creation(settings, reopened, manifest)
    with prepare(settings, binding, manifest) as prepared:
        assert prepared.completion.job_id == binding["job_id"]
    assert io_fixture.snapshot(root) == frozen


def test_complete_old_package_without_start_remains_unclaimed(tmp_path, monkeypatch):
    settings, binding = setup(tmp_path)
    identifier, root, manifest = write_package(settings, binding, monkeypatch)
    before = io_fixture.snapshot(root)
    with backup_exclusive_lease(settings, (identifier,)):
        assert refs.start_creation(settings, **binding) is None
    with prepare(settings, binding, manifest) as prepared:
        assert prepared.completion is None
    controls = settings.data_directory / "backup-controls" / str(identifier)
    assert not (controls / "creation-start.json").exists()
    assert not (controls / "creation-complete.json").exists()
    assert io_fixture.snapshot(root) == before


def test_legacy_without_summary_and_with_unlisted_file_keeps_old_reader_contract(
    tmp_path, monkeypatch
):
    settings, binding = setup(tmp_path)
    identifier, root, manifest = write_package(settings, binding, monkeypatch)
    del manifest["database_summary"]
    (root / "manifest.json").write_bytes(canonical(manifest))
    (root / "old-unlisted-file.bin").write_bytes(b"legacy-file-stays-protected")
    before = io_fixture.snapshot(root)
    assert verify_backup(root.parent, identifier) == manifest
    with prepare(settings, binding, manifest) as prepared:
        assert prepared.completion is None and prepared.package is None
        assert prepared.backup_id == identifier
        with pytest.raises(BackupLeaseError):
            with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
                pytest.fail("legacy source SH ended before completion")
    assert io_fixture.snapshot(root) == before


@pytest.mark.parametrize("changed", ["job_id", "owner_user_id", "instance_id", "epoch"])
def test_same_uuid_cannot_rebind_existing_start(tmp_path, changed):
    settings, binding = setup(tmp_path)
    with backup_exclusive_lease(settings, (binding["backup_id"],)):
        refs.start_creation(settings, **binding)
        controls = settings.data_directory / "backup-controls" / str(binding["backup_id"])
        before = journal_snapshot(controls)
        with pytest.raises(ApiError, match="backup_creation_proof_conflict"):
            refs.start_creation(settings, **{**binding, changed: uuid4()})
        assert journal_snapshot(controls) == before


@pytest.mark.parametrize("mutation", ["nonce", "extra", "duplicate", "oversized", "hardlink"])
def test_invalid_private_completion_never_yields_registration_context(
    tmp_path, monkeypatch, mutation
):
    settings, binding = setup(tmp_path)
    identifier = binding["backup_id"]
    with backup_exclusive_lease(settings, (identifier,)):
        start = refs.start_creation(settings, **binding)
        _, root, manifest = write_package(settings, binding, monkeypatch)
        refs.complete_creation(settings, start, manifest)
    controls = settings.data_directory / "backup-controls" / str(identifier)
    path = controls / "creation-complete.json"
    raw = path.read_bytes()
    value = refs._Completion.model_validate_json(raw).model_dump(mode="json")
    if mutation == "nonce":
        path.write_bytes(canonical({**value, "nonce": str(uuid4())}))
    elif mutation == "extra":
        path.write_bytes(canonical({**value, "endpoint": "private-sentinel"}))
    elif mutation == "duplicate":
        path.write_bytes(raw[:-1] + b',"nonce":"private-sentinel"}')
    elif mutation == "oversized":
        path.write_bytes(b"private-sentinel" * 4096)
    else:
        (tmp_path / "own-synthetic-link").hardlink_to(path)
    before = io_fixture.snapshot(root)
    with pytest.raises(ApiError) as caught:
        prepare(settings, binding, manifest)
    assert "private-sentinel" not in str(caught.value)
    assert io_fixture.snapshot(root) == before
    with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
        pass


def test_partial_package_does_not_gain_completion_and_is_preserved(tmp_path):
    settings, binding = setup(tmp_path)
    identifier = binding["backup_id"]
    with backup_exclusive_lease(settings, (identifier,)):
        refs.start_creation(settings, **binding)
        package = settings.data_directory / "backups" / str(identifier)
        package.mkdir(parents=True)
        (package / "database.dump").write_bytes(b"PGDMPpartial-keep")
        frozen = io_fixture.snapshot(package)
        assert refs.start_creation(settings, **binding) is not None
        with pytest.raises(FileNotFoundError):
            verify_backup(package.parent, identifier)
    assert io_fixture.snapshot(package) == frozen
    controls = settings.data_directory / "backup-controls" / str(identifier)
    assert not (controls / "creation-complete.json").exists()
