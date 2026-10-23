from datetime import timedelta
from uuid import uuid4

import pytest
from sqlalchemy import func, select

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import AdminRole, User, UserSession
from flowtrace_server.auth.service import now
from flowtrace_server.configuration.models import ConfigurationHead, ConfigurationRevision
from flowtrace_server.configuration.schemas import (
    ConfigurationRollbackCommand,
    ConfigurationSaveCommand,
    PreparedSecretReferencePatch,
    PublicConfigurationPatch,
)
from flowtrace_server.configuration.service import (
    list_revisions,
    preview_configuration,
    read_configuration,
    read_revision,
    request_hash,
    rollback_configuration,
    save_configuration,
)

from .conftest import PASSWORD


def accepted(public, refs):
    assert public.attachment_max_bytes <= public.per_user_attachment_quota_bytes


def command(base=0, *, request_id=None, secret_patch=None, **patch):
    return ConfigurationSaveCommand(
        base_version=base,
        request_id=request_id or uuid4(),
        public_patch=PublicConfigurationPatch(**patch),
        prepared_secret_refs=secret_patch or PreparedSecretReferencePatch(),
    )


def save(session, principal, request, validator=accepted, password=PASSWORD):
    return save_configuration(
        session, principal, request, password=password, validate_candidate=validator
    )


def test_preview_is_read_only_and_effective_fields_require_facade(config_system):
    session, principal = config_system
    initial = read_configuration(session, principal)
    assert initial.version == 0 and initial.effective_fields == ()
    candidate = preview_configuration(
        session, principal, PublicConfigurationPatch(registration_enabled=False)
    )
    assert candidate.version == 0 and not candidate.public_values.registration_enabled
    assert read_configuration(session, principal) == initial
    assert session.scalar(select(func.count()).select_from(ConfigurationRevision)) == 0
    assert not session.new and not session.dirty


def test_save_records_one_snapshot_and_safe_audit(config_system):
    session, principal = config_system
    reference = uuid4()
    request = command(
        secret_patch=PreparedSecretReferencePatch(ocr_api_key=reference),
        invitation_default_days=9,
    )
    outcome = save(session, principal, request)
    assert outcome.version == 1 and not outcome.replayed
    revision = session.get(ConfigurationRevision, 1)
    assert revision.secret_refs == {"ocr_api_key": str(reference), "ai_api_key": None}
    assert revision.public_values["invitation_default_days"] == 9
    view = read_configuration(session, principal)
    assert view.secret_presence.ocr_api_key
    assert str(reference) not in view.model_dump_json()
    record = session.scalar(select(AdminAudit).where(AdminAudit.action == "configuration.update"))
    assert record.target_id == request.request_id
    assert record.summary == {"version": 1, "base_version": 0}
    assert str(reference) not in str(record.summary)


def test_request_replay_returns_original_version_after_later_change(config_system):
    session, principal = config_system
    first = command(registration_enabled=False)
    save(session, principal, first)
    save(session, principal, command(1, invitation_default_days=8))

    def must_not_run(public, refs):
        pytest.fail("Replay must not re-prepare or revalidate already-published secret refs")

    replay = save(session, principal, first, must_not_run)
    assert replay.version == 1 and replay.replayed
    assert read_configuration(session, principal).version == 2
    assert session.scalar(select(func.count()).select_from(ConfigurationRevision)) == 2
    assert (
        session.scalar(
            select(func.count())
            .select_from(AdminAudit)
            .where(AdminAudit.action.like("configuration.%"))
        )
        == 2
    )


def test_request_hash_preserves_delete_replace_and_absent_semantics():
    actor, request_id, reference = uuid4(), uuid4(), uuid4()
    keep = command(request_id=request_id)
    delete = command(
        request_id=request_id, secret_patch=PreparedSecretReferencePatch(ocr_api_key=None)
    )
    replace = command(
        request_id=request_id, secret_patch=PreparedSecretReferencePatch(ocr_api_key=reference)
    )
    assert len({request_hash(actor, item) for item in (keep, delete, replace)}) == 3
    assert request_hash(actor, keep) != request_hash(uuid4(), keep)
    without_explicit_default = ConfigurationSaveCommand(
        base_version=0, request_id=request_id, public_patch=PublicConfigurationPatch()
    )
    assert request_hash(actor, keep) == request_hash(actor, without_explicit_default)


def test_request_uuid_conflict_and_cas_reject_without_history(config_system):
    session, principal = config_system
    first = command(invitation_default_days=8)
    save(session, principal, first)
    for request, code in (
        (
            command(request_id=first.request_id, invitation_default_days=9),
            "configuration_request_conflict",
        ),
        (command(invitation_default_days=9), "configuration_version_conflict"),
        (
            command(
                request_id=first.request_id,
                invitation_default_days=8,
                secret_patch=PreparedSecretReferencePatch(ocr_api_key=None),
            ),
            "configuration_request_conflict",
        ),
    ):
        with pytest.raises(ApiError) as caught:
            save(session, principal, request)
        assert caught.value.code == code
    assert session.scalar(select(func.count()).select_from(ConfigurationRevision)) == 1


def test_replay_still_requires_current_password(config_system):
    session, principal = config_system
    request = command(invitation_default_days=8)
    save(session, principal, request)
    with pytest.raises(ApiError) as caught:
        save(session, principal, request, password="Wrong-current-password-2026")
    assert caught.value.code == "reauthentication_failed"


@pytest.mark.parametrize(
    "change", ["recovery_only", "disabled", "session_revoked", "session_expired"]
)
def test_reads_and_mutations_recheck_current_identity(config_system, change):
    session, principal = config_system
    # The stale Principal still advertises the original privileged roles.
    if change == "recovery_only":
        for role in session.scalars(
            select(AdminRole).where(AdminRole.user_id == principal.user_id)
        ):
            if role.role != "recovery_admin":
                session.delete(role)
    elif change == "disabled":
        session.get(User, principal.user_id).enabled = False
    elif change == "session_revoked":
        session.get(UserSession, principal.session_id).revoked_at = now()
    else:
        session.get(UserSession, principal.session_id).expires_at = now() - timedelta(seconds=1)
    session.flush()
    with pytest.raises(ApiError):
        read_configuration(session, principal)
    with pytest.raises(ApiError):
        save(session, principal, command())
    assert session.scalar(select(func.count()).select_from(ConfigurationRevision)) == 0


def test_rollback_creates_new_revision_and_revalidates_historical_refs(config_system):
    session, principal = config_system
    reference = uuid4()
    save(
        session,
        principal,
        command(secret_patch=PreparedSecretReferencePatch(ocr_api_key=reference)),
    )
    save(
        session,
        principal,
        command(
            1,
            secret_patch=PreparedSecretReferencePatch(ocr_api_key=None),
            invitation_default_days=9,
        ),
    )
    checks = []

    def check(public, refs):
        checks.append(refs.ocr_api_key)

    rollback = ConfigurationRollbackCommand(base_version=2, target_version=1, request_id=uuid4())
    result = rollback_configuration(
        session, principal, rollback, password=PASSWORD, validate_candidate=check
    )
    assert result.version == 3 and checks == [reference]
    assert read_configuration(session, principal).secret_presence.ocr_api_key
    assert session.get(ConfigurationRevision, 2).secret_refs["ocr_api_key"] is None
    assert session.get(ConfigurationRevision, 3).rollback_target_version == 1
    replay = rollback_configuration(
        session, principal, rollback, password=PASSWORD, validate_candidate=check
    )
    assert replay.replayed and replay.version == 3 and checks == [reference]
    reset = ConfigurationRollbackCommand(base_version=3, target_version=0, request_id=uuid4())
    rollback_configuration(
        session, principal, reset, password=PASSWORD, validate_candidate=accepted
    )
    initial = read_configuration(session, principal)
    assert initial.version == 4 and initial.public_values.invitation_default_days == 7
    assert not initial.secret_presence.ocr_api_key


def test_invalid_rollback_target_is_closed(config_system):
    session, principal = config_system
    save(session, principal, command())
    for target in (1, 2, 999999):
        with pytest.raises(ApiError) as caught:
            rollback_configuration(
                session,
                principal,
                ConfigurationRollbackCommand(
                    base_version=1, target_version=target, request_id=uuid4()
                ),
                password=PASSWORD,
                validate_candidate=accepted,
            )
        assert caught.value.code == "configuration_rollback_target_invalid"


def test_validator_failure_preserves_caller_pending_write_and_no_revision(config_system):
    session, principal = config_system
    user = session.get(User, principal.user_id)
    user.username = "configuration_pending_username"

    def reject(public, refs):
        raise ApiError("provider_not_registered", 409)

    with pytest.raises(ApiError):
        save(session, principal, command(ocr_provider="ocr_primary"), reject)
    assert session.get(User, principal.user_id).username == "configuration_pending_username"
    assert session.get(ConfigurationHead, 1).current_version == 0
    assert session.scalar(select(func.count()).select_from(ConfigurationRevision)) == 0


def test_history_paginates_without_secret_references(config_system):
    session, principal = config_system
    reference = uuid4()
    for version in range(22):
        save(
            session,
            principal,
            command(version, secret_patch=PreparedSecretReferencePatch(ai_api_key=reference)),
        )
    first = list_revisions(session, principal)
    second = list_revisions(session, principal, before=first["next_cursor"])
    assert [item["version"] for item in first["items"]] == list(range(22, 2, -1))
    assert [item["version"] for item in second["items"]] == [2, 1]
    assert first["has_more"] and not second["has_more"]
    assert str(reference) not in str(first)
    with pytest.raises(ApiError):
        list_revisions(session, principal, before=True)


def test_api_principal_never_inherits_admin_configuration_scope(config_system):
    session, principal = config_system
    api = Principal(
        principal.user_id, principal.session_id, principal.client_id, "api_native", principal.roles
    )
    with pytest.raises(ApiError):
        read_configuration(session, api)


def test_revision_read_and_success_rollback_keep_caller_transaction_owned(config_system):
    session, principal = config_system
    reference = uuid4()
    save(
        session,
        principal,
        command(secret_patch=PreparedSecretReferencePatch(ai_api_key=reference)),
    )
    historical = read_revision(session, principal, 1)
    assert historical.version == 1 and historical.secret_presence.ai_api_key
    assert str(reference) not in historical.model_dump_json()
    session.rollback()
    assert read_configuration(session, principal).version == 0
    assert session.get(ConfigurationRevision, 1) is None
    assert not read_revision(session, principal, 0).secret_presence.ai_api_key
    for target in (True, -1, 2**63, 1):
        with pytest.raises(ApiError):
            read_revision(session, principal, target)


def test_cross_actor_request_reuse_is_conflict_even_with_same_payload(config_system):
    from flowtrace_server.auth.service import PASSWORDS, issue_session

    session, principal = config_system
    request = command(invitation_default_days=9)
    save(session, principal, request)
    other_user = User(
        id=uuid4(),
        username="configuration_other_service",
        password_hash=PASSWORDS.hash(PASSWORD),
        enabled=True,
        created_at=now(),
    )
    session.add(other_user)
    session.flush()
    session.add(AdminRole(user_id=other_user.id, role="service_admin"))
    record, _ = issue_session(session, other_user, uuid4(), "second administrator", "admin")
    other = Principal(other_user.id, record.id, record.client_id, "admin", frozenset())
    with pytest.raises(ApiError) as caught:
        save(session, other, request)
    assert caught.value.code == "configuration_request_conflict"
    assert read_configuration(session, other).version == 1


def test_real_second_connection_blocks_then_rechecks_cas(postgres_engine, committed_config_actor):
    from sqlalchemy import text
    from sqlalchemy.exc import OperationalError
    from sqlalchemy.orm import Session

    principal, owned_requests, base = committed_config_actor
    winner = command(base, invitation_default_days=8)
    loser = command(base, invitation_default_days=9)
    owned_requests.extend((winner.request_id, loser.request_id))
    with Session(postgres_engine) as first, Session(postgres_engine) as second:
        save(first, principal, winner)
        second.execute(text("SET LOCAL lock_timeout='250ms'"))
        with pytest.raises(OperationalError) as caught:
            save(second, principal, loser)
        assert caught.value.orig.sqlstate == "55P03"
        second.rollback()
        first.commit()
        with pytest.raises(ApiError) as conflict:
            save(second, principal, loser)
        assert conflict.value.code == "configuration_version_conflict"
        second.rollback()
        view = read_configuration(second, principal)
        assert view.version == base + 1 and view.public_values.invitation_default_days == 8


def test_database_constraints_reject_unknown_keys_and_null_rollback_target(config_system):
    from sqlalchemy import text
    from sqlalchemy.exc import IntegrityError

    session, principal = config_system
    with pytest.raises(IntegrityError), session.begin_nested():
        session.execute(
            text(
                "UPDATE service_configuration SET secret_refs=secret_refs || CAST(:extra AS jsonb)"
            ),
            {"extra": '{"unknown": null}'},
        )
    save(session, principal, command())
    with pytest.raises(IntegrityError), session.begin_nested():
        session.execute(
            text(
                "UPDATE service_configuration_revisions "
                "SET change_kind='rollback',rollback_target_version=NULL WHERE version=1"
            )
        )
