"""Verify actual UI downloads; never creates or alters application state."""

import argparse
import hashlib
import json
from pathlib import Path
from zipfile import ZipFile

from flowtrace_server.imports.parsers import parse_json, parse_xlsx


def verify(document, fixture):
    rows = document.rows
    assert len(rows) == 8
    by_id = {str(row.source_id): row for row in rows}
    targets = fixture["native_targets"]
    expense = by_id[targets["expense"]].payload
    refund = by_id[targets["refund"]].payload
    cash = by_id[targets["cash"]].payload
    assert cash["opening"]["amount_minor"] == "10000"
    assert expense["money"]["amount_minor"] == "125"
    assert refund["money"]["amount_minor"] == "25"
    assert refund["allocations"][0]["source_bill_id"] == targets["expense"]
    assert refund["allocations"][0]["source_amount_minor"] == "25"
    assert len(expense["attachment_ids"]) == 1
    for key in fixture["csv_target_ids"]:
        assert by_id[key].payload["money"]["amount_minor"] == "125"
        assert by_id[key].payload["note"] == fixture["names"]["csv_note"]
    assert (
        by_id[fixture["csv_target_ids"][0]].source_id
        != by_id[fixture["csv_target_ids"][1]].source_id
    )
    return expense["attachment_ids"][0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--json-receipt", type=Path, required=True)
    parser.add_argument("--xlsx-receipt", type=Path, required=True)
    args = parser.parse_args()
    fixture = json.loads(args.fixture.read_text("utf-8"))
    assert fixture["purpose"] == "flowtrace-data-tools-normal-browser-synthetic"
    output = Path(fixture["output_directory"]).resolve()
    for file in (args.json_receipt, args.xlsx_receipt):
        file.resolve().relative_to(output)
    native, excel = [
        json.loads(file.read_text("utf-8"))
        for file in (args.json_receipt, args.xlsx_receipt)
    ]
    assert native["result"] == excel["result"] == "passed"
    native_file = Path(native["download"]["file"])
    excel_file = Path(excel["download"]["file"])
    native_file.resolve().relative_to(output)
    excel_file.resolve().relative_to(output)
    content = native_file.read_bytes()
    attachment_id = verify(parse_json(content), fixture)
    envelope = json.loads(content)
    assert len(envelope["attachments"]) == 1
    image = envelope["attachments"][0]
    assert image["attachment_id"] == attachment_id
    assert image["sha256"] == fixture["image_sha256"]
    assert image["size_bytes"] == fixture["image_bytes"]
    assert image["href"] == f"/api/v1/attachments/{attachment_id}/content"
    parsed = parse_xlsx(excel_file.read_bytes(), "browser-readback")
    assert not parsed.errors and parsed.document is not None
    assert verify(parsed.document, fixture) == attachment_id
    with ZipFile(excel_file) as workbook:
        pictures = [
            name for name in workbook.namelist() if name.startswith("xl/media/")
        ]
        assert len(pictures) == 1
        original = workbook.read(pictures[0])
        assert len(original) == fixture["image_bytes"]
        assert hashlib.sha256(original).hexdigest() == fixture["image_sha256"]
    result = {
        "run_id": fixture["run_id"],
        "result": "passed",
        "downloaded_rows_each": 8,
        "exact_money_relationships": True,
        "distinct_same_amount_csv_bills": True,
        "embedded_original_sha256": fixture["image_sha256"],
        "embedded_original_bytes": fixture["image_bytes"],
        "json": native["download"],
        "xlsx": excel["download"],
    }
    destination = output / "browser-downloads-verified.json"
    destination.write_text(json.dumps(result, indent=2), "utf-8")
    print(json.dumps({"result": "passed", "receipt": str(destination)}))


if __name__ == "__main__":
    main()
