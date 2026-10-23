import asyncio
import hashlib
import io
from uuid import UUID, uuid4

import pytest
from PIL import Image
from sqlalchemy import select
from sqlalchemy.orm import Session
from sync.helpers import actor, epoch, expense, operation, push, share

from flowtrace_server.attachments.models import Attachment, AttachmentRef
from flowtrace_server.attachments.schemas import UploadDeclaration
from flowtrace_server.attachments.service import (
    attachment_for_read,
    complete_record,
    declare_upload,
    upload_for_write,
)
from flowtrace_server.attachments.storage import AttachmentStore
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.imports.schemas import ImportRequest, UndoRequest
from flowtrace_server.imports.service import (
    apply_import,
    preview_import,
    preview_undo,
    target_ids,
    undo_import,
)
from flowtrace_server.sync.models import SyncEntity


def ready_image(engine, owner, directory, *, scope_id=None, original=None):
    if original is None:
        output = io.BytesIO()
        Image.new("RGB", (3, 2), "purple").save(output, format="PNG")
        original = output.getvalue()
    store = AttachmentStore(directory)
    identifier = uuid4()
    declaration = UploadDeclaration(
        attachment_id=identifier,
        scope_id=scope_id or owner.principal.user_id,
        sha256=hashlib.sha256(original).hexdigest(),
        size_bytes=len(original),
        media_type="image/png",
    )

    async def receive(upload_id):
        async def chunks():
            yield original

        return await store.receive(upload_id, chunks(), len(original), declaration.sha256)

    with Session(engine) as session:
        record, _ = declare_upload(session, owner.principal, declaration, store)
        original_ticket = record.upload_id
        staged = asyncio.run(receive(original_ticket))
        image = store.publish(staged, record.storage_key, record.media_type)
        record.status = "uploaded"
        complete_record(session, owner.principal, record, image.width, image.height)
        session.commit()
    return identifier, original_ticket, original, store


def new_book_request(engine, owner, uploaded):
    book_id, account_id, source_attachment = map(str, (uuid4(), uuid4(), uuid4()))
    body = ImportRequest.model_validate(
        {
            "batch_id": str(uuid4()),
            "client_id": str(owner.principal.client_id),
            "sync_epoch": epoch(engine),
            "document": {
                "format": "flowtrace-data-v1",
                "source_namespace": "images-" + uuid4().hex,
                "rows": [
                    {
                        "source_id": str(uuid4()),
                        "entity_type": "bill",
                        "scope_id": book_id,
                        "payload": expense(
                            book_id, account_id, "125", attachment_ids=[source_attachment]
                        ),
                    },
                    {
                        "source_id": account_id,
                        "entity_type": "account",
                        "scope_id": book_id,
                        "payload": {
                            "name": "合成现金",
                            "kind": "cash",
                            "include_in_net_assets": True,
                            "hidden": False,
                            "opening": {
                                "currency": "CNY",
                                "currency_scale": 2,
                                "amount_minor": "10000",
                            },
                        },
                    },
                    {
                        "source_id": book_id,
                        "entity_type": "book",
                        "scope_id": str(owner.principal.user_id),
                        "payload": {
                            "name": "含图迁移",
                            "currency": "CNY",
                            "timezone": "Asia/Shanghai",
                            "month_start_day": 15,
                            "display_mode": "year",
                        },
                    },
                ],
            },
            "resource_mapping": {source_attachment: str(uploaded)},
            "attachment_transfers": {str(uploaded): book_id},
        }
    )
    return body, book_id, account_id


@pytest.mark.postgres
def test_private_upload_moves_atomically_preview_rolls_back_and_undo_restores_orphan(
    postgres_engine, tmp_path
):
    owner = actor(postgres_engine)
    uploaded, ticket, original, store = ready_image(postgres_engine, owner, tmp_path / "files")
    body, source_book, source_account = new_book_request(postgres_engine, owner, uploaded)
    mapped = target_ids(owner.principal, body)
    with Session(postgres_engine) as session:
        preview = preview_import(session, owner.principal, body)
        assert preview["can_apply"]
        record = session.get(Attachment, uploaded)
        assert record.scope_id == owner.principal.user_id and record.upload_id == ticket
        assert session.get(SyncEntity, UUID(mapped[source_book])) is None
        assert upload_for_write(session, owner.principal, ticket).id == uploaded
        session.rollback()
        result = apply_import(session, owner.principal, body)
        assert len(result["attachment_transfers"]) == 1
        record = session.get(Attachment, uploaded)
        assert record.scope_id == UUID(mapped[source_book])
        assert session.get(SyncEntity, UUID(mapped[source_account])).balance_minor == 9875
        assert store.content(record.storage_key) == original
        assert attachment_for_read(session, owner.principal, uploaded).id == uploaded
        with pytest.raises(ApiError) as error:
            upload_for_write(session, owner.principal, ticket)
        assert error.value.code == "upload_expired"
        session.rollback()
        undo_import(
            session,
            owner.principal,
            UUID(body.batch_id),
            UndoRequest(client_id=body.client_id, sync_epoch=body.sync_epoch),
        )
        record = session.get(Attachment, uploaded)
        assert record.scope_id == owner.principal.user_id
        assert not list(
            session.scalars(select(AttachmentRef).where(AttachmentRef.attachment_id == uploaded))
        )
        assert store.content(record.storage_key) == original


@pytest.mark.postgres
def test_precommit_failure_retains_original_private_orphan_and_ticket(postgres_engine, tmp_path):
    owner = actor(postgres_engine)
    uploaded, ticket, original, store = ready_image(postgres_engine, owner, tmp_path / "files")
    body, source_book, _ = new_book_request(postgres_engine, owner, uploaded)

    def fail(_):
        raise RuntimeError("synthetic_before_commit")

    with Session(postgres_engine) as session, pytest.raises(RuntimeError):
        apply_import(session, owner.principal, body, before_commit=fail)
    with Session(postgres_engine) as session:
        record = session.get(Attachment, uploaded)
        assert record.scope_id == owner.principal.user_id and record.upload_id == ticket
        assert store.content(record.storage_key) == original
        assert session.get(SyncEntity, UUID(target_ids(owner.principal, body)[source_book])) is None


@pytest.mark.postgres
def test_foreign_upload_and_later_authorized_reference_or_share_block_undo(
    postgres_engine, tmp_path
):
    owner, stranger = actor(postgres_engine), actor(postgres_engine)
    uploaded, _, _, _ = ready_image(postgres_engine, stranger, tmp_path / "foreign")
    body, _, _ = new_book_request(postgres_engine, owner, uploaded)
    with Session(postgres_engine) as session:
        preview = preview_import(session, owner.principal, body)
        assert not preview["can_apply"]
        assert preview["errors"] == [
            {
                "row": 1,
                "field": "payload.attachment_ids",
                "code": "import_attachment_transfer_conflict",
            }
        ]
    with Session(postgres_engine) as session, pytest.raises(ApiError) as error:
        apply_import(session, owner.principal, body)
    assert error.value.code == "import_attachment_transfer_conflict"
    uploaded, _, _, _ = ready_image(postgres_engine, owner, tmp_path / "owned")
    body, source_book, source_account = new_book_request(postgres_engine, owner, uploaded)
    with Session(postgres_engine) as session:
        apply_import(session, owner.principal, body)
    mapped = target_ids(owner.principal, body)
    # A later bill is a legitimate use outside the batch; undo must preserve it.
    assert (
        push(
            postgres_engine,
            owner,
            operation(
                mapped[source_book],
                "bill",
                expense(
                    mapped[source_book],
                    mapped[source_account],
                    "25",
                    attachment_ids=[str(uploaded)],
                ),
            ),
        )[0]["status"]
        == "applied"
    )
    with Session(postgres_engine) as session, pytest.raises(ApiError) as error:
        undo_import(
            session,
            owner.principal,
            UUID(body.batch_id),
            UndoRequest(client_id=body.client_id, sync_epoch=body.sync_epoch),
        )
    assert error.value.code == "import_undo_conflict"

    # Permission changes alone also forbid recalling images from a shared book.
    second, _, _, _ = ready_image(postgres_engine, owner, tmp_path / "second")
    second_body, second_book, _ = new_book_request(postgres_engine, owner, second)
    with Session(postgres_engine) as session:
        apply_import(session, owner.principal, second_body)
    from dataclasses import replace

    shared_owner = replace(
        owner, book_id=UUID(target_ids(owner.principal, second_body)[second_book])
    )
    share(postgres_engine, shared_owner, stranger)
    with Session(postgres_engine) as session:
        preview = preview_undo(session, owner.principal, UUID(second_body.batch_id))
        # The explicit preview must agree with the protected write.
        assert not preview["can_undo"]
