"""Validate byte-level input first, then hash its unchanged wire intent.

Do not hash model_dump(): interpreted defaults would erase the distinction
between absent and explicitly supplied fields.
"""

from dataclasses import dataclass

from .canonical import decode_body, operation_hash
from .schemas import PushRequest


@dataclass(frozen=True)
class ValidatedPush:
    request: PushRequest
    operation_hashes: tuple[str, ...]


def parse_push_body(raw: bytes, *, limit: int = 1024 * 1024) -> ValidatedPush:
    body = decode_body(raw, limit=limit)
    request = PushRequest.model_validate(body)
    hashes = tuple(
        operation_hash(body["protocol_version"], body["sync_epoch"], operation)
        for operation in body["operations"]
    )
    return ValidatedPush(request=request, operation_hashes=hashes)
