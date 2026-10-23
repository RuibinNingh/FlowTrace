from fastapi import Request
from fastapi.responses import RedirectResponse

from flowtrace_server.api.errors import error_response


class ApiError(Exception):
    def __init__(self, code: str, status: int = 403):
        self.code = code
        self.status = status


async def api_error_handler(request: Request, exc: ApiError):
    if request.url.path.startswith("/admin") and exc.status == 401:
        return RedirectResponse("/admin/login", status_code=303)
    messages = {
        401: "登录已失效或凭据不正确",
        403: "没有执行此操作的权限",
        409: "记录状态已变化",
        422: "输入不符合业务规则",
    }
    return error_response(exc.status, exc.code, messages.get(exc.status, "请求无法完成"))
