import asyncio
import hashlib
import secrets
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import delete, func, select, text
from sqlalchemy.orm import Session
from test_attachment_storage import chunks, image_bytes
from test_identity import bearer, invite, login_admin, register_user
from test_identity import identity as _identity

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.attachments.gc import claim, collect
from flowtrace_server.attachments.models import (
    Attachment,
    AttachmentHold,
    AttachmentRef,
    UploadTicket,
)
from flowtrace_server.attachments.service import (
    hold_attachments,
    reconcile_bill_attachments,
    release_hold,
)
from flowtrace_server.attachments.storage import AttachmentStore
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import RefreshToken, User, UserSession
from flowtrace_server.auth.service import (
    assert_active_principal,
    authenticate_access,
    create_user,
    issue_session,
    now,
)
from flowtrace_server.books.models import Book, BookMembership, SyncScope
from flowtrace_server.books.permissions import authorize_scope
from flowtrace_server.diagnostics import configure_logging
from flowtrace_server.diagnostics.policy import bind_diagnostics
from flowtrace_server.diagnostics.store import DiagnosticStore
from flowtrace_server.sync.models import SyncChange, SyncEntity
from flowtrace_server.sync.schemas import BillPayload

identity_fixture = _identity
pytestmark = pytest.mark.postgres


@pytest.fixture
def images(identity_fixture, tmp_path):
    client, connection, admin_id = identity_fixture
    client.app.state.settings.data_directory = tmp_path
    policy = configure_logging("INFO", tmp_path / "diagnostics", runtime_reader=lambda: True)
    client.app.state.diagnostic_policy = policy
    csrf = login_admin(client)
    alice = register_user(client, invite(client, csrf), "alice")
    book_id = client.get("/api/v1/books", headers=bearer(alice)).json()["items"][0]["id"]
    with bind_diagnostics(policy):
        yield client, connection, alice, book_id, csrf, AttachmentStore(tmp_path / "attachments")
    policy.close()
    configure_logging("INFO")


def declare(client, alice, book_id, content, media_type="image/png"):
    identity = uuid4()
    response = client.post(
        "/api/v1/attachments/uploads",
        headers=bearer(alice),
        json={
            "attachment_id": str(identity),
            "scope_id": book_id,
            "sha256": hashlib.sha256(content).hexdigest(),
            "size_bytes": len(content),
            "media_type": media_type,
        },
    )
    assert response.status_code == 201, response.text
    return identity, response.json()["upload_id"]


def upload(client, alice, book_id):
    content = image_bytes()
    identity, upload_id = declare(client, alice, book_id, content)
    received = client.put(
        f"/api/v1/attachments/uploads/{upload_id}/content", headers=bearer(alice), content=content
    )
    assert received.status_code == 200, received.text
    completed = client.post(
        f"/api/v1/attachments/uploads/{upload_id}/complete", headers=bearer(alice)
    )
    assert completed.status_code == 200, completed.text
    return identity, upload_id, content


def synthetic_bill(session, scope_id):
    identity = uuid4()
    payload = BillPayload.model_validate(
        {
            "bill_type": "expense",
            "money": {"currency": "CNY", "currency_scale": 2, "amount_minor": "100"},
            "business_date": "2026-10-21",
            "business_timezone": "Asia/Shanghai",
            "attachment_ids": [],
        }
    ).model_dump(mode="json")
    record = SyncEntity(
        id=identity,
        scope_id=UUID(scope_id),
        entity_type="bill",
        revision=1,
        deleted=False,
        payload=payload,
        balance_minor=None,
        created_at=now(),
        updated_at=now(),
    )
    session.add(record)
    session.flush()
    return identity


def test_real_upload_complete_replay_hash_and_download_security(images):
    client, connection, alice, book_id, _, store = images
    identity, upload_id, content = upload(client, alice, book_id)
    replay = client.post(f"/api/v1/attachments/uploads/{upload_id}/complete", headers=bearer(alice))
    assert replay.status_code == 200
    original = client.get(f"/api/v1/attachments/{identity}/content", headers=bearer(alice))
    assert original.content == content
    assert original.headers["x-content-type-options"] == "nosniff"
    assert "private,no-store" in original.headers["cache-control"]
    assert (
        client.get(f"/api/v1/attachments/{identity}/thumbnail", headers=bearer(alice)).headers[
            "content-type"
        ]
        == "image/webp"
    )
    changed = bytes([content[0] ^ 1]) + content[1:]
    rejected = client.put(
        f"/api/v1/attachments/uploads/{upload_id}/content", content=changed, headers=bearer(alice)
    )
    assert rejected.status_code == 409
    assert (
        client.get(f"/api/v1/attachments/{identity}/content", headers=bearer(alice)).content
        == content
    )
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert (
            session.scalar(
                select(func.count())
                .select_from(AdminAudit)
                .where(AdminAudit.action == "attachment.complete", AdminAudit.target_id == identity)
            )
            == 1
        )
    assert list(store.staging.iterdir()) == []


def test_unfinished_wrong_format_expired_uploads_never_become_ready(images):
    client, connection, alice, book_id, _, store = images
    identity, upload_id = declare(client, alice, book_id, image_bytes(), "image/jpeg")
    assert client.get(f"/api/v1/attachments/{identity}", headers=bearer(alice)).status_code == 409
    assert (
        client.put(
            f"/api/v1/attachments/uploads/{upload_id}/content",
            content=image_bytes(),
            headers=bearer(alice),
        ).status_code
        == 415
    )
    assert (
        client.post(
            f"/api/v1/attachments/uploads/{upload_id}/complete", headers=bearer(alice)
        ).status_code
        == 409
    )
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        session.get(Attachment, identity).upload_expires_at = now() - timedelta(seconds=1)
        session.commit()
    assert (
        client.put(
            f"/api/v1/attachments/uploads/{upload_id}/content",
            content=image_bytes(),
            headers=bearer(alice),
        ).status_code
        == 410
    )
    assert list(store.objects.iterdir()) == []


def test_private_and_revoked_shared_permissions_cover_metadata_original_thumbnail(images):
    client, _, alice, book_id, csrf, _ = images
    identity, _, _ = upload(client, alice, book_id)
    bob = register_user(client, invite(client, csrf), "bob")
    paths = [f"/api/v1/attachments/{identity}{suffix}" for suffix in ("", "/content", "/thumbnail")]
    for path in paths:
        assert client.get(path, headers=bearer(bob)).status_code == 403
        assert client.get(path).status_code == 401
    token = client.post(
        f"/api/v1/books/{book_id}/invites", json={"role": "viewer"}, headers=bearer(alice)
    ).json()["token"]
    assert (
        client.post("/api/v1/books/join", json={"token": token}, headers=bearer(bob)).status_code
        == 200
    )
    for path in paths:
        assert client.get(path, headers=bearer(bob)).status_code == 200
    assert (
        client.post(
            "/api/v1/attachments/uploads",
            json={
                "attachment_id": str(uuid4()),
                "scope_id": book_id,
                "sha256": "0" * 64,
                "size_bytes": 3,
                "media_type": "image/png",
            },
            headers=bearer(bob),
        ).status_code
        == 403
    )
    assert (
        client.delete(
            f"/api/v1/books/{book_id}/members/{bob['user_id']}", headers=bearer(alice)
        ).status_code
        == 204
    )
    for path in paths:
        assert client.get(path, headers=bearer(bob)).status_code == 403


def test_reference_gc_and_backup_holds_share_database_boundary(images):
    client, connection, alice, book_id, _, store = images
    identity, _, _ = upload(client, alice, book_id)
    hold_id = uuid4()
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        principal = authenticate_access(session, alice["access_token"])
        authorize_scope(session, principal, UUID(book_id), write=True, lock=True)
        bill_id = synthetic_bill(session, book_id)
        reconcile_bill_attachments(session, principal, bill_id, UUID(book_id), [], [identity])
        session.get(Attachment, identity).orphaned_at = now() - timedelta(days=8)
        key = session.get(Attachment, identity).storage_key
        session.commit()
    assert collect(connection, store)["retained"] == 1
    assert store.object_path(key).exists()
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        principal = authenticate_access(session, alice["access_token"])
        authorize_scope(session, principal, UUID(book_id), write=True, lock=True)
        reconcile_bill_attachments(session, principal, bill_id, UUID(book_id), [identity], [])
        session.get(Attachment, identity).orphaned_at = now() - timedelta(days=8)
        hold_attachments(session, hold_id, [identity], "backup")
        session.commit()
    assert collect(connection, store)["retained"] == 1
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        release_hold(session, hold_id)
        session.commit()
    assert collect(connection, store)["deleted"] == 1
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert session.get(Attachment, identity).status == "deleted"
    assert list(store.objects.iterdir()) == []


def test_gc_claim_crash_is_resumable_and_rejects_new_reference(images):
    client, connection, alice, book_id, _, store = images
    identity, _, _ = upload(client, alice, book_id)
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        session.get(Attachment, identity).orphaned_at = now() - timedelta(days=8)
        assert claim(session, identity).status == "deleting"
        session.commit()
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        principal = authenticate_access(session, alice["access_token"])
        authorize_scope(session, principal, UUID(book_id), write=True, lock=True)
        bill_id = synthetic_bill(session, book_id)
        with pytest.raises(ApiError) as rejected:
            reconcile_bill_attachments(session, principal, bill_id, UUID(book_id), [], [identity])
        assert rejected.value.code == "attachment_not_ready"
    assert collect(connection, store)["deleted"] == 1


def test_diagnostic_failure_does_not_reject_committed_registration(images, monkeypatch):
    client, connection, _, _, csrf, _ = images
    token = invite(client, csrf)
    monkeypatch.setattr(DiagnosticStore, "append", lambda *_args, **_kwargs: False)
    bob = register_user(client, token, "bob")
    assert client.get("/api/v1/users/me", headers=bearer(bob)).status_code == 200


def test_formal_audit_failure_rolls_back_attachment_completion(images, monkeypatch):
    client, connection, alice, book_id, _, _ = images
    content = image_bytes()
    identity, upload_id = declare(client, alice, book_id, content)
    assert (
        client.put(
            f"/api/v1/attachments/uploads/{upload_id}/content",
            headers=bearer(alice),
            content=content,
        ).status_code
        == 200
    )

    def fail(*args, **kwargs):
        raise RuntimeError("SENSITIVE_AUDIT_FAILURE")

    monkeypatch.setattr("flowtrace_server.attachments.service.audit", fail)
    response = client.post(
        f"/api/v1/attachments/uploads/{upload_id}/complete", headers=bearer(alice)
    )
    assert response.status_code == 500 and "SENSITIVE" not in response.text
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert session.get(Attachment, identity).status == "uploaded"


def test_diagnostic_export_requires_admin_and_only_exports_projected_metadata(images):
    client, _, alice, _, _, _ = images
    response = client.get("/admin/diagnostics/export")
    assert response.status_code == 200 and b'"sanitized":true' in response.content
    assert b"Fixture-only-password" not in response.content
    assert alice["access_token"].encode() not in response.content
    client.cookies.clear()
    assert client.get("/admin/diagnostics/export", follow_redirects=False).status_code == 303


def test_reference_commit_wins_real_concurrent_gc_scope_lock(postgres_engine, tmp_path):
    store = AttachmentStore(tmp_path / "private")
    content, identity = image_bytes(), uuid4()
    checksum, key = hashlib.sha256(content).hexdigest(), secrets.token_hex(32)
    staged = asyncio.run(store.receive(uuid4(), chunks(content), len(content), checksum))
    store.publish(staged, key, "image/png")
    with Session(postgres_engine, expire_on_commit=False) as session:
        user = create_user(session, "gc_race_" + uuid4().hex, "Synthetic-race-password-2026")
        user_id = user.id
        book_id = session.scalar(select(Book.id).where(Book.owner_user_id == user.id))
        _, tokens = issue_session(session, user, uuid4(), "Synthetic GC race", "api_native")
        record = Attachment(
            id=identity,
            upload_id=uuid4(),
            scope_id=book_id,
            created_by=user.id,
            sha256=checksum,
            size_bytes=len(content),
            media_type="image/png",
            storage_key=key,
            status="ready",
            created_at=now(),
            upload_expires_at=now() + timedelta(hours=24),
            ready_at=now(),
            orphaned_at=now() - timedelta(days=8),
            width=12,
            height=8,
        )
        session.add(record)
        bill_id = synthetic_bill(session, str(book_id))
        session.commit()
    acquired, allow_commit = threading.Event(), threading.Event()
    application = "flowtrace_gc_race_" + uuid4().hex

    def reference_writer():
        with Session(postgres_engine) as session:
            principal = authenticate_access(session, tokens["access_token"])
            assert_active_principal(session, principal)
            authorize_scope(session, principal, book_id, write=True, lock=True)
            acquired.set()
            if not allow_commit.wait(5):
                raise TimeoutError("synthetic_race_timeout")
            reconcile_bill_attachments(session, principal, bill_id, book_id, [], [identity])
            session.commit()

    def collector():
        with Session(postgres_engine) as session:
            session.execute(
                text("SELECT set_config('application_name',:name,true)"), {"name": application}
            )
            result = claim(session, identity)
            session.commit()
            return result

    try:
        with ThreadPoolExecutor(max_workers=2) as executor:
            writer = executor.submit(reference_writer)
            assert acquired.wait(5)
            cleanup = executor.submit(collector)
            waiting = False
            for _ in range(100):
                with postgres_engine.connect() as observer:
                    waiting = observer.execute(
                        text(
                            "SELECT EXISTS(SELECT 1 FROM pg_stat_activity "
                            "WHERE application_name=:name AND wait_event_type='Lock')"
                        ),
                        {"name": application},
                    ).scalar_one()
                if waiting:
                    break
                time.sleep(0.02)
            allow_commit.set()
            writer.result(timeout=5)
            assert waiting, "The collector must actually wait on the writer's scope lock"
            assert cleanup.result(timeout=5) is None
        with Session(postgres_engine) as session:
            assert session.get(Attachment, identity).status == "ready"
        assert store.object_path(key).exists()
    finally:
        allow_commit.set()
        with Session(postgres_engine) as session:
            session.execute(delete(AttachmentRef).where(AttachmentRef.attachment_id == identity))
            session.execute(delete(Attachment).where(Attachment.id == identity))
            session_ids = select(UserSession.id).where(UserSession.user_id == user_id)
            session.execute(delete(RefreshToken).where(RefreshToken.session_id.in_(session_ids)))
            session.execute(delete(UserSession).where(UserSession.user_id == user_id))
            session.execute(delete(SyncChange).where(SyncChange.scope_id.in_([user_id, book_id])))
            session.execute(delete(SyncEntity).where(SyncEntity.scope_id.in_([user_id, book_id])))
            session.execute(delete(BookMembership).where(BookMembership.book_id == book_id))
            session.execute(delete(SyncScope).where(SyncScope.id.in_([user_id, book_id])))
            session.execute(delete(Book).where(Book.id == book_id))
            session.execute(delete(User).where(User.id == user_id))
            session.commit()


def test_redeclaration_renews_exact_content_and_old_ticket_stays_expired(images):
    client, connection, alice, book_id, _, store = images
    content = image_bytes()
    identity, old_upload_id = declare(client, alice, book_id, content)
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        record = session.get(Attachment, identity)
        record.upload_expires_at = now() - timedelta(seconds=1)
        session.commit()
    url = f"/api/v1/attachments/uploads/{old_upload_id}/content"
    assert client.put(url, content=content, headers=bearer(alice)).status_code == 410
    response = client.post(
        "/api/v1/attachments/uploads",
        headers=bearer(alice),
        json={
            "attachment_id": str(identity),
            "scope_id": book_id,
            "sha256": hashlib.sha256(content).hexdigest(),
            "size_bytes": len(content),
            "media_type": "image/png",
        },
    )
    assert response.status_code == 201
    new_id = response.json()["upload_id"]
    assert new_id != old_upload_id
    assert client.put(url, content=content, headers=bearer(alice)).status_code == 410
    assert (
        client.put(
            f"/api/v1/attachments/uploads/{new_id}/content", content=content, headers=bearer(alice)
        ).status_code
        == 200
    )
    assert (
        client.post(
            f"/api/v1/attachments/uploads/{new_id}/complete", headers=bearer(alice)
        ).status_code
        == 200
    )
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert (
            session.scalar(
                select(func.count())
                .select_from(UploadTicket)
                .where(UploadTicket.attachment_id == identity)
            )
            == 2
        )
    assert list(store.staging.iterdir()) == []


def test_redeclaring_ready_keeps_formal_refs_and_backup_holds(images):
    client, connection, alice, book_id, _, _ = images
    identity, old_id, content = upload(client, alice, book_id)
    hold = uuid4()
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        principal = authenticate_access(session, alice["access_token"])
        authorize_scope(session, principal, UUID(book_id), write=True, lock=True)
        bill_id = synthetic_bill(session, book_id)
        reconcile_bill_attachments(session, principal, bill_id, UUID(book_id), [], [identity])
        hold_attachments(session, hold, [identity], "backup")
        session.get(Attachment, identity).upload_expires_at = now() - timedelta(seconds=1)
        session.commit()
    response = client.post(
        "/api/v1/attachments/uploads",
        headers=bearer(alice),
        json={
            "attachment_id": str(identity),
            "scope_id": book_id,
            "sha256": hashlib.sha256(content).hexdigest(),
            "size_bytes": len(content),
            "media_type": "image/png",
        },
    )
    assert response.status_code == 201 and response.json()["status"] == "ready"
    assert (
        client.post(
            f"/api/v1/attachments/uploads/{old_id}/complete", headers=bearer(alice)
        ).status_code
        == 410
    )
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert session.get(AttachmentRef, (bill_id, identity)) is not None
        assert session.get(AttachmentHold, (hold, identity)) is not None


def test_deleted_blob_redeclaration_requires_same_owner_scope_and_content(images):
    client, connection, alice, book_id, csrf, store = images
    identity, old_id, content = upload(client, alice, book_id)
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        session.get(Attachment, identity).orphaned_at = now() - timedelta(days=8)
        session.commit()
    assert collect(connection, store)["deleted"] == 1
    bob = register_user(client, invite(client, csrf), "bob")
    bob_book = client.get("/api/v1/books", headers=bearer(bob)).json()["items"][0]["id"]
    body = {
        "attachment_id": str(identity),
        "scope_id": book_id,
        "sha256": hashlib.sha256(content).hexdigest(),
        "size_bytes": len(content),
        "media_type": "image/png",
    }
    assert (
        client.post(
            "/api/v1/attachments/uploads", headers=bearer(bob), json={**body, "scope_id": bob_book}
        ).status_code
        == 409
    )
    assert (
        client.post(
            "/api/v1/attachments/uploads", headers=bearer(alice), json={**body, "sha256": "0" * 64}
        ).status_code
        == 409
    )
    renewed = client.post("/api/v1/attachments/uploads", headers=bearer(alice), json=body)
    assert renewed.status_code == 201 and renewed.json()["status"] == "pending"
    assert (
        client.put(
            f"/api/v1/attachments/uploads/{old_id}/content", content=content, headers=bearer(alice)
        ).status_code
        == 410
    )
