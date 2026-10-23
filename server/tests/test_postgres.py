import pytest
from alembic import command
from fastapi.testclient import TestClient
from sqlalchemy import text

from flowtrace_server.config import Settings
from flowtrace_server.main import create_app
from flowtrace_server.persistence.database import check_database, migration_config

pytestmark = pytest.mark.postgres


def test_real_migration_and_identity_survive_repeated_upgrade(postgres_engine):
    first = check_database(postgres_engine)
    with postgres_engine.begin() as connection:
        config = migration_config()
        config.attributes["connection"] = connection
        command.upgrade(config, "head")
        assert connection.execute(text("SELECT COUNT(*) FROM server_state")).scalar_one() == 1
    assert check_database(postgres_engine) == first


def test_real_readiness_and_info(postgres_engine):
    app = create_app(Settings(_env_file=None, database_url=None))
    app.state.engine = postgres_engine
    with TestClient(app) as client:
        assert client.get("/health/ready").status_code == 200
        response = client.get("/api/v1/server-info")
        assert response.status_code == 200
        assert set(response.json()["capabilities"]) >= {
            "health",
            "server-info",
            "identity",
            "books",
        }
        assert response.json()["instance_id"] == str(check_database(postgres_engine)[0])


def test_migration_mismatch_is_not_ready(postgres_engine):
    with postgres_engine.begin() as connection:
        revision = connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one()
        connection.execute(text("UPDATE alembic_version SET version_num='unknown_revision'"))
    try:
        app = create_app(Settings(_env_file=None, database_url=None))
        app.state.engine = postgres_engine
        with TestClient(app) as client:
            response = client.get("/health/ready")
            assert response.status_code == 503
            assert response.json()["error"]["code"] == "service_unavailable"
    finally:
        with postgres_engine.begin() as connection:
            connection.execute(
                text("UPDATE alembic_version SET version_num=:revision"), {"revision": revision}
            )
    assert check_database(postgres_engine)
