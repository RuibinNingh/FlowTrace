"""Serve the already-built normal client on the isolated loopback QA port."""

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
    directory = Path(__file__).resolve().parents[3] / "apps/flowtrace/build/web"
    if not (directory / "main.dart.js").is_file():
        raise SystemExit("Build the normal main Web client before serving it")
    ThreadingHTTPServer(
        ("127.0.0.1", 18181), partial(Handler, directory=directory)
    ).serve_forever()
