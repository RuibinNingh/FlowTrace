from datetime import timedelta
from uuid import uuid4

import pytest
from sqlalchemy.orm import Session

from flowtrace_server.admin.queries import list_users
from flowtrace_server.attachments.models import Attachment
from flowtrace_server.auth.service import create_user, issue_session, now
from flowtrace_server.sync.models import SyncClient

from .conftest import PASSWORD

pytestmark = pytest.mark.postgres


def test_nonzero_user_storage_and_activity_summary_is_declared_metadata(postgres_engine):
    # This transaction rolls back and does not bootstrap an admin or alter the
    # committed real-browser identities. No file content is read by the view.
    with postgres_engine.connect() as connection:
        transaction = connection.begin()
        try:
            with Session(connection, join_transaction_mode="create_savepoint") as session:
                user = create_user(session, "meta_" + uuid4().hex[:12], PASSWORD)
                issue_session(session, user, uuid4(), "Active", "api_native")
                revoked, _ = issue_session(session, user, uuid4(), "Revoked", "api_native")
                revoked.revoked_at = now()
                expired, _ = issue_session(session, user, uuid4(), "Expired", "api_native")
                expired.expires_at = now() - timedelta(seconds=1)
                observed = now() - timedelta(days=3)
                session.add(
                    SyncClient(
                        user_id=user.id,
                        client_id=uuid4(),
                        sync_epoch=uuid4(),
                        valid_until=now() + timedelta(days=30),
                        last_seen_at=observed,
                        frozen=False,
                        known_scope_ids=[],
                    )
                )
                for status, size in [
                    ("ready", 100),
                    ("ready", 200),
                    ("pending", 400),
                    ("uploaded", 800),
                    ("deleted", 1600),
                ]:
                    session.add(
                        Attachment(
                            id=uuid4(),
                            upload_id=uuid4(),
                            scope_id=user.id,
                            created_by=user.id,
                            sha256="a" * 64,
                            size_bytes=size,
                            media_type="image/png",
                            storage_key=uuid4().hex + uuid4().hex,
                            status=status,
                            created_at=now(),
                            upload_expires_at=now() + timedelta(hours=1),
                            ready_at=now() if status == "ready" else None,
                            orphaned_at=None,
                            width=1,
                            height=1,
                        )
                    )
                session.flush()
                summary = list_users(session, query=user.username)["summaries"][user.id]
                assert summary["active_sessions"] == 1
                assert summary["last_sync"] == observed
                assert summary["ready_attachments"] == 2 and summary["ready_bytes"] == 300
                assert summary["reserved_bytes"] == 1200
                assert summary["last_login"] is not None
        finally:
            transaction.rollback()
