"""Serve only the synthetic storage probe, with the production isolation headers."""

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
    directory = Path(__file__).resolve().parents[3] / "work/flowtrace-dev/web-transaction-probe"
    ThreadingHTTPServer(
        ("127.0.0.1", 18184), partial(Handler, directory=directory)
    ).serve_forever()
