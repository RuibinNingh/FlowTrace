"""Loopback-only synthetic admin acceptance host; never the final persistent service."""

import argparse
from pathlib import Path

import uvicorn
from dotenv import dotenv_values
from flowtrace_server.config import Settings
from flowtrace_server.main import create_app
from flowtrace_server.persistence.testing import require_isolated_database


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", required=True, type=Path)
    parser.add_argument("--port", choices=(18087, 18187), type=int, default=18087)
    arguments = parser.parse_args()
    values = dotenv_values(arguments.env_file)
    url = values["FLOWTRACE_TEST_DATABASE_URL"]
    require_isolated_database(url, values["FLOWTRACE_ENVIRONMENT"])
    if "flowtrace_test_p5_admin_" not in url:
        raise SystemExit("admin_fixture_database_required")
    settings = Settings(
        _env_file=arguments.env_file,
        database_url=url,
        environment="test",
        data_directory=Path(values["FLOWTRACE_DATA_DIRECTORY"]),
    )
    uvicorn.run(
        create_app(settings),
        host="127.0.0.1",
        port=arguments.port,
        access_log=False,
        log_level="warning",
    )


if __name__ == "__main__":
    main()
