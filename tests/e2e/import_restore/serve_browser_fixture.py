"""Serve a fresh synthetic fixture and a fixed sealed normal Web build."""

import argparse
import hashlib
import json
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

import uvicorn
from dotenv import dotenv_values
from flowtrace_server.config import Settings
from flowtrace_server.main import create_app
from flowtrace_server.persistence.testing import require_isolated_database

ROOT = Path(__file__).resolve().parents[3]
PURPOSE = "flowtrace-data-tools-normal-browser-synthetic"


class WebHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, format, *args):
        # Request paths are unnecessary; the browser records fixed categories.
        return


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("api", "web"))
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--build", type=Path)
    parser.add_argument("--main-sha256")
    args = parser.parse_args()
    fixture = json.loads(args.fixture.read_text("utf-8"))
    if fixture.get("purpose") != PURPOSE:
        raise SystemExit("synthetic_fixture_required")
    api, web = map(urlsplit, (fixture["api_origin"], fixture["web_origin"]))
    if (
        api.hostname != "127.0.0.1"
        or web.hostname != "127.0.0.1"
        or api.port not in (18090, 18091)
        or web.port not in (18190, 18191)
    ):
        raise SystemExit("isolated_loopback_ports_required")
    if args.kind == "web":
        build = args.build.resolve()
        build.relative_to(ROOT / "apps/flowtrace/build")
        if (
            not (build / "flowtrace-release.json").is_file()
            or hashlib.sha256((build / "main.dart.js").read_bytes()).hexdigest()
            != args.main_sha256
        ):
            raise SystemExit("fixed_sealed_build_required")
        print("synthetic_web_ready", flush=True)
        ThreadingHTTPServer(
            ("127.0.0.1", web.port), partial(WebHandler, directory=build)
        ).serve_forever()
    else:
        env = dotenv_values(fixture["environment_file"])
        raw_url = env.get("FLOWTRACE_TEST_DATABASE_URL")
        url = require_isolated_database(raw_url, env.get("FLOWTRACE_ENVIRONMENT", ""))
        if (url.host, url.port, url.username) != ("127.0.0.1", 55432, "flowtrace_dev"):
            raise SystemExit("isolated_database_required")
        settings = Settings(
            _env_file=None,
            environment="test",
            database_url=raw_url,
            data_directory=Path(fixture["data_directory"]),
            cors_origins=[fixture["web_origin"]],
            diagnostics_enabled=False,
        )
        uvicorn.run(
            create_app(settings),
            host="127.0.0.1",
            port=api.port,
            access_log=False,
            log_level="warning",
        )


if __name__ == "__main__":
    main()
