"""Trusted local QA registry reader; never accepts a descriptor from the web UI."""

import json
from pathlib import Path
from uuid import UUID

from dotenv import dotenv_values
from flowtrace_server.config import RestoreTargetConfig
from flowtrace_server.persistence.testing import require_isolated_database


def load_restore_targets(file):
    root = Path(__file__).resolve().parents[3]
    file = Path(file).resolve()
    if not file.is_relative_to(root / "outputs/validation/P5/admin"):
        raise ValueError("unexpected_restore_fixture")
    fixture = json.loads(file.read_text(encoding="utf-8-sig"))
    if fixture.get("purpose") != "flowtrace-p5-restore-browser-synthetic":
        raise ValueError("restore_fixture_required")
    targets = {}
    for item in fixture["restore_targets"]:
        env = Path(item["env_file"]).resolve()
        if env.parent != root / "work/flowtrace-dev/postgresql":
            raise ValueError("unexpected_target_env")
        values = dotenv_values(env)
        parsed = require_isolated_database(
            values["FLOWTRACE_TEST_DATABASE_URL"], "test"
        )
        if not parsed.database.startswith("flowtrace_test_p5_restore_"):
            raise ValueError("restore_target_required")
        targets[UUID(item["target_id"])] = RestoreTargetConfig(
            label=item["label"],
            database_url=values["FLOWTRACE_TEST_DATABASE_URL"],
            data_directory=Path(values["FLOWTRACE_DATA_DIRECTORY"]),
            pg_restore_executable=root
            / "work/flowtrace-dev/postgresql/pgsql/bin/pg_restore.exe",
        )
    return targets
