"""Closed backup metadata and action-scoped raw download preparation.

Only UUIDs cross the management boundary. Metadata is a manifest declaration
plus historical worker evidence, never a current integrity promise. A raw ZIP
is verified afresh, copied with independent hashes, and kept open in private
storage until its authenticated HTTP response has finished.
"""

import hashlib
import os
import re
import stat
import time
import zipfile
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import BinaryIO
from uuid import UUID, uuid4

from sqlalchemy import func, select

from flowtrace_server.admin.service import (
    audit,
    reauthenticate_admin,
    require_portal,
    require_recovery,
)
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import User
from flowtrace_server.auth.service import PASSWORDS, assert_active_principal
from flowtrace_server.imports.parsers import ImportFormatError, canonical, decode_json
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.jobs.store import JobResult
from flowtrace_server.persistence.private_files import (
    UnsafeFilePath,
    private_directory,
    private_open,
    private_unlink,
    regular_file,
)

from .leases import BackupLeaseError, backup_read_lease
from .service import (
    MAX_BACKUP_BYTES,
    MAX_FILES,
    OBJECT_NAME,
    BackupError,
    _package_settings,
    verify_backup,
)

PAGE_SIZE = 20
MAX_CATALOG_ENTRIES = 10000
MAX_MANIFEST_BYTES = 5 * 1024 * 1024
MAX_ARCHIVE_BYTES = MAX_BACKUP_BYTES + MAX_MANIFEST_BYTES + (MAX_FILES + 2) * 512 + 65536
DOWNLOAD_SECONDS = 120
CHUNK_BYTES = 1024 * 1024
SAFE_CODES = frozenset(
    {
        "backup_manifest_invalid",
        "backup_database_summary_invalid",
        "backup_manifest_path_invalid",
        "backup_file_size_mismatch",
        "backup_file_hash_mismatch",
        "backup_manifest_incomplete",
        "backup_database_format_invalid",
        "backup_too_large",
        "backup_too_many_files",
        "backup_package_changed",
        "backup_archive_too_large",
        "backup_download_timeout",
    }
)


def _identifier(value):
    if not isinstance(value, UUID):
        raise ApiError("backup_input_invalid", 422)
    return value


def _root(settings):
    root = Path(os.path.abspath(settings.data_directory)) / "backups"
    # private_open checks descendants; validate configured ancestors as well.
    for part in (root, *root.parents):
        if part.is_symlink() or part.is_junction():
            raise UnsafeFilePath
    if root.exists() and not root.is_dir():
        raise UnsafeFilePath
    return root


def _instant(value):
    if not isinstance(value, str) or len(value) > 48:
        raise BackupError("backup_manifest_invalid")
    try:
        instant = datetime.fromisoformat(value)
        if instant.tzinfo is None or instant.utcoffset() is None:
            raise ValueError
        return instant.astimezone(UTC).isoformat()
    except (ValueError, OverflowError):
        raise BackupError("backup_manifest_invalid") from None


def _open_checked(path, root, *, create=False):
    manager = private_open(path, root, create=create)
    stream = manager.__enter__()
    try:
        opened = os.fstat(stream.fileno())
        current = regular_file(path, root)
        if (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
            raise UnsafeFilePath
    except BaseException:
        manager.__exit__(None, None, None)
        raise
    return manager, stream


def _manifest(root, backup_id):
    target = root / str(backup_id)
    manager, stream = _open_checked(target / "manifest.json", root)
    try:
        raw = stream.read(MAX_MANIFEST_BYTES + 1)
    finally:
        manager.__exit__(None, None, None)
    if len(raw) > MAX_MANIFEST_BYTES:
        raise BackupError("backup_manifest_invalid")
    manifest = decode_json(raw)
    if (
        not isinstance(manifest, dict)
        or manifest.get("format") != "flowtrace-backup-v1"
        or manifest.get("backup_id") != str(backup_id)
        or manifest.get("server_version") != "0.1.0"
        or not isinstance(manifest.get("schema_versions"), list)
        or not 1 <= len(manifest["schema_versions"]) <= 10
        or any(
            not isinstance(v, str) or not re.fullmatch(r"[a-z0-9_]{1,80}", v)
            for v in manifest["schema_versions"]
        )
        or not isinstance(manifest.get("database"), dict)
        or manifest["database"].get("path") != "database.dump"
        or not isinstance(manifest.get("files"), list)
        or not 1 <= len(manifest["files"]) <= MAX_FILES
    ):
        raise BackupError("backup_manifest_invalid")
    created_at = _instant(manifest.get("created_at"))
    names, total = set(), 0
    for index, item in enumerate([manifest["database"], *manifest["files"]]):
        if not isinstance(item, dict):
            raise BackupError("backup_manifest_invalid")
        name = item.get("path")
        if not isinstance(name, str) or (
            index > 0
            and name != "settings.json"
            and not (name.startswith("objects/") and OBJECT_NAME.fullmatch(name[8:]))
        ):
            raise BackupError("backup_manifest_path_invalid")
        size, digest = item.get("size_bytes"), item.get("sha256")
        if (
            name in names
            or type(size) is not int
            or not 0 <= size <= MAX_BACKUP_BYTES
            or not isinstance(digest, str)
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
        ):
            raise BackupError("backup_manifest_invalid")
        names.add(name)
        total += size
        if total > MAX_BACKUP_BYTES:
            raise BackupError("backup_too_large")
    if "settings.json" not in names:
        raise BackupError("backup_manifest_incomplete")
    return (
        manifest,
        raw,
        {
            "backup_id": str(backup_id),
            "created_at": created_at,
            "server_version": manifest["server_version"],
            "schema_versions": list(manifest["schema_versions"]),
            "declared_bytes": total + len(raw),
            "file_count": len(names) + 1,
            "manifest_sha256": hashlib.sha256(canonical(manifest)).hexdigest(),
            "state": "manifest_available",
            "error_code": None,
        },
    )


def _error(error):
    if isinstance(error, UnsafeFilePath):
        return "backup_storage_unsafe"
    if isinstance(error, FileNotFoundError):
        return "backup_not_found"
    if isinstance(error, BackupError) and str(error) in SAFE_CODES:
        return str(error)
    if isinstance(error, ImportFormatError):
        return "backup_manifest_invalid"
    return "backup_storage_unavailable"


def _metadata(root, backup_id):
    try:
        # Catalog callers may still own short authority reads. Never wait for a
        # package there: show unavailable while an exclusive owner is active.
        with backup_read_lease(_package_settings(root), backup_id, timeout_seconds=0):
            return _manifest(root, backup_id)[2]
    except (OSError, BackupError, BackupLeaseError, ImportFormatError) as error:
        return {
            "backup_id": str(backup_id),
            "state": "unavailable",
            "error_code": error.code if isinstance(error, BackupLeaseError) else _error(error),
            "created_at": None,
            "server_version": None,
            "schema_versions": [],
            "declared_bytes": None,
            "file_count": None,
            "manifest_sha256": None,
        }


def _verification(job):
    return {
        "job_id": str(job.id),
        "status": job.status,
        "at": job.updated_at.isoformat(),
        "error_code": job.error_code,
    }


def latest_success(session, principal):
    assert_active_principal(session, principal, lock=False)
    require_portal(session, principal)
    records = session.scalars(
        select(BackgroundJob)
        .where(BackgroundJob.kind == "backup_verify", BackgroundJob.status == "succeeded")
        .order_by(BackgroundJob.updated_at.desc(), BackgroundJob.id.desc())
        .limit(50)
    )
    for record in records:
        try:
            result = JobResult.model_validate(record.result)
        except ValueError:
            continue
        if result.code == "backup_verified" and result.artifact_id and result.sha256:
            return {
                **_verification(record),
                "backup_id": result.artifact_id,
                "manifest_sha256": result.sha256,
            }
    return None


def list_backups(session, principal, settings, *, before=None):
    assert_active_principal(session, principal, lock=False)
    require_portal(session, principal)
    if before is not None:
        _identifier(before)
    try:
        root = _root(settings)
        identifiers = []
        if root.exists():
            with os.scandir(root) as entries:
                for count, entry in enumerate(entries, 1):
                    if count > MAX_CATALOG_ENTRIES:
                        raise ApiError("backup_catalog_limit", 503)
                    try:
                        value = UUID(entry.name)
                    except ValueError:
                        continue
                    if str(value) == entry.name:
                        identifiers.append(value)
        identifiers.sort(reverse=True)
        selected = [value for value in identifiers if before is None or value < before][
            : PAGE_SIZE + 1
        ]
        items = [_metadata(root, value) for value in selected[:PAGE_SIZE]]
    except OSError:
        raise ApiError("backup_storage_unavailable", 503) from None
    by_id = {item["backup_id"]: item for item in items}
    if by_id:
        target_id = BackgroundJob.payload["backup_id"].as_string()
        ranked = (
            select(
                BackgroundJob.id,
                func.row_number()
                .over(
                    partition_by=target_id,
                    order_by=(BackgroundJob.updated_at.desc(), BackgroundJob.id.desc()),
                )
                .label("position"),
            )
            .where(
                BackgroundJob.kind == "backup_verify",
                target_id.in_(by_id),
            )
            .subquery()
        )
        records = session.scalars(
            select(BackgroundJob)
            .join(ranked, BackgroundJob.id == ranked.c.id)
            .where(ranked.c.position == 1)
            .limit(PAGE_SIZE)
        )
        for record in records:
            item = by_id.get(record.payload["backup_id"])
            if item is not None and "verification" not in item:
                item["verification"] = _verification(record)
    return {
        "items": items,
        "has_more": len(selected) > PAGE_SIZE,
        "next_cursor": str(items[-1]["backup_id"]) if len(selected) > PAGE_SIZE else None,
        "latest_success": latest_success(session, principal),
    }


def get_backup(session, principal, settings, backup_id):
    assert_active_principal(session, principal, lock=False)
    require_portal(session, principal)
    _identifier(backup_id)
    try:
        return _metadata(_root(settings), backup_id)
    except OSError:
        raise ApiError("backup_storage_unavailable", 503) from None


class _LimitedWriter:
    def __init__(self, stream):
        self.stream = stream

    def write(self, value):
        if self.stream.tell() + len(value) > MAX_ARCHIVE_BYTES:
            raise BackupError("backup_archive_too_large")
        return self.stream.write(value)

    def __getattr__(self, name):
        return getattr(self.stream, name)


@dataclass
class PreparedDownload:
    backup_id: UUID
    stream: BinaryIO
    manager: object
    path: Path
    root: Path
    filename: str
    size_bytes: int
    sha256: str
    file_count: int
    closed: bool = False

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            self.manager.__exit__(None, None, None)
        finally:
            try:
                private_unlink(self.path, self.root)
            except OSError:
                # An OS-blocked artifact remains in private storage, never published.
                pass

    def chunks(self):
        try:
            while chunk := self.stream.read(CHUNK_BYTES):
                yield chunk
        finally:
            self.close()


def _deadline(start):
    if time.monotonic() - start > DOWNLOAD_SECONDS:
        raise BackupError("backup_download_timeout")


def _zip_info(name, size):
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_STORED
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | 0o600) << 16
    info.file_size = size
    return info


def precheck_download(session, principal, *, backup_id, password):
    """Read-only preflight; caller explicitly ends this transaction before I/O."""
    _identifier(backup_id)
    assert_active_principal(session, principal, lock=False)
    require_recovery(session, principal)
    user = session.get(User, principal.user_id)
    if (
        not isinstance(password, str)
        or not 12 <= len(password) <= 256
        or not PASSWORDS.verify(password, user.password_hash)
    ):
        raise ApiError("reauthentication_failed", 403)


def authorize_download(session, principal, prepared, *, password):
    """Short locked reauthentication after I/O; caller commits before streaming."""
    if prepared.closed or prepared.stream.closed:
        raise ApiError("backup_download_invalid", 409)
    reauthenticate_admin(session, principal, password, capability="recovery")
    audit(
        session,
        principal.user_id,
        "backup.raw_download",
        prepared.backup_id,
        bytes=prepared.size_bytes,
        files=prepared.file_count,
        succeeded=True,
    )


def prepare_archive(settings, *, backup_id, before_read=None):
    """Hold the source SH until an independently verified ZIP is complete.

    A trusted caller may supply a short control gate which commits before
    returning. No caller database Session is retained during the long copy.
    """
    _identifier(backup_id)
    try:
        with backup_read_lease(settings, backup_id):
            if before_read is not None:
                before_read()
            return _prepare_archive(settings, backup_id=backup_id)
    except BackupLeaseError as error:
        raise ApiError(error.code, 409 if error.transient else 503) from None


def _prepare_archive(settings, *, backup_id):
    """Bounded filesystem phase; the trusted wrapper owns the source lease."""
    _identifier(backup_id)
    started = time.monotonic()
    output = None
    manager = stream = None
    try:
        root = _root(settings)
        manifest, raw, metadata = _manifest(root, backup_id)
        verified = verify_backup(root, backup_id, check_budget=lambda: _deadline(started))
        if hashlib.sha256(canonical(verified)).hexdigest() != metadata["manifest_sha256"]:
            raise BackupError("backup_package_changed")
        _deadline(started)
        private_root = private_directory(
            Path(os.path.abspath(settings.data_directory)) / "admin-downloads"
        )
        output = private_root / f"{uuid4()}.zip"
        manager, stream = _open_checked(output, private_root, create=True)
        with zipfile.ZipFile(_LimitedWriter(stream), mode="w", allowZip64=True) as archive:
            archive.writestr(_zip_info(f"{backup_id}/manifest.json", len(raw)), raw)
            for item in [manifest["database"], *manifest["files"]]:
                _deadline(started)
                source_manager, source = _open_checked(root / str(backup_id) / item["path"], root)
                checksum, count = hashlib.sha256(), 0
                try:
                    with archive.open(
                        _zip_info(f"{backup_id}/{item['path']}", item["size_bytes"]), "w"
                    ) as target:
                        while chunk := source.read(
                            min(CHUNK_BYTES, item["size_bytes"] - count + 1)
                        ):
                            count += len(chunk)
                            if count > item["size_bytes"]:
                                raise BackupError("backup_file_size_mismatch")
                            _deadline(started)
                            checksum.update(chunk)
                            target.write(chunk)
                finally:
                    source_manager.__exit__(None, None, None)
                if count != item["size_bytes"]:
                    raise BackupError("backup_file_size_mismatch")
                if checksum.hexdigest() != item["sha256"]:
                    raise BackupError("backup_file_hash_mismatch")
        if _manifest(root, backup_id)[1] != raw:
            raise BackupError("backup_package_changed")
        stream.flush()
        size = stream.tell()
        checksum = hashlib.sha256()
        stream.seek(0)
        while chunk := stream.read(CHUNK_BYTES):
            _deadline(started)
            checksum.update(chunk)
        stream.seek(0)
        return PreparedDownload(
            backup_id,
            stream,
            manager,
            output,
            private_root,
            f"flowtrace-backup-{backup_id}.zip",
            size,
            checksum.hexdigest(),
            metadata["file_count"],
        )
    except BaseException as error:
        if manager is not None:
            manager.__exit__(None, None, None)
        if output is not None:
            try:
                private_unlink(output, output.parent)
            except OSError:
                pass
        if isinstance(error, (OSError, BackupError, ImportFormatError)):
            code = _error(error)
            raise ApiError(code, 404 if code == "backup_not_found" else 409) from None
        raise
