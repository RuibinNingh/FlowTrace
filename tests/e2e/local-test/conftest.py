"""Small sealed synthetic resources; no ordinary application acceptance claim."""

import hashlib
import json

import pytest


@pytest.fixture
def sealed_web(tmp_path):
    root = tmp_path / "synthetic-web"
    root.mkdir()
    resources = {
        "index.html": b"<!doctype html><title>synthetic FlowTrace shell</title>",
        "main.dart.js": b"console.log('synthetic, not an application build');",
        "sqlite3.wasm": b"\0asm\x01\0\0\0",
        "drift_worker.js": b"// synthetic worker",
        "flowtrace_shell.js": b"// synthetic shell",
        "flutter_bootstrap.js": b"// synthetic bootstrap",
    }
    for name, content in resources.items():
        (root / name).write_bytes(content)
    manifest = {
        "schema": 1,
        "release_id": hashlib.sha256(b"synthetic-release").hexdigest(),
        "resources": {
            name: {"bytes": len(content), "sha256": hashlib.sha256(content).hexdigest()}
            for name, content in resources.items()
        },
    }
    encoded = json.dumps(manifest, sort_keys=True, separators=(",", ":"))
    (root / "flowtrace-release.json").write_text(encoded, encoding="utf-8")
    (root / "flutter_service_worker.js").write_text(
        "'use strict';\nconst RELEASE = " + encoded + ";\n", encoding="utf-8"
    )
    return root, manifest
