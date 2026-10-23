"""Inspect this test's downloaded ZIP without extracting any entry."""

import hashlib
import json
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / "outputs/validation/P3"
DOWNLOAD = OUTPUT / "p3-browser-images.zip"


def main():
    if not DOWNLOAD.resolve().is_relative_to(OUTPUT.resolve()):
        raise ValueError("download_path_outside_test_output")
    fixture = json.loads((OUTPUT / "web-fixture.json").read_text(encoding="utf-8-sig"))
    expected = fixture["image"]
    if not 0 < DOWNLOAD.stat().st_size <= 21 * 1024 * 1024:
        raise ValueError("download_size_invalid")
    with ZipFile(DOWNLOAD) as archive:
        entries = archive.infolist()
        if len(entries) != 1 or archive.comment:
            raise ValueError("unexpected_zip_structure")
        item = entries[0]
        if item.filename != "images/image_0001.png" or item.comment:
            raise ValueError("unexpected_zip_entry_name_or_comment")
        if item.file_size != expected["size_bytes"] or item.file_size > 10 * 1024 * 1024:
            raise ValueError("unexpected_image_size")
        image = archive.read(item)
        if hashlib.sha256(image).hexdigest() != expected["sha256"]:
            raise ValueError("original_image_hash_changed")
    result = {"result": "passed", "download_bytes": DOWNLOAD.stat().st_size,
              "entry_count": 1, "original_bytes": len(image),
              "original_sha256": expected["sha256"], "extracted_to_disk": False}
    (OUTPUT / "web-zip-receipt.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        raise SystemExit("download_verification_failed_no_raw_contents_printed") from None
