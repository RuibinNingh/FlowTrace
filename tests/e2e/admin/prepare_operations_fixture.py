"""Extend an existing isolated admin fixture with real backups and bounded jobs."""

import argparse
import json
from datetime import timedelta
from pathlib import Path
from uuid import UUID, uuid4

from alembic import command
from dotenv import dotenv_values
from flowtrace_server.auth.models import User
from flowtrace_server.backups.service import create_backup
from flowtrace_server.config import Settings
from flowtrace_server.jobs import store
from flowtrace_server.persistence.database import build_engine, migration_config
from flowtrace_server.persistence.testing import require_isolated_database
from sqlalchemy.orm import Session


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    fixture_path = args.fixture.resolve()
    if not fixture_path.is_relative_to(root / "outputs/validation/P5/admin"):
        raise SystemExit("unexpected_fixture_location")
    fixture = json.loads(fixture_path.read_text(encoding="utf-8-sig"))
    if fixture.get("purpose") != "flowtrace-p5-admin-synthetic":
        raise SystemExit("unexpected_fixture")
    values = dotenv_values(args.env_file)
    url = values.get("FLOWTRACE_TEST_DATABASE_URL")
    parsed = require_isolated_database(url, values.get("FLOWTRACE_ENVIRONMENT", ""))
    if not parsed.database.startswith("flowtrace_test_p5_admin_"):
        raise SystemExit("unexpected_database")
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url=url,
        data_directory=Path(values["FLOWTRACE_DATA_DIRECTORY"]),
    )
    engine = build_engine(settings)
    run_id = uuid4()
    output = fixture_path.parent / f"operations-{run_id}.json"
    if output.exists():
        raise SystemExit("fixture_already_exists")
    try:
        with engine.begin() as connection:
            config = migration_config()
            config.attributes["connection"] = connection
            command.upgrade(config, "head")
        owner_id = UUID(fixture["identities"]["owner"]["user_id"])
        with Session(engine) as session:
            if session.get(User, owner_id) is None:
                raise SystemExit("fixture_owner_not_in_database")
        executable = root / "work/flowtrace-dev/postgresql/pgsql/bin/pg_dump.exe"
        good, damaged = [
            create_backup(
                settings, settings.data_directory / "backups", pg_dump=executable
            )
            for _ in range(2)
        ]
        damaged_file = (
            settings.data_directory / "backups" / damaged["backup_id"] / "database.dump"
        )
        original = damaged_file.read_bytes()
        damaged_file.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
        unsupported = []
        stale_id = uuid4()
        sentinel = f"fixture_private_operation_{run_id.hex}"
        with Session(engine) as session, session.begin():
            for index in range(52):
                record = store.enqueue(
                    session,
                    kind="export",
                    occurrence_key=f"admin-operations:{run_id}:{index}",
                    owner_user_id=owner_id,
                    payload={"fixture_private_body": sentinel},
                )
                unsupported.append(str(record.id))
            worker = store.heartbeat(
                session,
                stale_id,
                version="fixture.0",
                supported_kinds={"backup_verify"},
            )
            worker.heartbeat_at = store.stamp(session) - timedelta(seconds=120)
        result = {
            "purpose": "flowtrace-p5-admin-operations-synthetic",
            "run_id": str(run_id),
            "admin_fixture": str(fixture_path),
            "env_file": str(args.env_file.resolve()),
            "good_backup_id": good["backup_id"],
            "damaged_backup_id": damaged["backup_id"],
            "unsupported_job_ids": unsupported,
            "stale_worker_id": str(stale_id),
            "private_body_sentinel": sentinel,
            "state": "seeded",
        }
        output.write_text(json.dumps(result, indent=2), encoding="utf-8")
        print(json.dumps({"operations_fixture": str(output), "backups": 2, "jobs": 52}))
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
