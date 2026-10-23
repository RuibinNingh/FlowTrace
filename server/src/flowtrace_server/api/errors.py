from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException

from flowtrace_server.diagnostics import request_id_context


class ServiceUnavailable(Exception):
    """Public response never contains a database error or DSN."""


def error_response(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(
        status_code=status,
        content={
            "error": {
                "code": code,
                "message": message,
                "request_id": request_id_context.get() or "unavailable",
                "details": {},
            }
        },
        headers={"Cache-Control": "no-store"},
    )


async def unavailable_handler(request: Request, exc: ServiceUnavailable) -> JSONResponse:
    return error_response(503, "service_unavailable", "服务暂不可用")


async def validation_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    return error_response(422, "validation_error", "输入不符合接口约定")


async def http_handler(request: Request, exc: HTTPException) -> JSONResponse:
    codes = {404: ("not_found", "资源不存在"), 405: ("method_not_allowed", "请求方法不支持")}
    code, message = codes.get(exc.status_code, ("request_rejected", "请求被拒绝"))
    return error_response(exc.status_code, code, message)
