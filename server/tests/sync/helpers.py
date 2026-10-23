import json
from copy import deepcopy
from dataclasses import dataclass, field
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.orm import Session

from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.models import User
from flowtrace_server.auth.service import create_user, issue_session
from flowtrace_server.books.models import BookMembership, SyncScope
from flowtrace_server.books.router import update_membership
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.sync.input import parse_push_body
from flowtrace_server.sync.writer import push_operations


@dataclass
class Actor:
    principal: Principal
    token: str = field(repr=False)
    book_id: UUID


def actor(engine, existing_user=None):
    with Session(engine, expire_on_commit=False) as session:
        user = (
            session.get(User, existing_user)
            if existing_user
            else create_user(session, "sync_" + uuid4().hex, "Synthetic-password-2026-only")
        )
        record, tokens = issue_session(session, user, uuid4(), "合成同步测试", "api_native")
        principal = Principal(user.id, record.id, record.client_id, record.purpose, frozenset())
        book_id = session.scalar(
            select(BookMembership.book_id)
            .where(BookMembership.user_id == user.id, BookMembership.role == "owner")
            .limit(1)
        )
        session.commit()
        return Actor(principal, tokens["access_token"], book_id)


def share(engine, owner, member, role="editor"):
    with Session(engine) as session:
        session.add(
            BookMembership(
                book_id=owner.book_id, user_id=member.principal.user_id, role=role, active=True
            )
        )
        scope = session.get(SyncScope, member.principal.user_id)
        scope.permission_version += 1
        session.get(SyncScope, owner.book_id).permission_version += 1
        session.commit()


def revoke(engine, owner, member):
    with Session(engine) as session:
        update_membership(session, owner.principal, owner.book_id, member.principal.user_id, None)
        session.commit()


def money(amount="100", currency="CNY", scale=2):
    return {"currency": currency, "currency_scale": scale, "amount_minor": amount}


def operation(
    scope_id, kind, payload, *, identifier=None, action="create", revision="0", depends=None
):
    return {
        "operation_id": str(uuid4()),
        "scope_id": str(scope_id),
        "entity_type": kind,
        "entity_id": str(identifier or uuid4()),
        "action": action,
        "base_revision": revision,
        "depends_on": depends,
        "payload": payload,
    }


def expense(book_id, account_id=None, amount="100", **changes):
    return {
        "bill_type": "expense",
        "book_id": str(book_id),
        "money": money(amount),
        "account_id": str(account_id) if account_id else None,
        "business_date": "2026-10-21",
        "business_timezone": "Asia/Shanghai",
        **changes,
    }


def push(engine, actor, operations, *, epoch=None, before_commit=None):
    with Session(engine) as session:
        current_epoch = session.get(ServerState, 1).sync_epoch
        session.rollback()
        request = {
            "protocol_version": 1,
            "client_id": str(actor.principal.client_id),
            "sync_epoch": str(epoch or current_epoch),
            "operations": deepcopy(operations if isinstance(operations, list) else [operations]),
        }
        validated = parse_push_body(json.dumps(request, ensure_ascii=False).encode())
        return push_operations(session, actor.principal, validated, before_commit=before_commit)[
            "results"
        ]


def account(engine, owner, *, opening="100000", kind="cash", shared=False, currency="CNY", scale=2):
    command = operation(
        owner.book_id if shared else owner.principal.user_id,
        "account",
        {
            "name": "合成账户",
            "kind": kind,
            "opening": money(opening, currency, scale),
            "include_in_net_assets": True,
            "hidden": False,
        },
    )
    result = push(engine, owner, command)[0]
    assert result["status"] == "applied", result
    return UUID(command["entity_id"])


def epoch(engine):
    with Session(engine) as session:
        return str(session.get(ServerState, 1).sync_epoch)
