"""Explicit migration command included in the wheel; never runs during API startup."""

import argparse

from alembic import command

from flowtrace_server.config import Settings
from flowtrace_server.persistence.database import build_engine, migration_config


def main() -> None:
    parser = argparse.ArgumentParser(description="Apply reviewed FlowTrace migrations")
    parser.add_argument("action", choices=["upgrade", "check"])
    args = parser.parse_args()
    config = migration_config()
    try:
        if args.action == "upgrade":
            command.upgrade(config, "head")
        else:
            from flowtrace_server.persistence.database import check_database

            engine = build_engine(Settings())
            try:
                check_database(engine)
            finally:
                if engine is not None:
                    engine.dispose()
        print("migration_ok")
    except Exception:
        raise SystemExit("migration_failed: check configuration and database readiness") from None


if __name__ == "__main__":
    main()
