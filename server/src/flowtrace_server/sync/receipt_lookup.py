"""Read an existing Applied receipt without executing or refreshing anything."""

from copy import deepcopy
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session

from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal, now
from flowtrace_server.books.permissions import authorize_scope
from flowtrace_server.persistence.models import ServerState

from .common import lock_scopes, run_transaction
from .input import ValidatedPush
from .models import SyncClient, SyncReceipt


def lookup_receipt(session: Session, principal: Principal, validated: ValidatedPush) -> dict:
    body = validated.request
    if len(body.operations) != 1:
        raise ApiError("validation_error", 422)
    operation = body.operations[0]
    digest = validated.operation_hashes[0]

    def read_one():
        # The write-side require_current_client creates/extends device leases.
        # A proof lookup must neither do that nor turn a missing receipt into a write.
        if principal.purpose not in {"api_native", "api_web"}:
            raise ApiError("session_purpose_invalid", 403)
        assert_active_principal(session, principal, lock=True)
        if UUID(body.client_id) != principal.client_id:
            raise ApiError("client_mismatch", 403)
        state = session.scalar(select(ServerState).with_for_update(read=True))
        if state is None:
            raise ApiError("service_unavailable", 503)
        if UUID(body.sync_epoch) != state.sync_epoch:
            raise ApiError("epoch_changed", 409)
        client = session.scalar(
            select(SyncClient)
            .where(
                SyncClient.user_id == principal.user_id,
                SyncClient.client_id == principal.client_id,
            )
            .with_for_update(read=True)
            .execution_options(populate_existing=True)
        )
        if (
            client is None
            or client.frozen
            or client.valid_until <= now()
            or client.sync_epoch != state.sync_epoch
        ):
            raise ApiError("resync_required", 410)
        receipt = session.get(
            SyncReceipt,
            (principal.user_id, principal.client_id, UUID(operation.operation_id)),
        )
        wanted = {principal.user_id, UUID(operation.scope_id)}
        if receipt is not None:
            wanted.update(UUID(value) for value in receipt.required_scope_ids)
        scopes = lock_scopes(session, wanted)
        for scope_id in scopes:
            authorize_scope(session, principal, scope_id, write=True)
        if receipt is None:
            raise ApiError("receipt_not_found", 404)
        if receipt.content_hash != digest:
            raise ApiError("idempotency_mismatch", 409)
        if receipt.status != "applied":
            raise ApiError("receipt_not_applied", 409)
        result = deepcopy(receipt.result)
        result["replayed"] = True
        assert_active_principal(session, principal, lock=True)
        return {"results": [result]}

    return run_transaction(session, read_one, repeatable=True)
