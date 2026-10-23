"""Fresh retention browser fixtures; synthetic PGDMP, never a restore claim."""

import argparse
import hashlib
import json
import re
import secrets
from datetime import timedelta
from pathlib import Path
from uuid import UUID, uuid4

from alembic import command
from alembic.script import ScriptDirectory
from dotenv import dotenv_values
from flowtrace_server.auth.models import AdminRole, UserSession
from flowtrace_server.auth.service import (
    authenticate_access,
    create_user,
    issue_session,
    now,
)
from flowtrace_server.backups import retention
from flowtrace_server.backups.retention_models import BackupControl, BackupPin
from flowtrace_server.backups.retention_schemas import PinCreateCommand
from flowtrace_server.config import Settings
from flowtrace_server.imports.parsers import canonical
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
from flowtrace_server.persistence.testing import require_isolated_database
from sqlalchemy import func, select, text
from sqlalchemy.orm import Session

ROOT = Path(__file__).resolve().parents[3]
PURPOSE = "flowtrace-retention-browser-synthetic"
HEAD = "0015_import_requirements"
ORIGIN = "http://127.0.0.1:18092"
LABELS = {"old_eligible", "old_unregistered", "newest_witness", "pinned"}


def write_new(path, value):
    private_directory(path.parent)
    with private_open(path, path.parent, create=True) as stream:
        stream.write(json.dumps(value, ensure_ascii=False, indent=2).encode("utf-8"))


def environment(path):
    path = path.absolute()
    parent = ROOT / "work/flowtrace-dev/postgresql"
    regular_file(path, parent)
    if path.parent != parent or not re.fullmatch(
        r"server-p5-restore-[0-9a-f]{32}\.env", path.name
    ):
        raise ValueError("fresh_retention_environment_required")
    values = dotenv_values(path)
    url = values.get("FLOWTRACE_TEST_DATABASE_URL")
    parsed = require_isolated_database(url, values.get("FLOWTRACE_ENVIRONMENT", ""))
    run_id = path.stem.removeprefix("server-p5-restore-")
    if (
        parsed.database != f"flowtrace_test_p5_admin_{run_id[:16]}"
        or parsed.port != 55432
        or parsed.query
    ):
        raise ValueError("fresh_retention_database_required")
    data = Path(values["FLOWTRACE_DATA_DIRECTORY"]).absolute()
    if data.parent != ROOT / "work/flowtrace-dev/p5-restores" or data.name != run_id:
        raise ValueError("fresh_retention_data_required")
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url=url,
        data_directory=data,
        diagnostics_enabled=False,
    )
    return settings, parsed.database


def package_snapshot(path):
    files, directories = {}, []
    for item in sorted(path.rglob("*")):
        if item.is_symlink() or item.is_junction():
            raise ValueError("fixture_link_rejected")
        name = item.relative_to(path).as_posix()
        if item.is_dir():
            directories.append(name)
        else:
            regular_file(item, path)
            value = item.read_bytes()
            files[name] = {
                "sha256": hashlib.sha256(value).hexdigest(),
                "size_bytes": len(value),
            }
    return {"files": files, "directories": directories}


def make_package(settings, instance, epoch, age_days):
    identifier = uuid4()
    path = private_directory(settings.data_directory / "backups" / str(identifier))
    records = []
    for name, content in (
        ("database.dump", b"PGDMPsynthetic-browser-not-a-restorable-dump"),
        ("settings.json", canonical({"environment": "test", "synthetic": True})),
    ):
        with private_open(path / name, path, create=True) as stream:
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
        "backup_id": str(identifier),
        "created_at": (now() - timedelta(days=age_days)).isoformat(),
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
    with private_open(path / "manifest.json", path, create=True) as stream:
        stream.write(canonical(manifest))
    return identifier, path


def load_fixture(path):
    path = path.absolute()
    parent = ROOT / "outputs/validation/P5/admin"
    regular_file(path, parent)
    if (
        path.parent.parent != parent
        or not re.fullmatch(r"retention-[0-9a-f]{32}", path.parent.name)
        or path.name != "fixture.json"
    ):
        raise ValueError("retention_fixture_location_invalid")
    fixture = json.loads(path.read_text(encoding="utf-8"))
    if fixture.get("purpose") != PURPOSE or fixture.get("api_origin") != ORIGIN:
        raise ValueError("retention_fixture_invalid")
    if fixture.get("run_id") != path.parent.name.removeprefix("retention-"):
        raise ValueError("retention_fixture_invalid")
    if (
        fixture.get("expected_head") != HEAD
        or set(fixture.get("packages", {})) != LABELS
    ):
        raise ValueError("retention_fixture_invalid")
    settings, database = environment(Path(fixture["env_file"]))
    if fixture["database"] != database or fixture["data_directory"] != str(
        settings.data_directory
    ):
        raise ValueError("retention_fixture_binding_invalid")
    for item in fixture["packages"].values():
        if str(UUID(item["id"])) != item["id"]:
            raise ValueError("retention_fixture_uuid_invalid")
    identifiers = [item["id"] for item in fixture["packages"].values()]
    if (
        len(set(identifiers)) != 4
        or sorted(identifiers) != fixture["package_directory_names"]
    ):
        raise ValueError("retention_fixture_uuid_invalid")
    credential = Path(fixture["credential_file"])
    if (
        credential
        != ROOT / "work/flowtrace-dev" / f"retention-{fixture['run_id']}.json"
    ):
        raise ValueError("retention_fixture_credentials_invalid")
    regular_file(credential, credential.parent)
    return fixture, settings


def seed(env_file):
    settings, database = environment(env_file)
    engine = build_engine(settings)
    run_id = uuid4().hex
    output = (
        ROOT / "outputs/validation/P5/admin" / f"retention-{run_id}" / "fixture.json"
    )
    credential = ROOT / "work/flowtrace-dev" / f"retention-{run_id}.json"
    credentials, packages = {"wrong_password": secrets.token_urlsafe(24)}, {}
    try:
        if settings.data_directory.exists() or output.exists() or credential.exists():
            raise ValueError("fresh_retention_data_required")
        with engine.begin() as connection:
            count = connection.scalar(
                text(
                    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'"
                )
            )
            if count:
                raise ValueError("fresh_empty_retention_database_required")
            config = migration_config()
            if ScriptDirectory.from_config(config).get_heads() != [HEAD]:
                raise ValueError("retention_expected_head_changed")
            config.attributes["connection"] = connection
            command.upgrade(config, HEAD)
        instance, epoch = check_database(engine)
        with Session(engine) as session, session.begin():
            for label, roles in (
                ("owner", ("server_owner", "service_admin", "recovery_admin")),
                ("recovery_only", ("recovery_admin",)),
                ("service_only", ("service_admin",)),
            ):
                password = secrets.token_urlsafe(24)
                username = f"rt_{label}_{run_id[:12]}"
                user = create_user(session, username, password)
                session.add_all(
                    [AdminRole(user_id=user.id, role=role) for role in roles]
                )
                credentials[label] = {
                    "username": username,
                    "password": password,
                    "user_id": str(user.id),
                }
                if label == "owner":
                    owner = user
            seed_session, tokens = issue_session(
                session, owner, uuid4(), "retention seed", "admin"
            )
            seed_session_id = seed_session.id
            principal = authenticate_access(session, tokens["access_token"], admin=True)
        try:
            for label, age in (
                ("old_eligible", 40),
                ("old_unregistered", 40),
                ("pinned", 40),
                ("newest_witness", 0),
            ):
                identifier, path = make_package(settings, instance, epoch, age)
                if label != "old_unregistered":
                    with (
                        retention.prepare_registration(
                            settings, identifier
                        ) as prepared,
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
                        for version in range(1, 22):
                            retention.create_backup_pin(
                                session,
                                principal,
                                command=PinCreateCommand(
                                    backup_id=identifier,
                                    pin_id=uuid4(),
                                    request_id=uuid4(),
                                    expected_control_version=version,
                                ),
                                password=credentials["owner"]["password"],
                            )
                packages[label] = {
                    "id": str(identifier),
                    **package_snapshot(path),
                    "manifest_sha256": hashlib.sha256(
                        (path / "manifest.json").read_bytes()
                    ).hexdigest(),
                }
        finally:
            with Session(engine) as session, session.begin():
                session.get(UserSession, seed_session_id).revoked_at = now()
        write_new(credential, credentials)
        fixture = {
            "purpose": PURPOSE,
            "run_id": run_id,
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
            "package_directory_names": sorted(item["id"] for item in packages.values()),
        }
        write_new(output, fixture)
        return {
            "fixture": str(output),
            "packages": 4,
            "active_seed_sessions": 0,
            "pins": 21,
        }
    finally:
        engine.dispose()


def verify(path):
    fixture, settings = load_fixture(path)
    engine = build_engine(settings)
    try:
        instance, epoch = check_database(engine)
        if (str(instance), str(epoch)) != (
            fixture["source_instance"],
            fixture["source_epoch"],
        ):
            raise ValueError("retention_source_changed")
        names = sorted(
            item.name for item in (settings.data_directory / "backups").iterdir()
        )
        if names != fixture["package_directory_names"]:
            raise ValueError("retention_package_directories_changed")
        for item in fixture["packages"].values():
            actual = package_snapshot(settings.data_directory / "backups" / item["id"])
            if actual != {key: item[key] for key in ("files", "directories")}:
                raise ValueError("retention_package_bytes_changed")
        with private_open(
            Path(fixture["credential_file"]), ROOT / "work/flowtrace-dev"
        ) as stream:
            credentials = json.load(stream)
        actors = [
            UUID(credentials[label]["user_id"])
            for label in ("owner", "recovery_only", "service_only")
        ]
        with Session(engine) as session:
            active = session.scalar(
                select(func.count())
                .select_from(UserSession)
                .where(
                    UserSession.user_id.in_(actors),
                    UserSession.revoked_at.is_(None),
                    UserSession.expires_at > now(),
                )
            )
            control_count = session.scalar(
                select(func.count()).select_from(BackupControl)
            )
            pins = session.scalar(
                select(func.count())
                .select_from(BackupPin)
                .where(
                    BackupPin.backup_id == UUID(fixture["packages"]["pinned"]["id"]),
                    BackupPin.released_at.is_(None),
                )
            )
        return {
            "purpose": PURPOSE + "-postconditions",
            "run_id": fixture["run_id"],
            "database": fixture["database"],
            "head": HEAD,
            "packages_unchanged": 4,
            "directories_unchanged": True,
            "active_sessions": active,
            "registered_packages": control_count,
            "active_fixture_pins": pins,
            "restorable_dump": False,
        }
    finally:
        engine.dispose()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--env-file", type=Path)
    group.add_argument("--verify", type=Path)
    args = parser.parse_args()
    print(json.dumps(seed(args.env_file) if args.env_file else verify(args.verify)))


if __name__ == "__main__":
    main()
