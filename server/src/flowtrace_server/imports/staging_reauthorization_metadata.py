"""Read-only source-owner metadata before an explicit new-origin binding.

Ordinary GET and every write keep their original origin checks. This endpoint
does not create/renew a SyncClient, bind an origin, enqueue a job or change a
stage. An uploaded UUID/hash is never authority for any financial resource.
"""

from flowtrace_server.sync.common import run_transaction

from .parsers import digest
from .staging import _stage
from .staging_metadata import read_metadata_actor
from .staging_schemas import StageMapping, StageReauthorizationMetadata


def stage_reauthorization_metadata(session, principal, stage_id):
    def read():
        state, stamp = read_metadata_actor(session, principal)
        # A real newly logged-in client may not yet have SyncClient history.
        # Metadata may be read without creating it; the explicit write still
        # goes through the unchanged require_current_client path afterwards.
        stage = _stage(session, principal, stage_id, state, origin=False, allow_expired=True)
        return StageReauthorizationMetadata(
            stage_id=str(stage.id),
            batch_id=str(stage.batch_id),
            stage_version=stage.stage_version,
            format=stage.format,
            expected_bytes=stage.expected_bytes,
            source_sha256=stage.source_sha256,
            mapping_hash=digest(StageMapping.model_validate(stage.mapping).model_dump(mode="json")),
            status=stage.status,
            source_released=stage.source_released_at is not None,
            expired=stage.expires_at <= stamp,
        )

    return run_transaction(session, read)
