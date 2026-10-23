"""Bounded trusted expiry cleanup; published financial stages are preserved."""

from uuid import UUID

from sqlalchemy import delete, select

from flowtrace_server.auth.models import User

from .staging import _invalidate, _now
from .staging_models import ImportStage, ImportStageUploadChunk


def expire_owned_stages_in_transaction(session, owner_user_id, *, check_budget, limit=100):
    """Actual source removal precedes quota release; no timer/HTTP route is installed.

    Cleanup can release this owner's exact orphan holds after origin expiry.
    It never revives, resets or removes an applied/undoing/undone publication.
    The caller owns the maintenance/job transaction and execution budget.
    """
    if (
        not isinstance(owner_user_id, UUID)
        or type(limit) is not int
        or not 1 <= limit <= 1000
        or not callable(check_budget)
    ):
        raise TypeError("trusted_owner_cleanup_budget_required")
    check_budget()
    user = session.scalar(select(User).where(User.id == owner_user_id).with_for_update())
    if user is None:
        return ()
    rows = list(
        session.scalars(
            select(ImportStage)
            .where(
                ImportStage.owner_user_id == owner_user_id,
                ImportStage.expires_at <= _now(session),
                ImportStage.status.not_in(
                    {"applied", "applying", "undoing", "undone", "cancelled", "expired"}
                ),
            )
            .order_by(ImportStage.id)
            .limit(limit)
            .with_for_update(skip_locked=True)
            .execution_options(populate_existing=True)
        )
    )
    removed = []
    for row in rows:
        check_budget()
        _invalidate(session, row)
        session.execute(
            delete(ImportStageUploadChunk).where(ImportStageUploadChunk.stage_id == row.id)
        )
        row.status, row.received_bytes, row.received_chunks = "expired", 0, 0
        row.updated_at = _now(session)
        removed.append(row.id)
        session.flush()
    check_budget()
    return tuple(removed)
