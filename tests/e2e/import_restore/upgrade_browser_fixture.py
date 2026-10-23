"""Additive upgrade of this run's isolated QA DB; never resets or reseeds it."""

import argparse
import json
from pathlib import Path

from alembic import command
from dotenv import dotenv_values
from flowtrace_server.config import Settings
from flowtrace_server.persistence.database import build_engine, migration_config
from flowtrace_server.persistence.testing import require_isolated_database
from sqlalchemy import text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--from-revision", required=True)
    parser.add_argument("--to-revision", required=True)
    args = parser.parse_args()
    fixture = json.loads(args.fixture.read_text("utf-8"))
    assert fixture["purpose"] == "flowtrace-data-tools-normal-browser-synthetic"
    env = dotenv_values(fixture["environment_file"])
    raw_url = env["FLOWTRACE_TEST_DATABASE_URL"]
    url = require_isolated_database(raw_url, env["FLOWTRACE_ENVIRONMENT"])
    assert (url.host, url.port, url.username) == ("127.0.0.1", 55432, "flowtrace_dev")
    assert url.database != "flowtrace_test_p5_local"
    engine = build_engine(
        Settings(_env_file=None, environment="test", database_url=raw_url)
    )
    with engine.begin() as connection:
        assert (
            connection.scalar(text("SELECT version_num FROM alembic_version"))
            == args.from_revision
        )
        before = connection.execute(
            text("SELECT instance_id,sync_epoch FROM server_state")
        ).one()
        configuration = migration_config()
        configuration.attributes["connection"] = connection
        command.upgrade(configuration, args.to_revision)
        assert (
            connection.scalar(text("SELECT version_num FROM alembic_version"))
            == args.to_revision
        )
        assert (
            connection.execute(
                text("SELECT instance_id,sync_epoch FROM server_state")
            ).one()
            == before
        )
    engine.dispose()
    print(
        json.dumps(
            {
                "additive_upgrade": True,
                "instance_and_epoch_preserved": True,
                "target": args.to_revision,
                "reset_or_seed": False,
            }
        )
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # noqa: BLE001 -- CLI redacts driver DSNs.
        raise SystemExit("fixture_upgrade_failed_" + type(error).__name__) from None
