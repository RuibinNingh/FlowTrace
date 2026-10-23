import re
import secrets
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urlencode
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, Request, Response
from fastapi.responses import RedirectResponse, StreamingResponse
from fastapi.templating import Jinja2Templates
from pydantic import ValidationError
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from starlette.background import BackgroundTask
from starlette.concurrency import run_in_threadpool

from flowtrace_server import __version__
from flowtrace_server.admin import quarantine_cancel_pages, quarantine_pages, retention_pages
from flowtrace_server.admin.configuration_forms import (
    PUBLIC_FIELDS,
    SECRET_FIELDS,
)
from flowtrace_server.admin.configuration_forms import (
    parse_update as parse_configuration_update,
)
from flowtrace_server.admin.configuration_forms import (
    request_uuid as configuration_request_uuid,
)
from flowtrace_server.admin.configuration_forms import (
    version as configuration_version,
)
from flowtrace_server.admin.queries import (
    AuditFilters,
    export_audit,
    list_audit,
    list_users,
    overview_metadata,
    page_number,
)
from flowtrace_server.admin.service import (
    ADMIN_ROLES,
    audit,
    create_invite,
    lock_admin_control,
    reauthenticate_admin,
    require_admin,
    require_portal,
    require_recovery,
    reset_user_password,
    set_admin_roles,
    set_user_enabled,
)
from flowtrace_server.auth.dependencies import get_session
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import Invite, User, UserSession
from flowtrace_server.auth.router import require_origin
from flowtrace_server.auth.service import (
    PASSWORDS,
    assert_active_principal,
    authenticate_access,
    digest,
    issue_session,
    now,
    roles_for,
    secret,
    verify_password,
)
from flowtrace_server.backups import administration as backup_admin
from flowtrace_server.backups import quarantine_cancel, quarantine_submission, rehearsal, retention
from flowtrace_server.backups.leases import BackupLeaseError
from flowtrace_server.configuration import facade as configuration_facade
from flowtrace_server.configuration import service as configuration_service
from flowtrace_server.configuration.runtime import read_runtime_configuration
from flowtrace_server.configuration.schemas import ConfigurationRollbackCommand
from flowtrace_server.diagnostics.policy import current_policy
from flowtrace_server.diagnostics.store import DiagnosticStore
from flowtrace_server.jobs import administration as job_admin
from flowtrace_server.persistence.database import check_database
from flowtrace_server.persistence.models import ServerState

router = APIRouter(prefix="/admin", include_in_schema=False)
templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))


def utc_time(value: datetime, seconds: bool = False) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("An aware timestamp is required")
    return value.astimezone(UTC).strftime(
        "%Y-%m-%d %H:%M:%S UTC" if seconds else "%Y-%m-%d %H:%M UTC"
    )


templates.env.filters["utc_time"] = utc_time

JOB_KIND_LABELS = {
    "recurring_occurrence": "周期发生项",
    "installment_occurrence": "分期发生项",
    "import_preview": "导入预览",
    "import_apply": "导入执行",
    "export": "数据导出",
    "backup_create": "备份创建",
    "backup_verify": "备份校验",
    "restore_rehearsal": "隔离恢复演练",
    "backup_quarantine": "备份隔离",
}
JOB_STATUS_LABELS = {
    "pending": "待执行",
    "running": "执行中",
    "succeeded": "已完成",
    "retry_wait": "等待重试",
    "failed": "失败",
    "cancelled": "已取消",
}


def csrf(request: Request, token: str) -> None:
    require_origin(request)
    cookie = request.cookies.get("flowtrace_admin_csrf", "")
    if not token or not cookie or not secrets.compare_digest(token, cookie):
        raise ApiError("csrf_invalid", 403)


def administrator(request: Request, session: Session, *, portal: bool = False, owner: bool = False):
    raw = request.cookies.get("flowtrace_admin_session")
    if not raw:
        raise ApiError("admin_login_required", 401)
    principal = authenticate_access(session, raw, admin=True)
    if portal:
        require_portal(session, principal)
    else:
        require_admin(session, principal, owner=owner)
    request.state.admin_roles = roles_for(session, principal.user_id)
    request.state.admin_user_id = str(principal.user_id)
    if request.method in {"GET", "HEAD"}:
        assert_active_principal(session, principal)
        session.commit()
    if request.method not in {"GET", "HEAD"}:
        record = session.get(UserSession, principal.session_id)
        supplied = request.cookies.get("flowtrace_admin_csrf", "")
        if not supplied or not secrets.compare_digest(digest(supplied), record.csrf_hash):
            raise ApiError("csrf_invalid", 403)
    return principal


def render(request: Request, page: str, *, response_status: int = 200, **data):
    current_roles = getattr(request.state, "admin_roles", frozenset())
    return templates.TemplateResponse(
        request=request,
        name="panel.html",
        status_code=response_status,
        context={
            "page": page,
            "csrf_token": request.cookies.get("flowtrace_admin_csrf", ""),
            "current_time": now(),
            "current_roles": current_roles,
            "current_admin_user_id": getattr(request.state, "admin_user_id", None),
            "can_service": bool(current_roles.intersection({"server_owner", "service_admin"})),
            "can_owner": "server_owner" in current_roles,
            "can_recovery": "recovery_admin" in current_roles,
            "role_labels": {
                "server_owner": "服务器所有者",
                "service_admin": "服务管理员",
                "recovery_admin": "恢复管理员",
            },
            "job_kind_labels": JOB_KIND_LABELS,
            "job_status_labels": JOB_STATUS_LABELS,
            **data,
        },
    )


async def verified_form(request: Request, *, max_fields=20):
    form = await request.form(max_fields=max_fields, max_files=0)
    csrf(request, str(form.get("csrf_token", "")))
    return form


def mutate(session: Session, principal, action: str, target: UUID | None, callback):
    try:
        result = callback()
        session.commit()
        return result
    except ApiError as error:
        # The rejected action is rolled back in full before its fixed metadata
        # audit is committed. Passwords, arbitrary form fields and error text
        # are never persisted in that audit or returned as form values.
        session.rollback()
        audit(session, principal.user_id, action, target, succeeded=False, status=error.status)
        session.commit()
        raise


def failure_message(code: str) -> str:
    return {
        "reauthentication_failed": "当前管理密码验证失败，请重新输入。",
        "restore_target_unavailable": "部署未登记可用的隔离目标或恢复工具。",
        "restore_target_intent_conflict": "此目标已有恢复意图，请返回目标列表查看原任务。",
        "restore_preview_expired": "预览已过期，请为尚未使用的目标重新预览。",
        "restore_configuration_changed": "服务配置已改变，请重新预览。",
        "restore_target_not_empty": "隔离目标已有数据，已拒绝覆盖；现有资料会保留。",
        "restore_empty_target_changed": "目标状态已改变，已拒绝执行；现有资料会保留。",
        "restore_preview_identity_changed": "此预览属于其他管理身份或会话，请重新预览。",
        "password_input_invalid": "新密码需为12至256个字符，并且两次输入相同。",
        "last_admin_protected": "不能移除最后一个有效的可恢复管理身份。",
        "last_owner_protected": "至少需要保留一个已启用的服务器所有者。请先设置其他所有者。",
        "admin_owner_required": "只有服务器所有者可以修改管理账号。",
        "admin_forbidden": "当前角色没有执行此操作的权限。",
        "audit_export_filter_required": "导出最多5000条，请缩小筛选范围。",
        "job_already_completed": "任务已经完成，不能取消。",
        "job_not_retryable": "任务当前状态不允许重试，请刷新后核对。",
        "job_epoch_changed": "任务属于旧部署纪元，不能直接重试。",
        "job_handler_unavailable": "此任务类型尚无可执行处理器。",
        "job_occurrence_conflict": "同一请求已用于另一个备份，请重新选择目标。",
        "backup_reference_released": "该任务的备份保护已释放，请到备份页新建校验任务。",
        "backup_quarantine_control_required": (
            "请到备份保留页面核对原隔离任务，任务队列不能直接取消或重试。"
        ),
        "backup_quarantine_unavailable": "备份隔离执行器尚不可用，请稍后重新核对。",
        "backup_quarantine_new_preview_required": "请重新生成零删除预览，再核对隔离范围。",
        "backup_quarantine_already_claimed": "任务已被领取或状态已经变化，不能按未领取任务取消。",
        "backup_quarantine_effect_not_absent": (
            "发现隔离目录或文件状态变化，已保留现场，不能解除预留。"
        ),
        "backup_quarantine_cancel_phase_changed": "核验期间服务状态已变化，请重新核对任务。",
        "backup_quarantine_cancel_conflict": "取消请求与已有结果不一致，请核对原任务记录。",
        "backup_preview_expired": "预览已过期，请重新核对候选。",
        "backup_busy": "所选备份正在使用，请稍后重新核对。",
        "backup_control_conflict": "备份保护状态已变化，请刷新后重新核对。",
        "backup_package_changed": "备份声明或文件已变化，未完成登记，请重新核对。",
        "backup_unregistered": "该备份尚未显式登记，原包继续保留。",
        "backup_retention_selection_protected": "选定备份存在保护或状态变化，请重新查看候选。",
        "admin_recovery_required": "下载原始备份需要恢复管理员资格。",
        "backup_not_found": "备份清单或文件不存在。",
        "backup_file_hash_mismatch": "备份文件校验失败，未生成下载包。",
        "backup_file_size_mismatch": "备份文件大小不符，未生成下载包。",
        "backup_storage_unsafe": "备份包含不允许的链接或存储位置，已拒绝下载。",
        "backup_download_timeout": "备份打包超过时间限制，请检查服务存储后重试。",
        "backup_archive_too_large": "备份归档超过允许大小，未生成下载包。",
        "configuration_input_invalid": "配置输入不符合要求，请核对范围、处理方式和目标。",
        "configuration_target_confirmation_required": "请明确确认当前配置版本。",
        "configuration_version_conflict": "配置版本已变化，请刷新并重新核对后提交。",
        "configuration_request_conflict": "同一请求已用于不同的配置内容，请刷新后重新提交。",
        "configuration_rollback_target_invalid": "回滚目标不是当前版本之前的有效配置。",
        "configuration_secret_unavailable": "密钥资料当前不可用，请检查部署存储或替换当前密钥。",
        "provider_not_registered": "此服务尚未由部署环境登记，不能启用。",
        "provider_secret_missing": "此服务尚未配置密钥，不能启用。",
        "backup_tool_unavailable": "部署尚未登记可用的备份工具，无法排队创建。",
        "backup_source_changed": "服务恢复点已变化，请刷新并重新核对当前服务。",
        "confirmation_invalid": "目标确认不匹配，请刷新并重新核对。",
    }.get(code, "当前无法完成操作，请核对对象、权限和输入后重试。")


def configuration_data(request, session, principal):
    data = configuration_facade.read_admin_configuration(
        session, principal, request.app.state.settings
    )
    return {
        "config": data["configuration"],
        "secret_states": data["secret_states"],
        "configuration_fields": PUBLIC_FIELDS,
        "secret_fields": SECRET_FIELDS,
        "registered_providers": {
            item["provider_id"] for item in data["provider_catalog"] if item["registered"]
        },
        "provider_catalog": data["provider_catalog"],
        "request_id": uuid4(),
    }


def configuration_form_error(request, session, principal, error):
    return render(
        request,
        "configuration",
        response_status=error.status,
        error=failure_message(error.code),
        **configuration_data(request, session, principal),
    )


def closed_configuration_form(form, keys):
    if set(form) != set(keys) or any(len(form.getlist(key)) != 1 for key in form):
        raise ApiError("configuration_input_invalid", 422)


@router.get("/configuration")
def configuration_page(request: Request, session: Session = Depends(get_session)):
    principal = administrator(request, session)
    return render(
        request,
        "configuration",
        message="配置请求已处理，请核对当前版本。" if request.query_params.get("saved") else None,
        **configuration_data(request, session, principal),
    )


@router.post("/configuration/preview")
async def configuration_preview(request: Request, session: Session = Depends(get_session)):
    form = await verified_form(request)
    principal = administrator(request, session)
    try:
        parsed = parse_configuration_update(form, require_confirmation=False)
        data = configuration_data(request, session, principal)
        if data["config"].version != parsed.base_version:
            raise ApiError("configuration_version_conflict", 409)
        data["config"] = configuration_service.preview_configuration(
            session,
            principal,
            parsed.public_patch,
            effective_fields=data["config"].effective_fields,
        )
    except ValidationError:
        return configuration_form_error(
            request, session, principal, ApiError("configuration_input_invalid", 422)
        )
    except ApiError as error:
        return configuration_form_error(request, session, principal, error)
    return render(request, "configuration", preview=True, **data)


@router.post("/configuration")
async def configuration_save(request: Request, session: Session = Depends(get_session)):
    form = await verified_form(request)
    principal = administrator(request, session)
    try:
        parsed = parse_configuration_update(form)

        def apply():
            try:
                return configuration_facade.save_admin_configuration(
                    session,
                    principal,
                    request.app.state.settings,
                    base_version=parsed.base_version,
                    request_id=parsed.request_id,
                    public_patch=parsed.public_patch,
                    secret_changes=parsed.secret_changes,
                    password=parsed.password,
                )
            except ValidationError:
                raise ApiError("configuration_input_invalid", 422) from None

        result = await run_in_threadpool(
            mutate, session, principal, "configuration.update", parsed.request_id, apply
        )
    except ValidationError:
        session.rollback()
        return configuration_form_error(
            request, session, principal, ApiError("configuration_input_invalid", 422)
        )
    except ApiError as error:
        return configuration_form_error(request, session, principal, error)
    return RedirectResponse(f"/admin/configuration?saved={result.version}", status_code=303)


@router.get("/configuration/history")
def configuration_history(request: Request, session: Session = Depends(get_session)):
    principal = administrator(request, session)
    raw_cursor = request.query_params.get("before")
    before = configuration_version(raw_cursor) if raw_cursor is not None else None
    return render(
        request,
        "configuration_history",
        revisions=configuration_service.list_revisions(session, principal, before=before),
        current_version=configuration_service.read_configuration(session, principal).version,
    )


@router.get("/configuration/rollback/{target_version}")
def configuration_rollback_page(
    target_version: int, request: Request, session: Session = Depends(get_session)
):
    principal = administrator(request, session)
    data = configuration_data(request, session, principal)
    if target_version >= data["config"].version:
        raise ApiError("configuration_rollback_target_invalid", 422)
    return render(
        request,
        "configuration_rollback",
        target_version=target_version,
        target=configuration_service.read_revision(session, principal, target_version),
        **data,
    )


@router.post("/configuration/rollback/{target_version}")
async def configuration_rollback(
    target_version: int, request: Request, session: Session = Depends(get_session)
):
    form = await verified_form(request)
    principal = administrator(request, session)
    closed_configuration_form(
        form, {"csrf_token", "base_version", "request_id", "current_password", "confirm_target"}
    )
    if form["confirm_target"] != str(target_version):
        raise ApiError("configuration_target_confirmation_required", 422)
    try:
        command = ConfigurationRollbackCommand(
            base_version=configuration_version(form["base_version"]),
            target_version=target_version,
            request_id=configuration_request_uuid(form["request_id"]),
        )
    except ValidationError:
        raise ApiError("configuration_input_invalid", 422) from None

    def apply():
        return configuration_facade.rollback_admin_configuration(
            session,
            principal,
            request.app.state.settings,
            command=command,
            password=form["current_password"],
        )

    try:
        result = await run_in_threadpool(
            mutate, session, principal, "configuration.rollback", command.request_id, apply
        )
    except ApiError as error:
        return render(
            request,
            "configuration_rollback",
            response_status=error.status,
            error=failure_message(error.code),
            target_version=target_version,
            target=configuration_service.read_revision(session, principal, target_version),
            **configuration_data(request, session, principal),
        )
    return RedirectResponse(f"/admin/configuration?saved={result.version}", status_code=303)


@router.get("/configuration/providers")
def configuration_providers(request: Request, session: Session = Depends(get_session)):
    principal = administrator(request, session)
    return render(
        request, "configuration_providers", **configuration_data(request, session, principal)
    )


@router.post("/configuration/providers/{provider_id}/check")
async def configuration_provider_check(
    provider_id: str, request: Request, session: Session = Depends(get_session)
):
    form = await verified_form(request)
    principal = administrator(request, session)
    closed_configuration_form(
        form, {"csrf_token", "expected_version", "current_password", "confirm_provider"}
    )
    if form["confirm_provider"] != provider_id:
        raise ApiError("configuration_target_confirmation_required", 422)
    try:
        expected = configuration_version(form["expected_version"])

        def apply():
            return configuration_facade.check_admin_provider(
                session,
                principal,
                request.app.state.settings,
                provider_id=provider_id,
                expected_version=expected,
                password=form["current_password"],
            )

        result = await run_in_threadpool(
            mutate, session, principal, "configuration.connection_check", principal.user_id, apply
        )
    except ApiError as error:
        return render(
            request,
            "configuration_providers",
            response_status=error.status,
            error=failure_message(error.code),
            **configuration_data(request, session, principal),
        )
    return render(
        request,
        "configuration_providers",
        provider_result=result,
        **configuration_data(request, session, principal),
    )


@router.get("")
def entry():
    return RedirectResponse("/admin/overview", status_code=303)


@router.get("/login")
def login_page(request: Request):
    token = secret()
    response = templates.TemplateResponse(
        request=request, name="login.html", context={"csrf_token": token, "error": None}
    )
    response.set_cookie(
        "flowtrace_admin_csrf",
        token,
        max_age=8 * 3600,
        path="/admin",
        httponly=True,
        secure=request.app.state.settings.environment == "production",
        samesite="strict",
    )
    return response


@router.post("/login")
async def login(request: Request, session: Session = Depends(get_session)):
    form = await verified_form(request)
    username, password = str(form.get("username", "")).lower(), str(form.get("password", ""))
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]{2,63}", username) or not 12 <= len(password) <= 256:
        raise ApiError("invalid_credentials", 401)
    try:
        user = verify_password(session, username, password, admin=True)
    except ApiError:
        return templates.TemplateResponse(
            request=request,
            name="login.html",
            status_code=401,
            context={
                "csrf_token": request.cookies.get("flowtrace_admin_csrf"),
                "error": "账号或密码不正确，或没有后台访问权限。",
            },
        )
    _, tokens = issue_session(session, user, uuid4(), "管理浏览器", "admin")
    audit(session, user.id, "admin.login", user.id)
    session.commit()
    response = RedirectResponse("/admin/overview", status_code=303)
    secure = request.app.state.settings.environment == "production"
    response.set_cookie(
        "flowtrace_admin_session",
        tokens["access_token"],
        max_age=8 * 3600,
        httponly=True,
        secure=secure,
        samesite="strict",
        path="/admin",
    )
    response.set_cookie(
        "flowtrace_admin_csrf",
        tokens["csrf_token"],
        max_age=8 * 3600,
        httponly=True,
        secure=secure,
        samesite="strict",
        path="/admin",
    )
    return response


@router.post("/logout")
async def logout(request: Request, session: Session = Depends(get_session)):
    await verified_form(request)
    principal = administrator(request, session, portal=True)
    record = assert_active_principal(session, principal)
    record.revoked_at = now()
    audit(session, principal.user_id, "admin.logout", principal.user_id)
    session.commit()
    response = RedirectResponse("/admin/login", status_code=303)
    response.delete_cookie("flowtrace_admin_session", path="/admin")
    response.delete_cookie("flowtrace_admin_csrf", path="/admin")
    return response


@router.get("/overview")
def overview(request: Request, session: Session = Depends(get_session)):
    principal = administrator(request, session, portal=True)
    check_database(request.app.state.engine)
    counts = {
        "users": session.scalar(select(func.count()).select_from(User)),
        "sessions": session.scalar(
            select(func.count())
            .select_from(UserSession)
            .join(User, User.id == UserSession.user_id)
            .where(
                User.enabled.is_(True),
                UserSession.revoked_at.is_(None),
                UserSession.expires_at > now(),
                UserSession.idle_expires_at > now(),
            )
        ),
        "invites": session.scalar(
            select(func.count())
            .select_from(Invite)
            .where(
                Invite.consumed_by.is_(None), Invite.revoked_at.is_(None), Invite.expires_at > now()
            )
        ),
    }
    try:
        attachments_state = (
            "可访问" if request.app.state.settings.data_directory.is_dir() else "尚未创建"
        )
    except OSError:
        attachments_state = "无法访问"
    return render(
        request,
        "overview",
        counts=counts,
        username=session.get(User, principal.user_id).username,
        version=__version__,
        operational=overview_metadata(session),
        attachments_state=attachments_state,
        workers=job_admin.list_workers(session, principal),
        latest_backup_success=backup_admin.latest_success(session, principal),
    )


@router.get("/backups")
def backups(request: Request, session: Session = Depends(get_session)):
    principal = administrator(request, session, portal=True)
    raw_cursor = request.query_params.get("before", "")
    try:
        before = UUID(raw_cursor) if raw_cursor else None
    except ValueError:
        raise ApiError("backup_input_invalid", 422) from None
    data = backup_admin.list_backups(session, principal, request.app.state.settings, before=before)
    return render(
        request,
        "backups",
        **data,
        next_url="/admin/backups?" + urlencode({"before": data["next_cursor"]}),
        can_create_backup="backup_create" in job_admin.executable_kinds(request.app.state.settings),
    )


def backup_creation_data(request, session):
    source = session.get(ServerState, 1)
    if source is None:
        raise ApiError("backup_source_changed", 409)
    return {
        "request_id": uuid4(),
        "source_instance": source.instance_id,
        "source_epoch": source.sync_epoch,
        "server_version": __version__,
        "tool_available": "backup_create" in job_admin.executable_kinds(request.app.state.settings),
    }


def retention_rejected(session, principal, error, target=None):
    session.rollback()
    audit(
        session,
        principal.user_id,
        "backup.retention_rejected",
        target,
        succeeded=False,
        status=error.status,
    )
    session.commit()
    assert_active_principal(session, principal, lock=False)
    require_recovery(session, principal)


def retention_actor(request, session):
    principal = administrator(request, session, portal=True)
    require_recovery(session, principal)
    return principal


@router.get("/backups/retention")
def backup_retention_page(request: Request, session: Session = Depends(get_session)):
    principal = administrator(request, session, portal=True)
    before = retention_pages.optional_cursor(request.query_params.get("before"))
    data = retention_pages.catalog_data(
        session, principal, request.app.state.settings, before=before
    )
    return render(request, "backup_retention", **data)


@router.get("/backups/{backup_id}/register")
def backup_registration_page(
    backup_id: UUID, request: Request, session: Session = Depends(get_session)
):
    principal = administrator(request, session, portal=True)
    data = retention_pages.registration_data(
        session, principal, request.app.state.settings, backup_id
    )
    return render(request, "backup_retention_register", **data)


@router.post("/backups/{backup_id}/register")
async def backup_registration(
    backup_id: UUID, request: Request, session: Session = Depends(get_session)
):
    form = await verified_form(request)
    principal = await run_in_threadpool(retention_actor, request, session)
    command = retention_pages.parse_registration(form, backup_id)
    settings = request.app.state.settings

    def precheck():
        retention_pages.precheck_registration(session, principal, command)
        session.commit()

    def finish(prepared):
        retention_pages.finish_registration(
            session, principal, settings, prepared=prepared, command=command
        )
        session.commit()

    prepared = None
    try:
        await run_in_threadpool(precheck)
        prepared = await run_in_threadpool(retention.prepare_registration, settings, backup_id)
        await run_in_threadpool(finish, prepared)
    except ApiError as error:
        await run_in_threadpool(retention_rejected, session, principal, error, backup_id)
        data = await run_in_threadpool(
            retention_pages.registration_data, session, principal, settings, backup_id
        )
        return render(
            request,
            "backup_retention_register",
            response_status=error.status,
            error=failure_message(error.code),
            **data,
        )
    finally:
        if prepared is not None:
            prepared.close()
    return RedirectResponse(f"/admin/backups/{backup_id}/protection", status_code=303)


@router.get("/backups/{backup_id}/protection")
def backup_protection_page(
    backup_id: UUID, request: Request, session: Session = Depends(get_session)
):
    principal = administrator(request, session, portal=True)
    after = retention_pages.optional_cursor(request.query_params.get("pins_after"))
    data = retention_pages.protection_data(session, principal, backup_id, pins_after=after)
    return render(request, "backup_retention_protection", **data)


@router.post("/backups/{backup_id}/pins")
async def backup_pin_create(
    backup_id: UUID, request: Request, session: Session = Depends(get_session)
):
    form = await verified_form(request)
    principal = await run_in_threadpool(retention_actor, request, session)
    command, password = retention_pages.parse_pin_create(form, backup_id)
    try:
        await run_in_threadpool(
            mutate,
            session,
            principal,
            "backup.pin_create_rejected",
            backup_id,
            lambda: retention_pages.create_pin(
                session, principal, command=command, password=password
            ),
        )
    except ApiError as error:
        data = await run_in_threadpool(
            retention_pages.protection_data, session, principal, backup_id
        )
        return render(
            request,
            "backup_retention_protection",
            response_status=error.status,
            error=failure_message(error.code),
            **data,
        )
    return RedirectResponse(f"/admin/backups/{backup_id}/protection", status_code=303)


@router.post("/backups/{backup_id}/pins/{pin_id}/release")
async def backup_pin_release(
    backup_id: UUID, pin_id: UUID, request: Request, session: Session = Depends(get_session)
):
    form = await verified_form(request)
    principal = await run_in_threadpool(retention_actor, request, session)
    command, password = retention_pages.parse_pin_release(form, pin_id)
    try:
        await run_in_threadpool(
            mutate,
            session,
            principal,
            "backup.pin_release_rejected",
            pin_id,
            lambda: retention_pages.release_pin(
                session, principal, backup_id=backup_id, command=command, password=password
            ),
        )
    except ApiError as error:
        data = await run_in_threadpool(
            retention_pages.protection_data, session, principal, backup_id
        )
        return render(
            request,
            "backup_retention_protection",
            response_status=error.status,
            error=failure_message(error.code),
            **data,
        )
    return RedirectResponse(f"/admin/backups/{backup_id}/protection", status_code=303)


@router.post("/backups/retention/preview")
async def backup_retention_preview(request: Request, session: Session = Depends(get_session)):
    form = await verified_form(request, max_fields=26)
    principal = await run_in_threadpool(retention_actor, request, session)
    selection, password = retention_pages.parse_preview(form)
    settings = request.app.state.settings

    def precheck():
        authority = retention.precheck_retention_request(
            session, principal, selection=selection, password=password
        )
        session.commit()
        return authority

    def authorize(prepared):
        result = retention.authorize_retention_preview(
            session, principal, settings, prepared=prepared, password=password
        )
        session.commit()
        return result

    prepared = None
    try:
        authority = await run_in_threadpool(precheck)
        prepared = await run_in_threadpool(
            retention.build_retention_preview, settings, authority=authority
        )
        result = await run_in_threadpool(authorize, prepared)
    except ApiError as error:
        await run_in_threadpool(retention_rejected, session, principal, error, selection.request_id)
        data = await run_in_threadpool(retention_pages.catalog_data, session, principal, settings)
        return render(
            request,
            "backup_retention",
            response_status=error.status,
            error=failure_message(error.code),
            **data,
        )
    finally:
        if prepared is not None:
            prepared.close()
    return render(
        request,
        "backup_retention_preview",
        quarantine_available="backup_quarantine" in job_admin.executable_kinds(settings),
        **retention_pages.preview_data(result),
    )


@router.get("/backups/retention/{preview_id}/quarantine")
def backup_quarantine_confirmation(
    preview_id: UUID, request: Request, session: Session = Depends(get_session)
):
    principal = retention_actor(request, session)
    settings = request.app.state.settings
    record = quarantine_submission.load_quarantine_preview(settings, preview_id)
    data = quarantine_pages.confirmation_data(session, principal, settings, record)
    return render(request, "backup_quarantine", **data)


@router.post("/backups/retention/{preview_id}/quarantine")
async def backup_quarantine_submission(
    preview_id: UUID, request: Request, session: Session = Depends(get_session)
):
    form = await verified_form(request)
    principal = await run_in_threadpool(retention_actor, request, session)
    command, password = quarantine_pages.parse_submission(form, preview_id)
    settings = request.app.state.settings

    def replay():
        result = quarantine_submission.replay_quarantine_submission(
            session, principal, command=command, password=password
        )
        session.commit()
        return result

    def precheck(record):
        quarantine_pages.require_executable(settings)
        authority = quarantine_submission.precheck_quarantine_submission(
            session, principal, settings, command=command, record=record, password=password
        )
        session.commit()
        return authority

    def prepare(authority):
        try:
            return quarantine_submission.prepare_quarantine_submission(
                settings, authority=authority
            )
        except BackupLeaseError:
            raise ApiError("backup_busy", 409) from None

    def enqueue(prepared):
        result = quarantine_submission.enqueue_quarantine_submission(
            session,
            principal,
            settings,
            prepared=prepared,
            command=command,
            password=password,
        )
        session.commit()
        return result

    prepared = None
    try:
        result = await run_in_threadpool(replay)
        if result is None:
            record = await run_in_threadpool(
                quarantine_submission.load_quarantine_preview, settings, preview_id
            )
            authority = await run_in_threadpool(precheck, record)
            prepared = await run_in_threadpool(prepare, authority)
            result = await run_in_threadpool(enqueue, prepared)
    except ApiError as error:
        await run_in_threadpool(retention_rejected, session, principal, error, preview_id)
        data = await run_in_threadpool(retention_pages.catalog_data, session, principal, settings)
        return render(
            request,
            "backup_retention",
            response_status=error.status,
            error=failure_message(error.code),
            **data,
        )
    finally:
        if prepared is not None:
            prepared.close()
    return RedirectResponse(
        f"/admin/jobs?kind=backup_quarantine#job-{result['job_id']}", status_code=303
    )


@router.get("/backups/retention/jobs/{job_id}/cancel-unclaimed")
def backup_quarantine_cancel_confirmation(
    job_id: UUID, request: Request, session: Session = Depends(get_session)
):
    principal = retention_actor(request, session)
    data = quarantine_cancel_pages.confirmation_data(
        session, principal, request.app.state.settings, job_id
    )
    return render(request, "backup_quarantine_cancel", **data)


@router.post("/backups/retention/jobs/{job_id}/cancel-unclaimed")
async def backup_quarantine_cancel_unclaimed(
    job_id: UUID, request: Request, session: Session = Depends(get_session)
):
    form = await verified_form(request)
    principal = await run_in_threadpool(retention_actor, request, session)
    command, password = quarantine_cancel_pages.parse_cancellation(form, job_id)
    settings = request.app.state.settings

    def replay():
        result = quarantine_cancel.replay_unclaimed_cancel(
            session, principal, command=command, password=password
        )
        session.commit()
        return result

    def precheck():
        authority = quarantine_cancel.precheck_unclaimed_cancel(
            session, principal, settings, command=command, password=password
        )
        session.commit()
        return authority

    def prepare(authority):
        try:
            return quarantine_cancel.prepare_unclaimed_cancel(settings, authority=authority)
        except BackupLeaseError:
            raise ApiError("backup_busy", 409) from None

    def cancel(prepared):
        result = quarantine_cancel.cancel_unclaimed_quarantine(
            session,
            principal,
            settings,
            prepared=prepared,
            command=command,
            password=password,
        )
        session.commit()
        return result

    prepared = None
    try:
        result = await run_in_threadpool(replay)
        if result is None:
            authority = await run_in_threadpool(precheck)
            prepared = await run_in_threadpool(prepare, authority)
            result = await run_in_threadpool(cancel, prepared)
    except ApiError as error:
        await run_in_threadpool(retention_rejected, session, principal, error, job_id)
        data = await run_in_threadpool(
            job_admin.list_jobs, session, principal, kind="backup_quarantine", settings=settings
        )
        return render(
            request,
            "jobs",
            response_status=error.status,
            error=failure_message(error.code),
            kind_filter="backup_quarantine",
            status_filter="",
            next_url="/admin/jobs?"
            + urlencode({"kind": "backup_quarantine", "before": data["next_cursor"]}),
            **data,
        )
    finally:
        if prepared is not None:
            prepared.close()
    return RedirectResponse(
        f"/admin/jobs?kind=backup_quarantine#job-{result['job_id']}", status_code=303
    )


def restore_input(value):
    try:
        identity = UUID(value)
        if str(identity) != value:
            raise ValueError
        return identity
    except (ValueError, TypeError, AttributeError):
        raise ApiError("restore_input_invalid", 422) from None


def restore_error(session, principal, error):
    session.rollback()
    audit(session, principal.user_id, "restore.rejected", succeeded=False, status=error.status)
    session.commit()
    assert_active_principal(session, principal, lock=False)
    require_recovery(session, principal)


@router.get("/restores")
def restores(request: Request, session: Session = Depends(get_session)):
    principal = administrator(request, session, portal=True)
    targets = rehearsal.list_restore_targets(session, principal, request.app.state.settings)
    return render(request, "restores", targets=targets, error=None)


@router.post("/restores/preview")
async def restore_preview(request: Request, session: Session = Depends(get_session)):
    form = await verified_form(request)
    principal = administrator(request, session, portal=True)
    require_recovery(session, principal)
    closed_configuration_form(form, {"csrf_token", "backup_id", "target_id", "current_password"})
    backup_id, target_id = restore_input(form["backup_id"]), restore_input(form["target_id"])
    settings = request.app.state.settings
    password = form["current_password"]

    def precheck():
        authority = rehearsal.precheck_restore_request(session, principal, password)
        targets = rehearsal.list_restore_targets(session, principal, settings)
        selected = next((item for item in targets if item["target_id"] == str(target_id)), None)
        if selected is None or not selected["tool_available"]:
            raise ApiError("restore_target_unavailable", 503)
        if selected["has_intent"]:
            raise ApiError("restore_target_intent_conflict", 409)
        session.commit()
        return authority

    def authorize(prepared):
        view = rehearsal.authorize_restore_preview(session, principal, settings, prepared, password)
        session.commit()
        return view

    def readable(identifier):
        retention.require_backup_readable(session, identifier)
        session.commit()  # Keep only the filesystem SH during target/hash I/O.

    prepared = None
    try:
        authority = await run_in_threadpool(precheck)
        prepared = await run_in_threadpool(
            rehearsal.build_restore_preview,
            settings,
            authority=authority,
            backup_id=backup_id,
            target_id=target_id,
            before_read=readable,
        )
        view = await run_in_threadpool(authorize, prepared)
    except ApiError as error:
        restore_error(session, principal, error)
        return render(
            request,
            "restores",
            response_status=error.status,
            targets=rehearsal.list_restore_targets(session, principal, settings),
            error=failure_message(error.code),
        )
    finally:
        if prepared is not None:
            prepared.close()
    return RedirectResponse(f"/admin/restores/previews/{view.preview_id}", status_code=303)


@router.get("/restores/previews/{preview_id}")
def restore_confirmation(
    preview_id: UUID, request: Request, session: Session = Depends(get_session)
):
    principal = administrator(request, session, portal=True)
    preview = rehearsal.read_restore_preview(
        session, principal, request.app.state.settings, preview_id
    )
    return render(request, "restore_confirm", preview=preview, error=None)


@router.post("/restores/previews/{preview_id}")
async def restore_confirm(
    preview_id: UUID, request: Request, session: Session = Depends(get_session)
):
    form = await verified_form(request)
    principal = administrator(request, session, portal=True)
    require_recovery(session, principal)
    closed_configuration_form(form, {"csrf_token", "current_password", "confirm_target"})
    if form["confirm_target"] != str(preview_id):
        raise ApiError("confirmation_invalid", 403)
    settings, password = request.app.state.settings, form["current_password"]
    prepared = None

    def replay():
        job = rehearsal.replay_restore_intent(
            session, principal, settings, preview_id=preview_id, password=password
        )
        session.commit()  # No source transaction during target/hash preparation.
        return job

    def enqueue():
        job = rehearsal.enqueue_restore_rehearsal(
            session, principal, settings, prepared=prepared, password=password
        )
        session.commit()  # Target lock remains held through this commit.
        return job

    def readable(identifier):
        retention.require_backup_readable(session, identifier)
        session.commit()  # Source SH is already held; target lock follows it.

    try:
        job = await run_in_threadpool(replay)
        if job is None:
            prepared = await run_in_threadpool(
                rehearsal.prepare_restore_submission,
                settings,
                owner_user_id=principal.user_id,
                session_id=principal.session_id,
                preview_id=preview_id,
                before_read=readable,
            )
            job = await run_in_threadpool(enqueue)
    except ApiError as error:
        restore_error(session, principal, error)
        preview = rehearsal.read_restore_preview(session, principal, settings, preview_id)
        return render(
            request,
            "restore_confirm",
            preview=preview,
            response_status=error.status,
            error=failure_message(error.code),
        )
    finally:
        if prepared is not None:
            prepared.close()
    return RedirectResponse(f"/admin/restores/jobs/{job['job_id']}", status_code=303)


@router.get("/restores/jobs/{job_id}")
def restore_status(job_id: UUID, request: Request, session: Session = Depends(get_session)):
    principal = administrator(request, session, portal=True)
    require_recovery(session, principal)
    job = job_admin.get_job(session, principal, job_id, settings=request.app.state.settings)
    if job["kind"] != "restore_rehearsal":
        raise ApiError("not_found", 404)
    return render(request, "restore_status", job=job)


@router.get("/backups/create")
def backup_create_page(request: Request, session: Session = Depends(get_session)):
    principal = administrator(request, session, portal=True)
    require_recovery(session, principal)
    data = backup_creation_data(request, session)
    return render(
        request,
        "backup_create",
        response_status=200 if data["tool_available"] else 503,
        **data,
    )


@router.post("/backups/create")
async def backup_create(request: Request, session: Session = Depends(get_session)):
    form = await verified_form(request)
    principal = administrator(request, session, portal=True)
    require_recovery(session, principal)
    closed_configuration_form(
        form, {"csrf_token", "request_id", "expected_epoch", "confirm_target", "current_password"}
    )
    try:
        request_id = UUID(form["request_id"])
        epoch = UUID(form["expected_epoch"])
        target = UUID(form["confirm_target"])
        if any(
            str(value) != form[key]
            for value, key in (
                (request_id, "request_id"),
                (epoch, "expected_epoch"),
                (target, "confirm_target"),
            )
        ):
            raise ValueError
    except (ValueError, TypeError, AttributeError):
        raise ApiError("backup_input_invalid", 422) from None

    def apply():
        source = session.get(ServerState, 1, populate_existing=True)
        if source is None or source.sync_epoch != epoch:
            raise ApiError("backup_source_changed", 409)
        if source.instance_id != target:
            raise ApiError("confirmation_invalid", 403)
        return job_admin.enqueue_backup_creation(
            session,
            principal,
            request.app.state.settings,
            request_id=request_id,
            password=form["current_password"],
        )

    try:
        job = await run_in_threadpool(
            mutate, session, principal, "job.backup_create_enqueue", request_id, apply
        )
    except ApiError as error:
        if error.status == 401:
            raise
        require_recovery(session, principal)
        return render(
            request,
            "backup_create",
            response_status=error.status,
            error=failure_message(error.code),
            **backup_creation_data(request, session),
        )
    return RedirectResponse(
        "/admin/jobs?" + urlencode({"kind": "backup_create", "created": job["job_id"]}),
        status_code=303,
    )


@router.get("/backups/{backup_id}/download")
def backup_download_page(
    backup_id: UUID, request: Request, session: Session = Depends(get_session)
):
    principal = administrator(request, session, portal=True)
    require_recovery(session, principal)
    target = backup_admin.get_backup(session, principal, request.app.state.settings, backup_id)
    return render(request, "backup_download", target=target, error=None)


@router.post("/backups/{backup_id}/download")
async def backup_download(
    backup_id: UUID, request: Request, session: Session = Depends(get_session)
):
    form = await verified_form(request)
    if set(form) - {"csrf_token", "current_password", "confirm_target"}:
        raise ApiError("backup_input_invalid", 422)
    principal = administrator(request, session, portal=True)
    if str(form.get("confirm_target", "")) != str(backup_id):
        raise ApiError("confirmation_invalid", 403)
    prepared = None
    password = str(form.get("current_password", ""))

    def preflight():
        backup_admin.precheck_download(session, principal, backup_id=backup_id, password=password)
        session.commit()  # End the read-only phase; no DB locks during filesystem work.

    def authorize():
        backup_admin.authorize_download(session, principal, prepared, password=password)
        session.commit()  # Only the final current authority can publish the response.

    def build():
        nonlocal prepared

        def readable():
            retention.require_backup_readable(session, backup_id)
            session.commit()  # The source SH outlives this short control gate.

        prepared = backup_admin.prepare_archive(
            request.app.state.settings, backup_id=backup_id, before_read=readable
        )
        return prepared

    try:
        await run_in_threadpool(preflight)
        await run_in_threadpool(build)
        await run_in_threadpool(authorize)
    except BaseException as error:
        if prepared is not None:
            prepared.close()
        session.rollback()
        if isinstance(error, ApiError):
            audit(
                session,
                principal.user_id,
                "backup.raw_download",
                backup_id,
                succeeded=False,
                status=error.status,
            )
            session.commit()
        if not isinstance(error, ApiError) or error.status == 401:
            raise
        require_recovery(session, principal)
        target = backup_admin.get_backup(session, principal, request.app.state.settings, backup_id)
        return render(
            request,
            "backup_download",
            target=target,
            error=failure_message(error.code),
            response_status=error.status,
        )
    return StreamingResponse(
        prepared.chunks(),
        media_type="application/zip",
        background=BackgroundTask(prepared.close),
        headers={
            "Content-Disposition": f'attachment; filename="{prepared.filename}"',
            "Content-Length": str(prepared.size_bytes),
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "private,no-store",
            "X-FlowTrace-Archive-SHA256": prepared.sha256,
        },
    )


@router.get("/jobs")
def jobs(request: Request, session: Session = Depends(get_session)):
    principal = administrator(request, session, portal=True)
    kind = request.query_params.get("kind", "")
    status = request.query_params.get("status", "")
    raw_cursor = request.query_params.get("before", "")
    try:
        before = UUID(raw_cursor) if raw_cursor else None
    except ValueError:
        raise ApiError("job_cursor_invalid", 422) from None
    data = job_admin.list_jobs(
        session,
        principal,
        kind=kind or None,
        status=status or None,
        before=before,
        settings=request.app.state.settings,
    )
    return render(
        request,
        "jobs",
        **data,
        kind_filter=kind,
        status_filter=status,
        next_url="/admin/jobs?"
        + urlencode({"kind": kind, "status": status, "before": data["next_cursor"]}),
    )


@router.get("/workers")
def workers(request: Request, session: Session = Depends(get_session)):
    principal = administrator(request, session, portal=True)
    return render(request, "workers", workers=job_admin.list_workers(session, principal))


@router.get("/jobs/{job_id}/{action}")
def job_control_page(
    job_id: UUID, action: str, request: Request, session: Session = Depends(get_session)
):
    if action not in {"retry", "cancel"}:
        raise ApiError("not_found", 404)
    principal = administrator(request, session, portal=True)
    job = job_admin.get_job(session, principal, job_id, settings=request.app.state.settings)
    if action not in job["allowed_actions"]:
        raise ApiError("job_action_unavailable", 409)
    return render(request, "job_control", job=job, action=action, error=None)


@router.post("/jobs/{job_id}/{action}")
async def job_control(
    job_id: UUID, action: str, request: Request, session: Session = Depends(get_session)
):
    if action not in {"retry", "cancel"}:
        raise ApiError("not_found", 404)
    form = await verified_form(request)
    principal = administrator(request, session, portal=True)
    if str(form.get("confirm_target", "")) != str(job_id):
        raise ApiError("confirmation_invalid", 403)
    try:
        mutate(
            session,
            principal,
            f"job.{action}",
            job_id,
            lambda: job_admin.control_job(
                session,
                principal,
                job_id=job_id,
                action=action,
                password=str(form.get("current_password", "")),
                settings=request.app.state.settings,
            ),
        )
    except ApiError as error:
        if error.status == 401:
            raise
        job = job_admin.get_job(session, principal, job_id, settings=request.app.state.settings)
        return render(
            request,
            "job_control",
            job=job,
            action=action,
            error=failure_message(error.code),
            response_status=error.status,
        )
    return RedirectResponse("/admin/jobs", status_code=303)


@router.get("/jobs/backup-verify")
def verify_backup_page(request: Request, session: Session = Depends(get_session)):
    principal = administrator(request, session, portal=True)
    require_recovery(session, principal)
    return render(request, "backup_verify", target_id=None, request_id=None, error=None)


@router.post("/jobs/backup-verify")
async def verify_backup_job(request: Request, session: Session = Depends(get_session)):
    form = await verified_form(request)
    principal = administrator(request, session, portal=True)
    require_recovery(session, principal)
    try:
        target_id = UUID(str(form.get("backup_id", "")))
    except ValueError:
        raise ApiError("job_input_invalid", 422) from None
    confirmed = str(form.get("confirm_target", ""))
    if not confirmed:
        return render(request, "backup_verify", target_id=target_id, request_id=uuid4(), error=None)
    if confirmed != str(target_id):
        raise ApiError("confirmation_invalid", 403)
    try:
        request_id = UUID(str(form.get("request_id", "")))
    except ValueError:
        raise ApiError("job_input_invalid", 422) from None
    try:
        mutate(
            session,
            principal,
            "job.backup_verify_enqueue",
            target_id,
            lambda: job_admin.enqueue_backup_verification(
                session,
                principal,
                backup_id=target_id,
                request_id=request_id,
                password=str(form.get("current_password", "")),
            ),
        )
    except ApiError as error:
        if error.status == 401:
            raise
        require_recovery(session, principal)
        return render(
            request,
            "backup_verify",
            target_id=target_id,
            request_id=request_id,
            error=failure_message(error.code),
            response_status=error.status,
        )
    return RedirectResponse("/admin/jobs?kind=backup_verify", status_code=303)


@router.get("/users")
def users(request: Request, session: Session = Depends(get_session)):
    administrator(request, session)
    data = list_users(
        session,
        query=request.query_params.get("q", ""),
        state=request.query_params.get("state", "all"),
        page=page_number(request.query_params.get("page", "1")),
    )
    parameters = {"q": data["query"], "state": data["state_filter"]}
    return render(
        request,
        "users",
        **data,
        previous_url="/admin/users?" + urlencode({**parameters, "page": data["page_number"] - 1}),
        next_url="/admin/users?" + urlencode({**parameters, "page": data["page_number"] + 1}),
    )


@router.get("/users/{user_id}/roles")
def roles_page(user_id: UUID, request: Request, session: Session = Depends(get_session)):
    administrator(request, session, owner=True)
    target = session.get(User, user_id)
    if target is None:
        raise ApiError("not_found", 404)
    return render(
        request,
        "roles",
        target=target,
        selected_roles=roles_for(session, user_id),
        available_roles=sorted(ADMIN_ROLES),
        error=None,
    )


@router.post("/users/{user_id}/roles")
async def roles_update(user_id: UUID, request: Request, session: Session = Depends(get_session)):
    form = await verified_form(request)
    principal = administrator(request, session, portal=True)
    if str(form.get("confirm_target", "")) != str(user_id):
        raise ApiError("confirmation_invalid", 403)
    selected = frozenset(str(role) for role in form.getlist("roles"))
    try:
        mutate(
            session,
            principal,
            "admin.roles_change",
            user_id,
            lambda: set_admin_roles(
                session, principal, user_id, selected, str(form.get("current_password", ""))
            ),
        )
    except ApiError as error:
        if error.status == 401:
            raise
        require_admin(session, principal, owner=True)
        target = session.get(User, user_id)
        if target is None:
            raise ApiError("not_found", 404) from None
        return render(
            request,
            "roles",
            target=target,
            selected_roles=roles_for(session, user_id),
            available_roles=sorted(ADMIN_ROLES),
            error=failure_message(error.code),
            response_status=error.status,
        )
    return RedirectResponse("/admin/users", status_code=303)


@router.get("/users/{user_id}/password")
def reset_page(user_id: UUID, request: Request, session: Session = Depends(get_session)):
    principal = administrator(request, session)
    target = session.get(User, user_id)
    if target is None:
        raise ApiError("not_found", 404)
    if roles_for(session, user_id) and "server_owner" not in roles_for(session, principal.user_id):
        raise ApiError("admin_owner_required", 403)
    return render(request, "reset_password", target=target, error=None)


@router.post("/users/{user_id}/password")
async def password_reset(user_id: UUID, request: Request, session: Session = Depends(get_session)):
    form = await verified_form(request)
    principal = administrator(request, session, portal=True)
    if str(form.get("confirm_target", "")) != str(user_id):
        raise ApiError("confirmation_invalid", 403)
    try:
        mutate(
            session,
            principal,
            "user.password_reset",
            user_id,
            lambda: reset_user_password(
                session,
                principal,
                user_id,
                str(form.get("current_password", "")),
                str(form.get("new_password", "")),
                str(form.get("repeat_password", "")),
            ),
        )
    except ApiError as error:
        if error.status == 401:
            raise
        require_admin(session, principal)
        target = session.get(User, user_id)
        if target is None:
            raise ApiError("not_found", 404) from None
        if roles_for(session, user_id) and "server_owner" not in roles_for(
            session, principal.user_id
        ):
            raise ApiError("admin_owner_required", 403) from None
        return render(
            request,
            "reset_password",
            target=target,
            error=failure_message(error.code),
            response_status=error.status,
        )
    return RedirectResponse(f"/admin/users/{user_id}/sessions", status_code=303)


@router.post("/users/{user_id}/enabled")
async def user_enabled(user_id: UUID, request: Request, session: Session = Depends(get_session)):
    form = await verified_form(request)
    principal = administrator(request, session)
    flag = str(form.get("enabled"))
    if flag not in {"true", "false"}:
        raise ApiError("enabled_flag_invalid", 422)
    target = session.get(User, user_id)
    if target is None:
        raise ApiError("not_found", 404)
    confirmed = str(form.get("confirm_target", ""))
    if not confirmed:
        return render(
            request,
            "confirm",
            target_display=target.username,
            confirmation_title="确认禁用账号" if flag == "false" else "确认启用账号",
            confirmation_text="禁用后，该账号的已有会话会撤销。"
            if flag == "false"
            else "启用后，该账号可重新登录。",
            action_url=f"/admin/users/{user_id}/enabled",
            confirmation_id=str(user_id),
            extra_fields={"enabled": flag},
            back_url="/admin/users",
        )
    if confirmed != str(user_id):
        raise ApiError("confirmation_invalid", 403)
    set_user_enabled(session, principal, user_id, flag == "true")
    session.commit()
    return RedirectResponse("/admin/users", status_code=303)


@router.get("/users/{user_id}/sessions")
def user_sessions(user_id: UUID, request: Request, session: Session = Depends(get_session)):
    administrator(request, session)
    user = session.get(User, user_id)
    if user is None:
        raise ApiError("not_found", 404)
    return render(
        request,
        "sessions",
        target=user,
        sessions=list(
            session.scalars(
                select(UserSession)
                .where(UserSession.user_id == user_id)
                .order_by(UserSession.created_at.desc())
            )
        ),
    )


@router.post("/sessions/{session_id}/revoke")
async def revoke_session(
    session_id: UUID, request: Request, session: Session = Depends(get_session)
):
    form = await verified_form(request)
    principal = administrator(request, session)
    target = session.get(UserSession, session_id)
    if target is None:
        raise ApiError("not_found", 404)
    confirmed = str(form.get("confirm_target", ""))
    if not confirmed:
        user = session.get(User, target.user_id)
        return render(
            request,
            "confirm",
            target_display=f"{user.username} · {target.device_name}",
            confirmation_title="确认撤销会话",
            confirmation_text="该设备下次访问需要重新登录。",
            action_url=f"/admin/sessions/{session_id}/revoke",
            confirmation_id=str(session_id),
            extra_fields={},
            back_url=f"/admin/users/{target.user_id}/sessions",
        )
    if confirmed != str(session_id):
        raise ApiError("confirmation_invalid", 403)
    lock_admin_control(session)
    assert_active_principal(session, principal)
    require_admin(session, principal)
    target = session.get(UserSession, session_id)
    if target is None:
        raise ApiError("not_found", 404)
    if roles_for(session, target.user_id) and "server_owner" not in roles_for(
        session, principal.user_id
    ):
        raise ApiError("admin_owner_required", 403)
    session.scalar(select(User).where(User.id == target.user_id).with_for_update())
    target = session.scalar(
        select(UserSession).where(UserSession.id == session_id).with_for_update()
    )
    target.revoked_at = now()
    audit(session, principal.user_id, "session.revoke", target.id)
    session.commit()
    return RedirectResponse(f"/admin/users/{target.user_id}/sessions", status_code=303)


@router.get("/invites")
def invites(request: Request, session: Session = Depends(get_session)):
    administrator(request, session)
    return render(
        request,
        "invites",
        token=None,
        default_days=read_runtime_configuration(session).values.invitation_default_days,
        invites=list(session.scalars(select(Invite).order_by(Invite.created_at.desc()))),
    )


@router.post("/invites")
async def invitation(request: Request, session: Session = Depends(get_session)):
    form = await verified_form(request)
    principal = administrator(request, session)
    try:
        days = int(str(form["days"])) if "days" in form else None
    except ValueError:
        raise ApiError("invite_duration_invalid", 422) from None
    _, token = create_invite(session, principal, days)
    session.commit()
    return render(
        request,
        "invites",
        token=token,
        default_days=read_runtime_configuration(session).values.invitation_default_days,
        invites=list(session.scalars(select(Invite).order_by(Invite.created_at.desc()))),
    )


@router.post("/invites/{invite_id}/revoke")
async def revoke_invite(invite_id: UUID, request: Request, session: Session = Depends(get_session)):
    await verified_form(request)
    principal = administrator(request, session)
    lock_admin_control(session)
    assert_active_principal(session, principal)
    require_admin(session, principal)
    record = session.scalar(select(Invite).where(Invite.id == invite_id).with_for_update())
    if record is None:
        raise ApiError("not_found", 404)
    record.revoked_at = now()
    audit(session, principal.user_id, "invite.revoke", record.id)
    session.commit()
    return RedirectResponse("/admin/invites", status_code=303)


@router.get("/password")
def password_page(request: Request, session: Session = Depends(get_session)):
    administrator(request, session, portal=True)
    return render(request, "password", changed=False)


@router.post("/password")
async def password_update(request: Request, session: Session = Depends(get_session)):
    form = await verified_form(request)
    principal = administrator(request, session, portal=True)
    lock_admin_control(session)
    assert_active_principal(session, principal)
    require_portal(session, principal)
    current = str(form.get("current_password", ""))
    replacement = str(form.get("new_password", ""))
    repeated = str(form.get("repeat_password", ""))
    if (
        not 12 <= len(current) <= 256
        or not 12 <= len(replacement) <= 256
        or replacement != repeated
    ):
        raise ApiError("password_input_invalid", 422)
    user = session.get(User, principal.user_id)
    if not PASSWORDS.verify(current, user.password_hash):
        raise ApiError("invalid_credentials", 401)
    user.password_hash = PASSWORDS.hash(replacement)
    for record in session.scalars(
        select(UserSession).where(
            UserSession.user_id == user.id, UserSession.id != principal.session_id
        )
    ):
        record.revoked_at = now()
    audit(session, principal.user_id, "admin.password_change", user.id)
    session.commit()
    return render(request, "password", changed=True)


@router.get("/audit")
def audit_page(request: Request, session: Session = Depends(get_session)):
    administrator(request, session)
    filters = AuditFilters.parse(request.query_params)
    data = list_audit(session, filters, page_number(request.query_params.get("page", "1")))
    parameters = filters.parameters()
    return render(
        request,
        "audit",
        **data,
        error=None,
        previous_url="/admin/audit?" + urlencode({**parameters, "page": data["page_number"] - 1}),
        next_url="/admin/audit?" + urlencode({**parameters, "page": data["page_number"] + 1}),
    )


@router.post("/audit/export")
async def audit_export(request: Request, session: Session = Depends(get_session)):
    form = await verified_form(request)
    principal = administrator(request, session, portal=True)
    filters = AuditFilters.parse(form)

    def create_export():
        reauthenticate_admin(session, principal, str(form.get("current_password", "")))
        content, count = export_audit(session, filters)
        audit(session, principal.user_id, "admin.audit_export", count=count)
        return content

    try:
        content = mutate(session, principal, "admin.audit_export", None, create_export)
    except ApiError as error:
        if error.status == 401:
            raise
        require_admin(session, principal)
        data = list_audit(session, filters)
        return render(
            request,
            "audit",
            **data,
            error=failure_message(error.code),
            response_status=error.status,
            previous_url="",
            next_url="",
        )
    return Response(
        content,
        media_type="application/x-ndjson",
        headers={
            "Content-Disposition": 'attachment; filename="flowtrace-admin-audit.jsonl"',
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "private,no-store",
        },
    )


@router.get("/recovery")
def recovery_instructions(request: Request, session: Session = Depends(get_session)):
    principal = administrator(request, session, portal=True)
    return render(request, "recovery", username=session.get(User, principal.user_id).username)


@router.get("/diagnostics/export")
def export_diagnostics(request: Request, session: Session = Depends(get_session)):
    principal = administrator(request, session)
    lock_admin_control(session)
    assert_active_principal(session, principal)
    require_admin(session, principal)
    policy = current_policy()
    if not request.app.state.settings.diagnostics_enabled or policy is None or not policy.enabled():
        raise ApiError("diagnostic_unavailable", 503)
    try:
        content = DiagnosticStore(
            request.app.state.settings.data_directory / "diagnostics"
        ).export()
    except OSError:
        raise ApiError("diagnostic_unavailable", 503) from None
    audit(session, principal.user_id, "diagnostics.export", count=content.count(b"\n") - 1)
    session.commit()
    return Response(
        content,
        media_type="application/x-ndjson",
        headers={
            "Content-Disposition": 'attachment; filename="flowtrace-diagnostics.jsonl"',
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "private,no-store",
        },
    )
