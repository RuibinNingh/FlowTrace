import pytest
from fastapi.testclient import TestClient

from flowtrace_server.config import Settings
from flowtrace_server.main import create_app
from flowtrace_server.sync.router import router

from .helpers import actor


@pytest.fixture
def actors(postgres_engine):
    return actor(postgres_engine), actor(postgres_engine), actor(postgres_engine)


@pytest.fixture
def sync_http(postgres_engine):
    app = create_app(Settings(_env_file=None, database_url=None, environment="test"))
    app.state.engine = postgres_engine
    if not any(getattr(route, "path", "") == "/api/v1/sync/push" for route in app.routes):
        app.include_router(router)
    with TestClient(app) as client:
        yield client
