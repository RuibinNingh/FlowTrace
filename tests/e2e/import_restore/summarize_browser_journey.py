"""Join preserved UI/HTTP/readback evidence without turning failed runs green."""

import argparse
import json
from pathlib import Path


def read(file):
    return json.loads(file.read_text("utf-8"))


def latest(output, phase, *, passed=True):
    rows = [
        (file, read(file)) for file in output.glob(f"browser-{phase}-*-receipt.json")
    ]
    rows = [(file, data) for file, data in rows if data["phase"] == phase]
    if passed:
        rows = [(file, data) for file, data in rows if data["result"] == "passed"]
    assert rows, "missing_browser_evidence"
    return max(rows, key=lambda item: item[1]["started_at"])


def operation(receipt, suffix):
    values = [
        item
        for item in receipt["operations"]
        if item["category"].endswith(suffix) and item["status"] == 200
    ]
    assert len(values) == 1
    return values[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    args = parser.parse_args()
    fixture = read(args.fixture)
    output = Path(fixture["output_directory"])
    phases = {
        phase: latest(output, phase)
        for phase in (
            "login",
            "native-preview",
            "offline-prepared",
            "native-apply",
            "csv-preview",
            "csv-apply",
            "csv-repeat",
            "export-json",
            "export-xlsx",
            "csv-undo-readback",
            "offline",
            "logout",
        )
    }
    native_preview = operation(phases["native-preview"][1], "imports/preview")
    native_apply = operation(phases["native-apply"][1], "imports/apply")
    assert native_preview["request_sha256"] == native_apply["request_sha256"]
    assert native_preview["receipt"]["batch_id"] == native_apply["receipt"]["batch_id"]
    assert len(native_apply["receipt"]["created"]) == 6
    csv_preview = operation(phases["csv-preview"][1], "imports/preview")
    csv_apply = operation(phases["csv-apply"][1], "imports/apply")
    repeat = operation(phases["csv-repeat"][1], "imports/apply")
    assert csv_preview["request_sha256"] == csv_apply["request_sha256"]
    assert len(csv_apply["receipt"]["created"]) == 2
    assert len(repeat["receipt"]["created"]) == 0
    assert len(repeat["receipt"]["duplicates"]) == 2
    undo_file, undo = latest(output, "csv-undo", passed=False)
    undone = operation(undo, "/undo")["receipt"]
    assert undone["batch_id"] == csv_apply["receipt"]["batch_id"]
    assert undone["status"] == "undone"
    aria = Path(str(undo_file).replace("-receipt.json", "-aria.txt")).read_text("utf-8")
    assert "迁移已撤销，本机账本已刷新。" in aria
    assert undo["result"] == "failed"  # Preserve the incorrect text assertion.
    assert not phases["csv-undo-readback"][1]["operations"]
    downloads = read(output / "browser-downloads-verified.json")
    assert downloads["result"] == "passed" and downloads["downloaded_rows_each"] == 8
    assert downloads["embedded_original_sha256"] == fixture["image_sha256"]
    raster = read(output / "offline-original-raster-verified.json")
    assert raster["result"] == "passed" and raster["matching_interior_pixels"] == 4
    assert phases["offline-prepared"][1]["shell"]["complete"] is True
    remote_dirs = [
        file.parent
        for file in output.glob("remote-case-*/remote-native-undo-receipt.json")
    ]
    assert len(remote_dirs) == 1
    remote = read(remote_dirs[0] / "remote-native-undo-receipt.json")
    remote_ui_file, remote_ui = latest(remote_dirs[0], "remote-refresh")
    assert (
        remote["result"] == "passed"
        and remote["attachment_scope"] == fixture["user_id"]
    )
    assert remote["own_history_after_new_book_deleted"][0]["status"] == "undone"
    assert any(
        item.get("filtered_batch_id") == remote["batch_id"]
        for item in remote_ui["http"]
    )
    failed = [
        str(file.relative_to(output))
        for file in output.rglob("browser-*-receipt.json")
        if read(file)["result"] == "failed"
    ]
    result = {
        "result": "functional_slices_completed_with_recorded_accessibility_gap",
        "run_id": fixture["run_id"],
        "ordinary_main_sha256": phases["native-apply"][1]["normal_main_sha256"],
        "browser": "isolated_headful_installed_Chrome_155",
        "business_seeded_outside_ui": False,
        "frozen_native_request_sha256": native_apply["request_sha256"],
        "native_created": 6,
        "public_csv_created": 2,
        "same_file_repeat_created": 0,
        "same_file_repeat_duplicates": 2,
        "balances_minor": ["9900", "9650", "9650", "9900"],
        "download_rows_each": 8,
        "embedded_original_bytes": fixture["image_bytes"],
        "embedded_original_sha256": fixture["image_sha256"],
        "offline_original_actual_image_and_interior_raster_verified": True,
        "remote_simulation_separate_from_ui": True,
        "remote_read_only_recovery_without_undo_resend": remote[
            "read_only_recovery_without_undo_resend"
        ],
        "remote_ui_receipt": str(remote_ui_file.relative_to(output)),
        "final_ui_logout": str(phases["logout"][0].relative_to(output)),
        "unresolved_accessibility_gap": "save_server_address_then_immediately_open_account_form_loses_semantic_controls; cold_reopen_current_address_exposes_controls",
        "all_attempts_green": False,
        "preserved_failed_browser_receipts": sorted(failed),
        "corrections": [
            "Harness adjusted actual Flutter virtual scrolling and persistent desktop drawer controls",
            "Synthetic CSV timestamp corrected from seconds to official minute precision; original preserved",
            "UI undo actually succeeded; wrong expected success wording preserved as failure, followed by cold read-only UI and DB confirmation",
            "Original native undo correctly refused account revision changes from later CSV; separate fresh six-row UI import used for second-client simulation",
            "Second-client undo committed before history.items harness KeyError; batches read-only recovery confirmed without resending undo",
            "Full screenshot-byte equality rejected due subpixel antialiasing; original byte identity checked in XLSX, visible interior pixels checked separately",
        ],
        "successful_phase_receipts": {
            phase: str(file.relative_to(output)) for phase, (file, _) in phases.items()
        },
        "full_product_or_large_import_acceptance": False,
    }
    target = output / "browser-functional-slices-summary.json"
    target.write_text(json.dumps(result, ensure_ascii=False, indent=2), "utf-8")
    print(
        json.dumps(
            {
                "result": result["result"],
                "receipt": str(target),
                "all_attempts_green": False,
            }
        )
    )


if __name__ == "__main__":
    main()
