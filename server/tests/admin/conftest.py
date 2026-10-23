import re

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from flowtrace_server.admin.service import bootstrap_admin
from flowtrace_server.auth.dependencies import get_session
from flowtrace_server.config import Settings
from flowtrace_server.main import create_app

PASSWORD = "Admin-fixture-password-2026"
ORIGIN = {"origin": "http://testserver"}


@pytest.fixture
def admin_system(postgres_engine, tmp_path):
    with postgres_engine.connect() as connection:
        outer = connection.begin()

        def session_provider():
            with Session(
                connection, expire_on_commit=False, join_transaction_mode="create_savepoint"
            ) as session:
                yield session

        with Session(connection, join_transaction_mode="create_savepoint") as session:
            owner = bootstrap_admin(session, "admin_owner", PASSWORD)
            owner_id = owner.id
            session.commit()
        app = create_app(
            Settings(_env_file=None, database_url=None, environment="test", data_directory=tmp_path)
        )
        app.state.engine = postgres_engine
        app.dependency_overrides[get_session] = session_provider
        with TestClient(app) as client:
            yield client, connection, owner_id
        outer.rollback()


def login(client, username="admin_owner", password=PASSWORD):
    page = client.get("/admin/login")
    csrf = re.search(r'name="csrf_token" value="([^"]+)"', page.text).group(1)
    response = client.post(
        "/admin/login",
        data={"username": username, "password": password, "csrf_token": csrf},
        headers=ORIGIN,
        follow_redirects=False,
    )
    assert response.status_code == 303
    return client.cookies.get("flowtrace_admin_csrf")
