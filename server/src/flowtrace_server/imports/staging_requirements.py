"""Version-bound persistent source references and private keyset pages."""

import base64
import hashlib

from sqlalchemy import delete, insert, select

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.sync.common import run_transaction

from .parsers import ImportFormatError, canonical, decode_json, digest
from .staging_models import ImportStageRequirement
from .staging_schemas import STAGE_MAX_REQUIREMENTS, StageRequirement, StageRequirementsPage

MAX_PAGE_BYTES = 1024 * 1024


def clear_stage_requirements(session, stage):
    removed = session.execute(
        delete(ImportStageRequirement).where(ImportStageRequirement.stage_id == stage.id)
    ).rowcount
    stage.requirements_version = stage.requirements_hash = None
    stage.requirements_count = 0
    return removed


def key_hash(item):
    return digest(
        {key: getattr(item, key) for key in ("kind", "source_kind", "resource_type", "source_key")}
    )


class RequirementCollector:
    """Bound source-only derivation; no financial writes or authority inference."""

    def __init__(self, *, check_budget):
        if not callable(check_budget):
            raise TypeError("trusted_budget_callback_required")
        self.references, self.definitions, self.check_budget = {}, set(), check_budget

    def add(self, parsed):
        self.check_budget()
        if parsed.defined_source_id is not None:
            self.definitions.add(parsed.defined_source_id)
        for item in parsed.requirements:
            self.check_budget()
            self.references.setdefault(item.identity, item)
            # Up to 200k native definitions may satisfy forward references.
            # The final external-reference limit remains 200k, not 400k.
            if len(self.references) > STAGE_MAX_REQUIREMENTS * 2:
                raise ImportFormatError("too_many_mapping_requirements", row=item.first_line)

    def persist(self, session, stage, manifest):
        sources = {source["source_id"]: source for source in manifest}
        count, pending, seen_hashes, whole = 0, [], {}, hashlib.sha256(b"[")
        for reference in self.references.values():
            self.check_budget()
            if (
                reference.source_kind == "identifier"
                and reference.kind != "image"
                and reference.source_key in self.definitions
            ):
                continue
            count += 1
            if count > STAGE_MAX_REQUIREMENTS:
                raise ImportFormatError("too_many_mapping_requirements", row=reference.first_line)
            item = StageRequirement(
                position=count,
                kind=reference.kind,
                source_kind=reference.source_kind,
                source_key=reference.source_key,
                resource_type=reference.resource_type,
                first_line=reference.first_line,
                attachment_source=(
                    sources.get(reference.source_key)
                    if reference.kind == "image" and reference.source_kind == "identifier"
                    else None
                ),
            )
            key = key_hash(item)
            previous = seen_hashes.setdefault(key, reference.identity)
            if previous != reference.identity:
                raise ImportFormatError("mapping_requirement_hash_collision")
            encoded = canonical(item.model_dump(mode="json"))
            whole.update((b"," if count > 1 else b"") + encoded)
            source = item.attachment_source
            pending.append(
                {
                    "stage_id": stage.id,
                    "position": count,
                    "parsed_version": stage.stage_version,
                    "kind": item.kind,
                    "source_kind": item.source_kind,
                    "source_key": item.source_key,
                    "resource_type": item.resource_type,
                    "key_sha256": key,
                    "first_line": item.first_line,
                    "attachment_sha256": source.sha256 if source else None,
                    "attachment_size_bytes": source.size_bytes if source else None,
                    "attachment_media_type": source.media_type if source else None,
                }
            )
            if len(pending) == 500:
                self.check_budget()
                session.execute(insert(ImportStageRequirement), pending)
                pending.clear()
        if pending:
            self.check_budget()
            session.execute(insert(ImportStageRequirement), pending)
        whole.update(b"]")
        stage.requirements_version = stage.stage_version
        stage.requirements_hash, stage.requirements_count = whole.hexdigest(), count
        self.check_budget()


def _item(row):
    source = (
        None
        if row.attachment_sha256 is None
        else dict(
            source_id=row.source_key,
            sha256=row.attachment_sha256,
            size_bytes=row.attachment_size_bytes,
            media_type=row.attachment_media_type,
        )
    )
    result = StageRequirement(
        position=row.position,
        kind=row.kind,
        source_kind=row.source_kind,
        source_key=row.source_key,
        resource_type=row.resource_type,
        first_line=row.first_line,
        attachment_source=source,
    )
    if key_hash(result) != row.key_sha256:
        raise ApiError("import_stage_requirements_changed", 409)
    return result


def _cursor(stage, after):
    value = canonical(
        dict(
            stage_id=str(stage.id),
            stage_version=stage.stage_version,
            requirements_hash=stage.requirements_hash,
            after=after,
        )
    )
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _after(stage, cursor):
    if cursor is None:
        return 0
    try:
        if not isinstance(cursor, str) or not 1 <= len(cursor) <= 512:
            raise ValueError
        value = decode_json(
            base64.b64decode(cursor + "=" * (-len(cursor) % 4), altchars=b"-_", validate=True)
        )
        after = value["after"]
        if type(after) is not int or not 1 <= after < stage.requirements_count:
            raise ValueError
        if cursor != _cursor(stage, after):
            raise ValueError
        return after
    except (ValueError, TypeError, KeyError, ImportFormatError):
        raise ApiError("import_stage_requirements_cursor_invalid", 422) from None


def stage_requirements(session, principal, stage_id, *, stage_version, cursor=None, limit=100):
    """Only the current real source owner/origin/epoch can read these names."""
    from .staging import _current, _stage

    if type(limit) is not int or not 1 <= limit <= 100:
        raise ApiError("import_stage_page_size_invalid", 422)

    def read():
        state = _current(session, principal)
        stage = _stage(session, principal, stage_id, state, version=stage_version)
        if stage.source_released_at is not None:
            raise ApiError("import_stage_source_released", 410)
        if stage.status not in {"parsed", "ready", "applied", "undone", "failed"} or (
            stage.requirements_version != stage.stage_version or stage.requirements_hash is None
        ):
            raise ApiError("import_stage_requirements_unavailable", 409)
        after = _after(stage, cursor)
        values = list(
            session.scalars(
                select(ImportStageRequirement)
                .where(
                    ImportStageRequirement.stage_id == stage.id,
                    ImportStageRequirement.parsed_version == stage.stage_version,
                    ImportStageRequirement.position > after,
                )
                .order_by(ImportStageRequirement.position)
                .limit(limit + 1)
            )
        )
        expected = min(limit + 1, stage.requirements_count - after)
        if len(values) != expected or [row.position for row in values] != list(
            range(after + 1, after + expected + 1)
        ):
            raise ApiError("import_stage_requirements_changed", 409)
        items, size = [], 0
        for row in values[:limit]:
            item = _item(row)
            encoded_size = len(canonical(item.model_dump(mode="json"))) + 1
            if size + encoded_size > MAX_PAGE_BYTES - 2048:
                if not items:
                    raise ApiError("import_stage_requirement_response_too_large", 422)
                break
            items.append(item)
            size += encoded_size
        has_more = after + len(items) < stage.requirements_count
        result = StageRequirementsPage(
            stage_id=str(stage.id),
            stage_version=stage.stage_version,
            requirements_hash=stage.requirements_hash,
            items=items,
            has_more=has_more,
            next_cursor=_cursor(stage, items[-1].position) if has_more else None,
        )
        if len(canonical(result.model_dump(mode="json"))) > MAX_PAGE_BYTES:
            raise ApiError("import_stage_requirements_response_too_large", 422)
        return result

    return run_transaction(session, read)
