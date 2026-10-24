"""Real PostgreSQL/HTTP publication, refund links, replay, deduplication and undo."""

import hashlib
from uuid import uuid4, uuid5

import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session
from sync.helpers import account, actor, epoch

from flowtrace_server.imports.qianji_export import EXPORT_NAMESPACE, source_identifier
from flowtrace_server.sync.models import LedgerEntry, SyncEntity

from .test_qianji_export import content, record
from .test_staging_http import PREFIX, headers, post, run, status, upload_seal
from .test_staging_http import stage_http as stage_http

pytestmark = pytest.mark.postgres


def test_105_export_rows_refunds_atomic_replay_reordered_dedupe_and_undo(
    stage_http, postgres_engine
):
    owner = actor(postgres_engine)
    cash = account(postgres_engine, owner, opening="100000")
    original = record("original", 金额="10.00", 账户1="合成现金")
    rows = (
        [
            record(f"refund-{i}", 类型="退款", 金额="1.00", 关联账单="original", 账户1="合成现金")
            for i in range(3)
        ]
        + [record("income", 类型="收入", 金额="200.00", 账户1="合成现金")]
        + [record(f"expense-{i}", 金额="1.00", 账户1="合成现金") for i in range(100)]
        + [original]
    )
    assert len(rows) == 105
    stage_http.stage_owners.append(owner.principal.user_id)

    def prepared(records):
        raw = content(records, false_dimension=True)
        body = {
            "stage_id": str(uuid4()),
            "client_id": str(owner.principal.client_id),
            "sync_epoch": epoch(postgres_engine),
            "format": "qianji_xlsx",
            "expected_bytes": len(raw),
            "source_sha256": hashlib.sha256(raw).hexdigest(),
            "mapping": {
                "template_mapping": {
                    "scope_id": str(owner.book_id),
                    "timezone": "Asia/Shanghai",
                    "account_names": {"合成现金": str(cash)},
                }
            },
        }
        response = stage_http.post(PREFIX, headers=headers(owner), json=body)
        assert response.status_code == 200, response.text
        stage = response.json()
        parsed = upload_seal(stage_http, owner, stage, body, raw)
        run(stage_http, postgres_engine, parsed["job_id"])
        assert status(stage_http, owner, stage)["row_count"] == 105
        assert status(stage_http, owner, stage)["error_count"] == 0
        preview = post(stage_http, owner, stage, "preview", {"stage_version": 1})
        assert preview.status_code == 200, preview.text
        run(stage_http, postgres_engine, preview.json()["job_id"])
        current = status(stage_http, owner, stage)
        assert current["status"] == "ready", current
        return stage, {
            "stage_version": 1,
            "batch_id": stage["batch_id"],
            "preview_hash": current["preview_hash"],
        }

    stage, apply = prepared(rows)
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, cash).balance_minor == 100000
    page = stage_http.get(
        PREFIX + f"/{stage['stage_id']}/rows",
        headers=headers(owner),
        params={"stage_version": 1, "include_diagnostics": "true"},
    )
    assert page.status_code == 200 and len(page.json()["rows"]) == 100
    assert page.json()["request_id"] == page.headers["x-request-id"]
    assert page.json()["has_more"]
    legacy = stage_http.get(
        PREFIX + f"/{stage['stage_id']}/rows", headers=headers(owner), params={"stage_version": 1}
    )
    assert "request_id" not in legacy.json()
    queued = post(stage_http, owner, stage, "apply", apply)
    assert queued.status_code == 200, queued.text
    assert post(stage_http, owner, stage, "apply", apply).json() == queued.json()
    run(stage_http, postgres_engine, queued.json()["job_id"])
    assert status(stage_http, owner, stage)["status"] == "applied"
    target = uuid5(owner.principal.user_id, EXPORT_NAMESPACE + ":" + source_identifier("original"))
    with Session(postgres_engine) as session:
        bills = list(
            session.scalars(
                select(SyncEntity).where(
                    SyncEntity.scope_id == owner.book_id,
                    SyncEntity.entity_type == "bill",
                    SyncEntity.deleted.is_(False),
                )
            )
        )
        assert len(bills) == 105
        refunds = [bill for bill in bills if bill.payload["bill_type"] == "refund"]
        assert len(refunds) == 3
        assert all(
            bill.payload["allocations"]
            == [
                {
                    "source_bill_id": str(target),
                    "source_amount_minor": "100",
                    "receipt_amount_minor": "100",
                "rate": None,
                }
            ]
            for bill in refunds
        )
        assert session.get(SyncEntity, cash).balance_minor == 109300
        entries = list(
            session.scalars(select(LedgerEntry.amount_minor).where(LedgerEntry.account_id == cash))
        )
        assert len(entries) == 105 and sum(entries) == 9300
    duplicate, duplicate_apply = prepared(list(reversed(rows)))
    duplicate_job = post(stage_http, owner, duplicate, "apply", duplicate_apply)
    assert duplicate_job.status_code == 200, duplicate_job.text
    run(stage_http, postgres_engine, duplicate_job.json()["job_id"])
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, cash).balance_minor == 109300
        assert (
            len(list(session.scalars(select(LedgerEntry).where(LedgerEntry.account_id == cash))))
            == 105
        )
    for current_stage in [duplicate, stage]:
        undo = post(
            stage_http,
            owner,
            current_stage,
            "undo",
            {"stage_version": 1, "batch_id": current_stage["batch_id"]},
        )
        assert undo.status_code == 200, undo.text
        run(stage_http, postgres_engine, undo.json()["job_id"])
        assert status(stage_http, owner, current_stage)["status"] == "undone"
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, cash).balance_minor == 100000
        assert not list(session.scalars(select(LedgerEntry).where(LedgerEntry.account_id == cash)))
