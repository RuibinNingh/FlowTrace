"""Immutable private secret references; never returned by management views.

Windows uses current-user DPAPI with UI forbidden, without machine-wide scope.
POSIX uses service-owned 0700/0600 files, not an encryption-at-rest claim. Secret
material is intentionally excluded from ordinary database/attachment backups.
"""

import base64
import ctypes
import json
import os
import secrets
import stat
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from time import monotonic, sleep
from uuid import UUID, uuid5

import portalocker
from pydantic import SecretStr

from flowtrace_server.persistence.private_files import prepare_file, private_directory, private_open

FIELDS = frozenset({"ocr_api_key", "ai_api_key"})
MAX_PAYLOAD_BYTES = 65536
MAX_ENVELOPE_BYTES = 131072
REFERENCE_NAMESPACE = UUID("477d6725-f87c-44d4-8d24-218749557098")


class SecretStorageError(RuntimeError):
    pass


@dataclass(frozen=True)
class PreparedSecret:
    reference: UUID
    field: str
    actor_id: UUID
    base_version: int
    request_id: UUID


def _dpapi(content: bytes, reference: UUID, *, decrypt=False) -> bytes:
    # API contract: https://learn.microsoft.com/windows/win32/api/dpapi/
    # nf-dpapi-cryptprotectdata ; allocated output is released with LocalFree.
    from ctypes import wintypes

    class Blob(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("data", ctypes.POINTER(ctypes.c_ubyte))]

    incoming = ctypes.create_string_buffer(content)
    entropy_buffer = ctypes.create_string_buffer(b"flowtrace-config-secret-v1:" + reference.bytes)
    source = Blob(len(content), ctypes.cast(incoming, ctypes.POINTER(ctypes.c_ubyte)))
    entropy = Blob(
        len(entropy_buffer.raw) - 1,
        ctypes.cast(entropy_buffer, ctypes.POINTER(ctypes.c_ubyte)),
    )
    output = Blob()
    crypt = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    function = crypt.CryptUnprotectData if decrypt else crypt.CryptProtectData
    function.argtypes = [
        ctypes.POINTER(Blob),
        ctypes.c_void_p,
        ctypes.POINTER(Blob),
        ctypes.c_void_p,
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(Blob),
    ]
    function.restype = wintypes.BOOL
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    try:
        if not function(
            ctypes.byref(source),
            None,
            ctypes.byref(entropy),
            None,
            None,
            1,
            ctypes.byref(output),
        ):
            raise SecretStorageError("secret_protection_unavailable")
        if not 0 < output.size <= MAX_ENVELOPE_BYTES:
            raise SecretStorageError("secret_protection_invalid")
        return ctypes.string_at(output.data, output.size)
    finally:
        ctypes.memset(incoming, 0, len(incoming))
        if output.data:
            ctypes.memset(output.data, 0, output.size)
            kernel.LocalFree(output.data)


class SecretVault:
    def __init__(self, data_directory: Path):
        self.root = private_directory(data_directory.absolute() / "configuration-secrets")

    @contextmanager
    def _prepare_guard(self):
        path = self.root / "prepare.lock"
        prepare_file(path, self.root)
        with private_open(path, self.root, append=True) as stream:
            started = monotonic()
            while True:
                try:
                    portalocker.lock(stream, portalocker.LOCK_EX | portalocker.LOCK_NB)
                    break
                except portalocker.exceptions.LockException:
                    if monotonic() - started >= 5:
                        raise SecretStorageError("secret_storage_busy") from None
                    sleep(0.01)
            try:
                yield
            finally:
                portalocker.unlock(stream)

    def prepare(
        self,
        field: str,
        value: SecretStr,
        *,
        actor_id: UUID,
        base_version: int,
        request_id: UUID,
    ) -> PreparedSecret:
        if (
            field not in FIELDS
            or not isinstance(value, SecretStr)
            or not isinstance(actor_id, UUID)
            or not isinstance(request_id, UUID)
            or type(base_version) is not int
            or not 0 <= base_version < 2**63 - 1
        ):
            raise SecretStorageError("secret_input_invalid")
        plain = value.get_secret_value()
        if not 1 <= len(plain) <= 4096 or any(char in plain for char in "\x00\r\n"):
            raise SecretStorageError("secret_input_invalid")
        reference = uuid5(REFERENCE_NAMESPACE, f"{actor_id}:{base_version}:{request_id}:{field}")
        payload = json.dumps(
            {
                "reference": str(reference),
                "field": field,
                "actor_id": str(actor_id),
                "base_version": base_version,
                "request_id": str(request_id),
                "value": plain,
            },
            separators=(",", ":"),
            ensure_ascii=True,
        ).encode()
        if len(payload) > MAX_PAYLOAD_BYTES:
            raise SecretStorageError("secret_input_too_large")
        method = "dpapi-current-user" if os.name == "nt" else "posix-private-file"
        protected = _dpapi(payload, reference) if os.name == "nt" else payload
        envelope = json.dumps(
            {
                "format": "flowtrace-config-secret-v1",
                "protection": method,
                "content": base64.b64encode(protected).decode("ascii"),
            },
            separators=(",", ":"),
        ).encode()
        if len(envelope) > MAX_ENVELOPE_BYTES:
            raise SecretStorageError("secret_input_too_large")
        prepared = PreparedSecret(reference, field, actor_id, base_version, request_id)
        try:
            with self._prepare_guard():
                target = self.root / f"{reference}.json"
                if target.exists():
                    self.validate_prepared(prepared)
                    existing = self._load(reference)["value"]
                    if not secrets.compare_digest(existing.encode("utf-8"), plain.encode("utf-8")):
                        raise SecretStorageError("secret_preparation_conflict")
                    return prepared
                with private_open(target, self.root, create=True) as stream:
                    stream.write(envelope)
                    stream.flush()
                    os.fsync(stream.fileno())
        except OSError:
            raise SecretStorageError("secret_storage_unavailable") from None
        return prepared

    def _load(self, reference: UUID) -> dict:
        if not isinstance(reference, UUID):
            raise SecretStorageError("secret_reference_invalid")
        try:
            with private_open(self.root / f"{reference}.json", self.root) as stream:
                if os.name != "nt" and stat.S_IMODE(os.fstat(stream.fileno()).st_mode) & 0o077:
                    raise SecretStorageError("secret_storage_permissions_invalid")
                raw = stream.read(MAX_ENVELOPE_BYTES + 1)
            if len(raw) > MAX_ENVELOPE_BYTES:
                raise ValueError
            envelope = json.loads(raw)
            expected = "dpapi-current-user" if os.name == "nt" else "posix-private-file"
            if (
                set(envelope) != {"format", "protection", "content"}
                or envelope["format"] != "flowtrace-config-secret-v1"
                or envelope["protection"] != expected
            ):
                raise ValueError
            content = base64.b64decode(envelope["content"], validate=True)
            if os.name == "nt":
                content = _dpapi(content, reference, decrypt=True)
            if len(content) > MAX_PAYLOAD_BYTES:
                raise ValueError
            payload = json.loads(content)
            if (
                set(payload)
                != {"reference", "field", "actor_id", "base_version", "request_id", "value"}
                or payload["reference"] != str(reference)
                or payload["field"] not in FIELDS
                or str(UUID(payload["actor_id"])) != payload["actor_id"]
                or str(UUID(payload["request_id"])) != payload["request_id"]
                or type(payload["base_version"]) is not int
                or not 0 <= payload["base_version"] < 2**63 - 1
                or not isinstance(payload["value"], str)
                or not 1 <= len(payload["value"]) <= 4096
                or any(char in payload["value"] for char in "\x00\r\n")
            ):
                raise ValueError
            return payload
        except (OSError, ValueError, TypeError, KeyError, AttributeError):
            raise SecretStorageError("secret_reference_unavailable") from None

    def validate_prepared(self, prepared: PreparedSecret) -> UUID:
        if not isinstance(prepared, PreparedSecret):
            raise SecretStorageError("secret_reference_invalid")
        payload = self._load(prepared.reference)
        if (
            payload["field"] != prepared.field
            or payload["actor_id"] != str(prepared.actor_id)
            or payload["base_version"] != prepared.base_version
            or payload["request_id"] != str(prepared.request_id)
        ):
            raise SecretStorageError("secret_preparation_mismatch")
        return prepared.reference

    def read(self, reference: UUID, field: str) -> SecretStr:
        payload = self._load(reference)
        if field not in FIELDS or payload["field"] != field:
            raise SecretStorageError("secret_reference_mismatch")
        return SecretStr(payload["value"])
