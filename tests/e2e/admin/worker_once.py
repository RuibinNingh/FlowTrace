"""Use the production Worker for one iteration, with private isolated settings."""

import argparse
import json
from pathlib import Path

from dotenv import dotenv_values
from flowtrace_server.config import Settings
from flowtrace_server.persistence.database import build_engine
from flowtrace_server.persistence.testing import require_isolated_database
from flowtrace_server.worker.runtime import Worker
from restore_fixture import load_restore_targets


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--backup-create", action="store_true")
    parser.add_argument("--restore-fixture", type=Path)
    args = parser.parse_args()
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
        pg_dump_executable=(
            Path(__file__).resolve().parents[3]
            / "work/flowtrace-dev/postgresql/pgsql/bin/pg_dump.exe"
        )
        if args.backup_create
        else None,
        restore_targets=load_restore_targets(args.restore_fixture)
        if args.restore_fixture
        else {},
    )
    engine = build_engine(settings)
    try:
        print(json.dumps({"worked": Worker(engine, settings).run_once()}))
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
