from uuid import UUID, uuid4

from sqlalchemy.orm import Session
from sync.helpers import money, operation, push

from flowtrace_server.persistence.models import ServerState
from flowtrace_server.sync.models import SyncEntity


def headers(who):
    return {"Authorization": f"Bearer {who.token}"}


def envelope(engine, who, base="0", **extra):
    with Session(engine) as session:
        state = session.get(ServerState, 1)
        return {
            "operation_id": str(uuid4()),
            "client_id": str(who.principal.client_id),
            "instance_id": str(state.instance_id),
            "sync_epoch": str(state.sync_epoch),
            "base_revision": base,
            **extra,
        }


def new_account(engine, who, *, kind="cash", opening="10000", scope=None, **extra):
    payload = {
        "name": "合成资产",
        "kind": kind,
        "opening": money(opening) if isinstance(opening, str) else opening,
        "include_in_net_assets": True,
        "hidden": False,
        "opening_date": "2026-01-01",
        **extra,
    }
    command = operation(scope or who.principal.user_id, "account", payload)
    result = push(engine, who, command)[0]
    assert result["status"] == "applied", result
    return UUID(command["entity_id"])


def payload(engine, identifier):
    with Session(engine) as session:
        return dict(session.get(SyncEntity, identifier).payload)


def overview(client, who, **params):
    return client.get(
        "/api/v1/assets/overview", headers=headers(who), params={"as_of": "2026-10-21", **params}
    )


def config_post(client, engine, who, path, data, base="0"):
    return client.post(path, headers=headers(who), json=envelope(engine, who, base, **data))
