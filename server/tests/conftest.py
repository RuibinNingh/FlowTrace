import os

import pytest
from alembic import command

from flowtrace_server.config import Settings
from flowtrace_server.persistence.database import build_engine, migration_config
from flowtrace_server.persistence.testing import require_isolated_database


@pytest.fixture(scope="session")
def postgres_engine():
    value = os.environ.get("FLOWTRACE_TEST_DATABASE_URL")
    if not value:
        pytest.skip("FLOWTRACE_TEST_DATABASE_URL not set: real PostgreSQL not verified")
    require_isolated_database(value, os.environ.get("FLOWTRACE_ENVIRONMENT", ""))
    engine = build_engine(Settings(_env_file=None, database_url=value))
    with engine.begin() as connection:
        config = migration_config()
        config.attributes["connection"] = connection
        command.upgrade(config, "head")
    yield engine
    engine.dispose()
