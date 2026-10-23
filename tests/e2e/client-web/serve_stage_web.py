"""Serve one fixed sealed ordinary stage candidate on owned loopback 18194."""

import argparse
import hashlib
import json
import re
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class StageWebHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, format, *args):
        return


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--build", required=True, type=Path)
    parser.add_argument("--main-sha256", required=True)
    args = parser.parse_args()
    fixture_path = args.fixture.resolve(strict=True)
    build = args.build.resolve(strict=True)
    if (
        not fixture_path.is_relative_to(ROOT / "work/flowtrace-stage/live")
        or fixture_path.name != "client-config.json"
        or not build.is_relative_to(ROOT / "apps/flowtrace/build")
        or not re.fullmatch(r"[0-9a-f]{64}", args.main_sha256)
    ):
        raise SystemExit("fixed_owned_stage_candidate_required")
    fixture = json.loads(fixture_path.read_text("utf-8"))
    if (
        fixture.get("purpose") != "flowtrace-stage-tcp-normal-client-synthetic-v1"
        or fixture.get("web_origin") != "http://127.0.0.1:18194"
        or fixture.get("genuine_main_stage_and_group") is not True
        or not (build / "flowtrace-release.json").is_file()
        or hashlib.sha256((build / "main.dart.js").read_bytes()).hexdigest()
        != args.main_sha256
    ):
        raise SystemExit("seeded_fixture_and_exact_sealed_build_required")
    server = ThreadingHTTPServer(
        ("127.0.0.1", 18194), partial(StageWebHandler, directory=str(build))
    )
    print("owned_stage_web_ready", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
