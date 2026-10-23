"""User-scope serialized configuration; receipts never bypass current authentication."""

from copy import deepcopy
from datetime import date
from decimal import Decimal
from uuid import UUID

from sqlalchemy import func, select

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal, now
from flowtrace_server.books.permissions import authorize_scope
from flowtrace_server.currencies.models import CurrencyPreferences, ValuationRate
from flowtrace_server.domain.money import checked_minor, parse_minor
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.sync.canonical import content_hash
from flowtrace_server.sync.common import lock_scopes, require_current_client, run_transaction
from flowtrace_server.sync.models import SyncEntity

from .models import AssetConfigReceipt, AssetConfigState, AssetGroup


def revision(session, user_id):
    value = session.get(AssetConfigState, user_id)
    return value.revision if value is not None else 0


def envelope(session, user_id):
    state = session.get(ServerState, 1)
    return {
        "instance_id": str(state.instance_id),
        "sync_epoch": str(state.sync_epoch),
        "revision": str(revision(session, user_id)),
    }


def groups(session, user_id):
    return {
        **envelope(session, user_id),
        "groups": [
            {
                "id": str(row.id),
                "name": row.name,
                "sort_order": row.sort_order,
                "revision": str(row.revision),
            }
            for row in session.scalars(
                select(AssetGroup)
                .where(AssetGroup.user_id == user_id, AssetGroup.deleted.is_(False))
                .order_by(AssetGroup.sort_order, AssetGroup.id)
            )
        ],
    }


def preferences(session, user_id):
    row = session.get(CurrencyPreferences, user_id)
    fields = {"base_currency": "CNY", "enabled_codes": ["CNY"], "valuation_policy": "exact_date"}
    if row is not None:
        fields = {key: getattr(row, key) for key in fields}
    return {**envelope(session, user_id), "preferences": fields}


def rates(session, user_id):
    return {
        **envelope(session, user_id),
        "rates": [
            {
                "id": str(row.id),
                "from_currency": row.from_currency,
                "to_currency": row.to_currency,
                "effective_date": row.effective_date.isoformat(),
                "rate": row.rate_text,
                "rate_source": row.rate_source,
                "revision": str(row.revision),
            }
            for row in session.scalars(
                select(ValuationRate)
                .where(ValuationRate.user_id == user_id, ValuationRate.deleted.is_(False))
                .order_by(ValuationRate.effective_date, ValuationRate.id)
            )
        ],
    }


def read_configuration(session, principal, reader):
    def read():
        assert_active_principal(session, principal, lock=True)
        if principal.purpose not in {"api_native", "api_web"}:
            raise ApiError("session_purpose_invalid", 403)
        lock_scopes(session, {principal.user_id})
        authorize_scope(session, principal, principal.user_id)
        result = reader(session, principal.user_id)
        assert_active_principal(session, principal, lock=False)
        return result

    return run_transaction(session, read, repeatable=True)


def _owned_group(session, user_id, identifier):
    row = session.get(AssetGroup, identifier)
    if row is None or row.user_id != user_id or row.deleted:
        raise ApiError("not_found", 404)
    return row


def _apply(session, user_id, action, command, identifier, new_revision):
    if action == "groups.create":
        data = command.group
        if session.get(AssetGroup, UUID(data.id)) is not None:
            raise ApiError("asset_group_id_used", 409)
        count = session.scalar(
            select(func.count())
            .select_from(AssetGroup)
            .where(AssetGroup.user_id == user_id, AssetGroup.deleted.is_(False))
        )
        if count >= 1000:
            raise ApiError("asset_config_limit", 409)
        session.add(
            AssetGroup(
                id=UUID(data.id),
                user_id=user_id,
                name=data.name,
                sort_order=data.sort_order,
                revision=new_revision,
                deleted=False,
            )
        )
    elif action in {"groups.update", "groups.delete"}:
        row = _owned_group(session, user_id, identifier)
        if action == "groups.delete":
            if (
                session.scalar(
                    select(SyncEntity.id)
                    .where(
                        SyncEntity.entity_type == "account",
                        SyncEntity.scope_id == user_id,
                        SyncEntity.deleted.is_(False),
                        SyncEntity.payload["group_id"].astext == str(identifier),
                    )
                    .limit(1)
                )
                is not None
            ):
                raise ApiError("asset_group_in_use", 409)
            row.deleted = True
        else:
            row.name, row.sort_order = command.group.name, command.group.sort_order
        row.revision = new_revision
    elif action == "preferences.update":
        row = session.get(CurrencyPreferences, user_id)
        if row is None:
            row = CurrencyPreferences(user_id=user_id)
            session.add(row)
        for key, value in command.preferences.model_dump().items():
            setattr(row, key, value)
    elif action == "rates.create":
        data = command.rate
        if session.get(ValuationRate, UUID(data.id)) is not None:
            raise ApiError("valuation_rate_id_used", 409)
        existing = session.scalar(
            select(ValuationRate.id).where(
                ValuationRate.user_id == user_id,
                ValuationRate.deleted.is_(False),
                ValuationRate.from_currency == data.from_currency,
                ValuationRate.to_currency == data.to_currency,
                ValuationRate.effective_date == date.fromisoformat(data.effective_date),
            )
        )
        if existing is not None:
            raise ApiError("valuation_rate_exists", 409)
        count = session.scalar(
            select(func.count())
            .select_from(ValuationRate)
            .where(ValuationRate.user_id == user_id, ValuationRate.deleted.is_(False))
        )
        if count >= 10000:
            raise ApiError("asset_config_limit", 409)
        session.add(
            ValuationRate(
                id=UUID(data.id),
                user_id=user_id,
                from_currency=data.from_currency,
                to_currency=data.to_currency,
                effective_date=date.fromisoformat(data.effective_date),
                rate=Decimal(data.rate),
                rate_text=data.rate,
                rate_source=data.rate_source,
                revision=new_revision,
                deleted=False,
            )
        )
    elif action == "rates.delete":
        row = session.get(ValuationRate, identifier)
        if row is None or row.user_id != user_id or row.deleted:
            raise ApiError("not_found", 404)
        row.deleted, row.revision = True, new_revision
    else:
        raise ValueError("unknown_configuration_action")


def mutate_configuration(session, principal, action, command, identifier=None):
    original = command.model_dump(exclude_unset=True)
    hashed = content_hash(
        {"action": action, "id": str(identifier) if identifier else None, "command": original}
    )

    def write():
        state, _ = require_current_client(session, principal, command.sync_epoch, command.client_id)
        if UUID(command.instance_id) != state.instance_id:
            raise ApiError("instance_changed", 409)
        lock_scopes(session, {principal.user_id})
        authorize_scope(session, principal, principal.user_id, write=True)
        previous = session.get(AssetConfigReceipt, (principal.user_id, UUID(command.operation_id)))
        if previous is not None:
            if (
                previous.client_id != principal.client_id
                or previous.content_hash != hashed
                or previous.sync_epoch != state.sync_epoch
            ):
                raise ApiError("idempotency_conflict", 409)
            return deepcopy(previous.result)
        config = session.get(AssetConfigState, principal.user_id)
        current = config.revision if config is not None else 0
        if current != parse_minor(command.base_revision):
            raise ApiError("asset_config_conflict", 409)
        new_revision = checked_minor(current + 1)
        _apply(session, principal.user_id, action, command, identifier, new_revision)
        if config is None:
            config = AssetConfigState(user_id=principal.user_id, revision=new_revision)
            session.add(config)
        else:
            config.revision = new_revision
        session.flush()
        reader = (
            groups
            if action.startswith("groups.")
            else (rates if action.startswith("rates.") else preferences)
        )
        result = {**reader(session, principal.user_id), "operation_id": command.operation_id}
        session.add(
            AssetConfigReceipt(
                user_id=principal.user_id,
                operation_id=UUID(command.operation_id),
                client_id=principal.client_id,
                sync_epoch=state.sync_epoch,
                content_hash=hashed,
                result=result,
                created_at=now(),
            )
        )
        session.flush()
        assert_active_principal(session, principal, lock=False)
        return result

    return run_transaction(session, write)
