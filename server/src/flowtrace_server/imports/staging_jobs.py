"""At most four bound job facts; no arbitrary lookup, payload or retry RPC."""

from pydantic import ValidationError

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.jobs.store import _payload
from flowtrace_server.sync.common import run_transaction

from .staging import JOB_FIELDS, JOB_TYPES, _stage
from .staging_metadata import read_metadata_actor
from .staging_schemas import StageJobMetadata, StageJobsMetadata


def stage_jobs(session, principal, stage_id, *, stage_version):
    def read():
        state, _ = read_metadata_actor(session, principal)
        stage = _stage(
            session, principal, stage_id, state, version=stage_version, allow_expired=True
        )
        items = []
        for action, field in JOB_FIELDS.items():
            identifier = getattr(stage, field)
            if identifier is None:
                continue
            job = session.get(BackgroundJob, identifier)
            try:
                if job is None:
                    raise ValueError
                intent = JOB_TYPES[action].model_validate(job.payload)
                _, checksum = _payload(intent.model_dump(mode="json"))
                if (
                    job.owner_user_id != stage.owner_user_id
                    or job.sync_epoch != stage.sync_epoch
                    or job.kind
                    != ("import_preview" if action in {"parse", "preview"} else "import_apply")
                    or job.payload != intent.model_dump(mode="json")
                    or job.payload_hash != checksum
                    or intent.stage_id != str(stage.id)
                    or intent.stage_version > stage.stage_version
                    or action in {"parse", "preview"}
                    and intent.source_sha256 != stage.source_sha256
                    or action in {"apply", "undo"}
                    and intent.batch_id != str(stage.batch_id)
                ):
                    raise ValueError
                items.append(
                    StageJobMetadata(
                        action=action,
                        job_id=str(job.id),
                        stage_version=intent.stage_version,
                        status=job.status,
                        attempt=job.attempt,
                        error_code=job.error_code,
                        available_at=job.available_at.isoformat(),
                        lease_until=job.lease_until.isoformat() if job.lease_until else None,
                    )
                )
            except (ValidationError, ValueError):
                raise ApiError("import_stage_jobs_changed", 409) from None
        return StageJobsMetadata(
            stage_id=str(stage.id), stage_version=stage.stage_version, jobs=items
        )

    return run_transaction(session, read)
