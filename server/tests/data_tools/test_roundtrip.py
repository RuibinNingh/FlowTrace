"""Export a real authorized graph, then import it into a different empty database."""

import hashlib
import os
from uuid import UUID, uuid4

import pytest
from alembic import command
from sqlalchemy import select
from sqlalchemy.engine import make_url
from sqlalchemy.orm import Session
from sync.helpers import account, actor, epoch, expense, operation, push

from flowtrace_server.attachments.models import Attachment, AttachmentRef
from flowtrace_server.books.models import Book
from flowtrace_server.config import Settings
from flowtrace_server.exports.schemas import ExportRequest
from flowtrace_server.exports.service import export_document, json_bytes, xlsx_bytes
from flowtrace_server.imports.parsers import parse_json, parse_xlsx
from flowtrace_server.imports.schemas import ImportRequest
from flowtrace_server.imports.service import apply_import, preview_import, target_ids
from flowtrace_server.persistence.database import build_engine, migration_config
from flowtrace_server.persistence.testing import require_isolated_database
from flowtrace_server.sync.models import LedgerEntry, SyncEntity

from .test_import_attachments import ready_image


@pytest.fixture(scope="module")
def migration_engine():
    target = os.environ.get("FLOWTRACE_MIGRATION_TEST_DATABASE_URL")
    if not target:
        pytest.skip("fresh isolated migration destination not configured")
    url = require_isolated_database(target, "test")
    assert url.host == "127.0.0.1" and url.port == 55432
    assert url.database.startswith("flowtrace_test_p5_migration_")
    assert url.database != make_url(os.environ["FLOWTRACE_TEST_DATABASE_URL"]).database
    engine = build_engine(Settings(_env_file=None, environment="test", database_url=target))
    with engine.begin() as connection:
        config = migration_config()
        config.attributes["connection"] = connection
        command.upgrade(config, "head")
    yield engine
    engine.dispose()


@pytest.mark.postgres
@pytest.mark.parametrize("format_name", ["json", "xlsx"])
def test_new_database_roundtrip_money_receipts_settings_and_original_image(
    postgres_engine, migration_engine, tmp_path, format_name
):
    source = actor(postgres_engine)
    cash = account(postgres_engine, source, opening="10000")
    original_id, _, original, source_store = ready_image(
        postgres_engine, source, tmp_path / "src", scope_id=source.book_id
    )
    with Session(postgres_engine) as session:
        book_entity = session.get(SyncEntity, source.book_id)
        settings = {
            **book_entity.payload,
            "month_start_day": 15,
            "display_mode": "year",
            "template": "travel",
            "show_assets": True,
        }
    updated_book = operation(
        source.book_id, "book", settings, identifier=source.book_id, action="update", revision="1"
    )
    expense_command = operation(
        source.book_id,
        "bill",
        expense(
            source.book_id,
            cash,
            "125",
            attachment_ids=[str(original_id)],
            reimbursement_tracking=True,
            business_date="2026-10-22",
        ),
    )
    refund_command = operation(
        source.book_id,
        "bill",
        expense(
            source.book_id,
            cash,
            "25",
            bill_type="refund",
            business_date="2026-10-21",
            allocations=[
                {
                    "source_bill_id": expense_command["entity_id"],
                    "source_amount_minor": "25",
                    "receipt_amount_minor": "25",
                }
            ],
        ),
    )
    assert all(
        result["status"] == "applied"
        for result in push(postgres_engine, source, [updated_book, expense_command, refund_command])
    )
    with Session(postgres_engine) as session:
        exported = export_document(
            session,
            source.principal,
            ExportRequest(scope_ids=[str(source.principal.user_id), str(source.book_id)]),
        )
        attachment = session.get(Attachment, original_id)
        copied_bytes = source_store.content(attachment.storage_key)
        assert hashlib.sha256(copied_bytes).hexdigest() == exported["attachments"][0]["sha256"]
    if format_name == "json":
        document = parse_json(json_bytes(exported))
    else:
        parsed = parse_xlsx(xlsx_bytes(exported), "flowtrace-export")
        assert not parsed.errors
        document = parsed.document
    destination = actor(migration_engine)
    uploaded, _, copied, destination_store = ready_image(
        migration_engine, destination, tmp_path / "dst", original=copied_bytes
    )
    body = ImportRequest(
        batch_id=str(uuid4()),
        client_id=str(destination.principal.client_id),
        sync_epoch=epoch(migration_engine),
        document=document,
        scope_mapping={str(source.principal.user_id): str(destination.principal.user_id)},
        resource_mapping={str(original_id): str(uploaded)},
        attachment_transfers={str(uploaded): str(source.book_id)},
    )
    with Session(migration_engine) as session:
        assert preview_import(session, destination.principal, body)["can_apply"]
        result = apply_import(session, destination.principal, body)
        mapped = target_ids(destination.principal, body)
        account_entity = session.get(SyncEntity, UUID(mapped[str(cash)]))
        book = session.get(Book, UUID(mapped[str(source.book_id)]))
        book_entity = session.get(SyncEntity, book.id)
        assert account_entity.balance_minor == 9900
        assert book.month_start_day == 15
        assert book_entity.payload["display_mode"] == "year"
        assert book_entity.payload["template"] == "travel"
        assert book_entity.payload["show_assets"]
        restored_refund = session.get(SyncEntity, UUID(mapped[refund_command["entity_id"]]))
        assert (
            restored_refund.payload["allocations"][0]["source_bill_id"]
            == (mapped[expense_command["entity_id"]])
        )
        restored_source = session.get(SyncEntity, UUID(mapped[expense_command["entity_id"]]))
        assert restored_source.payload["reimbursement_tracking"] is True
        references = list(
            session.scalars(
                select(AttachmentRef).where(AttachmentRef.bill_id == restored_source.id)
            )
        )
        assert len(references) == 1 and references[0].attachment_id == uploaded
        record = session.get(Attachment, uploaded)
        assert destination_store.content(record.storage_key) == original == copied
        entries = list(
            session.scalars(
                select(LedgerEntry.amount_minor)
                .where(LedgerEntry.account_id == account_entity.id)
                .order_by(LedgerEntry.amount_minor)
            )
        )
        assert entries == [-125, 25]
        assert len(result["created"]) == len(document.rows)
        assert apply_import(session, destination.principal, body)["replayed"]
