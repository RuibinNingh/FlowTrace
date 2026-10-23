"""New synthetic quarantine fixtures and bounded postconditions; no pg_restore."""

import argparse
import hashlib
import json
import os
import secrets
import subprocess
import sys
from datetime import timedelta
from pathlib import Path
from uuid import UUID, uuid4

from alembic import command
from alembic.script import ScriptDirectory
from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.auth.models import AdminRole, UserSession
from flowtrace_server.auth.service import (
    authenticate_access,
    create_user,
    issue_session,
    now,
)
from flowtrace_server.backups import retention
from flowtrace_server.backups.quarantine_schemas import QuarantineReceipt
from flowtrace_server.backups.retention_models import (
    BackupControl,
    BackupRetentionIntent,
)
from flowtrace_server.backups.retention_schemas import PinCreateCommand
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.persistence.database import (
    build_engine,
    check_database,
    migration_config,
)
from flowtrace_server.persistence.private_files import (
    private_directory,
    private_open,
    regular_file,
)
from prepare_retention_fixture import environment, package_snapshot, write_new
from sqlalchemy import func, select, text
from sqlalchemy.orm import Session

ROOT = Path(__file__).resolve().parents[3]
PURPOSE = "flowtrace-quarantine-browser-synthetic-v1"
HEAD = "0016_backup_quarantine"
ORIGIN = "http://127.0.0.1:18096"
LABELS = {"selected_a", "selected_b", "pinned", "unregistered", "newest_witness"}
SELECTED = ("selected_a", "selected_b")


def make_package(settings, instance, epoch, age):
    identity = uuid4()
    root = private_directory(settings.data_directory / "backups" / str(identity))
    private_directory(root / "objects")
    records = []
    object_bytes = b"owned-quarantine-object-" + identity.bytes
    object_name = hashlib.sha256(object_bytes).hexdigest() + ".bin"
    for name, content in (
        (
            "database.dump",
            b"PGDMPsynthetic-quarantine-not-restorable-" + identity.bytes,
        ),
        (
            "settings.json",
            canonical({"environment": "test", "synthetic": str(identity)}),
        ),
        ("objects/" + object_name, object_bytes),
    ):
        with private_open(root / name, root, create=True) as stream:
            stream.write(content)
        records.append(
            {
                "path": name,
                "size_bytes": len(content),
                "sha256": hashlib.sha256(content).hexdigest(),
            }
        )
    manifest = {
        "format": "flowtrace-backup-v1",
        "backup_id": str(identity),
        "created_at": (now() - timedelta(days=age)).isoformat(),
        "server_version": "0.1.0",
        "schema_versions": [HEAD],
        "instance_id": str(instance),
        "sync_epoch": str(epoch),
        "database": records[0],
        "files": records[1:],
        "database_summary": {
            "algorithm": "sha256-length-framed-jsonb-utc-c-order-v1",
            "tables": {"synthetic": {"count": 0, "sha256": "0" * 64}},
        },
    }
    with private_open(root / "manifest.json", root, create=True) as stream:
        stream.write(canonical(manifest))
    return identity, root


def seed(env_file):
    settings, database = environment(env_file)
    run = uuid4().hex
    output = ROOT / "outputs/validation/P5/admin" / f"quarantine-{run}"
    credential = ROOT / "work/flowtrace-dev" / f"quarantine-{run}.json"
    if settings.data_directory.exists() or output.exists() or credential.exists():
        raise ValueError("fresh_quarantine_paths_required")
    engine = build_engine(settings)
    try:
        with engine.begin() as connection:
            if connection.scalar(
                text(
                    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'"
                )
            ):
                raise ValueError("new_empty_quarantine_database_required")
            config = migration_config()
            if ScriptDirectory.from_config(config).get_heads() != [HEAD]:
                raise ValueError("quarantine_head_changed")
            config.attributes["connection"] = connection
            command.upgrade(config, HEAD)
        instance, epoch = check_database(engine)
        credentials = {"wrong_password": secrets.token_urlsafe(24)}
        with Session(engine) as session, session.begin():
            for label, roles in (
                ("owner", ("server_owner", "service_admin", "recovery_admin")),
                ("recovery_only", ("recovery_admin",)),
                ("service_only", ("service_admin",)),
            ):
                password = secrets.token_urlsafe(24)
                username = f"q_{label}_{run[:12]}"
                user = create_user(session, username, password)
                session.add_all(AdminRole(user_id=user.id, role=role) for role in roles)
                credentials[label] = {
                    "username": username,
                    "password": password,
                    "user_id": str(user.id),
                }
                if label == "owner":
                    owner = user
            origin, tokens = issue_session(
                session, owner, uuid4(), "quarantine fixture seed", "admin"
            )
            origin_id = origin.id
            principal = authenticate_access(session, tokens["access_token"], admin=True)
        write_new(credential, credentials)
        packages = {}
        try:
            for label, age in (
                ("selected_a", 45),
                ("selected_b", 50),
                ("pinned", 60),
                ("unregistered", 45),
                ("newest_witness", 0),
            ):
                identity, package = make_package(settings, instance, epoch, age)
                if label != "unregistered":
                    with (
                        retention.prepare_registration(settings, identity) as prepared,
                        Session(engine) as session,
                    ):
                        retention.register_verified_backup(
                            session,
                            principal,
                            settings,
                            prepared=prepared,
                            password=credentials["owner"]["password"],
                        )
                        session.commit()
                if label == "pinned":
                    with Session(engine) as session, session.begin():
                        retention.create_backup_pin(
                            session,
                            principal,
                            command=PinCreateCommand(
                                backup_id=identity,
                                pin_id=uuid4(),
                                request_id=uuid4(),
                                expected_control_version=1,
                            ),
                            password=credentials["owner"]["password"],
                        )
                with Session(engine) as session:
                    control = session.get(BackupControl, identity)
                    version = control.version if control else None
                packages[label] = {
                    "id": str(identity),
                    "control_version": version,
                    **package_snapshot(package),
                }
        finally:
            with Session(engine) as session, session.begin():
                session.get(UserSession, origin_id).revoked_at = now()
        fixture = {
            "purpose": PURPOSE,
            "run_id": run,
            "env_file": str(env_file.absolute()),
            "database": database,
            "data_directory": str(settings.data_directory),
            "api_origin": ORIGIN,
            "credential_file": str(credential),
            "expected_head": HEAD,
            "source_instance": str(instance),
            "source_epoch": str(epoch),
            "packages": packages,
            "synthetic_dump": True,
            "restorable_dump": False,
        }
        write_new(output / "fixture.json", fixture)
        return {
            "fixture": str(output / "fixture.json"),
            "packages": 5,
            "registered": 4,
            "pins": 1,
            "active_seed_sessions": 0,
            "restorable_dump": False,
        }
    finally:
        engine.dispose()


def load_fixture(path):
    path = path.absolute()
    parent = ROOT / "outputs/validation/P5/admin"
    regular_file(path, parent)
    fixture = json.loads(path.read_text("utf-8"))
    run = fixture.get("run_id", "")
    if (
        fixture.get("purpose") != PURPOSE
        or fixture.get("api_origin") != ORIGIN
        or fixture.get("expected_head") != HEAD
        or path != parent / f"quarantine-{run}" / "fixture.json"
        or len(run) != 32
        or any(char not in "0123456789abcdef" for char in run)
        or set(fixture.get("packages", {})) != LABELS
        or fixture.get("restorable_dump") is not False
    ):
        raise ValueError("owned_quarantine_fixture_required")
    settings, database = environment(Path(fixture["env_file"]))
    if fixture["database"] != database or fixture["data_directory"] != str(
        settings.data_directory
    ):
        raise ValueError("quarantine_fixture_binding_changed")
    identities = [str(UUID(item["id"])) for item in fixture["packages"].values()]
    if len(set(identities)) != 5 or any(
        identity != item["id"]
        for identity, item in zip(identities, fixture["packages"].values(), strict=True)
    ):
        raise ValueError("quarantine_fixture_identity_changed")
    expected = ROOT / "work/flowtrace-dev" / f"quarantine-{run}.json"
    if fixture["credential_file"] != str(expected):
        raise ValueError("quarantine_credential_binding_changed")
    regular_file(expected, expected.parent)
    return fixture, settings


def credentials_for(fixture):
    with private_open(
        Path(fixture["credential_file"]), ROOT / "work/flowtrace-dev"
    ) as stream:
        return json.load(stream)


def verify(path, job_id=None):
    fixture, settings = load_fixture(path)
    credentials = credentials_for(fixture)
    engine = build_engine(settings)
    try:
        instance, epoch = check_database(engine)
        if (str(instance), str(epoch)) != (
            fixture["source_instance"],
            fixture["source_epoch"],
        ):
            raise ValueError("quarantine_source_changed")
        with Session(engine) as session:
            intent = None
            if job_id:
                job = session.get(BackgroundJob, job_id)
                intent = session.scalar(
                    select(BackupRetentionIntent).where(
                        BackupRetentionIntent.job_id == job_id
                    )
                )
                if (
                    job is None
                    or intent is None
                    or job.kind != "backup_quarantine"
                    or job.status != "succeeded"
                    or str(job.owner_user_id) != credentials["owner"]["user_id"]
                    or job.attempt != 1
                    or job.result.get("code") != "backup_quarantined"
                ):
                    raise ValueError("quarantine_job_not_completed")
                selected = {fixture["packages"][key]["id"] for key in SELECTED}
                if {item["backup_id"] for item in intent.packages} != selected:
                    raise ValueError("quarantine_intent_selection_changed")
            source = settings.data_directory / "backups"
            expected_source = set()
            for label, item in fixture["packages"].items():
                identity = UUID(item["id"])
                moved = intent is not None and label in SELECTED
                package = source / str(identity)
                control = session.get(BackupControl, identity)
                if moved:
                    if (
                        package.exists()
                        or control.state != "quarantined"
                        or control.version != item["control_version"] + 2
                    ):
                        raise ValueError("quarantine_final_control_changed")
                    target = (
                        settings.data_directory / "backup-quarantine" / str(intent.id)
                    )
                    package = target / "backups" / str(identity)
                    with private_open(
                        target / "receipts" / f"{identity}.json", target
                    ) as stream:
                        receipt = QuarantineReceipt.model_validate_json(
                            stream.read(32769)
                        )
                    if (
                        receipt.intent_id != intent.id
                        or receipt.job_id != job_id
                        or receipt.package.backup_id != identity
                        or receipt.selection_sha256 != intent.selection_sha256
                    ):
                        raise ValueError("quarantine_effect_receipt_changed")
                else:
                    expected_source.add(str(identity))
                    if label == "unregistered":
                        if control is not None:
                            raise ValueError("quarantine_legacy_auto_registered")
                    elif (
                        control.state != "available"
                        or control.version != item["control_version"]
                    ):
                        raise ValueError("quarantine_protected_control_changed")
                # Inspect the same deep owned destination without truncating
                # paths. This is read-only postverification; it never repairs
                # a missing production receipt or retries a file effect.
                inspection = (
                    Path("\\\\?\\" + str(package.absolute()))
                    if moved and os.name == "nt"
                    else package
                )
                if package_snapshot(inspection) != {
                    key: item[key] for key in ("files", "directories")
                }:
                    raise ValueError("quarantine_package_hash_or_layout_changed")
            if {item.name for item in source.iterdir()} != expected_source:
                raise ValueError("quarantine_source_directory_set_changed")
            if intent:
                target = settings.data_directory / "backup-quarantine" / str(intent.id)
                if {item.name for item in (target / "backups").iterdir()} != selected:
                    raise ValueError("quarantine_target_directory_set_changed")
                if {item.name for item in (target / "receipts").iterdir()} != {
                    f"{key}.json" for key in selected
                }:
                    raise ValueError("quarantine_receipt_set_changed")
            actors = [
                UUID(credentials[key]["user_id"])
                for key in ("owner", "recovery_only", "service_only")
            ]
            active = session.scalar(
                select(func.count())
                .select_from(UserSession)
                .where(
                    UserSession.user_id.in_(actors),
                    UserSession.revoked_at.is_(None),
                    UserSession.expires_at > now(),
                )
            )
            result = {
                "purpose": PURPOSE + "-postconditions",
                "run_id": fixture["run_id"],
                "database": fixture["database"],
                "head": HEAD,
                "restorable_dump": False,
                "verified_packages": 5,
                "quarantined_packages": 2 if intent else 0,
                "protected_packages_unchanged": 3 if intent else 5,
                "no_overwrite": True,
                "active_sessions": active,
                "job_id": str(job_id) if job_id else None,
                "intent_id": str(intent.id) if intent else None,
                "audits": {
                    action: session.scalar(
                        select(func.count())
                        .select_from(AdminAudit)
                        .where(
                            AdminAudit.action == action,
                            AdminAudit.target_id == intent.id,
                        )
                    )
                    if intent
                    else 0
                    for action in (
                        "backup.quarantine_enqueue",
                        "backup.quarantine_complete",
                    )
                },
            }
        output = path.parent / f"postconditions-{uuid4().hex}.json"
        write_new(output, result)
        return {"receipt": str(output), **result}
    finally:
        engine.dispose()


def worker(path, job_id):
    fixture, settings = load_fixture(path)
    credentials = credentials_for(fixture)
    engine = build_engine(settings)
    try:
        check_database(engine)
        with Session(engine) as session:
            pending = list(
                session.scalars(
                    select(BackgroundJob).where(
                        BackgroundJob.status.in_(("pending", "running", "retry_wait"))
                    )
                )
            )
            if (
                len(pending) != 1
                or pending[0].id != job_id
                or pending[0].kind != "backup_quarantine"
                or str(pending[0].owner_user_id) != credentials["owner"]["user_id"]
                or pending[0].status != "pending"
            ):
                raise ValueError("only_exact_owned_pending_job_required")
    finally:
        engine.dispose()
    scoped = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("FLOWTRACE_")
    }
    scoped.update(
        FLOWTRACE_ENVIRONMENT="test",
        FLOWTRACE_DATABASE_URL=settings.database_url.get_secret_value(),
        FLOWTRACE_DATA_DIRECTORY=str(settings.data_directory),
        FLOWTRACE_DIAGNOSTICS_ENABLED="false",
        FLOWTRACE_LOG_LEVEL="WARNING",
    )
    process = subprocess.Popen(
        [sys.executable, "-m", "flowtrace_server.worker", "--once"],
        cwd=ROOT,
        env=scoped,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
    )
    write_new(
        path.parent / f"worker-start-{uuid4().hex}.json",
        {
            "pid": process.pid,
            "job_id": str(job_id),
            "command": "python -m flowtrace_server.worker --once",
            "credentials_in_argv": False,
        },
    )
    try:
        process.communicate(timeout=90)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        raise ValueError("owned_worker_timed_out") from None
    if process.returncode:
        raise ValueError("owned_worker_failed")
    return verify(path, job_id)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("seed", "verify", "worker"))
    parser.add_argument("--env-file", type=Path)
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--job-id", type=UUID)
    args = parser.parse_args()
    if args.mode == "seed":
        if args.env_file is None or args.fixture or args.job_id:
            raise ValueError("closed_seed_arguments_required")
        result = seed(args.env_file)
    else:
        if (
            args.fixture is None
            or args.env_file
            or args.mode == "worker"
            and args.job_id is None
        ):
            raise ValueError("closed_fixture_arguments_required")
        result = (
            worker(args.fixture, args.job_id)
            if args.mode == "worker"
            else verify(args.fixture, args.job_id)
        )
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # noqa: BLE001 - never print connection/input exceptions
        print(
            json.dumps(
                {
                    "result": "failed",
                    "type": type(error).__name__,
                    "detail": "owned_quarantine_check_failed",
                }
            )
        )
        raise SystemExit(1) from None
