"""Only OS-registered provider IDs can cause outbound connection checks.

No management form supplies URLs, paths, arbitrary headers, or probe methods.
Responses expose fixed status codes and elapsed time, never bodies/endpoints.
"""

from dataclasses import dataclass, field
from http.client import HTTPException
from time import monotonic
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

from flowtrace_server.config import Settings

from .secrets import SecretStorageError, SecretVault

PROVIDERS = {"ocr_primary": ("ocr_api_key", "health"), "ai_primary": ("ai_api_key", "models")}


class _NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        return None


@dataclass(frozen=True)
class RegisteredProvider:
    identity: str
    endpoint: str = field(repr=False)
    secret_field: str
    probe_path: str


class ProviderRegistry:
    def __init__(self, settings: Settings):
        self._providers = {
            key: RegisteredProvider(key, value.get_secret_value(), *PROVIDERS[key])
            for key, value in settings.provider_endpoints.items()
        }

    def contains(self, identity: str) -> bool:
        return identity in self._providers

    def public_catalog(self):
        return [{"provider_id": key, "registered": key in self._providers} for key in PROVIDERS]

    def check(self, identity: str, vault: SecretVault, references: dict):
        started = monotonic()

        def result(code):
            return {
                "provider_id": identity if identity in PROVIDERS else "unknown",
                "code": code,
                "duration_ms": round((monotonic() - started) * 1000),
            }

        provider = self._providers.get(identity)
        if provider is None:
            return result("provider_not_registered")
        reference = references.get(provider.secret_field)
        if reference is None:
            return result("provider_secret_missing")
        try:
            token = vault.read(reference, provider.secret_field).get_secret_value()
        except SecretStorageError:
            return result("provider_secret_unavailable")
        # No ambient desktop proxy/cookies, redirects, response-body parsing,
        # or inherited authentication. Socket timeout is not a DNS hard kill.
        try:
            request = Request(
                provider.endpoint.rstrip("/") + "/" + provider.probe_path,
                headers={"Authorization": "Bearer " + token, "Accept": "application/json"},
                method="GET",
            )
            opener = build_opener(ProxyHandler({}), _NoRedirects())
            with opener.open(request, timeout=5) as response:
                code = "provider_reachable" if response.status == 200 else "provider_unavailable"
        except HTTPError as error:
            try:
                code = (
                    "provider_authentication_failed"
                    if error.code in {401, 403}
                    else "provider_rate_limited"
                    if error.code == 429
                    else "provider_redirect_rejected"
                    if 300 <= error.code < 400
                    else "provider_unavailable"
                )
            finally:
                error.close()
        except (URLError, OSError, ValueError, HTTPException):
            code = "provider_unavailable"
        return result(code)
