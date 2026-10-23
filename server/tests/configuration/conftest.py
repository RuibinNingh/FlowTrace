from uuid import uuid4

import pytest
from sqlalchemy.orm import Session

from flowtrace_server.admin.service import bootstrap_admin
from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.service import issue_session, roles_for

PASSWORD = "Configuration-fixture-password-2026"


@pytest.fixture
def config_system(postgres_engine):
    with postgres_engine.connect() as connection:
        outer = connection.begin()
        with Session(
            connection, expire_on_commit=False, join_transaction_mode="create_savepoint"
        ) as session:
            user = bootstrap_admin(session, "configuration_owner", PASSWORD)
            record, _ = issue_session(session, user, uuid4(), "configuration fixture", "admin")
            principal = Principal(
                user.id, record.id, record.client_id, "admin", roles_for(session, user.id)
            )
            session.commit()
            yield session, principal
        outer.rollback()


@pytest.fixture
def committed_config_actor(postgres_engine):
    from sqlalchemy import delete, select
    from sqlalchemy.dialects.postgresql import insert

    from flowtrace_server.admin.models import AdminAudit, AdminControl
    from flowtrace_server.auth.models import AdminRole, User, UserSession
    from flowtrace_server.auth.service import PASSWORDS, now
    from flowtrace_server.configuration.models import ConfigurationHead, ConfigurationRevision

    actor_id = uuid4()
    request_ids = []
    with Session(postgres_engine) as session, session.begin():
        original = session.get(ConfigurationHead, 1)
        baseline = (
            original.current_version,
            dict(original.public_values),
            dict(original.secret_refs),
            original.updated_at,
        )
        inserted_control = session.scalar(
            insert(AdminControl).values(id=1).on_conflict_do_nothing().returning(AdminControl.id)
        )
        user = User(
            id=actor_id,
            username=f"configuration_{actor_id.hex}",
            password_hash=PASSWORDS.hash(PASSWORD),
            enabled=True,
            created_at=now(),
        )
        session.add(user)
        session.flush()
        session.add(AdminRole(user_id=actor_id, role="service_admin"))
        record, _ = issue_session(session, user, uuid4(), "configuration contention", "admin")
        principal = Principal(actor_id, record.id, record.client_id, "admin", frozenset())
    try:
        yield principal, request_ids, baseline[0]
    finally:
        with Session(postgres_engine) as session, session.begin():
            session.scalar(select(AdminControl).where(AdminControl.id == 1).with_for_update())
            head = session.scalar(
                select(ConfigurationHead).where(ConfigurationHead.id == 1).with_for_update()
            )
            own_revisions = list(
                session.scalars(
                    select(ConfigurationRevision).where(
                        ConfigurationRevision.actor_user_id == actor_id
                    )
                )
            )
            # Restore only this fixture's exact published revisions. If any
            # unrelated writer intervened, fail rather than reset its state.
            assert all(item.request_id in request_ids for item in own_revisions)
            assert head.current_version == baseline[0] + len(own_revisions)
            head.current_version, head.public_values, head.secret_refs, head.updated_at = baseline
            session.execute(
                delete(ConfigurationRevision).where(ConfigurationRevision.actor_user_id == actor_id)
            )
            session.execute(delete(AdminAudit).where(AdminAudit.actor_id == actor_id))
            session.execute(delete(AdminRole).where(AdminRole.user_id == actor_id))
            session.execute(delete(UserSession).where(UserSession.user_id == actor_id))
            session.execute(delete(User).where(User.id == actor_id))
            if inserted_control is not None:
                session.execute(delete(AdminControl).where(AdminControl.id == 1))
