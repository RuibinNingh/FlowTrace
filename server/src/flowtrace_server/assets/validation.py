from uuid import UUID

from flowtrace_server.sync.common import CommandRejected

from .catalog import BANK_IDS, PROVIDER_KINDS
from .models import AssetGroup


def validate_account_metadata(session, principal, scope, payload):
    group_id = payload.get("group_id")
    if group_id is not None:
        if scope.kind != "user" or scope.owner_user_id != principal.user_id:
            raise CommandRejected("account.private_group_required", 403)
        group = session.get(AssetGroup, UUID(group_id))
        if group is None or group.deleted or group.user_id != principal.user_id:
            raise CommandRejected("account.group_unavailable", 409)
    if payload.get("bank_id") is not None and payload["bank_id"] not in BANK_IDS:
        raise CommandRejected("account.bank_unknown")
    provider = payload.get("provider_id")
    if provider is not None and PROVIDER_KINDS.get(provider) != payload["kind"]:
        raise CommandRejected("account.provider_mismatch")
