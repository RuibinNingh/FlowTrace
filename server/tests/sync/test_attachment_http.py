import hashlib
import struct
import zlib
from uuid import UUID, uuid4

import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session

from flowtrace_server.attachments.models import Attachment, AttachmentRef
from flowtrace_server.sync.models import SyncEntity

from .helpers import expense, operation
from .test_http import body_for

pytestmark = pytest.mark.postgres


def image():
    def chunk(kind, data):
        return (
            struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
        )

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(b"\x00\x20\x40\x60"))
        + chunk(b"IEND", b"")
    )


def declare(client, actor, scope_id):
    content, identifier = image(), uuid4()
    headers = {"authorization": "Bearer " + actor.token}
    response = client.post(
        "/api/v1/attachments/uploads",
        headers=headers,
        json={
            "attachment_id": str(identifier),
            "scope_id": str(scope_id),
            "sha256": hashlib.sha256(content).hexdigest(),
            "size_bytes": len(content),
            "media_type": "image/png",
        },
    )
    assert response.status_code == 201, response.text
    return identifier, response.json()["upload_id"], content


def test_real_sync_bill_attachment_ready_update_delete_and_foreign_rejection(
    actors, postgres_engine, sync_http, tmp_path
):
    alice, bob, _ = actors
    sync_http.app.state.settings.data_directory = tmp_path
    headers = {"authorization": "Bearer " + alice.token}
    identifier, upload_id, content = declare(sync_http, alice, alice.book_id)
    create = operation(
        alice.book_id, "bill", expense(alice.book_id, attachment_ids=[str(identifier)])
    )
    pending = sync_http.post(
        "/api/v1/sync/push", headers=headers, json=body_for(postgres_engine, alice, [create])
    )
    assert pending.status_code == 409 and pending.json()["error"]["code"] == "attachment_not_ready"
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, UUID(create["entity_id"])) is None
    assert (
        sync_http.put(
            f"/api/v1/attachments/uploads/{upload_id}/content", headers=headers, content=content
        ).status_code
        == 200
    )
    assert (
        sync_http.post(
            f"/api/v1/attachments/uploads/{upload_id}/complete", headers=headers
        ).status_code
        == 200
    )
    ready = sync_http.post(
        "/api/v1/sync/push", headers=headers, json=body_for(postgres_engine, alice, [create])
    )
    assert ready.status_code == 200, ready.text
    bill_id = UUID(create["entity_id"])
    with Session(postgres_engine) as session:
        assert session.get(AttachmentRef, (bill_id, identifier)) is not None
        assert session.get(Attachment, identifier).orphaned_at is None
    foreign, _, _ = declare(sync_http, bob, bob.book_id)
    bad = operation(alice.book_id, "bill", expense(alice.book_id, attachment_ids=[str(foreign)]))
    denied = sync_http.post(
        "/api/v1/sync/push", headers=headers, json=body_for(postgres_engine, alice, [bad])
    )
    assert denied.status_code == 403
    assert "sha256" not in denied.text and str(foreign) not in denied.text
    clear = operation(
        alice.book_id,
        "bill",
        expense(alice.book_id, note="合成附件移除", attachment_ids=[]),
        identifier=bill_id,
        action="update",
        revision="1",
    )
    assert (
        sync_http.post(
            "/api/v1/sync/push", headers=headers, json=body_for(postgres_engine, alice, [clear])
        ).status_code
        == 200
    )
    with Session(postgres_engine) as session:
        assert session.get(AttachmentRef, (bill_id, identifier)) is None
        assert session.get(Attachment, identifier).orphaned_at is not None
    restore = operation(
        alice.book_id,
        "bill",
        expense(alice.book_id, attachment_ids=[str(identifier)]),
        identifier=bill_id,
        action="update",
        revision="2",
    )
    assert (
        sync_http.post(
            "/api/v1/sync/push", headers=headers, json=body_for(postgres_engine, alice, [restore])
        ).status_code
        == 200
    )
    remove = operation(alice.book_id, "bill", {}, identifier=bill_id, action="delete", revision="3")
    assert (
        sync_http.post(
            "/api/v1/sync/push", headers=headers, json=body_for(postgres_engine, alice, [remove])
        ).status_code
        == 200
    )
    with Session(postgres_engine) as session:
        assert (
            list(session.scalars(select(AttachmentRef).where(AttachmentRef.bill_id == bill_id)))
            == []
        )
        assert session.get(Attachment, identifier).orphaned_at is not None
        assert session.get(SyncEntity, bill_id).deleted is True
