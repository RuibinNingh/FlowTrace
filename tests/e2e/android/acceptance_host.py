"""ADB host for the explicit local-only Android acceptance fixture.

No Flutter integration runner, account login, app clear or shared directory scan.
All identifiers/files are bound to a fresh run manifest. Unknown picker rows are
never printed or screenshotted. Run `--help` for the staged commands.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import struct
import subprocess
import time
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[3]
PACKAGE = "com.flowtrace.flowtrace.dev"
ACTIVITY = "com.flowtrace.flowtrace.MainActivity"
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAFElEQVR4nGPUaXnNAAZMEIqBgQEAHGMBn0OjIGsAAAAASUVORK5CYII=")
DEFAULT_ADB = Path("C:/Users/ruibi/AppData/Local/Android/Sdk/platform-tools/adb.exe")
DEFAULT_AAPT = Path("C:/Users/ruibi/AppData/Local/Android/Sdk/build-tools/36.1.0/aapt.exe")
UUID4 = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
PICKER_PACKAGES = {"com.google.android.documentsui", "com.android.documentsui", "com.coloros.filemanager"}
PICKER_NAVIGATION = {"显示根目录", "显示导航抽屉", "Show roots", "Show navigation drawer", "打开导航抽屉", "下载", "Download", "Downloads", "最近", "Recent", "搜索", "Search", "取消", "Cancel", "分类", "图片", "内部存储", "手机存储", "本机", "存储空间", "文件", "所有文件", "更多", "本地", "选择文件", "内部共享存储空间", "搜索文件", "返回", "手机", "内部存储空间", "设备存储", "手机存储空间", "本地文件", "内部存储器", "内部共享存储", "更多选项", "切换为列表", "列表视图", "列表", "切换视图", "视图", "排序", "查看方式", "排序方式"}
FIXTURE_CONTROLS = {"添加图片", "核验选图", "核验取消", "核验超限", "写入终止前 READY", "写入只读复验 READY"}
RECEIPTS = ["manifest", "seeded", "picker-selected", "picker-cancelled", "picker-oversized", "ready", "reopened", "ready-recheck", "reopened-recheck"]


def write_new(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as target:
        json.dump(value, target, ensure_ascii=False, indent=2)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Host:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        if not UUID4.fullmatch(args.run):
            raise ValueError("explicit v4 run UUID required")
        self.directory = ROOT / "outputs" / "validation" / "P4" / "android" / args.run
        self.manifest_path = self.directory / "host-manifest.json"
        self.device_directory = f"files/flowtrace-qa/android-{args.run}"

    def adb(self, *parts: str, check: bool = True) -> bytes:
        result = subprocess.run([str(self.args.adb), "-s", self.args.serial, *parts], capture_output=True, timeout=120)
        if check and result.returncode:
            # Do not echo a serial, arbitrary device UI or unrelated app output.
            raise RuntimeError(f"ADB {parts[0]} failed (exit {result.returncode})")
        return result.stdout

    def manifest(self) -> dict:
        value = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        if value["run_id"] != self.args.run or value["package"] != PACKAGE:
            raise ValueError("host manifest binding mismatch")
        return value

    def alias_names(self) -> set[str]:
        path = self.directory / "host-alias-files.json"
        if not path.exists():
            return set()
        value = json.loads(path.read_text(encoding="utf-8"))
        if value["run_id"] != self.args.run or value["status"] != "passed":
            raise RuntimeError("alias mapping not confirmed")
        return {row["alias"] for row in value["files"]}

    def aliases(self) -> None:
        manifest = self.manifest()
        self.verify_device()
        pushed = json.loads((self.directory / "host-push.json").read_text(encoding="utf-8"))
        checksums = {row["name"]: row["sha256"] for row in pushed["files"]}
        names = [(manifest["normal_name"], f"FT-{self.args.run[:13]}.png"), (manifest["oversized_name"], f"FT-{self.args.run[:13]}-big.png")]
        rows = []
        for source, alias in names:
            data = (self.directory / source).read_bytes()
            if sha(data) != checksums[source]:
                raise RuntimeError("original synthetic host source differs")
            if self.adb("shell", "ls", f"/sdcard/Download/{alias}", check=False).strip():
                raise RuntimeError("alias already exists on device; refusing overwrite")
            with (self.directory / alias).open("xb") as target:
                target.write(data)
            rows.append({"source_full_name": source, "alias": alias, "sha256": sha(data), "size_bytes": len(data), "encoded_dimensions": [3, 2]})
        write_new(self.directory / "host-alias-intent.json", {"run_id": self.args.run, "files": rows, "reason": "OEM manually elides UUID names in its accessibility TextView, including list mode"})
        for row in rows:
            path = f"/sdcard/Download/{row['alias']}"
            self.adb("push", str(self.directory / row["alias"]), path)
            if self.adb("shell", "sha256sum", path).decode().split()[0] != row["sha256"]:
                raise RuntimeError("alias device checksum mismatch")
            self.adb("shell", "am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE", "-d", f"file://{path}")
        write_new(self.directory / "host-alias-files.json", {"run_id": self.args.run, "status": "passed", "files": rows, "cleanup_exact_names": [manifest["normal_name"], manifest["oversized_name"], *[row["alias"] for row in rows]]})
        print("Two short unique aliases pushed; original names/bytes and all four cleanup paths retained.")

    def verify_device(self) -> dict:
        raw = subprocess.run([str(self.args.adb), "devices", "-l"], capture_output=True, check=True, timeout=20).stdout.decode()
        devices = [row.split() for row in raw.splitlines()[1:] if row.strip()]
        matched = [row for row in devices if row[:2] == [self.args.serial, "device"]]
        if len(matched) != 1:
            raise RuntimeError("exactly one explicitly bound authorized device required; other devices are ignored")
        properties = {}
        for name in ["ro.product.model", "ro.build.version.release", "ro.build.version.sdk", "ro.product.cpu.abi", "sys.boot_completed"]:
            properties[name] = self.adb("shell", "getprop", name).decode().strip()
        expected = {"ro.product.model": "PLT140", "ro.build.version.sdk": "36", "ro.product.cpu.abi": "arm64-v8a", "sys.boot_completed": "1"}
        if any(properties[k] != v for k, v in expected.items()):
            raise RuntimeError("authorized android-plt140-dev1 properties differ")
        binding_path = self.directory / "host-device-binding.json"
        serial_hash = sha(self.args.serial.encode("utf-8"))
        if binding_path.exists():
            binding = json.loads(binding_path.read_text(encoding="utf-8"))
            if binding["run_id"] != self.args.run or binding["serial_sha256"] != serial_hash:
                raise RuntimeError("explicit device differs from immutable authorized run binding")
        elif self.manifest_path.exists():
            write_new(binding_path, {"run_id": self.args.run, "tracking_name": "android-plt140-dev1", "serial_sha256": serial_hash, "properties": properties, "other_connected_devices_ignored": True})
        return {"tracking_name": "android-plt140-dev1", **properties}

    def prepare(self) -> None:
        device = self.verify_device()
        self.directory.mkdir(parents=True, exist_ok=False)
        normal = f"FlowTrace-{self.args.run}.png"
        oversized = f"FlowTrace-{self.args.run}-oversized.png"
        for name, data in [(normal, PNG), (oversized, PNG + bytes(10 * 1024 * 1024 + 1 - len(PNG)))]:
            (self.directory / name).write_bytes(data)
        write_new(self.manifest_path, {
            "run_id": self.args.run, "package": PACKAGE, "device": device,
            "normal_name": normal, "oversized_name": oversized,
            "normal_sha256": sha(PNG), "normal_size": len(PNG), "dimensions": [3, 2],
            "oversized_size": 10 * 1024 * 1024 + 1,
            "device_directory": self.device_directory, "network_tested": False,
        })
        print(json.dumps({"status": "prepared", "run_id": self.args.run, "device": device["tracking_name"], "manifest": str(self.manifest_path)}, ensure_ascii=False))

    def push(self) -> None:
        manifest = self.manifest()
        self.verify_device()
        results = []
        for field in ["normal_name", "oversized_name"]:
            name = manifest[field]
            path = f"/sdcard/Download/{name}"
            if self.adb("shell", "ls", path, check=False).strip():
                raise RuntimeError("refusing to overwrite a device Download file")
            self.adb("push", str(self.directory / name), path)
            actual = self.adb("shell", "sha256sum", path).decode().split()[0]
            if actual != sha((self.directory / name).read_bytes()):
                raise RuntimeError("pushed synthetic file SHA256 mismatch")
            self.adb("shell", "am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE", "-d", f"file://{path}")
            results.append({"name": name, "sha256": actual})
        write_new(self.directory / "host-push.json", {"run_id": self.args.run, "files": results})
        print("Synthetic Download files pushed and SHA256 verified.")

    def install(self) -> None:
        self.manifest()
        self.verify_device()
        if not self.args.apk:
            raise ValueError("--apk required")
        apk = Path(self.args.apk).resolve(strict=True)
        if apk.parent != self.directory.resolve():
            raise ValueError("install only the retained APK inside this run evidence directory")
        with zipfile.ZipFile(apk) as archive:
            kernel = archive.read("assets/flutter_assets/kernel_blob.bin")
        if self.args.run.encode("ascii") not in kernel:
            raise ValueError("APK does not contain this explicitly bound QA run")
        result = self.adb("install", "-r", str(apk)).decode()
        if "Success" not in result:
            raise RuntimeError("fixture install did not report Success")
        write_new(self.directory / ("host-install-repaired.json" if self.args.repair else "host-install.json"), {"run_id": self.args.run, "apk": str(apk), "sha256": sha(apk.read_bytes()), "package": PACKAGE, "status": "passed", "qa_read_adapter_repair": self.args.repair})
        print("Fixture APK installed without clearing application data.")

    def start(self) -> None:
        self.manifest()
        evidence = self.directory / ("host-start-repaired.json" if self.args.repair else "host-start.json")
        if evidence.exists():
            raise RuntimeError("start evidence already exists; refusing blind repeat")
        result = self.adb("shell", "am", "start", "-W", "-n", f"{PACKAGE}/{ACTIVITY}").decode()
        if "Status: ok" not in result:
            raise RuntimeError("fixture did not start successfully")
        write_new(evidence, {"run_id": self.args.run, "result": result, "qa_read_adapter_repair": self.args.repair})
        print("Fixture started.")

    def normal_install(self) -> None:
        self.manifest()
        self.verify_device()
        scan = json.loads((self.directory / "normal-main-artifact-scan.json").read_text(encoding="utf-8"))
        apk = self.directory / "normal-main-debug.apk"
        if scan["run_id"] != self.args.run or scan["status"] != "passed" or sha(apk.read_bytes()) != scan["apk_sha256"]:
            raise RuntimeError("normal main must exactly match passed QA marker/credential scan")
        badging = subprocess.run([str(self.args.aapt), "dump", "badging", str(apk)], capture_output=True, check=True, timeout=30).stdout.decode("utf-8")
        if f"package: name='{PACKAGE}'" not in badging or "native-code: 'arm64-v8a'" not in badging:
            raise RuntimeError("ordinary main package/ABI mismatch")
        (self.directory / "normal-main-aapt.txt").write_text(badging, encoding="utf-8")
        write_new(self.directory / "normal-main-install-intent.json", {"run_id": self.args.run, "apk_sha256": scan["apk_sha256"], "package": PACKAGE, "clear_data": False, "private_fixture_preserved": True})
        output = self.adb("install", "-r", str(apk)).decode()
        if "Success" not in output:
            raise RuntimeError("normal main install did not report Success")
        write_new(self.directory / "normal-main-install.json", {"run_id": self.args.run, "status": "passed", "package": PACKAGE, "apk_sha256": scan["apk_sha256"], "qa_defines": False, "private_fixture_preserved": True})
        print("Verified ordinary main installed without QA defines or clearing data.")

    def normal_start(self) -> None:
        self.manifest()
        self.verify_device()
        if json.loads((self.directory / "normal-main-install.json").read_text(encoding="utf-8"))["status"] != "passed":
            raise RuntimeError("normal cold launch requires verified normal APK install")
        evidence = self.directory / "normal-main-cold-start.json"
        if evidence.exists():
            raise RuntimeError("normal cold launch evidence already exists")
        self.adb("shell", "am", "force-stop", PACKAGE)
        started = self.adb("shell", "am", "start", "-W", "-n", f"{PACKAGE}/{ACTIVITY}").decode()
        write_new(self.directory / "normal-main-cold-start-raw.json", {"run_id": self.args.run, "start": started})
        if "Status: ok" not in started or "LaunchState: COLD" not in started:
            raise RuntimeError("normal main must report Status ok / COLD")
        time.sleep(2)
        process = self.adb("shell", "pidof", PACKAGE).decode().strip()
        if not re.fullmatch(r"\d+", process):
            raise RuntimeError("expected one normal main process")
        errors = self.adb("logcat", "-d", f"--pid={process}", "-v", "brief", "*:E")
        with (self.directory / "normal-main-own-pid-errors.log").open("xb") as target:
            target.write(errors)
        write_new(evidence, {"run_id": self.args.run, "status": "passed", "pid": process, "start": started, "own_pid_error_log_size": len(errors), "no_logcat_clear": True, "normal_main": True, "system_picker_network_test_claimed": False})
        print(json.dumps({"normal_main_cold_launch": "passed", "pid": process, "own_pid_error_log_bytes": len(errors)}))

    def xml(self) -> ET.Element:
        path = f"/data/local/tmp/flowtrace-{self.args.run}.xml"
        self.adb("shell", "uiautomator", "dump", path)
        raw = self.adb("shell", "cat", path)
        self.adb("shell", "rm", path)
        return ET.fromstring(raw.decode("utf-8"))

    @staticmethod
    def _texts(node: ET.Element) -> list[str]:
        return [node.get("text", ""), node.get("content-desc", "")]

    def tap(self, label: str, picker: bool = False) -> None:
        if picker:
            manifest = self.manifest()
            if label not in PICKER_NAVIGATION | {manifest["normal_name"], manifest["oversized_name"]} | self.alias_names():
                raise ValueError("only documented picker navigation or this run's synthetic filenames may be tapped")
        elif label not in FIXTURE_CONTROLS:
            raise ValueError("only this fixture's documented controls may be tapped")
        tree = self.xml()
        packages = {node.get("package") for node in tree.iter("node")}
        if picker:
            if not packages.intersection(PICKER_PACKAGES):
                raise RuntimeError("expected Android system document picker")
        elif PACKAGE not in packages:
            raise RuntimeError("expected FlowTrace foreground; refusing tap")
        matches = [node for node in tree.iter("node") if label in self._texts(node) and node.get("enabled") == "true"]
        if len(matches) != 1:
            raise RuntimeError(f"exact UI label match count {len(matches)}; no tap")
        if matches[0].get("enabled") != "true":
            raise RuntimeError("UI target disabled")
        self._tap_node(matches[0])
        print(f"Tapped known {'system' if picker else 'FlowTrace'} control: {label}")

    def _tap_node(self, node: ET.Element) -> None:
        numbers = list(map(int, re.findall(r"\d+", node.get("bounds", ""))))
        if len(numbers) != 4 or numbers[0] >= numbers[2] or numbers[1] >= numbers[3]:
            raise RuntimeError("invalid target bounds")
        self.adb("shell", "input", "tap", str((numbers[0] + numbers[2]) // 2), str((numbers[1] + numbers[3]) // 2))

    def picker_state(self) -> None:
        manifest = self.manifest()
        tree = self.xml()
        packages = {n.get("package") for n in tree.iter("node")}
        allowed = PICKER_NAVIGATION | {manifest["normal_name"], manifest["oversized_name"]} | self.alias_names()
        # Only documented navigation labels and the two synthetic names leave
        # this transient tree; other filenames/thumbnails are not exported.
        controls = [{"text": value, "enabled": n.get("enabled"), "resource_id": n.get("resource-id")} for n in tree.iter("node") for value in self._texts(n) if value in allowed]
        structure = sorted({(n.get("resource-id", ""), n.get("class", "")) for n in tree.iter("node") if n.get("package") in PICKER_PACKAGES and n.get("resource-id")})
        print(json.dumps({"system_picker": bool(packages.intersection(PICKER_PACKAGES)), "flowtrace": PACKAGE in packages, "packages": sorted(p for p in packages if p), "known_controls": controls, "structure_without_other_text": structure}, ensure_ascii=False))

    def select(self) -> None:
        manifest = self.manifest()
        label = manifest["oversized_name" if self.args.oversized else "normal_name"]
        source = label
        if self.args.alias:
            aliases = json.loads((self.directory / "host-alias-files.json").read_text(encoding="utf-8"))
            rows = [row for row in aliases["files"] if row["source_full_name"] == source]
            if aliases["run_id"] != self.args.run or aliases["status"] != "passed" or len(rows) != 1:
                raise RuntimeError("alias must be bound to exact original synthetic source")
            label = rows[0]["alias"]
        self.tap(label, picker=True)
        write_new(self.directory / ("host-select-oversized.json" if self.args.oversized else "host-select-normal.json"), {"run_id": self.args.run, "filename": label, "source_full_name": source, "system_picker": True, "selected_via_exact_name": True})

    def search(self) -> None:
        manifest = self.manifest()
        filename = manifest["oversized_name" if self.args.oversized else "normal_name"]
        tree = self.xml()
        if not {n.get("package") for n in tree.iter("node")}.intersection(PICKER_PACKAGES):
            raise RuntimeError("filename search requires verified system picker")
        inputs = [n for n in tree.iter("node") if n.get("package") in PICKER_PACKAGES and n.get("class") == "android.widget.EditText" and n.get("enabled") == "true"]
        if len(inputs) != 1 or inputs[0].get("text", "") not in {"", "搜索文件", "搜索", "Search"}:
            raise RuntimeError("one empty system picker search editor required")
        self._tap_node(inputs[0])
        self.adb("shell", "input", "text", filename)
        self.adb("shell", "input", "keyevent", "KEYCODE_ENTER")
        write_new(self.directory / ("host-search-oversized.json" if self.args.oversized else "host-search-normal.json"), {"run_id": self.args.run, "filename": filename, "system_picker": True})
        print("Searched only this run's full synthetic filename.")

    def cancel(self) -> None:
        tree = self.xml()
        if not {n.get("package") for n in tree.iter("node")}.intersection(PICKER_PACKAGES):
            raise RuntimeError("cancel requires system picker foreground")
        buttons = [n for n in tree.iter("node") if n.get("package") in PICKER_PACKAGES and n.get("enabled") == "true" and any(value in {"取消", "Cancel"} for value in self._texts(n))]
        if len(buttons) == 1:
            self._tap_node(buttons[0])
            action = "explicit_cancel_control"
        elif not buttons:
            self.adb("shell", "input", "keyevent", "KEYCODE_BACK")
            action = "KEYCODE_BACK"
        else:
            raise RuntimeError("ambiguous cancel controls")
        after = self.xml()
        if PACKAGE not in {n.get("package") for n in after.iter("node")}:
            raise RuntimeError("picker cancellation has not returned to own app")
        write_new(self.directory / "host-cancel.json", {"run_id": self.args.run, "system_picker": True, "action": action, "returned_to_app": True})
        print("Cancelled real Android system picker.")

    def navigate_back(self) -> None:
        tree = self.xml()
        if not {n.get("package") for n in tree.iter("node")}.intersection(PICKER_PACKAGES):
            raise RuntimeError("picker back navigation requires verified picker")
        self.adb("shell", "input", "keyevent", "KEYCODE_BACK")
        print("Returned one level within verified OEM picker navigation.")

    def scroll_picker(self) -> None:
        tree = self.xml()
        allowed = {"com.coloros.filemanager:id/main_expandable_recyclerview", "com.coloros.filemanager:id/recycler_view"}
        nodes = [n for n in tree.iter("node") if n.get("package") in PICKER_PACKAGES and n.get("resource-id") in allowed and n.get("scrollable") == "true"]
        if len(nodes) != 1:
            raise RuntimeError("exactly one documented scrollable picker container required")
        left, top, right, bottom = map(int, re.findall(r"\d+", nodes[0].get("bounds", "")))
        x = (left + right) // 2
        self.adb("shell", "input", "swipe", str(x), str(top + (bottom - top) * 4 // 5), str(x), str(top + (bottom - top) // 5), "400")
        print("Scrolled verified picker container without opening any file.")

    def assert_error(self) -> None:
        tree = self.xml()
        expected = "请选择10 MiB以内的图片。"
        if not any(expected in value for n in tree.iter("node") if n.get("package") == PACKAGE for value in self._texts(n)):
            raise RuntimeError("exact visible application oversized rejection not found")
        write_new(self.directory / "host-oversized-error.json", {"run_id": self.args.run, "visible_message": expected, "status": "passed"})
        print("Actual application oversized rejection is visible.")

    def screenshot(self) -> None:
        tree = self.xml()
        packages = {n.get("package") for n in tree.iter("node")}
        if PACKAGE not in packages or packages.intersection(PICKER_PACKAGES):
            raise RuntimeError("screenshots restricted to own FlowTrace app")
        if not self.args.name or not re.fullmatch(r"[a-z0-9-]{1,48}", self.args.name):
            raise ValueError("--name lowercase evidence name required")
        output = self.directory / f"{self.args.name}.png"
        if output.exists():
            raise RuntimeError("evidence file already exists")
        data = self.adb("exec-out", "screencap", "-p")
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise RuntimeError("device screenshot is not PNG")
        width, height = struct.unpack(">II", data[16:24])
        output.write_bytes(data)
        print(json.dumps({"file": str(output), "size": len(data), "width": width, "height": height, "sha256": sha(data)}))

    def receipt(self, name: str) -> dict:
        raw = self.adb("exec-out", "run-as", PACKAGE, "cat", f"{self.device_directory}/{name}.json")
        value = json.loads(raw)
        if value["run_id"] != self.args.run:
            raise RuntimeError("device receipt run mismatch")
        return value

    def export(self) -> None:
        self.manifest()
        exported = []
        for name in RECEIPTS:
            raw = self.adb("exec-out", "run-as", PACKAGE, "cat", f"{self.device_directory}/{name}.json", check=False)
            try:
                value = json.loads(raw)
            except (ValueError, UnicodeError):
                continue
            if value["run_id"] != self.args.run:
                raise RuntimeError("receipt run mismatch")
            path = self.directory / f"device-{name}.json"
            if path.exists():
                if json.loads(path.read_text(encoding="utf-8")) != value:
                    raise RuntimeError("refusing to overwrite differing exported receipt")
            else:
                write_new(path, value)
            exported.append(name)
        print(json.dumps({"run_id": self.args.run, "exported": exported}))

    def inspect_persisted(self) -> None:
        """Read only the UUID fixture DB/original against immutable READY."""
        if not self.args.name or not re.fullmatch(r"[a-z0-9-]{1,48}", self.args.name):
            raise ValueError("--name required for immutable inspection evidence")
        expected = json.loads((self.directory / "device-ready.json").read_text(encoding="utf-8"))["snapshot"]
        data = self.adb("exec-out", "run-as", PACKAGE, "cat", f"{self.device_directory}/acceptance.sqlite")
        if not data.startswith(b"SQLite format 3\x00"):
            raise RuntimeError("fixture SQLite header missing")
        path = self.directory / f"fixture-{self.args.name}.sqlite"
        with path.open("xb") as target:
            target.write(data)
        with sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True) as database:
            database.row_factory = sqlite3.Row
            if database.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise RuntimeError("copied isolated SQLite integrity_check failed")
            entities = [dict(row) for row in database.execute("SELECT entity_id, entity_type AS type, scope_id, data_json, server_revision AS revision, deleted FROM local_entities WHERE space_id=? ORDER BY entity_id", (expected["space_id"],))]
            for row in entities:
                row["deleted"] = bool(row["deleted"])
            if entities != expected["entities"]:
                raise RuntimeError("persisted entity rows differ from original READY")
            operations = [dict(row) for row in database.execute("SELECT operation_id, entity_id, operation_json, frozen_request_json, state, attempt_count, sequence FROM pending_operations WHERE space_id=? ORDER BY sequence", (expected["space_id"],))]
            if operations != expected["operations"]:
                raise RuntimeError("persisted exact intent/frozen body rows differ")
            drafts = database.execute("SELECT id, body FROM local_drafts WHERE space_id=?", (expected["space_id"],)).fetchall()
            if len(drafts) != 1 or drafts[0]["id"] != expected["draft_id"] or drafts[0]["body"] != expected["draft_body"]:
                raise RuntimeError("persisted full draft differs")
            state = database.execute("SELECT client_id, epoch, status, cursors_json, revoked_scopes_json FROM sync_states WHERE space_id=?", (expected["space_id"],)).fetchone()
            if dict(state) != expected["sync_state"]:
                raise RuntimeError("persisted sync identity differs")
            for item in expected["attachments"]:
                record = item["record"]
                key = f"attachments.v1.{expected['space_id']}.queue.{record['id']}"
                row = database.execute("SELECT value FROM app_settings WHERE key=?", (key,)).fetchone()
                if row is None or json.loads(row["value"]) != record or not re.fullmatch(r"[0-9a-f]{64}", record["blob_key"]):
                    raise RuntimeError("persisted attachment metadata differs")
                original = self.adb("exec-out", "run-as", PACKAGE, "cat", f"{self.device_directory}/originals/{record['blob_key']}.blob")
                if sha(original) != item["sha256"] or len(original) != record["size_bytes"]:
                    raise RuntimeError("persisted original bytes differ")
        write_new(self.directory / f"host-persisted-{self.args.name}.json", {"run_id": self.args.run, "status": "passed", "sqlite_sha256": sha(data), "read_only_host_sqlite": True, "compared_to": "original device-ready.json", "same_entity_operation_frozen_draft_sync_attachment_rows": True, "original_blob_sha256": expected["attachments"][0]["sha256"], "application_reopen_pass_claimed": False})
        print("Independent read-only isolated SQLite/original inspection matches original READY exactly.")

    def restart(self) -> None:
        self.manifest()
        ready_name = "ready-recheck" if self.args.recheck else "ready"
        reopened_name = "reopened-recheck" if self.args.recheck else "reopened"
        host_name = "host-restart-recheck" if self.args.recheck else "host-restart"
        ready = self.receipt(ready_name)
        expected = "READY_RECHECK" if self.args.recheck else "READY"
        if ready["status"] != expected:
            raise RuntimeError("OS force-stop requires durable READY")
        if self.args.recheck and ready["snapshot_sha256"] != self.receipt("ready")["snapshot_sha256"]:
            raise RuntimeError("recheck must preserve original immutable READY snapshot")
        old = self.adb("shell", "pidof", PACKAGE).decode().strip()
        if old != str(ready["pid"]):
            raise RuntimeError("READY must belong to current package process")
        write_new(self.directory / f"{host_name}-intent.json", {"run_id": self.args.run, "old_pid": old, "ready_snapshot_sha256": ready["snapshot_sha256"], "same_apk_between_ready_and_restart": True})
        self.adb("shell", "am", "force-stop", PACKAGE)
        if self.adb("shell", "pidof", PACKAGE, check=False).strip():
            raise RuntimeError("old package process still exists")
        started = self.adb("shell", "am", "start", "-W", "-n", f"{PACKAGE}/{ACTIVITY}").decode()
        if "Status: ok" not in started or "LaunchState: COLD" not in started:
            raise RuntimeError("restart must report Status ok / COLD")
        write_new(self.directory / f"{host_name}-started.json", {"run_id": self.args.run, "old_pid": old, "start": started, "status": "cold_started"})
        for _ in range(30):
            time.sleep(0.5)
            raw = self.adb("exec-out", "run-as", PACKAGE, "cat", f"{self.device_directory}/{reopened_name}.json", check=False)
            try:
                reopened = json.loads(raw)
            except ValueError:
                continue
            if reopened.get("status") == "passed":
                break
        else:
            raise RuntimeError("readonly reopen receipt missing; no reseed attempted")
        new = self.adb("shell", "pidof", PACKAGE).decode().strip()
        if new == old or new != str(reopened["pid"]) or reopened["snapshot_sha256"] != ready["snapshot_sha256"] or reopened["reseeded"] is not False or reopened["query_only"] is not True:
            raise RuntimeError("OS restart / exact snapshot verification failed")
        write_new(self.directory / f"{host_name}.json", {"run_id": self.args.run, "status": "passed", "old_pid": old, "new_pid": new, "start": started, "snapshot_sha256": ready["snapshot_sha256"], "network_tested": False, "no_reinstall_between_ready_and_reopen": True, "recheck": self.args.recheck})
        self.export()
        print("OS force-stop / COLD launch / exact readonly snapshot passed.")

    def validate(self) -> None:
        """Independent host checks over exported synthetic receipts, no ADB."""
        manifest = self.manifest()

        def read(name: str) -> dict:
            value = json.loads((self.directory / f"{name}.json").read_text(encoding="utf-8"))
            if value["run_id"] != self.args.run:
                raise RuntimeError(f"run mismatch in {name}")
            return value

        source = read("device-manifest")
        selected = read("device-picker-selected")
        ready = read("device-ready")
        repaired = read("device-reopened")
        recheck_ready = read("device-ready-recheck")
        reopened = read("device-reopened-recheck")
        restart = read("host-restart-recheck")
        snapshot = ready["snapshot"]
        checksum = sha(json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
        if not all(value == checksum for value in [ready["snapshot_sha256"], selected["snapshot_sha256"], repaired["snapshot_sha256"], recheck_ready["snapshot_sha256"], reopened["snapshot_sha256"], restart["snapshot_sha256"]]):
            raise RuntimeError("independent serialized snapshot SHA mismatch")
        if snapshot["balance_minor"] != "9875" or snapshot["epoch"] != source["epoch"] or snapshot["sync_state"]["client_id"] != source["client_id"]:
            raise RuntimeError("expected exact balance/sync identity mismatch")
        entities = {row["type"]: row for row in snapshot["entities"]}
        if len(snapshot["entities"]) != 3 or set(entities) != {"book", "account", "bill"}:
            raise RuntimeError("expected exactly three synthetic entity types")
        account = json.loads(entities["account"]["data_json"])
        bill = json.loads(entities["bill"]["data_json"])
        if entities["account"]["entity_id"] != source["account_id"] or account["opening"]["amount_minor"] != "10000" or bill["money"]["amount_minor"] != "125" or bill["account_id"] != source["account_id"] or bill["book_id"] != source["book_id"]:
            raise RuntimeError("host financial fixture values differ")
        operations = snapshot["operations"]
        frozen = [row for row in operations if row["frozen_request_json"] is not None]
        if len(operations) != 3 or len(frozen) != 1 or len({row["operation_id"] for row in operations}) != 3:
            raise RuntimeError("expected exactly three stable operations and one frozen request")
        frozen_row = frozen[0]
        body = json.loads(frozen_row["frozen_request_json"])
        command = body["operations"][0]
        if len(body["operations"]) != 1 or body["sync_epoch"] != source["epoch"] or body["client_id"] != source["client_id"] or command["operation_id"] != frozen_row["operation_id"] or command["entity_type"] != "book" or command["entity_id"] != source["book_id"] or frozen_row["attempt_count"] != 1:
            raise RuntimeError("frozen exact request binding mismatch")
        attachment = snapshot["attachments"]
        draft = json.loads(snapshot["draft_body"])
        if len(attachment) != 1 or attachment[0]["sha256"] != manifest["normal_sha256"] or attachment[0]["width"] != 3 or attachment[0]["height"] != 2 or attachment[0]["record"]["size_bytes"] != 77 or draft["ui"]["expression"] != "12+" or draft["payload"]["attachment_ids"] != [attachment[0]["record"]["id"]] or snapshot["draft_id"] != source["draft_id"]:
            raise RuntimeError("original/draft exact reference mismatch")
        for name in ["picker-cancelled", "picker-oversized"]:
            receipt = read(f"device-{name}")
            if receipt["status"] != "passed" or receipt["snapshot_sha256"] != checksum or receipt["attachment_count"] != 1:
                raise RuntimeError(f"unchanged snapshot assertion failed: {name}")
        for name, field in [("host-select-normal", "normal_name"), ("host-select-oversized", "oversized_name")]:
            receipt = read(name)
            filename = receipt["filename"]
            if filename != manifest[field]:
                aliases = read("host-alias-files")
                row = [row for row in aliases["files"] if row["alias"] == filename and row["source_full_name"] == manifest[field]]
                if aliases["status"] != "passed" or len(row) != 1 or sha((self.directory / filename).read_bytes()) != row[0]["sha256"]:
                    raise RuntimeError("selected alias/source exact byte mapping mismatch")
            if receipt["system_picker"] is not True or receipt["selected_via_exact_name"] is not True or receipt["source_full_name"] != manifest[field]:
                raise RuntimeError("actual named picker evidence mismatch")
        if read("host-cancel")["system_picker"] is not True or read("host-cancel")["returned_to_app"] is not True or read("host-oversized-error")["status"] != "passed":
            raise RuntimeError("actual cancellation/rejection evidence missing")
        if reopened["status"] != "passed" or reopened["query_only"] is not True or reopened["reseeded"] is not False or str(reopened["old_pid"]) != restart["old_pid"] or str(reopened["pid"]) != restart["new_pid"] or restart["old_pid"] == restart["new_pid"] or "LaunchState: COLD" not in restart["start"] or restart["no_reinstall_between_ready_and_reopen"] is not True or reopened["attempt"] != 2:
            raise RuntimeError("OS process replacement/read-only evidence mismatch")
        write_new(self.directory / "host-final-receipt.json", {
            "run_id": self.args.run, "status": "passed", "device": manifest["device"]["tracking_name"],
            "system_picker": {"selected_exact_synthetic_png": True, "cancelled_unchanged": True, "oversized_application_rejected_unchanged": True},
            "os_force_stop_cold_reopen": True, "snapshot_sha256": checksum,
            "original_os_attempt_failed": True, "qa_apk_read_adapter_repaired_before_final_os_attempt": True,
            "no_reinstall_between_final_ready_and_reopen": True,
            "frozen_body_sha256": sha(frozen_row["frozen_request_json"].encode("utf-8")),
            "balance_minor": "9875", "attachment_sha256": manifest["normal_sha256"],
            "database_query_only": True, "reseeded": False, "network_tested": False,
        })
        print("Independent host receipts / exact amounts / frozen bytes / draft / original / OS process checks passed.")

    def cleanup_downloads(self) -> None:
        manifest = self.manifest()
        final = json.loads((self.directory / "host-final-receipt.json").read_text(encoding="utf-8"))
        if final["run_id"] != self.args.run or final["status"] != "passed":
            raise RuntimeError("Downloads cleanup requires passed exported final receipts")
        pushed = json.loads((self.directory / "host-push.json").read_text(encoding="utf-8"))
        aliases = json.loads((self.directory / "host-alias-files.json").read_text(encoding="utf-8"))
        expected = {row["name"]: row["sha256"] for row in pushed["files"]}
        expected.update({row["alias"]: row["sha256"] for row in aliases["files"]})
        if set(expected) != set(aliases["cleanup_exact_names"]) or len(expected) != 4:
            raise RuntimeError("cleanup registration must name exactly the four synthetic files")
        self.verify_device()
        for name, checksum in expected.items():
            if Path(name).name != name or not re.fullmatch(r"[A-Za-z0-9-]+\.png", name):
                raise RuntimeError("refusing unsafe Downloads path")
            actual = self.adb("shell", "sha256sum", f"/sdcard/Download/{name}").decode().split()[0]
            if actual != checksum:
                raise RuntimeError("synthetic device file changed; no cleanup performed")
        write_new(self.directory / "host-downloads-cleanup-intent.json", {"run_id": self.args.run, "files": expected, "fixture_private_directory_preserved": True})
        for name in expected:
            self.adb("shell", "rm", f"/sdcard/Download/{name}")
            if self.adb("shell", "ls", f"/sdcard/Download/{name}", check=False).strip():
                raise RuntimeError("exact synthetic Download file still exists")
        write_new(self.directory / "host-downloads-cleanup.json", {"run_id": self.args.run, "status": "passed", "exact_removed_names": list(expected), "fixture_private_directory_preserved": True, "unrelated_files_accessed": False})
        print("Only four registered unchanged synthetic Download files removed; private fixture preserved.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "push", "aliases", "install", "start", "normal-install", "normal-start", "tap", "picker-state", "search", "select", "navigate-back", "scroll-picker", "cancel", "assert-error", "screenshot", "export", "inspect-persisted", "restart", "validate", "cleanup-downloads"])
    parser.add_argument("--run", required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--adb", type=Path, default=DEFAULT_ADB)
    parser.add_argument("--aapt", type=Path, default=DEFAULT_AAPT)
    parser.add_argument("--apk")
    parser.add_argument("--label")
    parser.add_argument("--picker", action="store_true")
    parser.add_argument("--oversized", action="store_true")
    parser.add_argument("--alias", action="store_true")
    parser.add_argument("--repair", action="store_true")
    parser.add_argument("--recheck", action="store_true")
    parser.add_argument("--name")
    args = parser.parse_args()
    host = Host(args)
    if args.command == "tap":
        if not args.label:
            parser.error("tap requires --label")
        host.tap(args.label, picker=args.picker)
    else:
        getattr(host, args.command.replace("-", "_"))()


if __name__ == "__main__":
    main()
