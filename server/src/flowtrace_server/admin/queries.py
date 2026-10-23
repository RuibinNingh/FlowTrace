"""Bounded operational metadata views; never inspect private ledger payloads."""

import json
import re
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import UUID

from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.admin.service import ADMIN_ROLES
from flowtrace_server.attachments.models import Attachment
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import AdminRole, User, UserSession
from flowtrace_server.auth.service import now
from flowtrace_server.sync.models import SyncClient

PAGE_SIZE = 50
AUDIT_EXPORT_LIMIT = 5000
SAFE_SUMMARY = frozenset(
    {
        "succeeded",
        "status",
        "count",
        "revoked_sessions",
        "granted_count",
        "revoked_count",
        "server_owner",
        "service_admin",
        "recovery_admin",
        "files",
        "bytes",
    }
)


def page_number(value: str) -> int:
    try:
        result = int(value)
    except (TypeError, ValueError):
        raise ApiError("admin_filter_invalid", 422) from None
    if not 1 <= result <= 1000000:
        raise ApiError("admin_filter_invalid", 422)
    return result


def list_users(session: Session, *, query: str = "", state: str = "all", page: int = 1) -> dict:
    query = query.strip().lower()
    if len(query) > 64 or state not in {"all", "enabled", "disabled"}:
        raise ApiError("admin_filter_invalid", 422)
    filters = []
    if query:
        name = User.username.contains(query, autoescape=True)
        try:
            identity = UUID(query)
        except ValueError:
            filters.append(name)
        else:
            filters.append(or_(name, User.id == identity))
    if state != "all":
        filters.append(User.enabled.is_(state == "enabled"))
    count = session.scalar(select(func.count()).select_from(User).where(*filters))
    users = list(
        session.scalars(
            select(User)
            .where(*filters)
            .order_by(User.created_at, User.id)
            .offset((page - 1) * PAGE_SIZE)
            .limit(PAGE_SIZE)
        )
    )
    ids = [user.id for user in users]
    summaries = {
        identity: {
            "roles": [],
            "active_sessions": 0,
            "last_login": None,
            "last_sync": None,
            "ready_bytes": 0,
            "reserved_bytes": 0,
            "ready_attachments": 0,
        }
        for identity in ids
    }
    if ids:
        for identity, role in session.execute(
            select(AdminRole.user_id, AdminRole.role)
            .where(AdminRole.user_id.in_(ids))
            .order_by(AdminRole.role)
        ):
            if role in ADMIN_ROLES:
                summaries[identity]["roles"].append(role)
        for identity, login in session.execute(
            select(UserSession.user_id, func.max(UserSession.created_at))
            .where(UserSession.user_id.in_(ids))
            .group_by(UserSession.user_id)
        ):
            summaries[identity]["last_login"] = login
        for identity, count_sessions in session.execute(
            select(UserSession.user_id, func.count())
            .where(
                UserSession.user_id.in_(ids),
                UserSession.revoked_at.is_(None),
                UserSession.expires_at > now(),
                UserSession.idle_expires_at > now(),
            )
            .group_by(UserSession.user_id)
        ):
            summaries[identity]["active_sessions"] = count_sessions
        for identity, seen in session.execute(
            select(SyncClient.user_id, func.max(SyncClient.last_seen_at))
            .where(SyncClient.user_id.in_(ids))
            .group_by(SyncClient.user_id)
        ):
            summaries[identity]["last_sync"] = seen
        for identity, status, count_files, declared_bytes in session.execute(
            select(
                Attachment.created_by,
                Attachment.status,
                func.count(),
                func.sum(Attachment.size_bytes),
            )
            .where(
                Attachment.created_by.in_(ids),
                Attachment.status.in_(["pending", "uploaded", "ready"]),
            )
            .group_by(Attachment.created_by, Attachment.status)
        ):
            if status == "ready":
                summaries[identity]["ready_bytes"] = declared_bytes
                summaries[identity]["ready_attachments"] = count_files
            else:
                summaries[identity]["reserved_bytes"] += declared_bytes
    return {
        "users": users,
        "summaries": summaries,
        "total": count,
        "page_number": page,
        "page_size": PAGE_SIZE,
        "query": query,
        "state_filter": state,
        "has_previous": page > 1,
        "has_next": page * PAGE_SIZE < count,
    }


def overview_metadata(session: Session) -> dict:
    return {
        "enabled_users": session.scalar(
            select(func.count()).select_from(User).where(User.enabled.is_(True))
        ),
        "recent_sync_users": session.scalar(
            select(func.count(func.distinct(SyncClient.user_id)))
            .join(User, User.id == SyncClient.user_id)
            .where(User.enabled.is_(True), SyncClient.last_seen_at >= now() - timedelta(days=7))
        ),
        "ready_bytes": session.scalar(
            select(func.coalesce(func.sum(Attachment.size_bytes), 0)).where(
                Attachment.status == "ready"
            )
        ),
        "reserved_bytes": session.scalar(
            select(func.coalesce(func.sum(Attachment.size_bytes), 0)).where(
                Attachment.status.in_(["pending", "uploaded"])
            )
        ),
    }


def _instant(value: str) -> datetime | None:
    if not value:
        return None
    if len(value) > 40:
        raise ApiError("admin_filter_invalid", 422)
    try:
        parsed = datetime.fromisoformat(value)
        # The form explicitly labels datetime-local input as UTC.
        return parsed.replace(tzinfo=UTC) if parsed.tzinfo is None else parsed.astimezone(UTC)
    except (ValueError, OverflowError):
        raise ApiError("admin_filter_invalid", 422) from None


@dataclass(frozen=True)
class AuditFilters:
    action: str = ""
    actor: UUID | None = None
    result: str = "all"
    since: datetime | None = None
    until: datetime | None = None
    snapshot: datetime | None = None

    @classmethod
    def parse(cls, values) -> "AuditFilters":
        action = str(values.get("action", "")).strip()
        if action and not re.fullmatch(r"[a-z][a-z0-9_.-]{0,63}", action):
            raise ApiError("admin_filter_invalid", 422)
        actor = str(values.get("actor", "")).strip()
        try:
            actor_id = UUID(actor) if actor else None
        except ValueError:
            raise ApiError("admin_filter_invalid", 422) from None
        result = str(values.get("result", "all"))
        if result not in {"all", "succeeded", "failed"}:
            raise ApiError("admin_filter_invalid", 422)
        since = _instant(str(values.get("since", "")))
        until = _instant(str(values.get("until", "")))
        if since and until and since >= until:
            raise ApiError("admin_filter_invalid", 422)
        snapshot = _instant(str(values.get("snapshot", ""))) or now()
        if snapshot > now() + timedelta(seconds=1):
            raise ApiError("admin_filter_invalid", 422)
        return cls(action, actor_id, result, since, until, snapshot)

    def conditions(self):
        conditions = [AdminAudit.created_at <= self.snapshot]
        if self.action:
            conditions.append(AdminAudit.action == self.action)
        if self.actor:
            conditions.append(AdminAudit.actor_id == self.actor)
        if self.since:
            conditions.append(AdminAudit.created_at >= self.since)
        if self.until:
            conditions.append(AdminAudit.created_at < self.until)
        succeeded = AdminAudit.summary["succeeded"].as_boolean()
        if self.result == "failed":
            conditions.append(succeeded.is_(False))
        elif self.result == "succeeded":
            conditions.append(or_(succeeded.is_(True), succeeded.is_(None)))
        return conditions

    def parameters(self) -> dict[str, str]:
        return {
            "action": self.action,
            "actor": str(self.actor or ""),
            "result": self.result,
            "since": self.since.isoformat() if self.since else "",
            "until": self.until.isoformat() if self.until else "",
            "snapshot": self.snapshot.isoformat(),
        }


def list_audit(session: Session, filters: AuditFilters, page: int = 1) -> dict:
    conditions = filters.conditions()
    count = session.scalar(select(func.count()).select_from(AdminAudit).where(*conditions))
    audits = list(
        session.scalars(
            select(AdminAudit)
            .where(*conditions)
            .order_by(AdminAudit.created_at.desc(), AdminAudit.id.desc())
            .offset((page - 1) * PAGE_SIZE)
            .limit(PAGE_SIZE)
        )
    )
    return {
        "audits": audits,
        "total": count,
        "page_number": page,
        "page_size": PAGE_SIZE,
        "has_previous": page > 1,
        "has_next": page * PAGE_SIZE < count,
        "filters": filters,
        "filter_values": filters.parameters(),
    }


def export_audit(session: Session, filters: AuditFilters) -> tuple[bytes, int]:
    audits = list(
        session.scalars(
            select(AdminAudit)
            .where(*filters.conditions())
            .order_by(AdminAudit.created_at.desc(), AdminAudit.id.desc())
            .limit(AUDIT_EXPORT_LIMIT + 1)
        )
    )
    if len(audits) > AUDIT_EXPORT_LIMIT:
        raise ApiError("audit_export_filter_required", 422)
    lines = [
        {
            "format": "flowtrace-admin-audit-v1",
            "count": len(audits),
            "snapshot": filters.snapshot.isoformat(),
        }
    ]
    for item in audits:
        safe_summary = {
            key: value
            for key, value in (item.summary or {}).items()
            if key in SAFE_SUMMARY and type(value) in {bool, int}
        }
        lines.append(
            {
                "id": str(item.id),
                "created_at": item.created_at.astimezone(UTC).isoformat(),
                "actor_id": str(item.actor_id) if item.actor_id else None,
                "action": item.action,
                "target_id": str(item.target_id) if item.target_id else None,
                "succeeded": safe_summary.get("succeeded", True),
                "summary": safe_summary,
            }
        )
    return (
        "\n".join(json.dumps(line, ensure_ascii=False, separators=(",", ":")) for line in lines)
        + "\n"
    ).encode("utf-8"), len(audits)
