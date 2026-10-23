"""Private group reader deadlines; no retries can silently multiply a step."""

from dataclasses import dataclass
from time import monotonic

from sqlalchemy import event
from sqlalchemy.exc import DBAPIError

from flowtrace_server.auth.errors import ApiError


class GroupDeadline(Exception):
    pass


@dataclass
class GroupBudget:
    deadline: float
    current_deadline: float

    @classmethod
    def start(cls, seconds):
        deadline = monotonic() + seconds
        return cls(deadline, deadline)

    def check(self):
        if monotonic() >= self.current_deadline:
            raise GroupDeadline()


def group_transaction(session, callback, *, repeatable=False, seconds=5):
    """Bound each SQL wait by remaining wall budget, including authority reads.

    A separate short work deadline leaves time for durable progress and the final
    authority fence. Driver/OS scheduling and COMMIT delivery remain external to
    a Python deadline; no capacity or absolute realtime guarantee is implied.
    """
    budget = GroupBudget.start(seconds)
    session.rollback()
    connection = session.connection(
        execution_options={"isolation_level": "REPEATABLE READ" if repeatable else "READ COMMITTED"}
    )

    def bounded_sql(conn, cursor, statement, parameters, context, executemany):
        if statement.lstrip().upper().startswith(("ROLLBACK", "RELEASE SAVEPOINT")):
            return
        remaining = int((budget.current_deadline - monotonic()) * 1000)
        if remaining <= 0:
            raise GroupDeadline()
        # Computed integers only. Use the DBAPI cursor to avoid event recursion.
        cursor.execute(f"SET LOCAL statement_timeout = '{remaining}ms'")
        cursor.execute(f"SET LOCAL lock_timeout = '{min(remaining, 3000)}ms'")

    event.listen(connection, "before_cursor_execute", bounded_sql)
    try:
        result = callback(budget)
        budget.check()
        session.commit()
        return result
    except (DBAPIError, GroupDeadline):
        session.rollback()
        raise ApiError("group_unavailable", 503) from None
    except Exception:
        session.rollback()
        raise
    finally:
        event.remove(connection, "before_cursor_execute", bounded_sql)
