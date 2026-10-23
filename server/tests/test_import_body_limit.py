import asyncio

import pytest

from flowtrace_server.api.middleware import RequestContextMiddleware


@pytest.mark.parametrize(
    "method,path,size,expected",
    [
        ("POST", "/api/v1/data-tools/imports/parse", 1024 * 1024 + 1, 204),
        ("POST", "/api/v1/data-tools/imports/parse", 5 * 1024 * 1024 + 65536, 204),
        ("POST", "/api/v1/data-tools/imports/parse", 5 * 1024 * 1024 + 65537, 413),
        ("PATCH", "/api/v1/data-tools/imports/parse", 1024 * 1024 + 1, 413),
        ("POST", "/api/v1/data-tools/imports/parse/", 1024 * 1024 + 1, 413),
        ("POST", "/api/v1/data-tools/exports/json", 1024 * 1024 + 1, 413),
    ],
)
def test_import_multipart_body_limit_is_exact(method, path, size, expected):
    async def run():
        messages, remaining, accepted = [], size, 0

        async def application(scope, receive, send):
            nonlocal accepted
            while True:
                message = await receive()
                accepted += len(message.get("body", b""))
                if not message.get("more_body", False):
                    break
            await send({"type": "http.response.start", "status": 204, "headers": []})
            await send({"type": "http.response.body", "body": b""})

        async def receive():
            nonlocal remaining
            chunk = min(remaining, 131072)
            remaining -= chunk
            return {"type": "http.request", "body": b"a" * chunk, "more_body": remaining > 0}

        async def send(message):
            messages.append(message)

        await RequestContextMiddleware(application)(
            {"type": "http", "method": method, "path": path, "headers": []}, receive, send
        )
        assert next(m["status"] for m in messages if m["type"] == "http.response.start") == expected
        assert accepted == (size if expected == 204 else 0)

    asyncio.run(run())
