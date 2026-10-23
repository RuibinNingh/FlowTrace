"""P4-02 contract checks; static arithmetic is not business execution evidence.

The actual export is checked independently from the retained P0 candidate. New
model checks deliberately skip until the corresponding real server fields exist.
No synthetic schema or test-only HTTP endpoint substitutes for production wire
tests; the fixture records those unexecuted acceptance surfaces separately.
"""

import copy
import hashlib
import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "contracts/fixtures/ledger/refund-reimbursement.json"
DATA = json.loads(FIXTURE.read_text(encoding="utf-8"))
ACTUAL = json.loads((ROOT / "contracts/openapi.json").read_text(encoding="utf-8"))
AMOUNT_KEYS = {
    "refund_source_minor",
    "reimbursement_source_minor",
    "remaining_source_minor",
}
SUMMARY_KEYS = AMOUNT_KEYS | {"settlement_reason"}


def canonical(value):
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode()


def nonnegative_minor(value):
    if not isinstance(value, str) or not re.fullmatch(r"0|[1-9][0-9]*", value):
        raise ValueError("not_canonical_minor")
    result = int(value)
    if result > 2**63 - 1:
        raise ValueError("minor_out_of_range")
    return result


def validate_summary_vector(item):
    """Check the fixture's own arithmetic, without calling a business projector."""
    paid = nonnegative_minor(item["paid_minor"])
    if paid <= 0:
        raise ValueError("expense_must_be_positive")
    if "source_summary" not in item:
        return
    summary = item["source_summary"]
    if item["bill_type"] != "expense" or not isinstance(summary, dict):
        raise ValueError("summary_not_allowed")
    if set(summary) != SUMMARY_KEYS:
        raise ValueError("summary_not_closed")
    refunded = nonnegative_minor(summary["refund_source_minor"])
    reimbursed = nonnegative_minor(summary["reimbursement_source_minor"])
    remaining = nonnegative_minor(summary["remaining_source_minor"])
    if paid != refunded + reimbursed + remaining:
        raise ValueError("not_conserved")
    if str(remaining) != item["remaining_allocatable_minor"]:
        raise ValueError("remaining_mismatch")
    reason = (
        "open"
        if remaining > 0
        else "refunded"
        if reimbursed == 0
        else "reimbursed"
        if refunded == 0
        else "mixed"
    )
    if summary["settlement_reason"] != reason:
        raise ValueError("reason_mismatch")


class ReceiptFixtureTests(unittest.TestCase):
    def test_contract_provenance_and_legacy_scenarios_unchanged(self):
        self.assertEqual(DATA["contract_version"], "1.1")
        self.assertEqual(DATA["evidence_level"], "N")
        self.assertEqual(DATA["capability"], "receipt-tracking-v1")
        legacy = json.loads(
            (ROOT / "contracts/fixtures/ledger/scenarios.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(legacy["contract_version"], "1.0")
        self.assertEqual(len(legacy["scenarios"]), 8)
        self.assertEqual(sum(len(item["steps"]) for item in legacy["scenarios"]), 57)
        chosen = {
            item["scenario_id"]: hashlib.sha256(canonical(item)).hexdigest()
            for item in legacy["scenarios"]
            if item["scenario_id"].startswith(("L02_", "L04_"))
        }
        self.assertEqual(chosen, DATA["legacy_scenarios_sha256"])

    def test_tracking_vectors_are_strict_and_legacy_absence_is_preserved(self):
        self.assertNotIn("reimbursement_tracking", DATA["base_expense_payload"])
        identifiers = set()
        for item in DATA["tracking_vectors"]:
            with self.subTest(vector=item["id"]):
                self.assertNotIn(item["id"], identifiers)
                identifiers.add(item["id"])
                payload = item["payload"]
                present = "reimbursement_tracking" in payload
                allowed = not present or (
                    payload["bill_type"] == "expense"
                    and type(payload["reimbursement_tracking"]) is bool
                )
                self.assertEqual(allowed, item["accepted"])
        # Missing, false and null have different canonical request bytes/hashes.
        raw = copy.deepcopy(DATA["base_expense_payload"])
        explicit_false = {**raw, "reimbursement_tracking": False}
        explicit_null = {**raw, "reimbursement_tracking": None}
        self.assertEqual(
            len({canonical(raw), canonical(explicit_false), canonical(explicit_null)}),
            3,
        )

    def test_omission_vectors_do_not_clear_true_or_inherit_after_type_change(self):
        for item in DATA["preservation_vectors"]:
            with self.subTest(vector=item["id"]):
                result = dict(item["incoming"])
                if item.get("after_bill_type", "expense") == "expense":
                    for key, value in item["before"].items():
                        result.setdefault(key, value)
                self.assertEqual(result, item["expected"])

    def test_summary_vectors_are_closed_exact_and_conserved(self):
        reasons = set()
        for item in DATA["source_summary_vectors"]:
            with self.subTest(vector=item["id"]):
                if item["accepted"]:
                    validate_summary_vector(item)
                    if "source_summary" in item:
                        reasons.add(item["source_summary"]["settlement_reason"])
                    else:
                        self.assertEqual(set(item["knowledge"].values()), {"unknown"})
                else:
                    with self.assertRaises(ValueError):
                        validate_summary_vector(item)
        self.assertEqual(reasons, {"open", "refunded", "reimbursed", "mixed"})

    def test_linked_source_vectors_compare_values_and_freeze_money(self):
        base = DATA["base_expense_payload"]
        remaining_branches = set()
        for item in DATA["linked_source_vectors"]:
            with self.subTest(vector=item["id"]):
                changes = item["changes"]
                restricted = (
                    changes.get("action") == "delete"
                    or changes.get("bill_type", "expense") != "expense"
                    or changes.get("money", base["money"]) != base["money"]
                )
                self.assertEqual(not restricted, item["accepted"])
                self.assertEqual(
                    item["error_code"], "bill.has_allocations" if restricted else None
                )
                allocated = int(item["refund_source_minor"]) + int(
                    item["reimbursement_source_minor"]
                )
                paid = int(item["before_paid_minor"])
                remaining_branches.add(
                    "fully_settled" if allocated == paid else "partly_settled"
                )
                self.assertLessEqual(allocated, paid)
        self.assertEqual(remaining_branches, {"fully_settled", "partly_settled"})

    def test_lifecycle_cash_source_summary_budget_and_net_assets(self):
        scenario = DATA["lifecycle"]
        setup = scenario["setup"]
        paid = int(setup["source_paid_minor"])
        receipts = {}
        source_live = False
        source_revision = 0
        tracking = {"present": False}
        previous = None
        for step in scenario["steps"]:
            with self.subTest(step=step["step_id"]):
                command, expected = step["command"], step["expected"]
                state = expected["state"]
                if expected["result"] in {"rejected", "replayed"}:
                    self.assertEqual(state, previous)
                    if expected["result"] == "rejected":
                        self.assertIn(
                            expected["error_code"],
                            {"bill.has_allocations", "allocation.exceeds_remaining"},
                        )
                    continue
                self.assertEqual(expected["result"], "applied")
                self.assertIsNone(expected["error_code"])
                source_revision += 1
                action = command["action"]
                if action == "create_expense":
                    source_live = True
                elif action == "create_receipt":
                    self.assertNotIn(command["id"], receipts)
                    self.assertEqual(
                        command["amount_minor"], command["source_amount_minor"]
                    )
                    receipts[command["id"]] = command
                elif action == "delete_receipt":
                    receipts.pop(command["id"])
                elif action == "delete_source":
                    self.assertEqual(receipts, {})
                    source_live = False
                    tracking = {"present": False}
                else:
                    self.assertEqual(action, "update_source")
                if "reimbursement_tracking" in command:
                    tracking = {
                        "present": True,
                        "value": command["reimbursement_tracking"],
                    }
                refunded = sum(
                    int(item["source_amount_minor"])
                    for item in receipts.values()
                    if item["bill_type"] == "refund"
                )
                reimbursed = sum(
                    int(item["source_amount_minor"])
                    for item in receipts.values()
                    if item["bill_type"] == "reimbursement"
                )
                remaining = paid - refunded - reimbursed if source_live else 0
                balance = (
                    int(setup["opening_minor"])
                    - (paid if source_live else 0)
                    + sum(int(item["amount_minor"]) for item in receipts.values())
                )
                self.assertEqual(
                    state["account_balances_minor"], {"bank": str(balance)}
                )
                self.assertEqual(state["net_assets_minor"], str(balance))
                self.assertEqual(state["source_revision"], str(source_revision))
                self.assertEqual(state["source_deleted"], not source_live)
                self.assertEqual(state["source_tracking"], tracking)
                if source_live:
                    summary = state["source_summary"]
                    self.assertEqual(summary["refund_source_minor"], str(refunded))
                    self.assertEqual(
                        summary["reimbursement_source_minor"], str(reimbursed)
                    )
                    validate_summary_vector(
                        {
                            "bill_type": "expense",
                            "paid_minor": str(paid),
                            "remaining_allocatable_minor": state[
                                "remaining_allocatable_minor"
                            ],
                            "source_summary": summary,
                        }
                    )
                else:
                    self.assertNotIn("source_summary", state)
                    self.assertNotIn("remaining_allocatable_minor", state)
                for period_id, period in state["periods"].items():
                    expense = remaining if period_id == "october" else 0
                    self.assertEqual(
                        period,
                        {
                            "income_minor": "0",
                            "expense_minor": str(expense),
                            "budget_eligible_minor": str(expense),
                        },
                    )
                limit = int(setup["budget_limit_minor"])
                self.assertEqual(
                    state["budget"],
                    {
                        "limit_minor": str(limit),
                        "spent_minor": str(remaining),
                        "remaining_minor": str(limit - remaining),
                    },
                )
                previous = copy.deepcopy(state)
        self.assertEqual(len(scenario["steps"]), 18)

    def test_account_and_date_changes_keep_receipt_cash_and_dates(self):
        account, period = DATA["account_date_vectors"]
        paid = int(account["source_paid_minor"])
        self.assertEqual(
            account["receipt_account_before"], account["receipt_account_after"]
        )
        before, after = (
            account["before_balances_minor"],
            account["after_balances_minor"],
        )
        self.assertEqual(int(after["bank"]) - int(before["bank"]), paid)
        self.assertEqual(int(after["second_bank"]) - int(before["second_bank"]), -paid)
        self.assertEqual(
            sum(map(int, before.values())), int(account["net_assets_minor"])
        )
        self.assertEqual(
            sum(map(int, after.values())), int(account["net_assets_minor"])
        )
        self.assertEqual(period["receipt_dates_before"], period["receipt_dates_after"])
        net = (
            int(period["paid_minor"])
            - int(period["refund_source_minor"])
            - int(period["reimbursement_source_minor"])
        )
        self.assertEqual(
            period["before_period_expense_minor"],
            {"october": str(net), "november": "0"},
        )
        self.assertEqual(
            period["after_period_expense_minor"], {"october": "0", "november": str(net)}
        )

    def test_future_revision_is_a_separate_unimplemented_capability(self):
        for case in DATA["future_typed_revisions"]:
            self.assertEqual(case["capability"], "receipt-restructure-v1")
            self.assertEqual(case["implementation_status"], "not_implemented")
            before, request, expected = (
                case["before"],
                case["request"],
                case["expected"],
            )
            allocated = int(before["refund_source_minor"]) + int(
                before["reimbursement_source_minor"]
            )
            self.assertEqual(
                int(expected["remaining_source_minor"]),
                int(request["paid_minor"]) - allocated,
            )
            self.assertEqual(
                int(expected["account_balance_minor"]),
                int(before["account_balance_minor"])
                - (int(request["paid_minor"]) - int(before["paid_minor"])),
            )
            self.assertEqual(request["modified_entity_ids"], ["source"])
            self.assertFalse(expected["unchanged_foreign_receipts_touched"])

    def test_wire_acceptance_matrix_covers_nested_and_frozen_pages(self):
        matrix = DATA["wire_verification_matrix"]
        self.assertEqual(len({item["id"] for item in matrix}), len(matrix))
        self.assertTrue(
            all(
                item["required_phase"] in {"real_http", "real_pg_http"}
                for item in matrix
            )
        )
        self.assertEqual(DATA["wire_evidence_at_fixture_creation"], "not_executed")
        surfaces = {item["surface"] for item in matrix}
        self.assertTrue(
            {
                "push_create_ack",
                "current_get",
                "new_pull_page",
                "new_snapshot_page",
                "old_materialized_pull_snapshot",
            }
            <= surfaces
        )
        frozen = next(item for item in matrix if item["id"] == "W06_frozen_pages")
        self.assertIn("exact_original_utf8", frozen["assertions"])
        self.assertIn("same_sha256", frozen["assertions"])

    def test_frozen_legacy_pages_have_exact_canonical_bytes_and_item_hash(self):
        for name, fixture in DATA["frozen_legacy_pages"].items():
            with self.subTest(surface=name):
                encoded = canonical(fixture["data"])
                self.assertEqual(encoded.decode(), fixture["canonical_utf8"])
                self.assertEqual(hashlib.sha256(encoded).hexdigest(), fixture["sha256"])
                self.assertNotIn('"reimbursement_tracking"', fixture["canonical_utf8"])
                self.assertNotIn('"source_summary"', fixture["canonical_utf8"])
                if name == "snapshot":
                    page = fixture["data"]
                    self.assertEqual(
                        hashlib.sha256(canonical(page["items"])).hexdigest(),
                        page["page_sha256"],
                    )


class ActualOpenApiReceiptTests(unittest.TestCase):
    def test_actual_export_references_and_operation_ids(self):
        operation_ids = []

        def visit(node):
            if isinstance(node, dict):
                if "$ref" in node:
                    ref = node["$ref"]
                    self.assertTrue(ref.startswith("#/"), ref)
                    target = ACTUAL
                    for key in ref[2:].split("/"):
                        target = target[key.replace("~1", "/").replace("~0", "~")]
                    self.assertIsInstance(target, dict)
                for value in node.values():
                    visit(value)
            elif isinstance(node, list):
                for value in node:
                    visit(value)

        visit(ACTUAL)
        for item in ACTUAL["paths"].values():
            for method, operation in item.items():
                if method in {
                    "get",
                    "post",
                    "put",
                    "patch",
                    "delete",
                    "head",
                    "options",
                }:
                    self.assertIsInstance(operation.get("operationId"), str)
                    operation_ids.append(operation["operationId"])
        self.assertTrue(operation_ids)
        self.assertEqual(len(operation_ids), len(set(operation_ids)))

    def test_actual_shared_models_are_closed_and_money_is_a_string(self):
        schemas = ACTUAL["components"]["schemas"]
        for name in (
            "Money",
            "PositiveMoney",
            "BillPayload",
            "BillPublic",
            "PublicBillFields",
            "Operation",
            "ChangeEvent",
        ):
            with self.subTest(schema=name):
                self.assertIs(schemas[name]["additionalProperties"], False)
                self.assertTrue(
                    set(schemas[name].get("required", []))
                    <= set(schemas[name]["properties"])
                )
        self.assertEqual(
            schemas["PositiveMoney"]["properties"]["amount_minor"]["type"], "string"
        )
        # A response-only summary is never writable even after its model is added.
        self.assertNotIn("source_summary", schemas["BillPayload"]["properties"])


class ActualReceiptModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, str(ROOT / "server/src"))
        try:
            from flowtrace_server.sync.responses import (
                BillPublic,
                PublicBillFields,
                PullResponse,
                SnapshotPageResponse,
            )
            from flowtrace_server.sync.schemas import BillPayload
            from pydantic import ValidationError
        except ImportError as error:
            raise unittest.SkipTest(
                "actual server model dependencies unavailable"
            ) from error
        cls.BillPayload = BillPayload
        cls.BillPublic = BillPublic
        cls.PublicBillFields = PublicBillFields
        cls.PullResponse = PullResponse
        cls.SnapshotPageResponse = SnapshotPageResponse
        cls.ValidationError = ValidationError

    def test_existing_expense_model_rejects_zero_paid_amount(self):
        self.BillPayload.model_validate(DATA["base_expense_payload"])
        payload = copy.deepcopy(DATA["base_expense_payload"])
        payload["money"]["amount_minor"] = "0"
        with self.assertRaises(self.ValidationError):
            self.BillPayload.model_validate(payload)

    def test_real_page_models_preserve_frozen_legacy_bytes_with_exclude_unset(self):
        for kind, model in (
            ("pull", self.PullResponse),
            ("snapshot", self.SnapshotPageResponse),
        ):
            with self.subTest(surface=kind):
                fixture = DATA["frozen_legacy_pages"][kind]
                parsed = model.model_validate(fixture["data"])
                result = parsed.model_dump(exclude_unset=True)
                self.assertEqual(canonical(result).decode(), fixture["canonical_utf8"])
                self.assertEqual(
                    hashlib.sha256(canonical(result)).hexdigest(), fixture["sha256"]
                )
        # Real model serialization is covered; actual FastAPI/PG routes remain W01-W08.

    def test_new_tracking_vectors_against_actual_input_model(self):
        if "reimbursement_tracking" not in self.BillPayload.model_fields:
            self.skipTest("receipt-tracking-v1 input model is not implemented")
        for item in DATA["tracking_vectors"]:
            with self.subTest(vector=item["id"]):
                if item["accepted"]:
                    self.BillPayload.model_validate(item["payload"])
                else:
                    with self.assertRaises(self.ValidationError):
                        self.BillPayload.model_validate(item["payload"])

    def test_new_source_summary_vectors_against_actual_public_model(self):
        if "source_summary" not in self.BillPublic.model_fields:
            self.skipTest("receipt-tracking-v1 summary model is not implemented")
        raw = copy.deepcopy(
            DATA["frozen_legacy_pages"]["snapshot"]["data"]["items"][0]["data"]
        )
        for item in DATA["source_summary_vectors"]:
            with self.subTest(vector=item["id"]):
                value = copy.deepcopy(raw)
                value["payload"]["bill_type"] = item["bill_type"]
                value["payload"]["money"]["amount_minor"] = item["paid_minor"]
                value["remaining_allocatable_minor"] = item[
                    "remaining_allocatable_minor"
                ]
                if "source_summary" in item:
                    value["source_summary"] = item["source_summary"]
                if item["accepted"]:
                    self.BillPublic.model_validate(value)
                else:
                    with self.assertRaises(self.ValidationError):
                        self.BillPublic.model_validate(value)

    def test_new_optional_fields_exported_without_becoming_writable_summary(self):
        if (
            "reimbursement_tracking" not in self.BillPayload.model_fields
            or "source_summary" not in self.BillPublic.model_fields
        ):
            self.skipTest(
                "receipt-tracking-v1 actual input/output models are not implemented"
            )
        schemas = ACTUAL["components"]["schemas"]
        payload = schemas["BillPayload"]
        self.assertIn("reimbursement_tracking", payload["properties"])
        self.assertNotIn("reimbursement_tracking", payload.get("required", []))
        self.assertEqual(
            payload["properties"]["reimbursement_tracking"].get("type"), "boolean"
        )
        self.assertNotIn("source_summary", payload["properties"])
        public = schemas["BillPublic"]
        self.assertIn("source_summary", public["properties"])
        self.assertNotIn("source_summary", public.get("required", []))

        def assert_nonnull_schema(node):
            if "$ref" in node:
                return assert_nonnull_schema(schemas[node["$ref"].rsplit("/", 1)[1]])
            field_type = node.get("type")
            self.assertNotEqual(field_type, "null")
            if isinstance(field_type, list):
                self.assertNotIn("null", field_type)
            if "enum" in node:
                self.assertNotIn(None, node["enum"])
            if "const" in node:
                self.assertIsNotNone(node["const"])
            for keyword in ("anyOf", "oneOf", "allOf"):
                for child in node.get(keyword, []):
                    assert_nonnull_schema(child)

        assert_nonnull_schema(public["properties"]["source_summary"])
        self.assertIn(
            "reimbursement_tracking", schemas["PublicBillFields"]["properties"]
        )

        def find_summary_schema(node):
            if "$ref" in node:
                return find_summary_schema(schemas[node["$ref"].rsplit("/", 1)[1]])
            if set(node.get("properties", {})) == SUMMARY_KEYS:
                return node
            for keyword in ("anyOf", "oneOf", "allOf"):
                for child in node.get(keyword, []):
                    found = find_summary_schema(child)
                    if found is not None:
                        return found
            return None

        summary = find_summary_schema(public["properties"]["source_summary"])
        self.assertIsNotNone(summary, "actual export must describe the closed summary")
        self.assertIs(summary["additionalProperties"], False)
        self.assertEqual(set(summary["required"]), SUMMARY_KEYS)
        for key in AMOUNT_KEYS:
            self.assertEqual(summary["properties"][key]["type"], "string")
        self.assertEqual(
            set(summary["properties"]["settlement_reason"]["enum"]),
            {"open", "refunded", "reimbursed", "mixed"},
        )

    def test_new_models_preserve_legacy_omissions_under_exclude_unset(self):
        if (
            "reimbursement_tracking" not in self.PublicBillFields.model_fields
            or "source_summary" not in self.BillPublic.model_fields
        ):
            self.skipTest(
                "receipt-tracking-v1 actual public models are not implemented"
            )
        raw = self.BillPayload.model_validate(DATA["base_expense_payload"]).model_dump()
        raw.pop("preserve_hidden_financial_links", None)
        raw.pop("reimbursement_tracking", None)
        value = {
            "projection_kind": "bill_public",
            "payload": raw,
            "hidden_account_fields": [],
            "hidden_allocation_count": 0,
            "paid_by_user_ids": [],
            "nonfinancial_editable_fields": [],
            "remaining_allocatable_minor": "10000",
        }
        serialized = self.BillPublic.model_validate(value).model_dump(
            exclude_unset=True
        )
        self.assertNotIn("reimbursement_tracking", serialized["payload"])
        self.assertNotIn("source_summary", serialized)
        # This only proves model serialization; W01-W08 still need real HTTP/PG.


if __name__ == "__main__":
    unittest.main()
