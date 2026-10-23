import hashlib
import io
import os
import stat
import subprocess
import zipfile
from uuid import UUID, uuid4

import pytest
from admin.conftest import PASSWORD
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import AdminRole
from flowtrace_server.backups import administration as backups
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.jobs import store

from .conftest import package


def prepare(system):
    _, connection, principal, settings, identifier, *_ = system
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        backups.precheck_download(session, principal, backup_id=identifier, password=PASSWORD)
        session.commit()
    result = backups.prepare_archive(settings, backup_id=identifier)
    try:
        with Session(connection, join_transaction_mode="create_savepoint") as session:
            backups.authorize_download(session, principal, result, password=PASSWORD)
            session.commit()
        return result
    except BaseException:
        result.close()
        raise


def temporary_files(settings):
    directory = settings.data_directory / "admin-downloads"
    return list(directory.iterdir()) if directory.exists() else []


def test_archive_is_complete_exact_regular_private_and_cleaned_on_close(backup_system):
    _, connection, principal, settings, identifier, _, _, contents = backup_system
    result = prepare(backup_system)
    assert result.path.parent == settings.data_directory / "admin-downloads"
    assert result.path.exists() and not result.stream.closed
    raw = b"".join(result.chunks())
    assert len(raw) == result.size_bytes and hashlib.sha256(raw).hexdigest() == result.sha256
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        assert set(archive.namelist()) == {f"{identifier}/{name}" for name in contents}
        for name, expected in contents.items():
            info = archive.getinfo(f"{identifier}/{name}")
            assert stat.S_ISREG(info.external_attr >> 16)
            assert archive.read(info) == expected
    assert result.stream.closed and temporary_files(settings) == []
    result.close()
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        audit = session.scalar(select(AdminAudit).where(AdminAudit.action == "backup.raw_download"))
        assert audit.actor_id == principal.user_id and audit.target_id == identifier
        assert audit.summary == {"bytes": len(raw), "files": len(contents), "succeeded": True}


def test_partly_consumed_response_generator_closes_private_artifact(backup_system):
    result = prepare(backup_system)
    chunks = result.chunks()
    assert next(chunks)
    chunks.close()
    assert result.stream.closed and temporary_files(backup_system[3]) == []


@pytest.mark.parametrize("changed", ["hash", "size", "manifest_path", "duplicate", "bound"])
def test_changed_or_unsafe_backup_never_yields_an_archive(backup_system, changed):
    *_, directory, manifest, _contents = backup_system
    if changed == "hash":
        path = directory / "database.dump"
        raw = path.read_bytes()
        path.write_bytes(raw[:-1] + bytes([raw[-1] ^ 1]))
    elif changed == "size":
        (directory / "database.dump").write_bytes(b"PGDMP")
    else:
        if changed == "manifest_path":
            manifest["files"][0]["path"] = "../../private"
        elif changed == "duplicate":
            manifest["files"].append(manifest["files"][0])
        else:
            manifest["database"]["size_bytes"] = backups.MAX_BACKUP_BYTES + 1
        (directory / "manifest.json").write_bytes(canonical(manifest))
    with pytest.raises(ApiError) as error:
        prepare(backup_system)
    assert error.value.status == 409
    assert temporary_files(backup_system[3]) == []


def test_file_change_after_initial_verification_is_rehashed_while_archiving(
    backup_system, monkeypatch
):
    actual = backups.verify_backup

    def verify_then_damage(root, identifier, **kwargs):
        result = actual(root, identifier, **kwargs)
        path = root / str(identifier) / "database.dump"
        raw = path.read_bytes()
        path.write_bytes(raw[:-1] + bytes([raw[-1] ^ 1]))
        return result

    monkeypatch.setattr(backups, "verify_backup", verify_then_damage)
    with pytest.raises(ApiError) as error:
        prepare(backup_system)
    assert error.value.code == "backup_file_hash_mismatch"
    assert temporary_files(backup_system[3]) == []


@pytest.mark.parametrize("bound", ["bytes", "time"])
def test_archive_time_and_byte_limits_cleanup_partial_output(backup_system, monkeypatch, bound):
    monkeypatch.setattr(
        backups,
        "MAX_ARCHIVE_BYTES" if bound == "bytes" else "DOWNLOAD_SECONDS",
        100 if bound == "bytes" else -1,
    )
    with pytest.raises(ApiError) as error:
        prepare(backup_system)
    assert error.value.code == (
        "backup_archive_too_large" if bound == "bytes" else "backup_download_timeout"
    )
    assert temporary_files(backup_system[3]) == []


@pytest.mark.parametrize("link_kind", ["hard", "symbolic", "junction"])
def test_real_file_links_and_directory_junction_are_rejected(backup_system, link_kind):
    directory = backup_system[5]
    if link_kind == "hard":
        (directory.parent / "unit-hard-link").hardlink_to(directory / "database.dump")
    elif link_kind == "symbolic":
        target = directory / "database.dump"
        other = directory.parent / "unit-other-data"
        target.rename(other)
        try:
            target.symlink_to(other)
        except OSError:
            pytest.skip("host does not permit symbolic links")
    else:
        original = directory / "objects"
        other = directory.parent / "unit-other-objects"
        original.rename(other)
        if os.name != "nt":
            original.symlink_to(other, target_is_directory=True)
        else:

            def quote(value):
                return "'" + str(value).replace("'", "''") + "'"

            result = subprocess.run(
                [
                    "powershell",
                    "-NoProfile",
                    "-Command",
                    f"New-Item -ItemType Junction -Path {quote(original)} "
                    f"-Target {quote(other)} | Out-Null",
                ],
                capture_output=True,
                timeout=10,
            )
            assert result.returncode == 0
    with pytest.raises(ApiError) as error:
        prepare(backup_system)
    assert error.value.code == "backup_storage_unsafe"
    assert temporary_files(backup_system[3]) == []


def test_changed_current_role_is_denied_before_file_access(backup_system, monkeypatch):
    _, connection, principal, settings, identifier, *_ = backup_system
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        session.execute(
            delete(AdminRole).where(
                AdminRole.user_id == principal.user_id, AdminRole.role == "recovery_admin"
            )
        )
        session.commit()
    touched = []
    monkeypatch.setattr(backups, "_root", lambda _: touched.append(True))
    with pytest.raises(ApiError) as error:
        prepare(backup_system)
    assert error.value.code == "admin_recovery_required" and touched == []
    assert temporary_files(settings) == []


def test_pagination_metadata_and_historical_success_do_not_claim_current_integrity(backup_system):
    _, connection, principal, settings, identifier, directory, manifest, _ = backup_system
    for number in range(1, 23):
        package(directory.parent, backup_id=UUID(int=number))
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        record = store.enqueue(
            session,
            kind="backup_verify",
            occurrence_key=f"unit:{uuid4()}",
            owner_user_id=principal.user_id,
            payload={"backup_id": str(identifier)},
        )
        job_id = record.id
        lease = store.claim(session, uuid4(), {"backup_verify"})
        store.complete(
            session,
            lease,
            lambda *_: {
                "code": "backup_verified",
                "artifact_id": str(identifier),
                "sha256": hashlib.sha256(canonical(manifest)).hexdigest(),
            },
        )
        session.commit()
    # A previously valid file can change after the recorded successful job.
    (directory / "database.dump").write_bytes(b"PGDMPcorrupt_after_past_success")
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        first = backups.list_backups(session, principal, settings)
        second = backups.list_backups(
            session, principal, settings, before=UUID(first["next_cursor"])
        )
        assert len(first["items"]) == 20 and len(second["items"]) == 3
        assert {row["backup_id"] for row in first["items"]}.isdisjoint(
            row["backup_id"] for row in second["items"]
        )
        assert first["latest_success"]["job_id"] == str(job_id)
        metadata = backups.get_backup(session, principal, settings, identifier)
        assert metadata["state"] == "manifest_available"
        assert "database_summary" not in metadata and "payload" not in metadata
    with pytest.raises(ApiError):
        prepare(backup_system)


def test_manifest_declarations_count_complete_package_including_manifest(tmp_path):
    identifier, _, _, contents = package(tmp_path)
    _, raw, metadata = backups._manifest(tmp_path, identifier)
    assert metadata["file_count"] == len(contents) == 5
    assert metadata["declared_bytes"] == sum(len(content) for content in contents.values())
    assert len(raw) == len(contents["manifest.json"])
