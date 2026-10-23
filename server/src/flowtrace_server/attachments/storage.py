import hashlib
import os
import re
import secrets
from collections.abc import AsyncIterable
from pathlib import Path
from uuid import UUID

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.persistence.private_files import (
    private_directory,
    private_open,
    private_unlink,
    regular_file,
)

from .images import ImageInfo, validate_image

MAX_BYTES = 10 * 1024 * 1024
STORAGE_KEY = re.compile(r"[a-f0-9]{64}\Z")


class AttachmentStore:
    def __init__(self, root: Path):
        self.root = private_directory(root)
        self.staging = private_directory(self.root / "staging")
        self.objects = private_directory(self.root / "objects")

    def object_path(self, key: str, *, thumbnail: bool = False) -> Path:
        if not isinstance(key, str) or STORAGE_KEY.fullmatch(key) is None:
            raise ApiError("attachment_storage_key_invalid", 503)
        return self.objects / (key + (".webp" if thumbnail else ".bin"))

    async def receive(
        self,
        upload_id: UUID,
        chunks: AsyncIterable[bytes],
        expected_size: int,
        expected_sha256: str,
    ) -> Path:
        if not 1 <= expected_size <= MAX_BYTES:
            raise ApiError("body_too_large", 413)
        target = self.staging / f"{upload_id.hex}-{secrets.token_hex(16)}.part"
        size, checksum = 0, hashlib.sha256()
        try:
            with private_open(target, self.root, create=True) as output:
                async for chunk in chunks:
                    size += len(chunk)
                    if size > MAX_BYTES:
                        raise ApiError("body_too_large", 413)
                    if size > expected_size:
                        raise ApiError("size_mismatch", 422)
                    checksum.update(chunk)
                    output.write(chunk)
                output.flush()
                os.fsync(output.fileno())
            if size != expected_size:
                raise ApiError("size_mismatch", 422)
            if checksum.hexdigest() != expected_sha256:
                raise ApiError("hash_mismatch", 422)
            return target
        except BaseException:
            private_unlink(target, self.root)
            raise

    def publish(self, staged: Path, key: str, media_type: str) -> ImageInfo:
        regular_file(staged, self.root)
        if staged.parent != self.staging:
            raise ApiError("attachment_storage_key_invalid", 503)
        image = validate_image(staged, media_type)
        original = self.object_path(key)
        thumbnail = self.object_path(key, thumbnail=True)
        derivative = self.staging / f"{key}-{secrets.token_hex(16)}.part"
        try:
            with private_open(derivative, self.root, create=True) as output:
                output.write(image.thumbnail)
                output.flush()
                os.fsync(output.fileno())
            for target in (original, thumbnail):
                if target.exists() or target.is_symlink():
                    regular_file(target, self.root)
            os.replace(staged, original)
            os.replace(derivative, thumbnail)
            return image
        finally:
            private_unlink(derivative, self.root)

    def delete(self, key: str) -> None:
        private_unlink(self.object_path(key), self.root)
        private_unlink(self.object_path(key, thumbnail=True), self.root)

    def content(self, key: str, *, thumbnail: bool = False) -> bytes:
        with private_open(self.object_path(key, thumbnail=thumbnail), self.root) as stream:
            output = stream.read(MAX_BYTES + 1)
        if not output or len(output) > MAX_BYTES:
            raise ApiError("attachment_storage_unavailable", 503)
        return output

    def verify(
        self, key: str, expected_size: int, expected_sha256: str, media_type: str
    ) -> ImageInfo:
        content = self.content(key)
        if len(content) != expected_size or hashlib.sha256(content).hexdigest() != expected_sha256:
            raise ApiError("hash_mismatch", 422)
        self.content(key, thumbnail=True)
        return validate_image(self.object_path(key), media_type)

    def delete_staging(self, upload_id: UUID, key: str) -> None:
        if STORAGE_KEY.fullmatch(key) is None:
            raise ApiError("attachment_storage_key_invalid", 503)
        pattern = re.compile(rf"(?:{upload_id.hex}|{key})-[a-f0-9]{{32}}\.part\Z")
        for path in self.staging.iterdir():
            if pattern.fullmatch(path.name):
                private_unlink(path, self.root)
