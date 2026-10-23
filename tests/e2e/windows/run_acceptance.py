"""Launch only the specified standalone Windows QA package and isolated data root.

The host never handles passwords, personal profiles, ADB, or the ordinary app DB.
It intentionally terminates only its own child to prove OS lock release/reopen.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import subprocess
import time
import uuid
from pathlib import Path


def wait_for(directory: Path, pattern: str, process: subprocess.Popen, timeout: int = 45):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        failures = list(directory.glob(f"qa-failed-*-{process.pid}.json"))
        if failures:
            raise RuntimeError(failures[0].read_text(encoding="utf-8"))
        for candidate in directory.glob(pattern):
            try:
                value = json.loads(candidate.read_text(encoding="utf-8"))
                if value.get("pid") == process.pid:
                    return candidate, value
            except (json.JSONDecodeError, PermissionError):
                pass
        if process.poll() is not None:
            raise RuntimeError(f"Owned QA process exited early: {process.returncode}")
        time.sleep(0.2)
    raise TimeoutError(f"No receipt {pattern}; child PID {process.pid} remains owned")


def window_for_pid(pid: int):
    results = []
    callback_type = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
    user32 = ctypes.windll.user32
    user32.EnumWindows.argtypes = [callback_type, ctypes.c_void_p]
    user32.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
    user32.IsWindowVisible.argtypes = [ctypes.c_void_p]
    user32.GetWindowTextLengthW.argtypes = [ctypes.c_void_p]
    user32.GetWindowTextW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]

    @callback_type
    def callback(handle, _):
        owner = ctypes.c_ulong()
        user32.GetWindowThreadProcessId(handle, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(handle):
            length = user32.GetWindowTextLengthW(handle)
            text = ctypes.create_unicode_buffer(length + 1)
            user32.GetWindowTextW(handle, text, length + 1)
            if text.value:
                results.append(text.value)
        return True

    user32.EnumWindows(callback, None)
    return results


def wait_for_frame(directory: Path, build: str, process: subprocess.Popen):
    frame = directory / f"qa-frame-{build}-{process.pid}.png"
    end = time.monotonic() + 15
    while not frame.is_file() and time.monotonic() < end:
        time.sleep(0.1)
    if not frame.is_file():
        raise RuntimeError("Native rendered frame was not captured")
    titles = window_for_pid(process.pid)
    if "流迹 FlowTrace" not in titles:
        raise RuntimeError(f"Native visible window not observed for owned PID: {titles}")
    return frame, titles


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--run", required=True)
    parser.add_argument("--build", choices=("one", "two"), required=True)
    parser.add_argument("--reopen-only", action="store_true")
    parser.add_argument("--hold-for-inspection", action="store_true")
    args = parser.parse_args()
    run = str(uuid.UUID(args.run))
    if run != args.run or uuid.UUID(run).version != 4:
        raise ValueError("A canonical fresh UUID v4 is required")
    executable = args.exe.resolve(strict=True)
    root = args.output.resolve()
    directory = root / f"data-{run}"
    directory.mkdir(parents=True, exist_ok=True)
    receipt_path = root / f"host-{args.build}-{uuid.uuid4()}.json"
    command = [str(executable), f"--flowtrace-data-dir={directory}"]
    if not args.reopen_only and (directory / "qa-manifest.json").exists():
        raise ValueError("Existing fixture must use --reopen-only; no reseeding")
    if args.reopen_only and not (directory / "qa-ready.json").is_file():
        raise ValueError("Missing original fixture; no reseeding")
    children = []
    observations = []
    try:
        process = subprocess.Popen(command, cwd=executable.parent)
        children.append(process)
        pattern = f"qa-reopened-{args.build}-{process.pid}.json" if args.reopen_only else "qa-ready.json"
        receipt, value = wait_for(directory, pattern, process)
        frame, titles = wait_for_frame(directory, args.build, process)
        observations.append({"receipt": str(receipt), "pid": process.pid, "window_titles": titles, "frame": str(frame), "snapshot_sha256": value["snapshot_sha256"]})
        second = subprocess.Popen(command, cwd=executable.parent)
        children.append(second)
        second_code = second.wait(timeout=15)
        if second_code != 73:
            raise RuntimeError(f"Second writer was not rejected: {second_code}")
        observations[-1]["second_writer_exit"] = second_code
        if not args.reopen_only:
            process.kill()
            terminated = process.wait(timeout=15)
            process = subprocess.Popen(command, cwd=executable.parent)
            children.append(process)
            reopened_path, reopened = wait_for(directory, f"qa-reopened-{args.build}-{process.pid}.json", process)
            if reopened["snapshot_sha256"] != value["snapshot_sha256"]:
                raise RuntimeError("OS termination/reopen changed preserved business data")
            reopened_frame, reopened_titles = wait_for_frame(directory, args.build, process)
            observations.append({"receipt": str(reopened_path), "pid": process.pid, "old_process_exit": terminated, "snapshot_sha256": reopened["snapshot_sha256"], "frame": str(reopened_frame), "window_titles": reopened_titles, "os_termination_not_system_reboot": True})
        output = {"status": "passed", "run": run, "build": args.build, "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(), "observations": observations, "system_reboot_tested": False, "network_tested": False}
        receipt_path.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps({"status": "passed", "host_receipt": str(receipt_path), "data_directory": str(directory)}, ensure_ascii=False))
        if args.hold_for_inspection:
            input('Owned QA window is available for official Computer Use inspection. Press Enter to terminate only owned children.\n')
    except Exception as error:
        receipt_path.write_text(json.dumps({"status": "failed", "run": run, "build": args.build, "error": str(error), "observations": observations}, ensure_ascii=False, indent=2), encoding="utf-8")
        raise
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=15)


if __name__ == "__main__":
    main()
