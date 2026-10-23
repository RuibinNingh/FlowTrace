"""Offline Python tests for immutable, complete release construction."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("seal_release", Path(__file__).with_name("seal_release.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
SOURCE = Path(__file__).resolve().parents[2] / "web"


class SealReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.build = Path(self.temp.name)
        for name in module.REQUIRED:
            (self.build / name).write_text("fixture", encoding="utf-8")
        (self.build / "index.html").write_text('<script src="flowtrace_shell.js"></script>', encoding="utf-8")
        (self.build / "flowtrace_shell.js").write_text((SOURCE / "flowtrace_shell.js").read_text(encoding="utf-8"), encoding="utf-8")

    def test_hashes_cover_final_bytes(self):
        manifest = module.seal(self.build, SOURCE)
        for name, metadata in manifest["resources"].items():
            actual = (self.build / name).read_bytes()
            self.assertEqual(metadata["sha256"], module.digest(actual))
            self.assertEqual(metadata["bytes"], len(actual))
        self.assertIn(manifest["release_id"], (self.build / "flowtrace_shell.js").read_text(encoding="utf-8"))
        self.assertNotIn("__FLOWTRACE_MANIFEST__", (self.build / "flutter_service_worker.js").read_text(encoding="utf-8"))

    def test_resealing_is_rejected_without_changes(self):
        module.seal(self.build, SOURCE)
        before = {p.name: p.read_bytes() for p in self.build.iterdir()}
        with self.assertRaisesRegex(ValueError, "immutable"):
            module.seal(self.build, SOURCE)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.build.iterdir()})

    def test_missing_required_resource_rejected(self):
        (self.build / "sqlite3.wasm").unlink()
        with self.assertRaisesRegex(ValueError, "Missing required"):
            module.seal(self.build, SOURCE)
        self.assertFalse((self.build / "flowtrace-release.json").exists())

    def test_loader_may_not_register_default_worker(self):
        (self.build / "flutter_bootstrap.js").write_text(
            '_flutter.loader.load({serviceWorkerSettings: {serviceWorkerVersion: "old"}});'
        )
        with self.assertRaisesRegex(ValueError, "default service worker"):
            module.seal(self.build, SOURCE)

    def test_legacy_loader_may_not_register_default_worker(self):
        (self.build / "flutter_bootstrap.js").write_text(
            '_flutter.loader.loadEntrypoint({serviceWorker: {serviceWorkerVersion: "old"}});'
        )
        with self.assertRaisesRegex(ValueError, "default service worker"):
            module.seal(self.build, SOURCE)

    def test_inlined_loader_supported_options_do_not_enable_default_worker(self):
        (self.build / "flutter_bootstrap.js").write_text(
            'class Loader {async load({serviceWorkerSettings:e,config:n}={}) {if(e) register(e);}};\n'
            '_flutter.loader.load({config: {canvasKitBaseUrl: "canvaskit/"}});'
        )
        self.assertTrue(module.seal(self.build, SOURCE)["release_id"])

    def test_bypass_shell_rejected(self):
        (self.build / "index.html").write_text('<script src="flutter_bootstrap.js"></script>')
        with self.assertRaisesRegex(ValueError, "boot through"):
            module.seal(self.build, SOURCE)

    def test_extra_resource_is_in_manifest(self):
        (self.build / "extra.bin").write_bytes(bytes(range(256)))
        manifest = module.seal(self.build, SOURCE)
        self.assertEqual(manifest["resources"]["extra.bin"]["bytes"], 256)

    def test_filename_with_url_fragment_rejected(self):
        (self.build / "ambiguous#name").write_text("fixture")
        with self.assertRaisesRegex(ValueError, "unambiguous"):
            module.seal(self.build, SOURCE)

    def test_worker_and_manifest_not_in_resource_cycle(self):
        (self.build / "flutter_service_worker.js").write_text("old generated worker")
        manifest = module.seal(self.build, SOURCE)
        self.assertNotIn("flutter_service_worker.js", manifest["resources"])
        parsed = json.loads((self.build / "flowtrace-release.json").read_text())
        self.assertEqual(parsed, manifest)


if __name__ == "__main__":
    unittest.main()
