"""Bounded retention-page data and closed form adapters.

Routes own CSRF/Origin, threadpool execution, commit/rollback and finally.close.
Long registration/preview filesystem work uses the existing prepared contexts,
with no database Session. No moving, deleting or job enqueue operation exists.
"""

import re
from dataclasses import dataclass
from uuid import UUID, uuid4

from pydantic import ValidationError
from sqlalchemy import select

from flowtrace_server.admin.service import reauthenticate_admin, require_recovery
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal
from flowtrace_server.backups import administration as backup_admin
from flowtrace_server.backups import retention
from flowtrace_server.backups.retention_models import BackupControl, BackupPin
from flowtrace_server.backups.retention_schemas import (
    PinCreateCommand,
    PinReleaseCommand,
    RetentionSelection,
)

PAGE_SIZE = 20
REASON_LABELS = {
    "unregistered": "尚未显式登记，保留原包",
    "pinned": "存在保留标记",
    "active_hold": "存在尚未释放的保护引用",
    "active_job": "存在待执行或正在执行的任务",
    "restore_intent": "恢复意图永久保留来源",
    "last_recovery_point": "当前来源的最近恢复点",
    "not_old": "未达到当前保留天数",
    "package_unavailable": "包不可用、正在占用或声明已变化",
    "partial": "部分结果保留待检查",
    "reserved": "已被其他意图预约",
    "quarantined": "已隔离，保留原状态",
    "destroyed": "已有销毁状态记录",
}
STATE_LABELS = {
    "unregistered": "未登记", "available": "可读", "reserved": "已预约",
    "quarantined": "已隔离", "partial": "部分结果", "destroyed": "已销毁记录",
}


def _input_error():
    return ApiError("backup_input_invalid", 422)


def _closed(form, expected, *, multiple=None):
    if set(form) != set(expected):
        raise _input_error()
    for key in form:
        values = form.getlist(key)
        if (
            (key != multiple and len(values) != 1)
            or any(not isinstance(value, str) for value in values)
        ):
            raise _input_error()
    if multiple is not None and not 1 <= len(form.getlist(multiple)) <= PAGE_SIZE:
        raise _input_error()


def _uuid(value):
    try:
        result = UUID(value)
        if str(result) != value:
            raise ValueError
        return result
    except (ValueError, TypeError, AttributeError):
        raise _input_error() from None


def _version(value, *, zero=False):
    if (
        not isinstance(value, str) or not re.fullmatch(r"0|[1-9][0-9]{0,18}", value)
        or not (0 if zero else 1) <= int(value) <= 2**63 - 1
    ):
        raise _input_error()
    return int(value)


def _password(form):
    value = form["current_password"]
    if not isinstance(value, str) or not 12 <= len(value) <= 256:
        raise ApiError("reauthentication_failed", 403)
    return value


def _confirm(form, identity):
    if _uuid(form["confirm_target"]) != identity:
        raise ApiError("confirmation_invalid", 403)


def optional_cursor(value):
    return None if value is None else _uuid(value)


@dataclass(frozen=True, repr=False)
class RegistrationInput:
    backup_id: UUID
    manifest_sha256: str
    instance_id: UUID
    sync_epoch: UUID
    password: str


def parse_registration(form, backup_id):
    _closed(form, {
        "csrf_token", "confirm_target", "expected_manifest_sha256",
        "expected_instance", "expected_epoch", "current_password",
    })
    _confirm(form, backup_id)
    checksum = form["expected_manifest_sha256"]
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise _input_error()
    return RegistrationInput(
        backup_id, checksum, _uuid(form["expected_instance"]), _uuid(form["expected_epoch"]),
        _password(form),
    )


def parse_pin_create(form, backup_id):
    _closed(form, {
        "csrf_token", "confirm_target", "pin_id", "request_id",
        "expected_control_version", "current_password",
    })
    _confirm(form, backup_id)
    command = PinCreateCommand(
        pin_id=_uuid(form["pin_id"]), backup_id=backup_id,
        expected_control_version=_version(form["expected_control_version"]),
        request_id=_uuid(form["request_id"]),
    )
    return command, _password(form)


def parse_pin_release(form, pin_id):
    _closed(form, {
        "csrf_token", "confirm_target", "request_id", "expected_control_version",
        "expected_pin_version", "current_password",
    })
    _confirm(form, pin_id)
    command = PinReleaseCommand(
        pin_id=pin_id, expected_pin_version=_version(form["expected_pin_version"]),
        expected_control_version=_version(form["expected_control_version"]),
        request_id=_uuid(form["request_id"]),
    )
    return command, _password(form)


def parse_preview(form):
    _closed(form, {
        "csrf_token", "confirm_target", "backup_ids", "request_id",
        "expected_config_version", "current_password",
    }, multiple="backup_ids")
    request_id = _uuid(form["request_id"])
    _confirm(form, request_id)
    identities = tuple(_uuid(value) for value in form.getlist("backup_ids"))
    try:
        selection = RetentionSelection(
            backup_ids=tuple(sorted(identities, key=str)), request_id=request_id,
            expected_config_version=_version(form["expected_config_version"], zero=True),
        )
    except ValidationError:
        raise _input_error() from None
    return selection, _password(form)


def _authority(session, principal):
    assert_active_principal(session, principal, lock=False)
    require_recovery(session, principal)


def catalog_data(session, principal, settings, *, before=None):
    catalog = retention.list_retention_candidates(session, principal, settings, before=before)
    identifiers = [item.backup_id for item in catalog["items"]]
    controls = {row.backup_id: row for row in session.scalars(
        select(BackupControl).where(BackupControl.backup_id.in_(identifiers))
        .execution_options(populate_existing=True)
    )} if identifiers else {}
    items = []
    for item in catalog["items"]:
        row = controls.get(item.backup_id)
        items.append({
            **item.model_dump(), "control_version": row.version if row is not None else None,
        })
    return {
        **catalog, "items": items, "reason_labels": REASON_LABELS,
        "state_labels": STATE_LABELS, "request_id": uuid4(),
        "next_url": f"/admin/backups/retention?before={catalog['next_cursor']}",
    }


def registration_data(session, principal, settings, backup_id):
    _authority(session, principal)
    if not isinstance(backup_id, UUID):
        raise _input_error()
    metadata = backup_admin.get_backup(session, principal, settings, backup_id)
    control = session.get(BackupControl, backup_id, populate_existing=True)
    instance, epoch = retention._source(session)
    return {
        "target": metadata, "source_instance": instance, "source_epoch": epoch,
        "already_registered": control is not None,
        "can_register": control is None and metadata["state"] == "manifest_available",
    }


def precheck_registration(session, principal, command):
    """Caller commits this read-only phase before prepare_registration I/O."""
    if not isinstance(command, RegistrationInput):
        raise _input_error()
    retention._readonly(session, principal, command.password)
    if retention._source(session) != (command.instance_id, command.sync_epoch):
        raise ApiError("backup_source_changed", 409)


def finish_registration(session, principal, settings, *, prepared, command):
    if not isinstance(command, RegistrationInput):
        raise _input_error()
    reauthenticate_admin(session, principal, command.password, capability="recovery")
    if (
        not isinstance(prepared, retention.PreparedRegistration)
        or prepared.closed or prepared.stamp.backup_id != command.backup_id
        or prepared.stamp.manifest_sha256 != command.manifest_sha256
        or (prepared.stamp.instance_id, prepared.stamp.sync_epoch) != (
            command.instance_id, command.sync_epoch
        )
    ):
        raise ApiError("backup_package_changed", 409)
    return retention.register_verified_backup(
        session, principal, settings, prepared=prepared, password=command.password
    )


def protection_data(session, principal, backup_id, *, pins_after=None):
    _authority(session, principal)
    if (
        not isinstance(backup_id, UUID)
        or (pins_after is not None and not isinstance(pins_after, UUID))
    ):
        raise _input_error()
    control = session.get(BackupControl, backup_id, populate_existing=True)
    if control is None:
        raise ApiError("backup_unregistered", 409)
    query = select(BackupPin).where(
        BackupPin.backup_id == backup_id, BackupPin.released_at.is_(None)
    ).order_by(BackupPin.id).limit(PAGE_SIZE + 1).execution_options(populate_existing=True)
    if pins_after is not None:
        query = query.where(BackupPin.id > pins_after)
    pins = list(session.scalars(query))
    current = (control.instance_id, control.sync_epoch) == retention._source(session)
    return {
        "target_id": backup_id, "control_version": control.version,
        "state": STATE_LABELS[control.state], "mutable": current and control.state == "available",
        "pins": [{
            "pin_id": pin.id, "version": pin.version, "created_at": pin.created_at,
            "created_by": pin.created_by, "release_request_id": uuid4(),
        } for pin in pins[:PAGE_SIZE]],
        "has_more": len(pins) > PAGE_SIZE,
        "next_url": f"/admin/backups/{backup_id}/protection?pins_after={pins[19].id}"
        if len(pins) > PAGE_SIZE else None,
        "pin_id": uuid4(), "request_id": uuid4(),
    }


def create_pin(session, principal, *, command, password):
    return retention.create_backup_pin(session, principal, command=command, password=password)


def release_pin(session, principal, *, backup_id, command, password):
    # Bind both URL UUIDs before consuming the existing CAS service. The service
    # still reauthenticates and locks control/pin in its established order.
    _authority(session, principal)
    if not isinstance(command, PinReleaseCommand) or session.scalar(
        select(BackupPin.backup_id).where(BackupPin.id == command.pin_id)
    ) != backup_id:
        raise ApiError("not_found", 404)
    return retention.release_backup_pin(session, principal, command=command, password=password)


def preview_data(record):
    """Project only the authorized result; do not expose session/private root."""
    return {
        "preview_id": record.preview_id, "request_id": record.request_id,
        "config_version": record.config_version, "retention_days": record.retention_days,
        "cutoff": record.cutoff, "issued_at": record.issued_at, "expires_at": record.expires_at,
        "packages": [{
            "backup_id": item.backup_id, "created_at": item.created_at,
            "size_bytes": item.size_bytes, "file_count": item.file_count,
            "control_version": item.control_version, "manifest_sha256": item.manifest_sha256,
        } for item in record.packages],
        "total_bytes": sum(item.size_bytes for item in record.packages),
        "total_files": sum(item.file_count for item in record.packages),
    }
