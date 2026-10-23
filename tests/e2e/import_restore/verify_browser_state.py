"""Read-only independent checks of the synthetic browser-created ledger."""

import argparse
import hashlib
import json
from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID

from dotenv import dotenv_values
from flowtrace_server.attachments.models import Attachment, AttachmentRef
from flowtrace_server.config import Settings
from flowtrace_server.imports.models import ImportBatch
from flowtrace_server.persistence.database import build_engine
from flowtrace_server.persistence.testing import require_isolated_database
from flowtrace_server.sync.models import LedgerEntry, SyncEntity
from sqlalchemy import func, select
from sqlalchemy.orm import Session

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "phase", choices=("prepared", "native", "csv", "repeat", "undo")
    )
    parser.add_argument("--fixture", required=True, type=Path)
    args = parser.parse_args()
    fixture = json.loads(args.fixture.read_text("utf-8"))
    assert fixture["purpose"] == "flowtrace-data-tools-normal-browser-synthetic"
    env = dotenv_values(fixture["environment_file"])
    raw_url = env["FLOWTRACE_TEST_DATABASE_URL"]
    url = require_isolated_database(raw_url, env["FLOWTRACE_ENVIRONMENT"])
    assert (url.host, url.port, url.username) == ("127.0.0.1", 55432, "flowtrace_dev")
    engine = build_engine(
        Settings(_env_file=None, environment="test", database_url=raw_url)
    )
    targets = {key: UUID(value) for key, value in fixture["native_targets"].items()}
    user_id = UUID(fixture["user_id"])
    with Session(engine) as session:
        session.connection().exec_driver_sql("SET TRANSACTION READ ONLY")
        batches = list(
            session.scalars(
                select(ImportBatch)
                .where(
                    ImportBatch.user_id == user_id,
                    *(
                        [ImportBatch.source_namespace == fixture["native_namespace"]]
                        if fixture.get("case") == "remote_undo"
                        else [
                            ImportBatch.source_namespace.in_(
                                [
                                    fixture["native_namespace"],
                                    "qianji-public-template-v10",
                                ]
                            )
                        ]
                    ),
                )
                .order_by(ImportBatch.created_at, ImportBatch.id)
            )
        )
        image = session.scalar(
            select(Attachment).where(
                Attachment.created_by == user_id,
                Attachment.sha256 == fixture["image_sha256"],
                Attachment.scope_id
                == (user_id if args.phase == "prepared" else targets["book"]),
            )
        )
        assert image is not None and image.status == "ready"
        original = (
            Path(fixture["data_directory"])
            / "attachments/objects"
            / (image.storage_key + ".bin")
        )
        assert (
            hashlib.sha256(original.read_bytes()).hexdigest() == fixture["image_sha256"]
        )
        assert len(original.read_bytes()) == fixture["image_bytes"]
        refs = session.scalar(
            select(func.count())
            .select_from(AttachmentRef)
            .where(AttachmentRef.attachment_id == image.id)
        )
        if args.phase == "prepared":
            assert not batches
            assert session.get(SyncEntity, targets["book"]) is None
            assert session.get(SyncEntity, targets["cash"]) is None
            assert image.scope_id == user_id and refs == 0
            balance = None
        else:
            expected = 9650 if args.phase in {"csv", "repeat"} else 9900
            account = session.get(SyncEntity, targets["cash"])
            assert account is not None and not account.deleted
            assert account.scope_id == user_id and account.balance_minor == expected
            entries = session.scalar(
                select(func.sum(LedgerEntry.amount_minor)).where(
                    LedgerEntry.account_id == account.id
                )
            )
            assert 10000 + entries == expected
            expense = session.get(SyncEntity, targets["expense"])
            refund = session.get(SyncEntity, targets["refund"])
            assert expense.payload["money"]["amount_minor"] == "125"
            assert refund.payload["money"]["amount_minor"] == "25"
            allocation = refund.payload["allocations"][0]
            assert allocation["source_bill_id"] == str(expense.id)
            assert allocation["source_amount_minor"] == "25"
            assert allocation["receipt_amount_minor"] == "25"
            assert expense.payload["attachment_ids"] == [str(image.id)]
            assert image.scope_id == targets["book"] and refs == 1
            book = session.get(SyncEntity, targets["book"])
            assert book.payload["month_start_day"] == 15
            assert book.payload["display_mode"] == "year"
            assert book.payload["show_assets"] is True
            if args.phase in {"csv", "repeat", "undo"}:
                csv_rows = [
                    session.get(SyncEntity, UUID(value))
                    for value in fixture["csv_target_ids"]
                ]
                assert all(row is not None for row in csv_rows)
                assert all(row.deleted == (args.phase == "undo") for row in csv_rows)
                assert csv_rows[0].id != csv_rows[1].id
            expected_batches = {"native": 1, "csv": 2, "repeat": 3, "undo": 3}[
                args.phase
            ]
            assert len(batches) == expected_batches
            assert batches[0].status == "applied"
            assert (
                batches[1].status == ("undone" if args.phase == "undo" else "applied")
                if len(batches) > 1
                else True
            )
            balance = str(expected)
        result = {
            "run_id": fixture["run_id"],
            "phase": args.phase,
            "result": "passed",
            "verification": "independent_read_only_database_and_original_file",
            "balance_minor": balance,
            "batches": [
                {
                    "batch_id": str(batch.id),
                    "namespace": batch.source_namespace,
                    "status": batch.status,
                    "created_count": len(batch.result.get("created", [])),
                    "duplicate_count": len(batch.result.get("duplicates", [])),
                }
                for batch in batches
            ],
            "original_sha256": image.sha256,
            "original_bytes": image.size_bytes,
            "attachment_reference_count": refs,
        }
    engine.dispose()
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    target = Path(fixture["output_directory"]) / f"readback-{args.phase}-{stamp}.json"
    target.write_text(json.dumps(result, ensure_ascii=False, indent=2), "utf-8")
    print(
        json.dumps(
            {
                "phase": args.phase,
                "result": "passed",
                "receipt": str(target.relative_to(ROOT)),
            }
        )
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # noqa: BLE001 -- CLI redacts driver DSNs on all failures.
        raise SystemExit("readback_failed_" + type(error).__name__) from None
