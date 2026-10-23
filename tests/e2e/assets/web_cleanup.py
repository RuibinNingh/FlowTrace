"""Explicit normal tombstone cleanup for the completed, exact P4 browser run.

Default check only parses the bound manifest. Audit is read-only. Cleanup needs
the exact run UUID and completed logout proof; no reset, SQL entity delete or
opening-balance correction is available. Unknown rows stop the operation.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from fractions import Fraction
from pathlib import Path
from uuid import UUID, uuid4, uuid5

sys.path.insert(0, str(Path(__file__).resolve().parent))
from web_fixture import (
    ACCOUNT_KEYS,
    CREDENTIAL_ROOT,
    DATABASE,
    MANIFEST,
    OUTPUT,
    PURPOSE,
    ROOT,
    WHEEL_SHA256,
    configure,
    read,
    write_json,
)

# isort: split
from flowtrace_server.assets import configuration
from flowtrace_server.assets.models import AssetGroup
from flowtrace_server.assets.schemas import ConfigCommand, PreferenceCommand
from flowtrace_server.attachments.models import AttachmentRef
from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.models import User, UserSession
from flowtrace_server.auth.service import issue_session, now
from flowtrace_server.books.models import Book, BookMembership
from flowtrace_server.currencies.models import ValuationRate
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.sync.canonical import content_hash
from flowtrace_server.sync.input import parse_push_body
from flowtrace_server.sync.models import LedgerEntry, SyncEntity
from flowtrace_server.sync.writer import push_operations
from sqlalchemy import func, select
from sqlalchemy.orm import Session

FUND_KINDS = {
    "fund-repayment": "credit_repayment",
    "fund-borrow": "loan_borrow",
    "fund-lend": "loan_lend",
    "fund-collect": "loan_collect",
    "fund-repay": "loan_repay",
    "fund-fx": "transfer",
}


def binding():
    manifest = read(MANIFEST)
    run_id = UUID(manifest["run_id"])
    if (
        manifest["purpose"] != PURPOSE
        or manifest["state"] != "seeded"
        or manifest["database"] != DATABASE
        or manifest["wheel_sha256"] != WHEEL_SHA256
        or manifest["api_origin"] != "http://127.0.0.1:18085"
    ):
        raise RuntimeError("bound_active_fixture_required")
    private = CREDENTIAL_ROOT / str(run_id)
    credentials = private / "credentials.json"
    if (ROOT / manifest["credentials_path"]).resolve() != credentials.resolve():
        raise RuntimeError("bound_credentials_path_required")
    control = read(private / "server-control.json")
    if any(
        control[key] != manifest[key]
        for key in ("purpose", "run_id", "instance_id", "sync_epoch", "user_id")
    ):
        raise RuntimeError("fixture_control_identity_mismatch")
    return manifest, private, control


def inspect(session, manifest):
    user_id, book_id = UUID(manifest["user_id"]), UUID(manifest["ids"]["book"])
    state, user, book = (
        session.get(ServerState, 1),
        session.get(User, user_id),
        session.get(Book, book_id),
    )
    marker = UUID(manifest["run_id"]).hex[:12]
    if (
        str(state.instance_id) != manifest["instance_id"]
        or str(state.sync_epoch) != manifest["sync_epoch"]
        or user is None
        or user.username != "p4_ui_" + marker
        or not user.enabled
        or book is None
        or book.owner_user_id != user_id
        or book.deleted
    ):
        raise RuntimeError("database_fixture_identity_mismatch")
    owned_books = set(
        session.scalars(
            select(BookMembership.book_id).where(
                BookMembership.user_id == user_id, BookMembership.active.is_(True)
            )
        )
    )
    if owned_books != {book_id}:
        raise RuntimeError("unknown_book_scope_refuses_cleanup")
    accounts = list(
        session.scalars(
            select(SyncEntity).where(
                SyncEntity.scope_id == user_id, SyncEntity.entity_type == "account"
            )
        )
    )
    by_name = {row.payload["name"]: row for row in accounts}
    names = {manifest["names"][key] for key in ACCOUNT_KEYS | {"ui_credit"}}
    if (
        len(accounts) != 8
        or set(by_name) != names
        or any(row.deleted for row in accounts)
    ):
        raise RuntimeError("unknown_or_missing_account_refuses_cleanup")
    keyed_accounts = {
        key: by_name[manifest["names"][key]] for key in ACCOUNT_KEYS | {"ui_credit"}
    }
    for key in ACCOUNT_KEYS:
        if str(keyed_accounts[key].id) != manifest["ids"][key]:
            raise RuntimeError("seed_account_identity_mismatch")
    current = {}
    for phase in ["initial", "account-create", *FUND_KINDS]:
        current.update(manifest["calculated"][phase]["balances_minor"])
    expected_openings = manifest["calculated"]["cleanup_balances_minor"]
    for key, row in keyed_accounts.items():
        if (
            str(row.balance_minor) != current[key]
            or row.payload["opening"]["amount_minor"] != expected_openings[key]
        ):
            raise RuntimeError("fixed_account_money_mismatch")
    children = list(
        session.scalars(select(SyncEntity).where(SyncEntity.scope_id == book_id))
    )
    bills = [row for row in children if row.entity_type == "bill"]
    expected_notes = {manifest["inputs"][key]["note"]: key for key in FUND_KINDS}
    if (
        len(bills) != 6
        or any(row.deleted for row in bills)
        or {row.payload["note"] for row in bills} != set(expected_notes)
        or any(row.entity_type not in {"book", "bill", "category"} for row in children)
        or {str(row.id) for row in children if row.entity_type == "category"}
        != {manifest["ids"]["expense_category"]}
    ):
        raise RuntimeError("unknown_or_missing_book_entity_refuses_cleanup")
    for row in bills:
        phase = expected_notes[row.payload["note"]]
        data = manifest["inputs"][phase]
        if (
            row.payload["bill_type"] != FUND_KINDS[phase]
            or row.payload["book_id"] != str(book_id)
            or row.payload["from_account_id"]
            != str(keyed_accounts[data["from_name_key"]].id)
            or row.payload["to_account_id"]
            != str(keyed_accounts[data["to_name_key"]].id)
        ):
            raise RuntimeError("fixed_bill_identity_mismatch")
    groups = list(
        session.scalars(select(AssetGroup).where(AssetGroup.user_id == user_id))
    )
    rates = list(
        session.scalars(select(ValuationRate).where(ValuationRate.user_id == user_id))
    )
    if (
        len(groups) != 1
        or groups[0].deleted
        or groups[0].name != manifest["names"]["ui_group"]
    ):
        raise RuntimeError("unknown_or_missing_group_refuses_cleanup")
    if len(rates) != 2 or len([row for row in rates if not row.deleted]) != 1:
        raise RuntimeError("unknown_or_missing_quote_refuses_cleanup")
    for row in rates:
        phase = "rate-create" if row.deleted else "rate-replace"
        data = manifest["inputs"][phase]
        if (
            row.from_currency != "EUR"
            or row.to_currency != "CNY"
            or row.rate_text != data["rate"]
            or row.rate_source != data["source"]
            or row.effective_date.isoformat() != data["date"]
        ):
            raise RuntimeError("fixed_quote_identity_mismatch")
    if configuration.preferences(session, user_id)["preferences"] != {
        "base_currency": "CNY",
        "enabled_codes": ["CNY"],
        "valuation_policy": "latest_on_or_before",
    }:
        raise RuntimeError("unexpected_currency_preferences_refuse_cleanup")
    if (
        session.scalar(
            select(func.count())
            .select_from(AttachmentRef)
            .where(AttachmentRef.bill_id.in_([row.id for row in bills]))
        )
        != 0
    ):
        raise RuntimeError("unexpected_attachment_refuses_cleanup")
    active = session.scalar(
        select(func.count())
        .select_from(UserSession)
        .where(UserSession.user_id == user_id, UserSession.revoked_at.is_(None))
    )
    return {
        "accounts": {key: str(row.id) for key, row in keyed_accounts.items()},
        "bills": [str(row.id) for row in bills],
        "group": str(groups[0].id),
        "rates": [str(row.id) for row in rates if not row.deleted],
        "category": manifest["ids"]["expense_category"],
        "active_sessions": active,
    }


def cleanup(manifest, private, engine, inspected):
    user_id, run_id = UUID(manifest["user_id"]), UUID(manifest["run_id"])
    intent = private / "cleanup-intent.json"
    if intent.exists():
        raise RuntimeError("previous_cleanup_attempt_requires_review")
    final = read(OUTPUT / "web-assets-logout-reopen-receipt.json")
    if final.get("run_id") != str(run_id) or final.get("result") != "passed":
        raise RuntimeError("completed_ui_logout_proof_required")
    if inspected["active_sessions"] != 0:
        raise RuntimeError("ui_sessions_must_be_logged_out_first")
    write_json(intent, {"run_id": str(run_id), "state": "started", "plan": inspected})
    principal = None
    completed = []
    try:
        with Session(engine) as session:
            user = session.get(User, user_id)
            record, _ = issue_session(
                session, user, uuid4(), "P4合成数据正常清理", "api_native"
            )
            principal = Principal(
                user_id, record.id, record.client_id, record.purpose, frozenset()
            )
            session.commit()

        def remove(identifier):
            with Session(engine) as session:
                row = session.get(SyncEntity, UUID(identifier))
                operation = {
                    "operation_id": str(uuid5(run_id, "cleanup:" + identifier)),
                    "scope_id": str(row.scope_id),
                    "entity_type": row.entity_type,
                    "entity_id": identifier,
                    "action": "delete",
                    "base_revision": str(row.revision),
                    "depends_on": None,
                    "payload": {},
                }
            raw = json.dumps(
                {
                    "protocol_version": 1,
                    "client_id": str(principal.client_id),
                    "sync_epoch": manifest["sync_epoch"],
                    "operations": [operation],
                }
            ).encode()
            with Session(engine) as session:
                result = push_operations(session, principal, parse_push_body(raw))
            if result["results"][0]["status"] != "applied":
                raise RuntimeError("normal_tombstone_rejected")
            completed.append(identifier)
            write_json(
                intent,
                {
                    "run_id": str(run_id),
                    "state": "started",
                    "completed": completed,
                    "plan": inspected,
                },
            )

        for identifier in inspected["bills"]:
            remove(identifier)
        with Session(engine) as session:
            for key, identifier in inspected["accounts"].items():
                row = session.get(SyncEntity, UUID(identifier))
                if (
                    str(row.balance_minor)
                    != manifest["calculated"]["cleanup_balances_minor"][key]
                ):
                    raise RuntimeError("normal_delete_did_not_restore_opening")
            if (
                session.scalar(
                    select(func.count())
                    .select_from(LedgerEntry)
                    .where(
                        LedgerEntry.bill_id.in_(
                            [UUID(value) for value in inspected["bills"]]
                        )
                    )
                )
                != 0
            ):
                raise RuntimeError("effective_entries_remain")
        for identifier in inspected["accounts"].values():
            remove(identifier)
        remove(inspected["category"])

        def config_remove(action, identifier=None):
            with Session(engine) as session:
                fields = {
                    "operation_id": str(
                        uuid5(run_id, "cleanup:" + action + str(identifier))
                    ),
                    "client_id": str(principal.client_id),
                    "instance_id": manifest["instance_id"],
                    "sync_epoch": manifest["sync_epoch"],
                    "base_revision": str(configuration.revision(session, user_id)),
                }
            if action == "preferences.update":
                command = PreferenceCommand(
                    **fields,
                    preferences={
                        "base_currency": "CNY",
                        "enabled_codes": ["CNY"],
                        "valuation_policy": "exact_date",
                    },
                )
            else:
                command = ConfigCommand(**fields)
            with Session(engine) as session:
                configuration.mutate_configuration(
                    session,
                    principal,
                    action,
                    command,
                    UUID(identifier) if identifier else None,
                )

        config_remove("groups.delete", inspected["group"])
        for identifier in inspected["rates"]:
            config_remove("rates.delete", identifier)
        config_remove("preferences.update")
        remove(manifest["ids"]["book"])
    finally:
        if principal is not None:
            with Session(engine) as session:
                session.get(UserSession, principal.session_id).revoked_at = now()
                session.commit()
    with Session(engine) as session:
        assert all(session.get(SyncEntity, UUID(value)).deleted for value in completed)
        assert (
            session.scalar(
                select(func.count())
                .select_from(UserSession)
                .where(UserSession.user_id == user_id, UserSession.revoked_at.is_(None))
            )
            == 0
        )
        assert not configuration.groups(session, user_id)["groups"]
        assert not configuration.rates(session, user_id)["rates"]
        assert configuration.preferences(session, user_id)["preferences"] == {
            "base_currency": "CNY",
            "enabled_codes": ["CNY"],
            "valuation_policy": "exact_date",
        }
    manifest["state"] = "cleaned"
    write_json(MANIFEST, manifest)
    receipt = {
        "passed": True,
        "run_id": str(run_id),
        "normal_tombstones": len(completed),
        "restored_openings": manifest["calculated"]["cleanup_balances_minor"],
        "effective_entries": 0,
        "active_synthetic_sessions": 0,
        "reset_or_drop": False,
        "changed_18080": False,
    }
    write_json(private / "cleanup-intent.json", {**receipt, "state": "completed"})
    write_json(OUTPUT / "web-assets-cleanup-receipt.json", receipt)
    return receipt


def audit_evidence(session, manifest, inspected):
    """Independent, exact synthetic-only checks; no authentication session is created."""

    def display_minor(value):
        match = re.fullmatch(r"(0|[1-9][0-9]*)(?:\.([0-9]{1,2}))?", value)
        if match is None:
            raise RuntimeError("fixed_display_amount_not_exact_minor")
        return int(match[1]) * 100 + int((match[2] or "").ljust(2, "0"))

    accounts = {
        key: session.get(SyncEntity, UUID(value))
        for key, value in inspected["accounts"].items()
    }
    by_note = {manifest["inputs"][key]["note"]: key for key in FUND_KINDS}
    bills = []
    for identifier in inspected["bills"]:
        entity = session.get(SyncEntity, UUID(identifier))
        payload = entity.payload
        phase = by_note[payload["note"]]
        inputs = manifest["inputs"][phase]
        amount = display_minor(inputs["amount"])
        if (
            entity.revision != 1
            or payload["money"]
            != {"currency": "CNY", "currency_scale": 2, "amount_minor": str(amount)}
            or payload["business_date"] != manifest["date"]
            or payload["allocations"]
            or payload["income_component_minor"] != "0"
        ):
            raise RuntimeError("fixed_bill_money_or_revision_mismatch")
        source = accounts[inputs["from_name_key"]]
        target = accounts[inputs["to_name_key"]]
        target_minor = (
            display_minor(inputs["target_money"]) if phase == "fund-fx" else amount
        )
        target_currency = "EUR" if phase == "fund-fx" else "CNY"
        expected = {
            (str(source.id), "principal", str(-amount), "CNY", 2),
            (str(target.id), "principal", str(target_minor), target_currency, 2),
        }
        if phase == "fund-fx":
            if (
                payload["target_money"]
                != {
                    "currency": "EUR",
                    "currency_scale": 2,
                    "amount_minor": str(target_minor),
                }
                or payload["transfer_fx"]
                != {
                    "rate": inputs["transfer_rate"],
                    "rate_date": manifest["date"],
                    "rate_source": "manual",
                }
                or payload["fee"]["money"]
                != {
                    "currency": "CNY",
                    "currency_scale": 2,
                    "amount_minor": str(display_minor(inputs["fee"])),
                }
                or payload["fee"]["account_id"] != str(accounts["fee_account"].id)
            ):
                raise RuntimeError("frozen_fx_or_independent_fee_mismatch")
            expected.add(
                (
                    str(accounts["fee_account"].id),
                    "fee",
                    str(-display_minor(inputs["fee"])),
                    "CNY",
                    2,
                )
            )
        elif payload["fee"] is not None or payload.get("transfer_fx") is not None:
            raise RuntimeError("unexpected_fee_or_fx_fact")
        entries = list(
            session.scalars(select(LedgerEntry).where(LedgerEntry.bill_id == entity.id))
        )
        actual = {
            (
                str(row.account_id),
                row.component,
                str(row.amount_minor),
                row.currency,
                row.currency_scale,
            )
            for row in entries
        }
        if (
            len(entries) != len(expected)
            or actual != expected
            or any(
                row.book_id != UUID(manifest["ids"]["book"])
                or row.business_date.isoformat() != manifest["date"]
                for row in entries
            )
        ):
            raise RuntimeError("fixed_signed_postings_mismatch")
        bills.append(
            {
                "phase": phase,
                "id": identifier,
                "revision": str(entity.revision),
                "bill_type": payload["bill_type"],
                "money": payload["money"],
                "target_money": payload["target_money"],
                "transfer_fx": payload.get("transfer_fx"),
                "fee_money": payload["fee"]["money"] if payload["fee"] else None,
                "payload_sha256": content_hash(payload),
                "signed_entries": [list(value) for value in sorted(actual)],
            }
        )
    assets = liabilities = borrowed = lent = 0
    positions = {}
    rate = Fraction(manifest["inputs"]["rate-replace"]["rate"])
    for key, account in accounts.items():
        value, payload = account.balance_minor, account.payload
        if payload["opening"]["currency_scale"] != 2 or payload["opening"][
            "currency"
        ] not in {"CNY", "EUR"}:
            raise RuntimeError("unexpected_fixture_currency")
        valued = Fraction(value) * (
            rate if payload["opening"]["currency"] == "EUR" else 1
        )
        if valued.denominator != 1:
            raise RuntimeError("fixture_valuation_unexpected_rounding")
        valued = int(valued)
        if payload["include_in_net_assets"]:
            if valued >= 0:
                assets += valued
            else:
                liabilities -= valued
            if payload["kind"] == "loan_payable":
                borrowed += max(0, -valued)
            if payload["kind"] == "loan_receivable":
                lent += max(0, valued)
        positions[key] = {
            "id": str(account.id),
            "revision": str(account.revision),
            "balance_minor": str(value),
            "opening": payload["opening"],
            "hidden": payload["hidden"],
            "include_in_net_assets": payload["include_in_net_assets"],
        }
    totals = {
        "assets": str(assets),
        "liabilities": str(liabilities),
        "net": str(assets - liabilities),
        "borrowed": str(borrowed),
        "lent": str(lent),
    }
    if totals != manifest["calculated"]["valuation_at_9"]["totals_minor"]:
        raise RuntimeError("independent_valuation_mismatch")
    quotes = list(
        session.scalars(
            select(ValuationRate).where(
                ValuationRate.user_id == UUID(manifest["user_id"])
            )
        )
    )
    evidence = {
        "positions": positions,
        "bills": sorted(bills, key=lambda row: row["phase"]),
        "valuation_totals_minor": totals,
        "config_revision": str(
            configuration.revision(session, UUID(manifest["user_id"]))
        ),
        "preferences": configuration.preferences(session, UUID(manifest["user_id"]))[
            "preferences"
        ],
        "rates": [
            {
                "id": str(row.id),
                "rate": row.rate_text,
                "effective_date": row.effective_date.isoformat(),
                "deleted": row.deleted,
            }
            for row in sorted(quotes, key=lambda row: row.rate)
        ],
        "all_bill_revisions_still_one_after_valuation_changes": True,
    }
    return {**evidence, "evidence_sha256": content_hash(evidence)}


def main():
    parser = argparse.ArgumentParser(description="Bound synthetic P4 normal cleanup")
    parser.add_argument(
        "action", choices=["check", "audit", "cleanup"], nargs="?", default="check"
    )
    parser.add_argument("--confirm-run")
    args = parser.parse_args()
    manifest, private, control = binding()
    if args.action == "check":
        print(json.dumps({"bound_run": manifest["run_id"], "database_mutated": False}))
        return
    if args.action == "cleanup" and args.confirm_run != manifest["run_id"]:
        raise RuntimeError("explicit_exact_run_confirmation_required")
    _settings, engine = configure(
        Path(control["runtime_directory"]), migrate=False, require_free_port=False
    )
    try:
        with Session(engine) as session:
            session.connection(execution_options={"isolation_level": "REPEATABLE READ"})
            session.connection().exec_driver_sql("SET TRANSACTION READ ONLY")
            inspected = inspect(session, manifest)
            # The frozen manifest and current rows are authoritative, never a
            # previously exported audit file. Cleanup receives the same strict
            # per-bill money/target/FX/fee/postings checks as a read-only audit.
            evidence = audit_evidence(session, manifest, inspected)
            inspected["financial_evidence_sha256"] = evidence["evidence_sha256"]
        if args.action == "cleanup":
            result = cleanup(manifest, private, engine, inspected)
        else:
            result = {
                "run_id": manifest["run_id"],
                "exact_completed_fixture": True,
                "account_count": len(inspected["accounts"]),
                "bill_count": len(inspected["bills"]),
                "active_sessions": inspected["active_sessions"],
                "database_mutated": False,
                "check_session_created": False,
                "passed": True,
                "checked_at": now().isoformat(),
                "evidence": evidence,
            }
            write_json(OUTPUT / "web-assets-financial-audit-receipt.json", result)
        print(json.dumps(result))
    finally:
        engine.dispose()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # noqa: BLE001 -- public error projection excludes private data
        code = (
            str(error)
            if re.fullmatch(r"[a-z_]{1,100}", str(error))
            else type(error).__name__
        )
        print(f"p4_ui_cleanup_failed:{code}; inspect ignored run state")
        raise SystemExit(1) from None
