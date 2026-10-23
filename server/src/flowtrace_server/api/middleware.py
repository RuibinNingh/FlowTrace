import re
from time import monotonic
from uuid import uuid4

from starlette.concurrency import run_in_threadpool
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from flowtrace_server.api.errors import error_response
from flowtrace_server.diagnostics import event, request_id_context
from flowtrace_server.diagnostics.policy import bind_diagnostics


class RequestContextMiddleware:
    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        application = scope.get("app")
        policy = getattr(getattr(application, "state", None), "diagnostic_policy", None)
        with bind_diagnostics(policy):
            await self._http(scope, receive, send)

    async def _http(self, scope: Scope, receive: Receive, send: Send) -> None:
        request_id = str(uuid4())
        token = request_id_context.set(request_id)
        started = monotonic()
        status = 500
        response_started = False

        async def send_with_context(message: Message) -> None:
            nonlocal status, response_started
            if message["type"] == "http.response.start":
                status = message["status"]
                response_started = True
                headers = list(message.get("headers", []))
                headers.append((b"x-request-id", request_id.encode("ascii")))
                headers.append((b"cache-control", b"no-store"))
                message = {**message, "headers": headers}
            await send(message)

        try:
            raw_upload = (
                scope.get("method") == "PUT"
                and re.fullmatch(
                    r"/api/v1/attachments/uploads/[0-9a-fA-F-]{36}/content", scope.get("path", "")
                )
                is not None
            )
            if scope.get("method") in {"POST", "PUT", "PATCH", "DELETE"} and not raw_upload:
                limit = (
                    5 * 1024 * 1024 + 65536
                    if scope.get("method") == "POST"
                    and scope.get("path") == "/api/v1/data-tools/imports/parse"
                    else 1024 * 1024
                )
                body = bytearray()
                while True:
                    message = await receive()
                    if message["type"] == "http.disconnect":
                        return
                    chunk = message.get("body", b"")
                    if len(body) + len(chunk) > limit:
                        await error_response(413, "body_too_large", "请求内容过大")(
                            scope, receive, send_with_context
                        )
                        return
                    body.extend(chunk)
                    if not message.get("more_body", False):
                        break
                supplied = False

                async def replay_body() -> Message:
                    nonlocal supplied
                    if not supplied:
                        supplied = True
                        return {"type": "http.request", "body": bytes(body), "more_body": False}
                    return await receive()

                await self.app(scope, replay_body, send_with_context)
            else:
                await self.app(scope, receive, send_with_context)
        except Exception:
            await run_in_threadpool(event, "request_failed", code="internal_error")
            if not response_started:
                await error_response(500, "internal_error", "服务处理失败")(
                    scope, receive, send_with_context
                )
            else:
                # Future streaming endpoints must provide their own structured terminal status.
                await send({"type": "http.response.body", "body": b"", "more_body": False})
        finally:
            route = getattr(scope.get("route"), "path", "unmatched")
            await run_in_threadpool(
                event,
                "http_request",
                method=scope.get("method", "UNKNOWN"),
                route=route,
                status_code=status,
                duration_ms=round((monotonic() - started) * 1000, 3),
            )
            request_id_context.reset(token)
