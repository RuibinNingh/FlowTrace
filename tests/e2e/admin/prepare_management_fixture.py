"""Create synthetic P5 admin identities only in a named isolated test database."""

import argparse
import json
import secrets
from pathlib import Path
from uuid import uuid4

from alembic import command
from dotenv import dotenv_values
from flowtrace_server.admin.service import audit, bootstrap_admin
from flowtrace_server.auth.models import AdminRole
from flowtrace_server.auth.service import create_user, issue_session
from flowtrace_server.books.models import Book
from flowtrace_server.config import Settings
from flowtrace_server.persistence.database import (
    build_engine,
    check_database,
    migration_config,
)
from flowtrace_server.persistence.testing import require_isolated_database
from sqlalchemy import select
from sqlalchemy.orm import Session


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--migrate", action="store_true")
    parser.add_argument("--configuration", action="store_true")
    arguments = parser.parse_args()
    values = dotenv_values(arguments.env_file)
    url = values["FLOWTRACE_TEST_DATABASE_URL"]
    require_isolated_database(url, values["FLOWTRACE_ENVIRONMENT"])
    if "flowtrace_test_p5_admin_" not in url:
        raise SystemExit("admin_fixture_database_required")
    root = Path(__file__).resolve().parents[3]
    run = str(uuid4())
    output = root / "outputs/validation/P5/admin" / run
    output.mkdir(parents=True)
    private = root / "work/flowtrace-dev" / f"admin-qa-{run}.json"
    settings = Settings(
        _env_file=arguments.env_file, database_url=url, environment="test"
    )
    engine = build_engine(settings)
    if arguments.migrate:
        with engine.begin() as connection:
            config = migration_config()
            config.attributes["connection"] = connection
            command.upgrade(config, "head")
    check_database(engine)
    credentials = {}
    identities = {}
    try:
        with Session(engine) as session:
            for label, roles in {
                "owner": ["server_owner", "service_admin", "recovery_admin"],
                "service": ["service_admin"],
                "recovery": ["recovery_admin"],
                "role_target": [],
                "reset_target": [],
            }.items():
                username = f"qa_{label}_{run[:8]}"
                password = secrets.token_urlsafe(24)
                if label == "owner":
                    user = bootstrap_admin(session, username, password)
                else:
                    user = create_user(session, username, password)
                    for role in roles:
                        session.add(AdminRole(user_id=user.id, role=role))
                session.flush()
                credentials[label] = {"username": username, "password": password}
                identities[label] = {
                    "user_id": str(user.id),
                    "book_id": str(
                        session.scalar(
                            select(Book.id).where(Book.owner_user_id == user.id)
                        )
                    ),
                }
                if label == "reset_target":
                    _, tokens = issue_session(
                        session, user, uuid4(), "Synthetic reset target", "api_native"
                    )
                    credentials[label]["original_access_token"] = tokens["access_token"]
                    credentials[label]["new_password"] = secrets.token_urlsafe(24)
            credentials["wrong_password"] = secrets.token_urlsafe(24)
            if arguments.configuration:
                credentials["configuration_ai_secret"] = secrets.token_urlsafe(32)
            owner = identities["owner"]["user_id"]
            from uuid import UUID

            for index in range(56):
                audit(
                    session,
                    UUID(owner),
                    "fixture.browser_page",
                    uuid4(),
                    succeeded=index % 2 == 0,
                    count=index,
                )
            session.commit()
        with private.open("x", encoding="utf-8") as file:
            json.dump(credentials, file, ensure_ascii=False)
        fixture = {
            "run_id": run,
            "purpose": "flowtrace-p5-admin-synthetic",
            "state": "seeded",
            "origin": "http://127.0.0.1:18087",
            "credentials_path": str(private),
            "identities": identities,
            "audit_fixture_count": 56,
            "env_file": str(arguments.env_file.absolute()),
            "configuration_fixture": arguments.configuration,
        }
        with (output / "fixture.json").open("x", encoding="utf-8") as file:
            json.dump(fixture, file, ensure_ascii=False, indent=2)
    finally:
        engine.dispose()
    print(json.dumps({"run_id": run, "fixture": str(output / "fixture.json")}))


if __name__ == "__main__":
    main()
