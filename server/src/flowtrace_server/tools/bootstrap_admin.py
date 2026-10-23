import argparse
import getpass
import os
import re

from sqlalchemy.orm import Session

from flowtrace_server.admin.service import bootstrap_admin, recover_admin
from flowtrace_server.config import Settings
from flowtrace_server.persistence.database import build_engine, check_database


def main() -> None:
    parser = argparse.ArgumentParser(description="Local-only administrator bootstrap/recovery")
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-env", help="Name of an existing environment variable")
    parser.add_argument("--recover", action="store_true", help="Restore local owner access")
    args = parser.parse_args()
    username = args.username.lower()
    password = (
        os.environ.get(args.password_env, "") if args.password_env else getpass.getpass("新密码: ")
    )
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]{2,63}", username) or not 12 <= len(password) <= 256:
        raise SystemExit("admin_input_invalid")
    engine = build_engine(Settings())
    try:
        check_database(engine)
        with Session(engine) as session:
            if not args.recover:
                bootstrap_admin(session, username, password)
            else:
                recover_admin(session, username, password)
            session.commit()
        print("administrator_ready")
    except Exception:
        raise SystemExit("administrator_operation_failed") from None
    finally:
        if engine is not None:
            engine.dispose()


if __name__ == "__main__":
    main()
