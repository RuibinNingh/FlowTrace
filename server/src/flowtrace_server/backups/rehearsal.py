"""Explicitly staged isolated restores; no target I/O under source write locks.

Prepared objects are trusted internal data, never public form inputs. Callers
end read transactions before build/prepare I/O, commit final authorization or
enqueue themselves, and close a PreparedRestoreIntent in finally. Target effects
cannot share the source job transaction: a private lock and independently
reverified receipt make a later generation safe without overwriting partial data.
"""

import hashlib
import ipaddress
import os
import re
from contextlib import ExitStack, contextmanager
from dataclasses import dataclass
from datetime import timedelta
from time import monotonic, sleep
from uuid import UUID, uuid4

import portalocker
from pydantic import ValidationError
from sqlalchemy import select

from flowtrace_server.admin.service import audit, reauthenticate_admin, require_recovery
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import User
from flowtrace_server.auth.service import PASSWORDS, assert_active_principal, now
from flowtrace_server.config import Settings
from flowtrace_server.configuration.models import ConfigurationHead
from flowtrace_server.configuration.runtime import read_runtime_configuration
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.persistence.private_files import (
    UnsafeFilePath,
    private_directory,
    private_open,
    private_unlink,
    regular_file,
)
from flowtrace_server.persistence.testing import require_isolated_database

from . import service as backups
from .leases import BackupLeaseError, backup_read_lease
from .rehearsal_schemas import (
    RestorePreview,
    RestorePreviewRecord,
    RestoreRehearsalPayload,
    RestoreVerifiedReceipt,
)

MAX_RECORD_BYTES = 16384
PREVIEW_SECONDS = 300
_PREPARED_TRUST = object()


class RehearsalError(ApiError):
    def __init__(self, code, status=409, *, transient=False):
        super().__init__(code, status)
        self.transient = transient


@dataclass(frozen=True)
class RestorePrecheck:
    actor_id: UUID
    session_id: UUID
    config_version: int
    source_epoch: UUID


@dataclass
class PreparedRestorePreview:
    record: RestorePreviewRecord
    _guard: ExitStack
    _trust: object
    closed: bool = False

    def close(self):
        if not self.closed:
            self.closed = True
            self._guard.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


@dataclass
class PreparedRestoreIntent:
    record: RestorePreviewRecord
    _guard: ExitStack
    _trust: object
    closed: bool = False

    def close(self):
        if not self.closed:
            self.closed = True
            self._guard.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def _digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def _target(settings, target_id):
    if not isinstance(target_id, UUID) or target_id not in settings.restore_targets:
        raise RehearsalError("restore_target_not_registered", 404)
    target = settings.restore_targets[target_id]
    if not target.pg_restore_executable.is_file():
        raise RehearsalError("restore_tool_unavailable", 503)
    return target


def _target_settings(target):
    return Settings(
        _env_file=None,
        environment="test",
        database_url=target.database_url,
        data_directory=target.data_directory,
        diagnostics_enabled=False,
    )


def _fingerprint(target):
    # Private binding only; never return the credential-bearing descriptor or
    # this fingerprint from public target/preview metadata.
    return _digest(
        {
            "label": target.label,
            "database": target.database_url.get_secret_value(),
            "root": os.path.abspath(target.data_directory),
            "tool": os.path.abspath(target.pg_restore_executable),
        }
    )


def _control(settings, target_id):
    root = private_directory(settings.data_directory.absolute() / "restore-targets")
    return private_directory(root / str(target_id))


@contextmanager
def _target_lock(settings, target_id):
    root = _control(settings, target_id)
    path = root / "target.lock"
    try:
        with private_open(path, root, create=True):
            pass
    except FileExistsError:
        regular_file(path, root)
    with private_open(path, root, append=True) as stream:
        started = monotonic()
        while True:
            try:
                portalocker.lock(stream, portalocker.LOCK_EX | portalocker.LOCK_NB)
                break
            except portalocker.exceptions.LockException:
                if monotonic() - started >= 5:
                    raise RehearsalError("restore_target_busy", transient=True) from None
                sleep(0.01)
        try:
            yield root
        finally:
            portalocker.unlock(stream)


def _write_record(path, root, record):
    content = record.model_dump_json().encode()
    if len(content) > MAX_RECORD_BYTES or path.exists() or path.is_symlink() or path.is_junction():
        raise RehearsalError("restore_record_conflict")
    temporary = root / f"{uuid4()}.pending"
    try:
        with private_open(temporary, root, create=True) as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        if os.name != "nt":
            descriptor = os.open(root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
    finally:
        private_unlink(temporary, root)


def _read_record(path, root, model):
    try:
        with private_open(path, root) as stream:
            raw = stream.read(MAX_RECORD_BYTES + 1)
        if len(raw) > MAX_RECORD_BYTES:
            raise ValueError
        decoded = backups.decode_json(raw)
        if set(decoded) != set(model.model_fields):
            raise ValueError
        return model.model_validate_json(raw)
    except (OSError, ValueError, TypeError, ValidationError, backups.BackupError):
        raise RehearsalError("restore_record_unavailable") from None


def _no_links(path):
    for ancestor in (path, *path.parents):
        if ancestor.is_symlink() or ancestor.is_junction():
            raise UnsafeFilePath
        if ancestor.exists() and not ancestor.is_dir():
            raise UnsafeFilePath


def _empty_filesystem(target):
    directory = target.data_directory.absolute()
    _no_links(directory)
    if directory.exists():
        if next(directory.iterdir(), None) is not None:
            raise RehearsalError("restore_target_not_empty")
        info = directory.stat()
        return {"root_exists": True, "device": info.st_dev, "inode": info.st_ino}
    parent = next(item for item in directory.parents if item.exists())
    info = parent.stat()
    return {"root_exists": False, "parent_device": info.st_dev, "parent_inode": info.st_ino}


def _identity(connection):
    name, address, port = connection.execute(
        "SELECT current_database(),host(inet_server_addr()),inet_server_port()"
    ).fetchone()
    if not isinstance(name, str) or not name.startswith("flowtrace_test_"):
        raise RehearsalError("restore_actual_database_invalid")
    try:
        parsed_address = ipaddress.ip_address(address) if address is not None else None
        mapped = getattr(parsed_address, "ipv4_mapped", None)
        if parsed_address is None or not (
            parsed_address.is_loopback or (mapped is not None and mapped.is_loopback)
        ):
            raise ValueError
    except ValueError:
        raise RehearsalError("restore_actual_database_invalid") from None
    return {"database": name, "address": address, "port": port}


def _probe_empty(settings, target):
    filesystem = _empty_filesystem(target)
    target_settings = _target_settings(target)
    require_isolated_database(target.database_url.get_secret_value(), "test")
    with backups._connection(settings) as source:
        source_name = source.execute("SELECT current_database()").fetchone()[0]
    with backups._connection(target_settings) as connection:
        connection.execute("SET LOCAL statement_timeout='5000ms'")
        identity = _identity(connection)
        if identity["database"] == source_name:
            raise RehearsalError("restore_actual_database_invalid")
        counts = connection.execute(
            "SELECT "
            "(SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
            "WHERE n.nspname NOT IN ('pg_catalog','information_schema') "
            "AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp_%'), "
            "(SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace "
            "WHERE n.nspname NOT IN ('pg_catalog','information_schema') "
            "AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp_%'), "
            "(SELECT count(*) FROM pg_namespace WHERE nspname NOT IN "
            "('pg_catalog','information_schema','public') AND nspname NOT LIKE 'pg_toast%' "
            "AND nspname NOT LIKE 'pg_temp_%'), "
            "(SELECT count(*) FROM pg_extension WHERE extname <> 'plpgsql')"
        ).fetchone()
        if any(counts):
            raise RehearsalError("restore_target_not_empty")
    return _digest(identity), _digest({"identity": identity, "filesystem": filesystem})


def _verified_manifest(settings, backup_id, *, check_budget=None):
    try:
        manifest = backups.verify_backup(
            settings.data_directory.absolute() / "backups", backup_id, check_budget=check_budget
        )
    except backups.BackupError as error:
        code = str(error)
        raise RehearsalError(
            code if re.fullmatch(r"[a-z][a-z0-9_]{0,63}", code) else "restore_backup_invalid"
        ) from None
    if not backups._valid_summary(manifest.get("database_summary")):
        raise RehearsalError("backup_database_summary_required")
    return manifest, _digest(manifest)


def list_restore_targets(session, principal, settings):
    assert_active_principal(session, principal, lock=False)
    require_recovery(session, principal)
    keys = {f"restore-target:{value}" for value in settings.restore_targets}
    used = dict(
        session.execute(
            select(BackgroundJob.occurrence_key, BackgroundJob.id).where(
                BackgroundJob.kind == "restore_rehearsal", BackgroundJob.occurrence_key.in_(keys)
            )
        ).all()
    )
    return [
        {
            "target_id": str(identity),
            "label": target.label,
            "tool_available": target.pg_restore_executable.is_file(),
            "has_intent": f"restore-target:{identity}" in used,
            "intent_job_id": str(used[f"restore-target:{identity}"])
            if f"restore-target:{identity}" in used
            else None,
        }
        for identity, target in settings.restore_targets.items()
    ]


def precheck_restore_request(session, principal, password):
    assert_active_principal(session, principal, lock=False)
    require_recovery(session, principal)
    password_hash = session.scalar(select(User.password_hash).where(User.id == principal.user_id))
    if (
        not isinstance(password, str)
        or not 12 <= len(password) <= 256
        or not PASSWORDS.verify(password, password_hash)
    ):
        raise ApiError("reauthentication_failed", 403)
    source_epoch = session.scalar(
        select(ServerState.sync_epoch).where(ServerState.singleton_id == 1)
    )
    if source_epoch is None:
        raise RehearsalError("restore_source_changed")
    return RestorePrecheck(
        principal.user_id,
        principal.session_id,
        read_runtime_configuration(session).version,
        source_epoch,
    )


def build_restore_preview(settings, *, authority, backup_id, target_id, before_read=None):
    if not isinstance(authority, RestorePrecheck) or not isinstance(backup_id, UUID):
        raise RehearsalError("restore_input_invalid", 422)
    guard = ExitStack()
    try:
        # Never wait for the source while owning a target lock or DB row locks.
        guard.enter_context(backup_read_lease(settings, backup_id))
        if before_read is not None:
            before_read(backup_id)
        target = _target(settings, target_id)
        with _target_lock(settings, target_id) as root:
            _, digest = _verified_manifest(settings, backup_id)
            identity, empty = _probe_empty(settings, target)
            stamp = now()
            record = RestorePreviewRecord(
                preview_id=uuid4(),
                actor_id=authority.actor_id,
                session_id=authority.session_id,
                target_id=target_id,
                backup_id=backup_id,
                source_epoch=authority.source_epoch,
                config_version=authority.config_version,
                manifest_sha256=digest,
                target_fingerprint=_fingerprint(target),
                empty_fingerprint=empty,
                target_identity=identity,
                issued_at=stamp,
                expires_at=stamp + timedelta(seconds=PREVIEW_SECONDS),
            )
            _write_record(root / f"preview-{record.preview_id}.json", root, record)
            prepared = PreparedRestorePreview(record, guard, _PREPARED_TRUST)
            guard = None
            return prepared
    except BackupLeaseError as error:
        raise RehearsalError(error.code, transient=error.transient) from None
    except ApiError:
        raise
    except Exception:
        raise RehearsalError("restore_preview_unavailable", 503, transient=True) from None
    finally:
        if guard is not None:
            guard.close()


def _current_binding(session, principal, settings, record, password):
    reauthenticate_admin(session, principal, password, capability="recovery")
    if record.actor_id != principal.user_id or record.session_id != principal.session_id:
        raise RehearsalError("restore_preview_identity_changed", 403)
    if record.expires_at <= now():
        raise RehearsalError("restore_preview_expired")
    version = session.scalar(
        select(ConfigurationHead.current_version)
        .where(ConfigurationHead.id == 1)
        .with_for_update(read=True)
    )
    if version != record.config_version:
        raise RehearsalError("restore_configuration_changed")
    epoch = session.scalar(select(ServerState.sync_epoch).where(ServerState.singleton_id == 1))
    if epoch != record.source_epoch:
        raise RehearsalError("restore_source_changed")
    if _fingerprint(_target(settings, record.target_id)) != record.target_fingerprint:
        raise RehearsalError("restore_target_registration_changed")
    from .retention import require_backup_readable

    readable = require_backup_readable(session, record.backup_id)
    if readable.registered and readable.stamp.manifest_sha256 != record.manifest_sha256:
        raise RehearsalError("restore_backup_changed")


def authorize_restore_preview(session, principal, settings, prepared, password):
    if (
        not isinstance(prepared, PreparedRestorePreview)
        or prepared.closed or prepared._trust is not _PREPARED_TRUST
    ):
        raise RehearsalError("restore_input_invalid", 422)
    record = prepared.record
    _current_binding(session, principal, settings, record, password)
    audit(
        session,
        principal.user_id,
        "restore.preview",
        record.preview_id,
        version=record.config_version,
        target_empty=True,
    )
    return RestorePreview(
        preview_id=record.preview_id,
        target_id=record.target_id,
        target_label=settings.restore_targets[record.target_id].label,
        backup_id=record.backup_id,
        config_version=record.config_version,
        expires_at=record.expires_at,
    )


def _find_preview(settings, preview_id):
    if not isinstance(preview_id, UUID):
        raise RehearsalError("restore_input_invalid", 422)
    # Target IDs are OS-registered, never inferred from caller-supplied paths.
    matches = []
    for target_id in settings.restore_targets:
        root = _control(settings, target_id)
        path = root / f"preview-{preview_id}.json"
        if path.exists() or path.is_symlink() or path.is_junction():
            record = _read_record(path, root, RestorePreviewRecord)
            if record.preview_id != preview_id or record.target_id != target_id:
                raise RehearsalError("restore_record_binding_invalid")
            matches.append(record)
    if len(matches) != 1:
        raise RehearsalError("restore_preview_not_found", 404)
    return matches[0]


def prepare_restore_submission(
    settings, *, owner_user_id, session_id, preview_id, before_read=None
):
    guard = ExitStack()
    try:
        record = _find_preview(settings, preview_id)
        if record.actor_id != owner_user_id or record.session_id != session_id:
            raise RehearsalError("restore_preview_identity_changed", 403)
        if record.expires_at <= now():
            raise RehearsalError("restore_preview_expired")
        target = _target(settings, record.target_id)
        if _fingerprint(target) != record.target_fingerprint:
            raise RehearsalError("restore_target_registration_changed")
        guard.enter_context(backup_read_lease(settings, record.backup_id))
        if before_read is not None:
            before_read(record.backup_id)
        guard.enter_context(_target_lock(settings, record.target_id))
        _, digest = _verified_manifest(settings, record.backup_id)
        if digest != record.manifest_sha256:
            raise RehearsalError("restore_backup_changed")
        identity, empty = _probe_empty(settings, target)
        if identity != record.target_identity or empty != record.empty_fingerprint:
            raise RehearsalError("restore_empty_target_changed")
        prepared = PreparedRestoreIntent(record, guard, _PREPARED_TRUST)
        guard = None
        return prepared
    except BackupLeaseError as error:
        raise RehearsalError(error.code, transient=error.transient) from None
    except ApiError:
        raise
    except Exception:
        raise RehearsalError("restore_submission_unavailable", 503, transient=True) from None
    finally:
        if guard is not None:
            guard.close()


def enqueue_restore_rehearsal(session, principal, settings, *, prepared, password):
    if (
        not isinstance(prepared, PreparedRestoreIntent)
        or prepared.closed or prepared._trust is not _PREPARED_TRUST
    ):
        raise RehearsalError("restore_input_invalid", 422)
    record = prepared.record
    # Lock the actor before the actual job, then config/control. Final binding
    # below may reject: the caller rolls this entire enqueue transaction back.
    reauthenticate_admin(session, principal, password, capability="recovery")
    if record.actor_id != principal.user_id or record.session_id != principal.session_id:
        raise RehearsalError("restore_preview_identity_changed", 403)
    payload = RestoreRehearsalPayload(
        target_id=record.target_id,
        backup_id=record.backup_id,
        preview_id=record.preview_id,
        manifest_sha256=record.manifest_sha256,
        target_fingerprint=record.target_fingerprint,
        config_version=record.config_version,
    )
    key = f"restore-target:{record.target_id}"
    existing = session.scalar(
        select(BackgroundJob.id).where(
            BackgroundJob.kind == "restore_rehearsal", BackgroundJob.occurrence_key == key
        )
    )
    try:
        job = store.enqueue(
            session,
            kind="restore_rehearsal",
            occurrence_key=key,
            owner_user_id=principal.user_id,
            payload=payload.model_dump(mode="json"),
        )
    except store.JobConflict:
        raise RehearsalError("restore_target_intent_conflict") from None
    _current_binding(session, principal, settings, record, password)
    from .job_references import retain_job_backup

    retain_job_backup(session, job.id)
    if existing is None:
        audit(
            session,
            principal.user_id,
            "restore.enqueue",
            job.id,
            version=record.config_version,
        )
    return store.metadata(job)


def read_restore_preview(session, principal, settings, preview_id):
    """Read only public confirmation metadata; execution still checks freshness."""
    assert_active_principal(session, principal, lock=False)
    require_recovery(session, principal)
    record = _find_preview(settings, preview_id)
    if record.actor_id != principal.user_id:
        raise RehearsalError("restore_preview_identity_changed", 403)
    return RestorePreview(
        preview_id=record.preview_id,
        target_id=record.target_id,
        target_label=settings.restore_targets[record.target_id].label,
        backup_id=record.backup_id,
        config_version=record.config_version,
        expires_at=record.expires_at,
    )


def replay_restore_intent(session, principal, settings, *, preview_id, password):
    """Find this exact committed intent without touching its consumed target.

    An expired preview may retrieve metadata, but cannot create another effect.
    Current recovery role and password remain mandatory on every replay.
    """
    reauthenticate_admin(session, principal, password, capability="recovery")
    record = _find_preview(settings, preview_id)
    if record.actor_id != principal.user_id:
        raise RehearsalError("restore_preview_identity_changed", 403)
    job = session.scalar(
        select(BackgroundJob).where(
            BackgroundJob.kind == "restore_rehearsal",
            BackgroundJob.occurrence_key == f"restore-target:{record.target_id}",
        )
    )
    if job is None:
        return None
    expected = RestoreRehearsalPayload(
        target_id=record.target_id,
        backup_id=record.backup_id,
        preview_id=record.preview_id,
        manifest_sha256=record.manifest_sha256,
        target_fingerprint=record.target_fingerprint,
        config_version=record.config_version,
    ).model_dump(mode="json")
    if job.owner_user_id != principal.user_id or job.payload != expected:
        raise RehearsalError("restore_target_intent_conflict")
    audit(session, principal.user_id, "restore.intent_replay", job.id)
    return store.metadata(job)


def _file_hash(path, root, *, check_budget):
    digest, size = hashlib.sha256(), 0
    with private_open(path, root) as stream:
        opened = os.fstat(stream.fileno())
        current = regular_file(path, root)
        if (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
            raise UnsafeFilePath
        while chunk := stream.read(1024 * 1024):
            check_budget()
            size += len(chunk)
            if size > backups.MAX_BACKUP_BYTES:
                raise RehearsalError("restore_file_too_large")
            digest.update(chunk)
    return {"sha256": digest.hexdigest(), "size_bytes": size}


def _verify_target(settings, target, manifest, *, check_budget):
    target_settings = _target_settings(target)
    _no_links(target.data_directory.absolute())
    attachment_root = target.data_directory.absolute() / "attachments"
    expected = {"attachments", "attachments/objects", "attachments/staging"}
    checks = []
    for item in manifest["files"]:
        if item["path"].startswith("objects/"):
            check_budget()
            path = attachment_root / item["path"]
            if _file_hash(path, attachment_root, check_budget=check_budget) != {
                "sha256": item["sha256"],
                "size_bytes": item["size_bytes"],
            }:
                raise RehearsalError("restore_object_hash_mismatch")
            expected.add("attachments/" + item["path"])
            checks.append(item)
    settings_file = attachment_root / "restored-settings.json"
    source_root = settings.data_directory.absolute() / "backups"
    with private_open(source_root / manifest["backup_id"] / "settings.json", source_root) as stream:
        public_settings = canonical(backups.decode_json(stream.read(1024 * 1024)))
    restored = _file_hash(settings_file, attachment_root, check_budget=check_budget)
    if restored != {
        "sha256": hashlib.sha256(public_settings).hexdigest(),
        "size_bytes": len(public_settings),
    }:
        raise RehearsalError("restore_settings_hash_mismatch")
    expected.add("attachments/restored-settings.json")
    found = set()
    for path in target.data_directory.absolute().rglob("*"):
        check_budget()
        if path.is_symlink() or path.is_junction():
            raise UnsafeFilePath
        if len(found) >= 100004:
            raise RehearsalError("restore_directory_invalid")
        found.add(path.relative_to(target.data_directory.absolute()).as_posix())
    if found != expected:
        raise RehearsalError("restore_directory_invalid")
    with backups._connection(target_settings) as connection:
        connection.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
        connection.execute("SET LOCAL statement_timeout='120s'")
        connection.execute("SET LOCAL lock_timeout='5s'")
        identity = _identity(connection)
        row = connection.execute(
            "SELECT instance_id,sync_epoch FROM server_state WHERE singleton_id=1"
        ).fetchone()
        if (
            row is None
            or str(row[0]) != manifest["instance_id"]
            or str(row[1]) == manifest["sync_epoch"]
        ):
            raise RehearsalError("restore_identity_mismatch")
        if connection.execute("SELECT count(*) FROM sessions WHERE revoked_at IS NULL").fetchone()[
            0
        ]:
            raise RehearsalError("restore_session_revoke_mismatch")
        if connection.execute("SELECT count(*) FROM sync_clients WHERE frozen=false").fetchone()[0]:
            raise RehearsalError("restore_client_freeze_mismatch")
        backups._verify_balances(connection)
        summary = backups._database_summary(connection, check_budget=check_budget)
    return {
        "target_identity": _digest(identity),
        "restored_instance": row[0],
        "restored_epoch": row[1],
        "database_summary_sha256": _digest(summary),
        "object_summary_sha256": _digest(sorted(checks, key=lambda item: item["path"])),
        "object_count": len(checks),
    }


def run_restore_rehearsal(
    settings, *, owner_user_id, job_id, payload, check_budget=None, before_read=None
):
    """Pure external-target work; the worker fences the source job separately."""
    try:
        if not isinstance(owner_user_id, UUID) or not isinstance(job_id, UUID):
            raise RehearsalError("restore_input_invalid", 422)
        parsed = (
            RestoreRehearsalPayload.model_validate_json(canonical(payload))
            if isinstance(payload, dict)
            else payload
        )
        if not isinstance(parsed, RestoreRehearsalPayload):
            raise RehearsalError("restore_input_invalid", 422)
        record = _find_preview(settings, parsed.preview_id)
        if record.actor_id != owner_user_id or any(
            getattr(record, key) != value for key, value in parsed.model_dump().items()
        ):
            raise RehearsalError("restore_record_binding_invalid")
        target = _target(settings, parsed.target_id)
        if _fingerprint(target) != parsed.target_fingerprint:
            raise RehearsalError("restore_target_registration_changed")
        deadline = monotonic() + 840
        external_budget = check_budget

        def check_budget():
            if external_budget is not None:
                external_budget()
            if monotonic() >= deadline:
                raise RehearsalError("restore_verification_timeout")

        with ExitStack() as guard:
            guard.enter_context(
                backup_read_lease(settings, parsed.backup_id, check_budget=check_budget)
            )
            if before_read is not None:
                before_read(parsed.backup_id)
            root = guard.enter_context(_target_lock(settings, parsed.target_id))
            manifest, digest = _verified_manifest(
                settings, parsed.backup_id, check_budget=check_budget
            )
            if digest != parsed.manifest_sha256:
                raise RehearsalError("restore_backup_changed")
            receipt_path = root / "verified.json"
            if receipt_path.exists() or receipt_path.is_symlink() or receipt_path.is_junction():
                receipt = _read_record(receipt_path, root, RestoreVerifiedReceipt)
                if (
                    receipt.job_id != job_id
                    or receipt.owner_user_id != owner_user_id
                    or any(
                        getattr(receipt, key) != value for key, value in parsed.model_dump().items()
                    )
                ):
                    raise RehearsalError("restore_receipt_binding_invalid")
                actual = _verify_target(settings, target, manifest, check_budget=check_budget)
                if actual["target_identity"] != record.target_identity:
                    raise RehearsalError("restore_actual_database_invalid")
                if any(getattr(receipt, key) != value for key, value in actual.items()):
                    raise RehearsalError("restore_receipt_verification_failed")
            else:
                identity, empty = _probe_empty(settings, target)
                if identity != record.target_identity or empty != record.empty_fingerprint:
                    raise RehearsalError("restore_empty_target_changed")
                check_budget()
                backups.restore_isolated(
                    settings.data_directory.absolute() / "backups",
                    parsed.backup_id,
                    _target_settings(target),
                    pg_restore=target.pg_restore_executable,
                    attachment_directory=target.data_directory.absolute() / "attachments",
                    check_budget=check_budget,
                )
                actual = _verify_target(settings, target, manifest, check_budget=check_budget)
                if actual["target_identity"] != record.target_identity:
                    raise RehearsalError("restore_actual_database_invalid")
                check_budget()
                receipt = RestoreVerifiedReceipt(
                    job_id=job_id,
                    owner_user_id=owner_user_id,
                    **parsed.model_dump(),
                    **actual,
                    verified_at=now(),
                )
                _write_record(receipt_path, root, receipt)
            return {
                "code": "restore_rehearsal_verified",
                "artifact_id": str(parsed.target_id),
                "file_count": receipt.object_count + 1,
                "sha256": _digest(receipt.model_dump(mode="json")),
            }
    except BackupLeaseError as error:
        raise RehearsalError(error.code, transient=error.transient) from None
    except ApiError:
        raise
    except backups.BackupError as error:
        code = str(error)
        raise RehearsalError(
            code if re.fullmatch(r"[a-z][a-z0-9_]{0,63}", code) else "restore_validation_failed"
        ) from None
    except (ValidationError, ValueError, TypeError):
        raise RehearsalError("restore_record_invalid") from None
    except Exception:
        raise RehearsalError("restore_operation_unavailable", 503, transient=True) from None
