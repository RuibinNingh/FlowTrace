"""Real API actor checks for metadata reads without client lease mutation."""

from sqlalchemy import select

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.sync.models import SyncClient

from .staging import _now


def read_metadata_actor(session, principal):
    if principal.purpose not in {"api_native", "api_web"}:
        raise ApiError("session_purpose_invalid", 403)
    assert_active_principal(session, principal, lock=True)
    state = session.scalar(select(ServerState).with_for_update(read=True))
    if state is None:
        raise ApiError("service_unavailable", 503)
    client = session.get(SyncClient, (principal.user_id, principal.client_id))
    stamp = _now(session)
    if client is not None and (
        client.frozen or client.valid_until <= stamp or client.sync_epoch != state.sync_epoch
    ):
        raise ApiError("resync_required", 410)
    return state, stamp
