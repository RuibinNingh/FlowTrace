"""Real PostgreSQL and ordinary HTTP paths consume fresh configuration."""

import hashlib
import io
import re
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import timedelta
from threading import Event
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from PIL import Image
from sqlalchemy import delete, func, select, text
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session

from flowtrace_server.admin.service import create_invite
from flowtrace_server.attachments.gc import collect
from flowtrace_server.attachments.models import (
    Attachment,
    AttachmentHold,
    AttachmentRef,
    UploadTicket,
)
from flowtrace_server.attachments.schemas import UploadDeclaration
from flowtrace_server.attachments.service import declare_upload, hold_attachments
from flowtrace_server.attachments.storage import AttachmentStore
from flowtrace_server.auth.dependencies import Principal, get_session
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import Invite, RefreshToken, User, UserSession
from flowtrace_server.auth.service import create_user, digest, issue_session, now
from flowtrace_server.books.models import Book, BookMembership, SyncScope
from flowtrace_server.config import Settings
from flowtrace_server.configuration.runtime import read_runtime_configuration
from flowtrace_server.configuration.schemas import (
    ConfigurationSaveCommand,
    PublicConfigurationPatch,
)
from flowtrace_server.configuration.service import save_configuration
from flowtrace_server.diagnostics import configure_logging
from flowtrace_server.main import create_app
from flowtrace_server.sync.models import SyncEntity
from flowtrace_server.sync.schemas import BillPayload

from .conftest import PASSWORD

pytestmark = pytest.mark.postgres
ORIGIN = {"origin": "http://testserver"}


def image_bytes(size=(12, 8)):
    output = io.BytesIO()
    Image.new("RGB", size, "#3593FD").save(output, format="PNG")
    return output.getvalue()


@dataclass
class Actor:
    user_id: UUID
    book_id: UUID
    headers: dict = field(repr=False)


@dataclass
class RuntimeCase:
    session: Session = field(repr=False)
    administrator: object = field(repr=False)
    client: TestClient = field(repr=False)
    store: AttachmentStore = field(repr=False)

    def policy(self, **patch):
        version = read_runtime_configuration(self.session).version
        result = save_configuration(
            self.session,
            self.administrator,
            ConfigurationSaveCommand(
                base_version=version,
                request_id=uuid4(),
                public_patch=PublicConfigurationPatch(**patch),
            ),
            password=PASSWORD,
            validate_candidate=lambda public, refs: None,
        )
        self.session.commit()
        return result.version

    def actor(self):
        user = create_user(self.session, f"runtime_{uuid4().hex}", PASSWORD)
        book_id = self.session.scalar(select(Book.id).where(Book.owner_user_id == user.id))
        _, tokens = issue_session(self.session, user, uuid4(), "runtime policy fixture", "native")
        result = Actor(user.id, book_id, {"authorization": "Bearer " + tokens["access_token"]})
        self.session.commit()
        return result

    def declaration(self, actor, *, content, scope_id=None, attachment_id=None):
        body = {
            "attachment_id": str(attachment_id or uuid4()),
            "scope_id": str(scope_id or actor.book_id),
            "sha256": hashlib.sha256(content).hexdigest(),
            "size_bytes": len(content),
            "media_type": "image/png",
        }
        return body, self.client.post(
            "/api/v1/attachments/uploads", headers=actor.headers, json=body
        )

    def ready(self, actor, content):
        body, declared = self.declaration(actor, content=content)
        assert declared.status_code == 201, declared.text
        upload_id = declared.json()["upload_id"]
        received = self.client.put(
            f"/api/v1/attachments/uploads/{upload_id}/content",
            headers=actor.headers,
            content=content,
        )
        assert received.status_code == 200, received.text
        completed = self.client.post(
            f"/api/v1/attachments/uploads/{upload_id}/complete", headers=actor.headers
        )
        assert completed.status_code == 200, completed.text
        return body, upload_id

    def counts(self):
        return tuple(
            self.session.scalar(select(func.count()).select_from(model))
            for model in (Attachment, UploadTicket)
        )


@pytest.fixture
def runtime_case(config_system, tmp_path):
    session, principal = config_system
    connection = session.get_bind()

    def db_session():
        with Session(
            connection, expire_on_commit=False, join_transaction_mode="create_savepoint"
        ) as request_session:
            yield request_session

    app = create_app(
        Settings(_env_file=None, environment="test", database_url=None, data_directory=tmp_path)
    )
    app.state.engine = connection.engine
    app.dependency_overrides[get_session] = db_session
    try:
        with TestClient(app) as client:
            yield RuntimeCase(session, principal, client, AttachmentStore(tmp_path / "attachments"))
    finally:
        configure_logging("INFO")


def test_disabled_registration_preserves_invite_for_identical_later_http_request(runtime_case):
    case = runtime_case
    invitation, token = create_invite(case.session, case.administrator)
    invitation_id = invitation.id
    case.session.commit()
    users_before = case.session.scalar(select(func.count()).select_from(User))
    body = {
        "username": f"runtime_registered_{uuid4().hex}",
        "password": PASSWORD,
        "client_id": str(uuid4()),
        "device_name": "runtime registration fixture",
        "client_kind": "native",
        "invite_token": token,
    }
    case.policy(registration_enabled=False)
    disabled = case.client.post("/api/v1/auth/register", json=body)
    assert disabled.status_code == 403
    assert disabled.json()["error"]["code"] == "registration_disabled"
    case.session.expire_all()
    assert case.session.get(Invite, invitation_id).consumed_by is None
    assert case.session.scalar(select(func.count()).select_from(User)) == users_before
    case.policy(registration_enabled=True)
    enabled = case.client.post("/api/v1/auth/register", json=body)
    assert enabled.status_code == 201, enabled.text
    case.session.expire_all()
    assert case.session.get(Invite, invitation_id).consumed_by == UUID(enabled.json()["user_id"])
    assert case.session.scalar(select(func.count()).select_from(User)) == users_before + 1
    assert case.client.post("/api/v1/auth/register", json=body).status_code == 422


def test_invite_service_uses_fresh_default_and_preserves_explicit_duration(runtime_case):
    case = runtime_case
    for configured, explicit, expected in ((3, None, 3), (11, None, 11), (11, 2, 2)):
        case.policy(invitation_default_days=configured)
        invitation, _ = create_invite(case.session, case.administrator, explicit)
        duration = (invitation.expires_at - invitation.created_at).total_seconds()
        assert expected * 86400 <= duration < expected * 86400 + 1
        case.session.commit()


@pytest.mark.parametrize("channel", ["form", "omitted-http-days"])
def test_admin_invite_default_consumes_current_policy(runtime_case, channel):
    case = runtime_case
    case.policy(invitation_default_days=11)
    login = case.client.get("/admin/login")
    csrf = re.search(r'name="csrf_token" value="([^"]+)"', login.text).group(1)
    signed_in = case.client.post(
        "/admin/login",
        headers=ORIGIN,
        data={"username": "configuration_owner", "password": PASSWORD, "csrf_token": csrf},
        follow_redirects=False,
    )
    assert signed_in.status_code == 303
    if channel == "form":
        page = case.client.get("/admin/invites")
        assert page.status_code == 200
        assert re.search(r'name="days"[^>]*value="11"', page.text)
    else:
        created = case.client.post(
            "/admin/invites",
            headers=ORIGIN,
            data={"csrf_token": case.client.cookies.get("flowtrace_admin_csrf")},
        )
        assert created.status_code == 200
        token = re.search(r'data-testid="invite-token">([^<]+)', created.text).group(1)
        invitation = case.session.scalar(select(Invite).where(Invite.token_hash == digest(token)))
        duration = (invitation.expires_at - invitation.created_at).total_seconds()
        assert 11 * 86400 <= duration < 11 * 86400 + 1


def test_pending_reservations_count_per_creator_across_owned_and_shared_scopes(runtime_case):
    case = runtime_case
    alice, bob = case.actor(), case.actor()
    case.session.add(BookMembership(book_id=bob.book_id, user_id=alice.user_id, role="editor"))
    case.session.commit()
    content = image_bytes()
    case.policy(attachment_max_bytes=len(content), per_user_attachment_quota_bytes=2 * len(content))
    for actor, scope in ((alice, alice.book_id), (alice, bob.book_id), (bob, bob.book_id)):
        _, response = case.declaration(actor, content=content, scope_id=scope)
        assert response.status_code == 201, response.text
    before = case.counts()
    rejected_body, exhausted = case.declaration(alice, content=content, scope_id=bob.book_id)
    assert exhausted.status_code == 409
    assert exhausted.json()["error"]["code"] == "attachment_quota_exceeded"
    assert case.counts() == before == (3, 3)
    assert case.session.get(Attachment, UUID(rejected_body["attachment_id"])) is None
    _, too_large = case.declaration(alice, content=content + b"x")
    assert too_large.status_code == 413
    assert too_large.json()["error"]["code"] == "attachment_file_limit_exceeded"
    assert case.counts() == before
    rows = list(case.session.scalars(select(Attachment)))
    assert all(row.status == "pending" for row in rows)
    assert sum(row.size_bytes for row in rows if row.created_by == alice.user_id) == 2 * len(
        content
    )
    assert sum(row.size_bytes for row in rows if row.created_by == bob.user_id) == len(content)


def test_lowered_limits_keep_existing_pending_upload_and_ready_replays(runtime_case):
    case = runtime_case
    actor, content = case.actor(), image_bytes()
    case.policy(attachment_max_bytes=len(content), per_user_attachment_quota_bytes=4 * len(content))
    pending_body, declared = case.declaration(actor, content=content)
    assert declared.status_code == 201
    ready_body, ready_upload = case.ready(actor, content)
    pending_upload = declared.json()["upload_id"]
    before = case.counts()
    case.policy(
        attachment_max_bytes=len(content) - 1,
        per_user_attachment_quota_bytes=len(content) - 1,
    )
    for body, upload, status in (
        (pending_body, pending_upload, "pending"),
        (ready_body, ready_upload, "ready"),
    ):
        replay = case.client.post("/api/v1/attachments/uploads", headers=actor.headers, json=body)
        assert replay.status_code == 201, replay.text
        assert replay.json()["replayed"] and replay.json()["upload_id"] == upload
        assert replay.json()["status"] == status
    received = case.client.put(
        f"/api/v1/attachments/uploads/{pending_upload}/content",
        headers=actor.headers,
        content=content,
    )
    assert received.status_code == 200, received.text
    assert (
        case.client.post(
            f"/api/v1/attachments/uploads/{pending_upload}/complete", headers=actor.headers
        ).status_code
        == 200
    )
    for body in (pending_body, ready_body):
        downloaded = case.client.get(
            f"/api/v1/attachments/{body['attachment_id']}/content", headers=actor.headers
        )
        assert downloaded.status_code == 200 and downloaded.content == content
    small = image_bytes((1, 1))
    assert len(small) <= len(content) - 1
    _, insufficient = case.declaration(actor, content=small)
    assert insufficient.status_code == 409
    assert insufficient.json()["error"]["code"] == "attachment_quota_exceeded"
    assert case.counts() == before == (2, 2)


def test_deleted_declarations_reserve_again_and_quota_failure_keeps_old_state(runtime_case):
    case = runtime_case
    actor, content = case.actor(), image_bytes()
    bodies = [case.ready(actor, content)[0] for _ in range(2)]
    for body in bodies:
        case.session.get(Attachment, UUID(body["attachment_id"])).orphaned_at = now() - timedelta(
            days=10
        )
    case.session.commit()
    assert collect(case.session.get_bind(), case.store)["deleted"] == 2
    case.session.expire_all()
    second = case.session.get(Attachment, UUID(bodies[1]["attachment_id"]))
    old_upload = second.upload_id
    case.policy(attachment_max_bytes=len(content), per_user_attachment_quota_bytes=len(content))
    resurrected = case.client.post(
        "/api/v1/attachments/uploads", headers=actor.headers, json=bodies[0]
    )
    assert resurrected.status_code == 201 and resurrected.json()["status"] == "pending"
    assert resurrected.json()["replayed"]
    before = case.counts()
    exhausted = case.client.post(
        "/api/v1/attachments/uploads", headers=actor.headers, json=bodies[1]
    )
    assert exhausted.status_code == 409
    assert exhausted.json()["error"]["code"] == "attachment_quota_exceeded"
    case.session.expire_all()
    second = case.session.get(Attachment, second.id)
    assert second.status == "deleted" and second.upload_id == old_upload
    assert case.counts() == before == (2, 3)


def test_competing_reservations_in_distinct_scopes_hold_one_creator_lock(
    postgres_engine, committed_config_actor, tmp_path
):
    administrator, request_ids, version = committed_config_actor
    owner_id, books = uuid4(), (uuid4(), uuid4())
    content = image_bytes()
    store = AttachmentStore(tmp_path / "concurrent-attachments")
    request = ConfigurationSaveCommand(
        base_version=version,
        request_id=uuid4(),
        public_patch=PublicConfigurationPatch(
            attachment_max_bytes=len(content), per_user_attachment_quota_bytes=len(content)
        ),
    )
    request_ids.append(request.request_id)
    with Session(postgres_engine) as session, session.begin():
        save_configuration(
            session,
            administrator,
            request,
            password=PASSWORD,
            validate_candidate=lambda public, refs: None,
        )
        user = User(
            id=owner_id,
            username=f"runtime_reservation_{owner_id.hex}",
            password_hash="not-a-login-fixture",
            enabled=True,
            created_at=now(),
        )
        session.add(user)
        session.flush()
        for book_id in books:
            session.add(
                Book(
                    id=book_id,
                    name="runtime reservation",
                    owner_user_id=owner_id,
                    shared=False,
                    created_at=now(),
                )
            )
        session.flush()
        for book_id in books:
            session.add_all(
                [
                    BookMembership(book_id=book_id, user_id=owner_id, role="owner"),
                    SyncScope(
                        id=book_id,
                        kind="book",
                        owner_user_id=owner_id,
                        book_id=book_id,
                        revision=0,
                        permission_version=1,
                    ),
                ]
            )
        record, _ = issue_session(session, user, uuid4(), "quota contention", "native")
        principal = Principal(owner_id, record.id, record.client_id, "native", frozenset())
    bodies = [
        UploadDeclaration(
            attachment_id=uuid4(),
            scope_id=book_id,
            sha256=hashlib.sha256(content).hexdigest(),
            size_bytes=len(content),
            media_type="image/png",
        )
        for book_id in books
    ]
    declared, release = Event(), Event()

    def first_reservation():
        with Session(postgres_engine) as session, session.begin():
            record, _ = declare_upload(session, principal, bodies[0], store)
            declared.set()
            assert release.wait(timeout=8)
            return record.id

    try:
        with ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(first_reservation)
            try:
                assert declared.wait(timeout=5)
                with pytest.raises(OperationalError) as blocked:
                    with Session(postgres_engine) as session, session.begin():
                        session.execute(text("SET LOCAL lock_timeout='250ms'"))
                        declare_upload(session, principal, bodies[1], store)
                assert blocked.value.orig.sqlstate == "55P03"
            finally:
                release.set()
            assert future.result(timeout=5) == bodies[0].attachment_id
        with pytest.raises(ApiError) as exhausted:
            with Session(postgres_engine) as session, session.begin():
                declare_upload(session, principal, bodies[1], store)
        assert exhausted.value.code == "attachment_quota_exceeded"
        with Session(postgres_engine) as session:
            rows = list(
                session.scalars(select(Attachment).where(Attachment.created_by == owner_id))
            )
            assert len(rows) == 1 and rows[0].id == bodies[0].attachment_id
            assert rows[0].status == "pending"
            assert (
                session.scalar(
                    select(func.count())
                    .select_from(UploadTicket)
                    .where(UploadTicket.created_by == owner_id)
                )
                == 1
            )
    finally:
        with Session(postgres_engine) as session, session.begin():
            session.execute(delete(UploadTicket).where(UploadTicket.created_by == owner_id))
            session.execute(delete(Attachment).where(Attachment.created_by == owner_id))
            sessions = select(UserSession.id).where(UserSession.user_id == owner_id)
            session.execute(delete(RefreshToken).where(RefreshToken.session_id.in_(sessions)))
            session.execute(delete(UserSession).where(UserSession.user_id == owner_id))
            session.execute(delete(BookMembership).where(BookMembership.user_id == owner_id))
            session.execute(delete(SyncScope).where(SyncScope.owner_user_id == owner_id))
            session.execute(delete(Book).where(Book.owner_user_id == owner_id))
            session.execute(delete(User).where(User.id == owner_id))


def test_gc_reads_changed_retention_and_preserves_real_refs_holds_and_originals(runtime_case):
    case = runtime_case
    actor, content = case.actor(), image_bytes()
    identities = [UUID(case.ready(actor, content)[0]["attachment_id"]) for _ in range(4)]
    old, young, referenced, held = identities
    records = {identity: case.session.get(Attachment, identity) for identity in identities}
    for identity, days in ((old, 3), (young, 1), (referenced, 10), (held, 10)):
        records[identity].orphaned_at = now() - timedelta(days=days)
    bill_id = uuid4()
    payload = BillPayload.model_validate(
        {
            "bill_type": "expense",
            "money": {"currency": "CNY", "currency_scale": 2, "amount_minor": "100"},
            "business_date": "2026-10-23",
            "business_timezone": "Asia/Shanghai",
            "attachment_ids": [str(referenced)],
        }
    ).model_dump(mode="json")
    case.session.add(
        SyncEntity(
            id=bill_id,
            scope_id=actor.book_id,
            entity_type="bill",
            revision=1,
            deleted=False,
            payload=payload,
            balance_minor=None,
            created_at=now(),
            updated_at=now(),
        )
    )
    case.session.flush()
    # A persisted reference must protect an original even if orphan metadata is stale.
    case.session.add(AttachmentRef(bill_id=bill_id, attachment_id=referenced))
    hold_id = uuid4()
    hold_attachments(case.session, hold_id, [held], "backup")
    case.session.commit()
    case.policy(orphan_retention_days=7)
    first = collect(case.session.get_bind(), case.store)
    assert first == {"deleted": 0, "retained": 2, "failed": 0}
    case.policy(orphan_retention_days=2)
    second = collect(case.session.get_bind(), case.store)
    assert second == {"deleted": 1, "retained": 2, "failed": 0}
    case.session.expire_all()
    assert case.session.get(Attachment, old).status == "deleted"
    assert not case.store.object_path(records[old].storage_key).exists()
    assert not case.store.object_path(records[old].storage_key, thumbnail=True).exists()
    records[young].orphaned_at = now() - timedelta(days=3)
    case.session.commit()
    case.policy(orphan_retention_days=4)
    assert collect(case.session.get_bind(), case.store) == {
        "deleted": 0,
        "retained": 2,
        "failed": 0,
    }
    case.session.expire_all()
    for identity in (young, referenced, held):
        record = case.session.get(Attachment, identity)
        assert record.status == "ready"
        assert case.store.content(record.storage_key) == content
    assert case.session.get(AttachmentRef, (bill_id, referenced)) is not None
    assert case.session.get(AttachmentHold, (hold_id, held)) is not None
