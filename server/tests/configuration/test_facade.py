"""Private preparation, exact replay and final current authority checks."""

from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4

import pytest
from pydantic import SecretStr
from sqlalchemy import func, select, update
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import User
from flowtrace_server.config import Settings
from flowtrace_server.configuration.facade import (
    check_admin_provider,
    read_admin_configuration,
    save_admin_configuration,
)
from flowtrace_server.configuration.models import ConfigurationHead, ConfigurationRevision
from flowtrace_server.configuration.providers import ProviderRegistry
from flowtrace_server.configuration.schemas import PublicConfigurationPatch

from .conftest import PASSWORD


def save(
    session, principal, settings, *, request_id=None, base=0, value=None, password=PASSWORD, **patch
):
    return save_admin_configuration(
        session,
        principal,
        settings,
        base_version=base,
        request_id=request_id or uuid4(),
        public_patch=PublicConfigurationPatch(**patch),
        secret_changes={}
        if value is None
        else {"ai_api_key": {"action": "replace", "value": SecretStr(value)}},
        password=password,
    )


def test_secret_prepare_replay_is_exact_after_later_configuration(config_system, tmp_path):
    session, principal = config_system
    settings = Settings(_env_file=None, data_directory=tmp_path)
    request = uuid4()
    first = save(session, principal, settings, request_id=request, value="synthetic-secret-one")
    assert first.version == 1
    save(session, principal, settings, base=1, invitation_default_days=8)
    repeated = save(session, principal, settings, request_id=request, value="synthetic-secret-one")
    assert repeated.version == 1 and repeated.replayed
    assert len(list((tmp_path / "configuration-secrets").glob("*.json"))) == 1
    with pytest.raises(ApiError) as error:
        save(session, principal, settings, request_id=request, value="synthetic-secret-two")
    assert error.value.code == "configuration_request_conflict"
    assert session.get(ConfigurationHead, 1).current_version == 2
    detail = read_admin_configuration(session, principal, settings)
    assert detail["secret_states"]["ai_api_key"] == "available"
    assert "synthetic-secret" not in str(detail)
    revisions = list(session.scalars(select(ConfigurationRevision)))
    audits = list(session.scalars(select(AdminAudit)))
    assert all("synthetic-secret" not in str(row.secret_refs) for row in revisions)
    assert all("synthetic-secret" not in str(row.summary) for row in audits)


def test_bad_password_cannot_prepare_secret_files(config_system, tmp_path):
    session, principal = config_system
    settings = Settings(_env_file=None, data_directory=tmp_path)
    with pytest.raises(ApiError) as error:
        save(session, principal, settings, value="synthetic-no-file", password="wrong-password-123")
    assert error.value.code == "reauthentication_failed"
    assert not (tmp_path / "configuration-secrets").exists()
    assert session.get(ConfigurationHead, 1).current_version == 0


def test_unregistered_provider_cannot_publish_and_unpublished_preparation_is_preserved(
    config_system, tmp_path
):
    session, principal = config_system
    settings = Settings(_env_file=None, data_directory=tmp_path)
    with pytest.raises(ApiError) as error:
        save(session, principal, settings, value="synthetic-unpublished", ai_provider="ai_primary")
    assert error.value.code == "provider_not_registered"
    assert session.get(ConfigurationHead, 1).current_version == 0
    assert session.scalar(select(func.count()).select_from(ConfigurationRevision)) == 0
    assert len(list((tmp_path / "configuration-secrets").glob("*.json"))) == 1


def test_unavailable_historical_reference_is_reported_without_echo(config_system, tmp_path):
    session, principal = config_system
    settings = Settings(_env_file=None, data_directory=tmp_path)
    head = session.get(ConfigurationHead, 1)
    missing = uuid4()
    head.secret_refs = {"ocr_api_key": None, "ai_api_key": str(missing)}
    session.flush()
    detail = read_admin_configuration(session, principal, settings)
    assert detail["secret_states"]["ai_api_key"] == "unavailable"
    assert str(missing) not in str(detail)
    outcome = save_admin_configuration(
        session,
        principal,
        settings,
        base_version=0,
        request_id=uuid4(),
        public_patch=PublicConfigurationPatch(),
        secret_changes={"ai_api_key": {"action": "delete", "value": None}},
        password=PASSWORD,
    )
    assert outcome.version == 1
    assert read_admin_configuration(session, principal, settings)["secret_states"][
        "ai_api_key"
    ] == ("not_configured")


def test_connection_check_releases_locks_and_rejects_owner_disabled_during_probe(
    postgres_engine, committed_config_actor, tmp_path, monkeypatch
):
    principal, _, baseline = committed_config_actor
    settings = Settings(_env_file=None, data_directory=tmp_path)

    def competing_disable():
        with Session(postgres_engine) as other, other.begin():
            other.connection().exec_driver_sql("SET LOCAL lock_timeout='500ms'")
            other.execute(update(User).where(User.id == principal.user_id).values(enabled=False))

    def probe(*_):
        with ThreadPoolExecutor(max_workers=1) as executor:
            executor.submit(competing_disable).result(timeout=5)
        return {"provider_id": "ai_primary", "code": "provider_reachable", "duration_ms": 1}

    monkeypatch.setattr(ProviderRegistry, "check", probe)
    with Session(postgres_engine) as session:
        with pytest.raises(ApiError) as error:
            check_admin_provider(
                session,
                principal,
                settings,
                provider_id="ai_primary",
                expected_version=baseline,
                password=PASSWORD,
            )
        assert error.value.code == "session_invalid"
        session.rollback()
        assert (
            session.scalar(
                select(func.count())
                .select_from(AdminAudit)
                .where(
                    AdminAudit.actor_id == principal.user_id,
                    AdminAudit.action == "configuration.connection_check",
                )
            )
            == 0
        )


def test_connection_check_rejects_configuration_changed_during_probe(
    postgres_engine, committed_config_actor, tmp_path, monkeypatch
):
    principal, requests, baseline = committed_config_actor
    settings = Settings(_env_file=None, data_directory=tmp_path)
    request_id = uuid4()
    requests.append(request_id)

    def probe(*_):
        with Session(postgres_engine) as other, other.begin():
            save(
                other,
                principal,
                settings,
                request_id=request_id,
                base=baseline,
                invitation_default_days=9,
            )
        return {"provider_id": "ai_primary", "code": "provider_reachable", "duration_ms": 1}

    monkeypatch.setattr(ProviderRegistry, "check", probe)
    with Session(postgres_engine) as session:
        with pytest.raises(ApiError) as error:
            check_admin_provider(
                session,
                principal,
                settings,
                provider_id="ai_primary",
                expected_version=baseline,
                password=PASSWORD,
            )
        assert error.value.code == "configuration_version_conflict"
        session.rollback()
        assert (
            session.scalar(
                select(func.count())
                .select_from(AdminAudit)
                .where(
                    AdminAudit.actor_id == principal.user_id,
                    AdminAudit.action == "configuration.connection_check",
                )
            )
            == 0
        )
