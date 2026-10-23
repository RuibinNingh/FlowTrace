"""Serve only the already-built normal P4 client, preserving the P3 build."""

from argparse import ArgumentParser
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


if __name__ == "__main__":
    parser = ArgumentParser(description=__doc__)
    parser.add_argument(
        "--build-directory",
        choices=(
            "web-p4", "web-p4-semantics", "web-p4-fonts", "web-p4-logout",
            "web-p4-auth-card",
        ),
        default="web-p4",
    )
    arguments = parser.parse_args()
    directory = (
        Path(__file__).resolve().parents[3]
        / "apps/flowtrace/build"
        / arguments.build_directory
    )
    if not (directory / "main.dart.js").is_file():
        raise SystemExit("The explicitly selected normal-main build is missing")
    ThreadingHTTPServer(
        ("127.0.0.1", 18185), partial(Handler, directory=directory)
    ).serve_forever()
