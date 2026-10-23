"""Strict guard for explicitly isolated databases used by integration tests."""

import re

from sqlalchemy.engine import URL, make_url


def require_isolated_database(value: str, environment: str) -> URL:
    try:
        url = make_url(value)
    except Exception:
        raise ValueError("isolated_test_database_required") from None
    if (
        environment != "test"
        or url.drivername != "postgresql+psycopg"
        or url.host not in {"localhost", "127.0.0.1", "::1"}
        or not re.fullmatch(r"flowtrace_test_[a-z0-9_]+", url.database or "")
    ):
        raise ValueError("isolated_test_database_required")
    return url
