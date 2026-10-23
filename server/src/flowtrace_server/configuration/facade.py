"""Management boundary for private preparation and fixed provider checks.

Save/rollback leave commit to the caller. A connection check explicitly ends a
clean read transaction before network I/O, then reauthenticates and audits in a
new short transaction; its caller commits the final audit before responding.
"""

from pydantic import SecretStr, ValidationError
from sqlalchemy import select

from flowtrace_server.admin.service import audit, reauthenticate_admin, require_admin
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import User
from flowtrace_server.auth.service import PASSWORDS, assert_active_principal

from . import service
from .providers import PROVIDERS, ProviderRegistry
from .runtime import EFFECTIVE_FIELDS
from .schemas import (
    ConfigurationRollbackCommand,
    ConfigurationSaveCommand,
    PreparedSecretReferencePatch,
)
from .secrets import FIELDS, SecretStorageError, SecretVault


def read_runtime_capabilities(settings):
    return {
        "effective_fields": EFFECTIVE_FIELDS,
        "provider_catalog": ProviderRegistry(settings).public_catalog(),
        "pending_fields": (
            "backup_retention_days",
            "ocr_provider",
            "ai_provider",
        ),
    }


def _precheck(session, principal, password):
    # No admin-control/user FOR UPDATE lock is held during private preparation.
    assert_active_principal(session, principal, lock=False)
    require_admin(session, principal)
    password_hash = session.scalar(select(User.password_hash).where(User.id == principal.user_id))
    if (
        not isinstance(password, str)
        or not 12 <= len(password) <= 256
        or not PASSWORDS.verify(password, password_hash)
    ):
        raise ApiError("reauthentication_failed", 403)


def _validator(settings):
    registry = ProviderRegistry(settings)

    def validate(public, references):
        refs = references.model_dump()
        for key, reference in refs.items():
            if reference is not None:
                try:
                    SecretVault(settings.data_directory).read(reference, key)
                except (SecretStorageError, OSError):
                    raise ApiError("configuration_secret_unavailable", 409) from None
        for identity in (public.ocr_provider, public.ai_provider):
            if identity != "disabled":
                if not registry.contains(identity):
                    raise ApiError("provider_not_registered", 422)
                if refs[PROVIDERS[identity][0]] is None:
                    raise ApiError("provider_secret_missing", 422)

    return validate


def read_admin_configuration(session, principal, settings):
    service._require_read(session, principal)
    head = service._head(session)
    public, references = service._snapshot(head.public_values, head.secret_refs)
    view = service._view(
        head.current_version, public, references, effective_fields=EFFECTIVE_FIELDS
    )
    states = {}
    for key, reference in references.model_dump().items():
        if reference is None:
            states[key] = "not_configured"
        else:
            try:
                SecretVault(settings.data_directory).read(reference, key)
                states[key] = "available"
            except (SecretStorageError, OSError):
                states[key] = "unavailable"
    return {"configuration": view, "secret_states": states, **read_runtime_capabilities(settings)}


def save_admin_configuration(
    session,
    principal,
    settings,
    *,
    base_version,
    request_id,
    public_patch,
    secret_changes,
    password,
):
    _precheck(session, principal, password)
    if not isinstance(secret_changes, dict) or not set(secret_changes).issubset(FIELDS):
        raise ApiError("configuration_input_invalid", 422)
    prepared_refs = {}
    for key, change in secret_changes.items():
        if not isinstance(change, dict) or set(change) != {"action", "value"}:
            raise ApiError("configuration_input_invalid", 422)
        action, value = change["action"], change["value"]
        if action in {"keep", "delete"} and value is None:
            if action == "delete":
                prepared_refs[key] = None
        elif action == "replace" and isinstance(value, SecretStr):
            try:
                vault = SecretVault(settings.data_directory)
                prepared = vault.prepare(
                    key,
                    value,
                    actor_id=principal.user_id,
                    base_version=base_version,
                    request_id=request_id,
                )
                prepared_refs[key] = vault.validate_prepared(prepared)
            except SecretStorageError as error:
                code = (
                    "configuration_request_conflict"
                    if str(error) == ("secret_preparation_conflict")
                    else "configuration_secret_unavailable"
                )
                raise ApiError(code, 409) from None
            except OSError:
                raise ApiError("configuration_secret_unavailable", 503) from None
        else:
            raise ApiError("configuration_input_invalid", 422)
    try:
        command = ConfigurationSaveCommand(
            base_version=base_version,
            request_id=request_id,
            public_patch=public_patch,
            prepared_secret_refs=PreparedSecretReferencePatch(**prepared_refs),
        )
    except ValidationError:
        raise ApiError("configuration_input_invalid", 422) from None
    return service.save_configuration(
        session, principal, command, password=password, validate_candidate=_validator(settings)
    )


def rollback_admin_configuration(session, principal, settings, *, command, password):
    if not isinstance(command, ConfigurationRollbackCommand):
        raise ApiError("configuration_input_invalid", 422)
    return service.rollback_configuration(
        session, principal, command, password=password, validate_candidate=_validator(settings)
    )


def check_admin_provider(
    session,
    principal,
    settings,
    *,
    provider_id,
    expected_version,
    password,
):
    if provider_id not in PROVIDERS or type(expected_version) is not int or expected_version < 0:
        raise ApiError("configuration_input_invalid", 422)
    if session.new or session.dirty or session.deleted:
        raise ApiError("configuration_action_transaction_busy", 409)
    _precheck(session, principal, password)
    head = service._head(session)
    if head.current_version != expected_version:
        raise ApiError("configuration_version_conflict", 409)
    _, references = service._snapshot(head.public_values, head.secret_refs)
    frozen_refs = references.model_dump()
    session.commit()  # End read-only transaction before any network operation.
    result = ProviderRegistry(settings).check(
        provider_id, SecretVault(settings.data_directory), frozen_refs
    )
    reauthenticate_admin(session, principal, password, capability="service")
    head = service._head(session, lock=True)
    if head.current_version != expected_version:
        raise ApiError("configuration_version_conflict", 409)
    audit(
        session,
        principal.user_id,
        "configuration.connection_check",
        principal.user_id,
        version=expected_version,
        succeeded=result["code"] == "provider_reachable",
    )
    return {**result, "version": expected_version}
