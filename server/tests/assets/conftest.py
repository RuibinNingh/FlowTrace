import pytest
from fastapi.testclient import TestClient

from flowtrace_server.assets.router import router as assets_router
from flowtrace_server.config import Settings
from flowtrace_server.currencies.router import router as currencies_router
from flowtrace_server.main import create_app


@pytest.fixture
def assets_http(postgres_engine, tmp_path):
    app = create_app(
        Settings(_env_file=None, database_url=None, environment="test", data_directory=tmp_path)
    )
    app.state.engine = postgres_engine
    for router in (assets_router, currencies_router):
        if not any(getattr(route, "path", None) == router.routes[0].path for route in app.routes):
            app.include_router(router)
    with TestClient(app) as client:
        yield client
