"""Real loopback probes prove fixed paths, auth and redirect rejection."""

import threading
from http.client import InvalidURL
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import uuid4

import pytest
from pydantic import SecretStr, ValidationError

from flowtrace_server.config import Settings
from flowtrace_server.configuration.providers import ProviderRegistry
from flowtrace_server.configuration.secrets import SecretVault


@pytest.mark.parametrize(
    "endpoint",
    [
        "http://example.invalid/",
        "https://user:password@example.invalid/",
        "https://example.invalid/?token=private",
        "file:///private",
        "https://host:0/",
        "https://example.invalid/v1?",
        "https://example.invalid/v1#",
        "https://@example.invalid/v1",
        "https://example.invalid/private path",
        "https://example.invalid/private\tpath",
        "https://example.invalid/private\x1fpath",
        "https://example.invalid/private\x7fpath",
    ],
)
def test_operator_registry_rejects_unsafe_endpoints_without_echo(endpoint):
    with pytest.raises(ValidationError) as error:
        Settings(_env_file=None, provider_endpoints={"ai_primary": endpoint})
    assert endpoint not in str(error.value)
    with pytest.raises(ValidationError):
        Settings(_env_file=None, provider_endpoints={"arbitrary": "https://example.invalid"})


@pytest.mark.parametrize(
    "status,code",
    [
        (200, "provider_reachable"),
        (403, "provider_authentication_failed"),
        (429, "provider_rate_limited"),
        (302, "provider_redirect_rejected"),
    ],
)
def test_probe_uses_only_registered_fixed_path_and_never_follows_redirect(tmp_path, status, code):
    received = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            received.append((self.path, self.headers.get("Authorization")))
            self.send_response(status)
            self.send_header("Location", "/must-not-follow")
            self.end_headers()
            self.wfile.write(b"synthetic-private-response-must-not-be-returned")

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    endpoint = f"http://127.0.0.1:{server.server_port}/v1"
    try:
        settings = Settings(
            _env_file=None,
            environment="test",
            provider_endpoints={"ai_primary": SecretStr(endpoint)},
        )
        assert "provider_endpoints" not in settings.model_dump()
        assert endpoint not in repr(settings)
        registry = ProviderRegistry(settings)
        vault = SecretVault(tmp_path)
        prepared = vault.prepare(
            "ai_api_key",
            SecretStr("synthetic-check-token"),
            actor_id=uuid4(),
            base_version=0,
            request_id=uuid4(),
        )
        result = registry.check("ai_primary", vault, {"ai_api_key": prepared.reference})
        assert result["code"] == code and result["duration_ms"] >= 0
        assert received == [("/v1/models", "Bearer synthetic-check-token")]
        assert "synthetic" not in str(result) and endpoint not in str(result)
        assert registry.check("ocr_primary", vault, {})["code"] == "provider_not_registered"
        assert registry.check("ai_primary", vault, {})["code"] == "provider_secret_missing"
        assert len(received) == 1
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def test_protocol_error_never_escapes_as_a_private_endpoint_exception(tmp_path, monkeypatch):
    settings = Settings(
        _env_file=None,
        provider_endpoints={"ai_primary": SecretStr("https://registered.invalid/private-prefix")},
    )
    vault = SecretVault(tmp_path)
    prepared = vault.prepare(
        "ai_api_key",
        SecretStr("synthetic-no-network-key"),
        actor_id=uuid4(),
        base_version=0,
        request_id=uuid4(),
    )

    class ProtocolFailure:
        def open(self, *_args, **_kwargs):
            raise InvalidURL("synthetic-private-endpoint-must-not-escape")

    monkeypatch.setattr(
        "flowtrace_server.configuration.providers.build_opener", lambda *_: ProtocolFailure()
    )
    result = ProviderRegistry(settings).check(
        "ai_primary", vault, {"ai_api_key": prepared.reference}
    )
    assert result["code"] == "provider_unavailable"
    assert "private" not in str(result) and "synthetic" not in str(result)
