import hashlib
import json
from uuid import uuid4

import pytest

from flowtrace_server.backups.service import BackupError, _environment, verify_backup
from flowtrace_server.config import Settings
from flowtrace_server.persistence.private_files import UnsafeFilePath


def package(tmp_path):
    identifier = uuid4()
    directory = tmp_path / str(identifier)
    directory.mkdir()
    database, settings = b"PGDMPsynthetic-checksum-only", b'{"environment":"test"}'
    (directory / "database.dump").write_bytes(database)
    (directory / "settings.json").write_bytes(settings)
    manifest = {
        "format": "flowtrace-backup-v1",
        "backup_id": str(identifier),
        "server_version": "0.1.0",
        "schema_versions": ["0007_import_batches"],
        "database": {
            "path": "database.dump",
            "size_bytes": len(database),
            "sha256": hashlib.sha256(database).hexdigest(),
        },
        "files": [
            {
                "path": "settings.json",
                "size_bytes": len(settings),
                "sha256": hashlib.sha256(settings).hexdigest(),
            }
        ],
    }
    (directory / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return identifier, directory, manifest


def test_manifest_checks_every_file_size_and_hash(tmp_path):
    identifier, directory, _ = package(tmp_path)
    assert verify_backup(tmp_path, identifier)["format"] == "flowtrace-backup-v1"
    (directory / "settings.json").write_bytes(b"x" * len(b'{"environment":"test"}'))
    with pytest.raises(BackupError, match="backup_file_hash_mismatch"):
        verify_backup(tmp_path, identifier)


@pytest.mark.parametrize(
    "name",
    [
        "../../outside",
        "objects/../settings.json",
        "objects/fake.bin",
        "C:/Windows/private",
        "\\\\server\\private",
    ],
)
def test_manifest_paths_are_closed_not_zip_paths(tmp_path, name):
    identifier, directory, manifest = package(tmp_path)
    manifest["files"][0]["path"] = name
    (directory / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(BackupError, match="backup_manifest_path_invalid"):
        verify_backup(tmp_path, identifier)


def test_hard_linked_backup_data_is_rejected(tmp_path):
    identifier, directory, _ = package(tmp_path)
    alias = tmp_path / "outside"
    try:
        alias.hardlink_to(directory / "database.dump")
    except OSError:
        pytest.skip("host does not allow hard links")
    with pytest.raises(UnsafeFilePath):
        verify_backup(tmp_path, identifier)


def test_failure_never_fabricates_success_manifest(tmp_path):
    identifier = uuid4()
    (tmp_path / str(identifier)).mkdir()
    with pytest.raises(FileNotFoundError):
        verify_backup(tmp_path, identifier)


def test_backup_subprocess_keeps_tls_policy_and_ignores_inherited_pg_override(monkeypatch):
    monkeypatch.setenv("PGHOSTADDR", "192.0.2.1")
    settings = Settings(
        _env_file=None,
        database_url=(
            "postgresql+psycopg://synthetic:synthetic@localhost/flowtrace_test_tls"
            "?sslmode=verify-full&sslrootcert=synthetic-ca.pem"
        ),
    )
    env = _environment(settings)
    assert env["PGSSLMODE"] == "verify-full"
    assert env["PGSSLROOTCERT"] == "synthetic-ca.pem"
    assert "PGHOSTADDR" not in env
    assert env["PGHOST"] == "localhost"


def test_unknown_db_connection_option_is_rejected_not_silently_downgraded():
    settings = Settings(
        _env_file=None,
        database_url=(
            "postgresql+psycopg://synthetic:synthetic@localhost/flowtrace_test_tls?unsafe=1"
        ),
    )
    with pytest.raises(BackupError, match="database_connection_option_unsupported"):
        _environment(settings)


@pytest.mark.parametrize(
    "summary",
    [
        {"algorithm": "arbitrary", "tables": {}},
        {"algorithm": "sha256-length-framed-jsonb-utc-c-order-v1", "tables": {}},
        {
            "algorithm": "sha256-length-framed-jsonb-utc-c-order-v1",
            "tables": {"../../private": {"count": 0, "sha256": "0" * 64}},
        },
        {
            "algorithm": "sha256-length-framed-jsonb-utc-c-order-v1",
            "tables": {"users": {"count": True, "sha256": "0" * 64}},
        },
    ],
)
def test_summary_is_closed_and_never_interpreted_as_arbitrary_sql(tmp_path, summary):
    identifier, directory, manifest = package(tmp_path)
    manifest["database_summary"] = summary
    (directory / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(BackupError, match="backup_database_summary_invalid"):
        verify_backup(tmp_path, identifier)
