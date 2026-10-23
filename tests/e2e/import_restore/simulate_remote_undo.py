"""Separate real-HTTP second-client undo simulation, not browser UI evidence."""

import argparse
import hashlib
import json
from pathlib import Path
from uuid import uuid4

import httpx


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--recover-only", action="store_true")
    args = parser.parse_args()
    fixture = json.loads(args.fixture.read_text("utf-8"))
    assert fixture["purpose"] == "flowtrace-data-tools-normal-browser-synthetic"
    assert fixture["api_origin"] in {"http://127.0.0.1:18090", "http://127.0.0.1:18091"}
    output = Path(fixture["output_directory"])
    previous = [
        json.loads(file.read_text("utf-8"))
        for file in output.glob("browser-native-apply-*-receipt.json")
    ]
    applied = [
        operation["receipt"]
        for receipt in previous
        if receipt["result"] == "passed"
        for operation in receipt["operations"]
        if operation["category"] == "imports/apply" and operation["status"] == 200
    ]
    assert len(applied) == 1, "expected_one_native_receipt"
    receipt = applied[0]
    assert len(receipt["created"]) == 6 and len(receipt["attachment_transfers"]) == 1, (
        "native_receipt_shape"
    )
    batch_id = receipt["batch_id"]
    image_id = receipt["attachment_transfers"][0]["attachment_id"]
    credentials = json.loads(Path(fixture["credentials_file"]).read_text("utf-8"))
    client_id = str(uuid4())
    body = {"client_id": client_id, "sync_epoch": fixture["sync_epoch"]}
    encoded = json.dumps(body, sort_keys=True, separators=(",", ":"))
    intent = output / "remote-native-undo-intent.json"
    if intent.exists():
        if not args.recover_only:
            raise SystemExit("remote_undo_already_attempted_inspect_metadata_no_resend")
        assert json.loads(intent.read_text("utf-8"))["batch_id"] == batch_id
    elif args.recover_only:
        raise SystemExit("no_prior_undo_intent")
    with httpx.Client(base_url=fixture["api_origin"], timeout=30) as client:
        login = client.post(
            "/api/v1/auth/login",
            json={
                **credentials,
                "client_id": client_id,
                "device_name": "FlowTrace synthetic second client",
                "client_kind": "native",
            },
        )
        login.raise_for_status()
        client.headers["Authorization"] = "Bearer " + login.json()["access_token"]
        try:
            info = client.get("/api/v1/server-info")
            info.raise_for_status()
            assert info.json()["sync_epoch"] == fixture["sync_epoch"]
            preview = client.get(f"/api/v1/data-tools/imports/{batch_id}/undo-preview")
            preview.raise_for_status()
            (output / f"remote-native-undo-preview-{client_id}.json").write_text(
                json.dumps(preview.json(), indent=2), "utf-8"
            )
            if args.recover_only:
                assert preview.json()["status"] == "undone", "prior_undo_not_confirmed"
                undone_receipt = None
            else:
                assert (
                    preview.json()["can_undo"] is True
                    and preview.json()["created_count"] == 6
                ), "native_undo_conflict_or_count"
                intent.write_text(
                    json.dumps(
                        {
                            "mode": "external_second_client_http",
                            "batch_id": batch_id,
                            "client_id": client_id,
                            "body_sha256": hashlib.sha256(encoded.encode()).hexdigest(),
                        }
                    ),
                    "utf-8",
                )
                undone = client.post(
                    f"/api/v1/data-tools/imports/{batch_id}/undo", json=body
                )
                undone.raise_for_status()
                assert undone.json()["status"] == "undone"
                undone_receipt = undone.json()
                (output / "remote-native-undo-wire.json").write_text(
                    json.dumps(undone_receipt, indent=2), "utf-8"
                )
            history = client.get(
                "/api/v1/data-tools/imports/history",
                params={"batch_id": batch_id, "limit": 1},
            )
            history.raise_for_status()
            item = history.json()["batches"]
            assert (
                len(item) == 1
                and item[0]["batch_id"] == batch_id
                and item[0]["status"] == "undone"
            )
            image = client.get(f"/api/v1/attachments/{image_id}")
            image.raise_for_status()
            metadata = image.json()
            assert metadata["scope_id"] == fixture["user_id"]
            assert metadata["sha256"] == fixture["image_sha256"]
            result = {
                "result": "passed",
                "mode": "external_second_client_http_not_browser_ui",
                "read_only_recovery_without_undo_resend": args.recover_only,
                "run_id": fixture["run_id"],
                "client_id": client_id,
                "batch_id": batch_id,
                "undo": undone_receipt,
                "own_history_after_new_book_deleted": item,
                "attachment_id": image_id,
                "attachment_scope": metadata["scope_id"],
                "attachment_sha256": metadata["sha256"],
                "tokens_or_credentials_recorded": False,
            }
            target = output / "remote-native-undo-receipt.json"
            target.write_text(json.dumps(result, ensure_ascii=False, indent=2), "utf-8")
            print(
                json.dumps(
                    {"result": "passed", "mode": result["mode"], "receipt": str(target)}
                )
            )
        finally:
            client.post("/api/v1/auth/logout")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # noqa: BLE001 -- Excludes credentials/HTTP bodies.
        detail = "_" + str(error) if isinstance(error, AssertionError) else ""
        raise SystemExit(
            "remote_simulation_failed_" + type(error).__name__ + detail
        ) from None
