"""Consistent logical backup under the shared database maintenance barrier.

No client-controlled file paths are accepted by these operator functions. Every
backup is an exclusive UUID directory beneath the service-owned backup root.
Restores accept only a validated package and an explicitly isolated empty DB.
"""

import hashlib
import os
import re
import subprocess
import threading
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from uuid import UUID, uuid4

import psycopg
from psycopg import sql
from sqlalchemy.engine import make_url

from flowtrace_server.config import Settings
from flowtrace_server.imports.parsers import canonical, decode_json
from flowtrace_server.persistence.private_files import (
    private_directory,
    private_open,
    regular_file,
)
from flowtrace_server.persistence.testing import require_isolated_database

from .leases import backup_exclusive_lease, backup_read_lease

OBJECT_NAME = re.compile(r"[0-9a-f]{64}\.(?:bin|webp)\Z")
MAX_BACKUP_BYTES = 1024 * 1024 * 1024
MAX_FILES = 100000
TABLE_NAME = re.compile(r"[a-z_][a-z0-9_]{0,62}\Z")


class BackupError(RuntimeError):
    pass


@dataclass(repr=False)
class _CreationLease:
    root: Path
    backup_id: UUID
    active: bool = True


def _package_settings(backup_root):
    # Trusted CLI sources may live outside the current service's data directory.
    # Both creation and restore derive the same stable source lock namespace.
    return SimpleNamespace(data_directory=Path(os.path.abspath(backup_root)).parent)


@contextmanager
def _creation_lease(backup_root, backup_id, *, check_budget=None):
    root = Path(os.path.abspath(backup_root))
    with backup_exclusive_lease(
        _package_settings(root), (backup_id,), check_budget=check_budget
    ):
        token = _CreationLease(root, backup_id)
        try:
            yield token
        finally:
            token.active = False


def _environment(settings: Settings):
    if settings.database_url is None:
        raise BackupError("database_unconfigured")
    url = make_url(settings.database_url.get_secret_value())
    env = {key: value for key, value in os.environ.items() if not key.startswith("PG")}
    parameters = {
        "sslmode": "PGSSLMODE",
        "sslrootcert": "PGSSLROOTCERT",
        "sslcert": "PGSSLCERT",
        "sslkey": "PGSSLKEY",
        "sslcrl": "PGSSLCRL",
        "sslcrldir": "PGSSLCRLDIR",
        "sslpassword": "PGSSLPASSWORD",
        "channel_binding": "PGCHANNELBINDING",
        "gssencmode": "PGGSSENCMODE",
        "target_session_attrs": "PGTARGETSESSIONATTRS",
        "hostaddr": "PGHOSTADDR",
        "sslnegotiation": "PGSSLNEGOTIATION",
    }
    if any(key not in parameters for key in url.query):
        raise BackupError("database_connection_option_unsupported")
    if any(not isinstance(value, str) for value in url.query.values()):
        raise BackupError("database_connection_option_invalid")
    env.update({parameters[key]: value for key, value in url.query.items()})
    env.update(
        PGHOST=url.host or "localhost",
        PGPORT=str(url.port or 5432),
        PGDATABASE=url.database,
        PGUSER=url.username or "",
        PGPASSWORD=url.password or "",
        PGCONNECT_TIMEOUT="5",
        PGAPPNAME="flowtrace-backup",
    )
    return env


def _connection(settings):
    env = _environment(settings)
    url = make_url(settings.database_url.get_secret_value())
    return psycopg.connect(
        host=env["PGHOST"],
        port=env["PGPORT"],
        dbname=env["PGDATABASE"],
        user=env["PGUSER"],
        password=env["PGPASSWORD"],
        connect_timeout=5,
        **url.query,
    )


def _dump(
    executable: Path,
    settings: Settings,
    target: Path,
    root: Path,
    timeout=120,
    *,
    check_budget=None,
):
    # The password stays in the private child environment, never argv/errors/receipts.
    with private_open(target, root, create=True) as output:
        process = subprocess.Popen(
            [str(executable), "--format=custom", "--no-owner", "--no-acl"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=_environment(settings),
            shell=False,
        )
        timed_out = threading.Event()

        def stop():
            timed_out.set()
            process.kill()

        timer = threading.Timer(timeout, stop)
        timer.start()
        size = 0
        checksum = hashlib.sha256()
        try:
            while chunk := process.stdout.read(1024 * 1024):
                if check_budget is not None:
                    check_budget()
                size += len(chunk)
                if size > MAX_BACKUP_BYTES:
                    process.kill()
                    raise BackupError("backup_too_large")
                checksum.update(chunk)
                output.write(chunk)
            if process.wait() != 0 or timed_out.is_set():
                raise BackupError("database_dump_failed")
            output.flush()
            os.fsync(output.fileno())
            return {"path": "database.dump", "size_bytes": size, "sha256": checksum.hexdigest()}
        finally:
            timer.cancel()
            process.stdout.close()
            if process.poll() is None:
                process.kill()
                process.wait()


def _write(path, root, content):
    with private_open(path, root, create=True) as output:
        output.write(content)
        output.flush()
        os.fsync(output.fileno())


def _copy(source, source_root, target, target_root, remaining, *, check_budget=None):
    size, checksum = 0, hashlib.sha256()
    with private_open(source, source_root) as incoming:
        with private_open(target, target_root, create=True) as output:
            while chunk := incoming.read(1024 * 1024):
                if check_budget is not None:
                    check_budget()
                size += len(chunk)
                if size > remaining:
                    raise BackupError("backup_too_large")
                checksum.update(chunk)
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
    return {"size_bytes": size, "sha256": checksum.hexdigest()}


def _verify_balances(connection):
    mismatches = connection.execute(
        "SELECT count(*) FROM sync_entities a WHERE "
        "a.entity_type='account' AND a.deleted=false AND (a.balance_minor IS NULL OR "
        "a.payload->'opening'->>'amount_minor' IS NULL OR a.balance_minor IS DISTINCT FROM "
        "((a.payload->'opening'->>'amount_minor')::bigint + COALESCE((SELECT "
        "sum(e.amount_minor) FROM ledger_entries e WHERE e.account_id=a.id),0)) OR EXISTS ("
        "SELECT 1 FROM ledger_entries e WHERE e.account_id=a.id AND (e.currency IS DISTINCT FROM "
        "a.payload->'opening'->>'currency' OR e.currency_scale IS DISTINCT FROM "
        "(a.payload->'opening'->>'currency_scale')::int)))"
    ).fetchone()[0]
    if mismatches:
        raise BackupError("restore_balance_mismatch")


def _database_summary(connection, *, check_budget=None):
    """Hash complete table contents before rotating restored operational state.

    The hashes are evidence, never a plaintext record export. Fixed UTC and
    bytewise ordering make independently restored rows comparable. A server
    cursor bounds Python memory; PostgreSQL enforces the query timeout.
    """
    connection.execute("SET LOCAL TIME ZONE 'UTC'")
    connection.execute("SET LOCAL statement_timeout='120s'")
    tables = [
        row[0]
        for row in connection.execute(
            "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename"
        )
    ]
    if not tables or len(tables) > 500 or any(not TABLE_NAME.fullmatch(t) for t in tables):
        raise BackupError("backup_database_summary_invalid")
    result, total = {}, 0
    for table in tables:
        if check_budget is not None:
            check_budget()
        checksum, count = hashlib.sha256(), 0
        with connection.cursor(name="backup_summary_" + uuid4().hex) as cursor:
            cursor.execute(
                sql.SQL(
                    "SELECT to_jsonb(t)::text FROM public.{} t "
                    'ORDER BY to_jsonb(t)::text COLLATE "C"'
                ).format(sql.Identifier(table))
            )
            while rows := cursor.fetchmany(500):
                if check_budget is not None:
                    check_budget()
                for (value,) in rows:
                    encoded = value.encode("utf-8")
                    total += len(encoded)
                    if total > MAX_BACKUP_BYTES * 4:
                        raise BackupError("backup_database_summary_too_large")
                    checksum.update(len(encoded).to_bytes(8, "big"))
                    checksum.update(encoded)
                    count += 1
        result[table] = {"count": count, "sha256": checksum.hexdigest()}
    return {"algorithm": "sha256-length-framed-jsonb-utc-c-order-v1", "tables": result}


def _valid_summary(value):
    return (
        isinstance(value, dict)
        and set(value) == {"algorithm", "tables"}
        and value["algorithm"] == "sha256-length-framed-jsonb-utc-c-order-v1"
        and isinstance(value["tables"], dict)
        and 1 <= len(value["tables"]) <= 500
        and all(
            isinstance(name, str)
            and TABLE_NAME.fullmatch(name)
            and isinstance(item, dict)
            and set(item) == {"count", "sha256"}
            and type(item["count"]) is int
            and 0 <= item["count"] <= 2**63 - 1
            and isinstance(item["sha256"], str)
            and re.fullmatch(r"[0-9a-f]{64}", item["sha256"])
            for name, item in value["tables"].items()
        )
    )


def create_backup(
    settings: Settings,
    backup_root: Path,
    *,
    pg_dump: Path,
    lease_factory=None,
    backup_id: UUID | None = None,
    check_budget=None,
    _package_lease=None,
) -> dict:
    from flowtrace_server.persistence.maintenance import MaintenanceLease

    if backup_id is not None and not isinstance(backup_id, UUID):
        raise BackupError("backup_id_invalid")
    backup_id = backup_id or uuid4()
    root = Path(os.path.abspath(backup_root))
    if _package_lease is None:
        with _creation_lease(root, backup_id, check_budget=check_budget) as token:
            return create_backup(
                settings, root, pg_dump=pg_dump, lease_factory=lease_factory,
                backup_id=backup_id, check_budget=check_budget, _package_lease=token,
            )
    if (
        not isinstance(_package_lease, _CreationLease)
        or not _package_lease.active
        or (_package_lease.root, _package_lease.backup_id) != (root, backup_id)
    ):
        raise BackupError("backup_creation_lease_invalid")
    if check_budget is not None:
        check_budget()
    root = private_directory(root)
    target = root / str(backup_id)
    # No success marker is published on any failure. Partial directories are
    # inspectable by the operator, and can never pass verify_backup.
    with (lease_factory or MaintenanceLease)(settings) as lease:
        if check_budget is not None:
            check_budget()
        target.mkdir(mode=0o700, exist_ok=False)
        objects = private_directory(target / "objects")
        connection = lease.connection
        versions = [r[0] for r in connection.execute("SELECT version_num FROM alembic_version")]
        state = connection.execute(
            "SELECT instance_id, sync_epoch FROM server_state WHERE singleton_id=1"
        ).fetchone()
        if state is None:
            raise BackupError("server_state_missing")
        attachments = connection.execute(
            "SELECT storage_key,sha256,size_bytes,status FROM attachments ORDER BY id"
        ).fetchall()
        if len(attachments) > MAX_FILES // 2:
            raise BackupError("backup_too_many_files")
        database = _dump(
            pg_dump, settings, target / "database.dump", root, check_budget=check_budget
        )
        database_summary = _database_summary(connection, check_budget=check_budget)
        total, files = database["size_bytes"], []
        source_root = settings.data_directory.absolute() / "attachments"
        for storage_key, original_hash, original_size, status in attachments:
            if check_budget is not None:
                check_budget()
            if not re.fullmatch(r"[0-9a-f]{64}", storage_key):
                raise BackupError("attachment_storage_key_invalid")
            for suffix in (".bin", ".webp"):
                name = storage_key + suffix
                source = source_root / "objects" / name
                if not source.exists():
                    if status in {"ready", "uploaded"}:
                        raise BackupError("attachment_missing")
                    continue
                info = _copy(
                    source,
                    source_root,
                    objects / name,
                    root,
                    MAX_BACKUP_BYTES - total,
                    check_budget=check_budget,
                )
                if suffix == ".bin" and status in {"ready", "uploaded"}:
                    if info["sha256"] != original_hash or info["size_bytes"] != original_size:
                        raise BackupError("attachment_hash_mismatch")
                total += info["size_bytes"]
                files.append({"path": "objects/" + name, **info})
        public_settings = settings.model_dump(
            mode="json", exclude={"database_url", "data_directory"}
        )
        settings_bytes = canonical(public_settings)
        _write(target / "settings.json", root, settings_bytes)
        files.append(
            {
                "path": "settings.json",
                "size_bytes": len(settings_bytes),
                "sha256": hashlib.sha256(settings_bytes).hexdigest(),
            }
        )
        manifest = {
            "format": "flowtrace-backup-v1",
            "backup_id": str(backup_id),
            "created_at": datetime.now(timezone.utc).isoformat(),
            "server_version": "0.1.0",
            "schema_versions": versions,
            "instance_id": str(state[0]),
            "sync_epoch": str(state[1]),
            "database": database,
            "database_summary": database_summary,
            "files": files,
            "secret_configuration": "excluded_provision_separately",
            "consistency": "maintenance_exclusive_database_barrier",
        }
        if check_budget is not None:
            check_budget()
        manifest_bytes = canonical(manifest)
        _write(target / "manifest.json", root, manifest_bytes)
        # Verify while the maintenance lease is still held, before reporting success.
        verify_backup(root, backup_id, check_budget=check_budget)
        return {
            "backup_id": str(backup_id),
            "status": "verified",
            "file_count": len(files) + 2,
            "size_bytes": total + len(settings_bytes) + len(manifest_bytes),
            "manifest_sha256": hashlib.sha256(canonical(manifest)).hexdigest(),
        }


def verify_backup(backup_root: Path, backup_id: UUID, *, check_budget=None) -> dict:
    """Low-level verification under the caller's existing SH or EX package lease.

    Deliberately do not acquire another handle: creators and retention already
    own EX, which cannot recursively acquire SH on Windows. Operator/worker
    consumers use verify_backup_leased, archive and restore own wider contexts.
    """
    if check_budget is not None:
        check_budget()
    if not isinstance(backup_id, UUID):
        raise BackupError("backup_id_invalid")
    root = Path(os.path.abspath(backup_root))
    target = root / str(backup_id)
    with private_open(target / "manifest.json", root) as stream:
        manifest = decode_json(stream.read(5 * 1024 * 1024 + 1))
    if check_budget is not None:
        check_budget()
    if (
        not isinstance(manifest, dict)
        or manifest.get("format") != "flowtrace-backup-v1"
        or manifest.get("backup_id") != str(backup_id)
        or not isinstance(manifest.get("files"), list)
        or len(manifest["files"]) > MAX_FILES
        or manifest.get("server_version") != "0.1.0"
        or not isinstance(manifest.get("schema_versions"), list)
        or not 1 <= len(manifest["schema_versions"]) <= 10
        or any(
            not isinstance(v, str) or not re.fullmatch(r"[a-z0-9_]{1,80}", v)
            for v in manifest["schema_versions"]
        )
    ):
        raise BackupError("backup_manifest_invalid")
    if "database_summary" in manifest and not _valid_summary(manifest["database_summary"]):
        raise BackupError("backup_database_summary_invalid")
    names, total = set(), 0
    try:
        for item in [manifest["database"], *manifest["files"]]:
            if check_budget is not None:
                check_budget()
            name = item["path"]
            if name not in {"database.dump", "settings.json"} and not (
                name.startswith("objects/") and OBJECT_NAME.fullmatch(name[8:])
            ):
                raise BackupError("backup_manifest_path_invalid")
            if name in names or type(item["size_bytes"]) is not int or item["size_bytes"] < 0:
                raise BackupError("backup_manifest_invalid")
            names.add(name)
            info = regular_file(target / name, root)
            total += info.st_size
            if total > MAX_BACKUP_BYTES or info.st_size != item["size_bytes"]:
                raise BackupError("backup_file_size_mismatch")
            checksum = hashlib.sha256()
            with private_open(target / name, root) as stream:
                while chunk := stream.read(1024 * 1024):
                    if check_budget is not None:
                        check_budget()
                    checksum.update(chunk)
            if checksum.hexdigest() != item["sha256"]:
                raise BackupError("backup_file_hash_mismatch")
        if not {"database.dump", "settings.json"}.issubset(names):
            raise BackupError("backup_manifest_incomplete")
        with private_open(target / "database.dump", root) as stream:
            if check_budget is not None:
                check_budget()
            if stream.read(5) != b"PGDMP":
                raise BackupError("backup_database_format_invalid")
    except (KeyError, TypeError, AttributeError):
        raise BackupError("backup_manifest_invalid") from None
    return manifest


def verify_backup_leased(settings, backup_id, *, before_read=None, check_budget=None):
    """Verify a fixed service package without holding a DB transaction over I/O."""
    with backup_read_lease(settings, backup_id, check_budget=check_budget):
        if before_read is not None:
            before_read()
        return verify_backup(
            settings.data_directory.absolute() / "backups", backup_id, check_budget=check_budget
        )


def restore_isolated(
    backup_root: Path,
    backup_id: UUID,
    target_settings: Settings,
    *,
    pg_restore: Path,
    attachment_directory: Path,
    check_budget=None,
) -> dict:
    """Read a trusted source under SH through restored DB/file postvalidation."""
    with backup_read_lease(
        _package_settings(backup_root), backup_id, check_budget=check_budget
    ):
        return _restore_isolated(
            backup_root, backup_id, target_settings, pg_restore=pg_restore,
            attachment_directory=attachment_directory, check_budget=check_budget,
        )


def _restore_isolated(
    backup_root: Path,
    backup_id: UUID,
    target_settings: Settings,
    *,
    pg_restore: Path,
    attachment_directory: Path,
    check_budget=None,
) -> dict:
    from flowtrace_server.persistence.maintenance import MaintenanceLease

    require_isolated_database(
        target_settings.database_url.get_secret_value(), target_settings.environment
    )
    manifest = verify_backup(backup_root, backup_id, check_budget=check_budget)
    if not _valid_summary(manifest.get("database_summary")):
        raise BackupError("backup_database_summary_required")
    # An existing data directory is never merged or overwritten.
    directory = Path(os.path.abspath(attachment_directory))
    if directory.exists():
        raise BackupError("restore_directory_exists")
    with MaintenanceLease(target_settings):
        with _connection(target_settings) as connection:
            count = connection.execute(
                "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'"
            ).fetchone()[0]
            if count:
                raise BackupError("restore_database_not_empty")
        source_root = Path(os.path.abspath(backup_root))
        package = source_root / str(backup_id)
        try:
            completed = subprocess.run(
                [
                    str(pg_restore),
                    "--no-owner",
                    "--no-acl",
                    "--single-transaction",
                    "--exit-on-error",
                    "--dbname=" + _environment(target_settings)["PGDATABASE"],
                    str(package / "database.dump"),
                ],
                env=_environment(target_settings),
                shell=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=120,
            )
        except subprocess.TimeoutExpired:
            raise BackupError("restore_timeout") from None
        if completed.returncode:
            raise BackupError("database_restore_failed")
        if check_budget is not None:
            check_budget()
        objects = private_directory(directory / "objects")
        private_directory(directory / "staging")
        for item in manifest["files"]:
            if item["path"].startswith("objects/"):
                copied = _copy(
                    package / item["path"],
                    source_root,
                    objects / item["path"][8:],
                    directory,
                    MAX_BACKUP_BYTES,
                    check_budget=check_budget,
                )
                if any(copied[k] != item[k] for k in ("sha256", "size_bytes")):
                    raise BackupError("restore_file_changed")
        with private_open(package / "settings.json", source_root) as source:
            public_settings = decode_json(source.read(1024 * 1024))
        # Save the recovered nonsecret settings separately from the explicit
        # isolated DB/port/path supplied by the operator. Do not boot a service
        # using the source environment's addresses.
        _write(directory / "restored-settings.json", directory, canonical(public_settings))
        with _connection(target_settings) as connection:
            state = connection.execute(
                "SELECT instance_id,sync_epoch FROM server_state WHERE singleton_id=1"
            ).fetchone()
            if state is None or (str(state[0]), str(state[1])) != (
                manifest.get("instance_id"),
                manifest.get("sync_epoch"),
            ):
                raise BackupError("restore_identity_mismatch")
            if _database_summary(connection, check_budget=check_budget) != manifest[
                "database_summary"
            ]:
                raise BackupError("restore_database_summary_mismatch")
            epoch = uuid4()
            connection.execute(
                "UPDATE server_state SET sync_epoch=%s WHERE singleton_id=1", (epoch,)
            )
            connection.execute("UPDATE sessions SET revoked_at=now() WHERE revoked_at IS NULL")
            connection.execute("UPDATE sync_clients SET frozen=true")
            versions = [r[0] for r in connection.execute("SELECT version_num FROM alembic_version")]
            if versions != manifest["schema_versions"]:
                raise BackupError("restore_schema_mismatch")
            counts = {
                name: connection.execute(f"SELECT count(*) FROM {name}").fetchone()[0]
                for name in (
                    "users",
                    "books",
                    "sync_entities",
                    "ledger_entries",
                    "attachments",
                    "attachment_refs",
                )
            }
            # Recompute every account balance from its immutable opening and exact postings.
            _verify_balances(connection)
            if check_budget is not None:
                check_budget()
            connection.commit()
        return {
            "backup_id": str(backup_id),
            "status": "isolated_verified",
            "counts": counts,
            "sync_epoch_changed": str(epoch) != manifest["sync_epoch"],
            "old_sessions_revoked": True,
            "database_contents_verified": True,
            "account_balances_recomputed": True,
            "attachment_files_verified": sum(
                i["path"].startswith("objects/") for i in manifest["files"]
            ),
        }
