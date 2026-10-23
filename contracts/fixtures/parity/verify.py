"""Validate evidence metadata without running or modifying either application."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import xml.etree.ElementTree as ET


BASE = Path(__file__).resolve().parent
ROOT = BASE.parents[2]
DATA_FILES = (
    "manifest.json",
    "states.json",
    "features.json",
    "claims.json",
    "retest-cases.json",
    "journeys.json",
)


def validate(local_sources: bool) -> dict:
    checks: list[str] = []

    def require(condition: bool, name: str) -> None:
        if not condition:
            raise ValueError(name)
        checks.append(name)

    payloads = {
        name: json.loads((BASE / name).read_text(encoding="utf-8-sig"))
        for name in DATA_FILES
    }
    for name, document in payloads.items():
        require(document.get("schema_version") == 1, f"schema:{name}")
    manifest = payloads["manifest.json"]
    states = payloads["states.json"]["states"]
    features = payloads["features.json"]["features"]
    cases = payloads["retest-cases.json"]["retest_cases"]
    journeys = payloads["journeys.json"]["journeys"]
    claims = payloads["claims.json"]["claims"]

    def indexed(rows: list[dict], prefix: str, count: int) -> dict:
        ids = [row["id"] for row in rows]
        require(len(ids) == len(set(ids)), f"unique:{prefix}")
        require(set(ids) == {f"{prefix}{n:02d}" for n in range(1, count + 1)}, f"coverage:{prefix}")
        return {row["id"]: row for row in rows}

    state_index = indexed(states, "S", 56)
    feature_index = indexed(features, "F", 22)
    case_index = indexed(cases, "V", 10)
    journey_index = indexed(journeys, "J", 12)
    require(len(claims) == 9 and len({c["id"] for c in claims}) == 9, "claims:unique-nine")

    sources = manifest["local_sources"]
    source_ids = {source["id"] for source in sources} | {
        source["id"] for source in manifest["external_sources"]
    }
    require(len(source_ids) == len(sources) + len(manifest["external_sources"]), "sources:unique")

    task_text = (ROOT / "AI/plans/flowtrace/tasks.md").read_text(encoding="utf-8-sig")
    task_ids = set(re.findall(r"^### (P\d-\d{2})\b", task_text, re.MULTILINE))
    require(len(task_ids) == 34, "tasks:34-defined")

    for feature in features:
        fid = feature["id"]
        require(set(feature["state_ids"]) <= state_index.keys(), f"{fid}:states")
        require(set(feature["source_ids"]) <= source_ids, f"{fid}:sources")
        require(set(feature["retest_ids"]) <= case_index.keys(), f"{fid}:retests")
        require(set(feature["journey_ids"]) <= journey_index.keys(), f"{fid}:journeys")
        require(bool(feature["implementation_tasks"]) and set(feature["implementation_tasks"]) <= task_ids, f"{fid}:tasks")
        require(bool(feature["acceptance_ids"]), f"{fid}:acceptance")
        if fid != "F22":
            require(bool(feature["retest_ids"]), f"{fid}:open-reference-retest")
    require(feature_index["F22"]["state_ids"] == [], "F22:no-invented-reference-screen")
    require(feature_index["F22"]["reference_fidelity_status"] == "new_flowtrace_requirement", "F22:new-requirement")

    all_artifacts = list(sources)
    png_count = xml_count = 0
    for state in states:
        sid = state["id"]
        require(bool(state["feature_ids"]) and set(state["feature_ids"]) <= feature_index.keys(), f"{sid}:features")
        for fid in state["feature_ids"]:
            require(sid in feature_index[fid]["state_ids"], f"{sid}:{fid}:reciprocal")
        require(state["historical_observation_class"] == "O", f"{sid}:historical-class")
        require(state["reference_submission_executed"] is False, f"{sid}:no-fake-submission")
        require(state["reference_exit_retested"] is False, f"{sid}:no-fake-exit-test")
        require(bool(state["entry_recipe"]) and bool(state["exit_plan"]) and bool(state["prerequisites"]), f"{sid}:navigation")
        require(len(state["artifacts"]) == 2, f"{sid}:two-artifacts")
        for artifact in state["artifacts"]:
            if artifact["kind"] == "historical_screenshot":
                png_count += 1
                require(artifact["width"] == 720 and artifact["height"] == 1570, f"{sid}:dimensions")
            elif artifact["kind"] == "historical_ui_hierarchy":
                xml_count += 1
                require(artifact["node_count"] > 0, f"{sid}:xml-metadata")
            else:
                require(False, f"{sid}:unknown-artifact-kind")
            all_artifacts.append(artifact)
    require(png_count == xml_count == 56, "artifacts:56-png-56-xml")

    for case in cases:
        vid = case["id"]
        require(set(case["feature_ids"]) <= feature_index.keys(), f"{vid}:features")
        require(set(case["state_ids"]) <= state_index.keys(), f"{vid}:states")
        require(set(case["journey_ids"]) <= journey_index.keys(), f"{vid}:journeys")
        require(set(case["implementation_tasks"]) <= task_ids, f"{vid}:tasks")
        require(case["reference_status"] == "not_executed_in_isolated_reference_environment", f"{vid}:not-run")
        require(case["blocks_independent_flowtrace_development"] is False, f"{vid}:independent-progress")
        require(case["exact_reference_parity_claim_allowed"] is False, f"{vid}:no-false-parity")
        require(bool(case["reference_test_steps"]) and bool(case["required_environment"]) and bool(case["owner_role"]), f"{vid}:retest-action")
        require(bool(case["flowtrace_defaults"]) and all(default["evidence_class"] == "N" for default in case["flowtrace_defaults"]), f"{vid}:defaults-not-observations")

    for journey in journeys:
        jid = journey["id"]
        require(set(journey["retest_ids"]) <= case_index.keys(), f"{jid}:retests")
        require(bool(journey["implementation_tasks"]) and set(journey["implementation_tasks"]) <= task_ids, f"{jid}:tasks")
        require(journey["status"] == "acceptance_plan_not_executed", f"{jid}:not-run")

    for claim in claims:
        require(set(claim["source_ids"]) <= source_ids, f"{claim['id']}:sources")
        require(claim["class"] in {"C", "G"} and bool(claim["limit"]), f"{claim['id']}:bounded")

    scope = manifest["this_task_scope"]
    require(all(scope[key] is False for key in ("reference_app_launched", "reference_writes_performed", "user_database_read", "business_api_called", "screenshots_copied", "private_xml_text_copied", "flowtrace_application_tested")), "scope:no-live-or-private-data-actions")
    require(scope["new_live_reference_observations"] == 0, "scope:no-new-live-observation")
    forbidden_keys = {"ocr_text", "raw_ui_text", "raw_screenshot", "password", "refresh_token", "account_name", "bill_remark", "private_amount"}

    def inspect_keys(value: object) -> None:
        if isinstance(value, dict):
            require(not (set(value) & forbidden_keys), "privacy:no-prohibited-raw-fields")
            for nested in value.values():
                inspect_keys(nested)
        elif isinstance(value, list):
            for nested in value:
                inspect_keys(nested)

    inspect_keys(payloads)

    verified_local_files = 0
    for artifact in all_artifacts:
        relative = Path(artifact["path"])
        require(not relative.is_absolute() and ".." not in relative.parts, "artifact:repo-relative-path")
        require(bool(re.fullmatch(r"[a-f0-9]{64}", artifact["sha256"])), "artifact:sha256-shape")
        if not local_sources:
            continue
        path = (ROOT / relative).resolve()
        require(path.is_relative_to(ROOT) and path.is_file(), f"local:exists:{artifact['path']}")
        data = path.read_bytes()
        require(len(data) == artifact["bytes"] and hashlib.sha256(data).hexdigest() == artifact["sha256"], f"local:integrity:{artifact['path']}")
        if artifact.get("kind") == "historical_screenshot":
            require(data[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", data[16:24]) == (artifact["width"], artifact["height"]), f"local:png:{artifact['path']}")
        elif artifact.get("kind") == "historical_ui_hierarchy":
            tree = ET.fromstring(data)
            require(tree.tag == artifact["root_tag"] and sum(1 for _ in tree.iter()) == artifact["node_count"], f"local:xml:{artifact['path']}")
        verified_local_files += 1

    return {
        "schema_version": 1,
        "task_id": "P0-01",
        "validation_kind": "evidence_metadata_and_local_integrity",
        "status": "passed",
        "mode": "local_sources" if local_sources else "portable_metadata",
        "checked_on": "2026-10-21",
        "timezone": "Asia/Shanghai",
        "counts": {"states": len(states), "features": len(features), "retest_cases": len(cases), "journeys": len(journeys), "claims": len(claims), "historical_pngs": png_count, "historical_xmls": xml_count, "local_source_files_verified": verified_local_files, "structural_assertions": len(checks)},
        "reference_live_tests_executed": 0,
        "flowtrace_business_tests_executed": 0,
        "unexecuted_reference_retests": sorted(case_index),
        "reference_parity_status": "partial_evidence_only_not_complete_runtime_parity",
        "check_groups": {
            group: sum(check.split(":", 1)[0] == group for check in checks)
            for group in sorted({check.split(":", 1)[0] for check in checks})
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--local-sources", action="store_true", help="Additionally verify ignored local research files.")
    parser.add_argument("--report", help="Write a JSON report in this parity directory; basename only.")
    args = parser.parse_args()
    try:
        report = validate(args.local_sources)
        if args.report:
            if Path(args.report).name != args.report or not args.report.endswith(".json"):
                raise ValueError("report must be a JSON basename inside the parity directory")
            (BASE / args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, ensure_ascii=False))
        return 0
    except (OSError, KeyError, ValueError, TypeError, ET.ParseError) as error:
        print(json.dumps({"status": "failed", "validation_kind": "evidence_metadata", "reason": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
