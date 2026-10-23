"""Check the exact synthetic browser journey without printing credentials or refs."""

import argparse
import json
import os
import secrets
from pathlib import Path
from uuid import UUID, uuid4

from dotenv import dotenv_values
from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.config import Settings
from flowtrace_server.configuration.models import (
    ConfigurationHead,
    ConfigurationRevision,
)
from flowtrace_server.configuration.secrets import SecretVault
from flowtrace_server.persistence.database import build_engine
from flowtrace_server.persistence.testing import require_isolated_database
from sqlalchemy import select
from sqlalchemy.orm import Session


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    fixture_path = args.fixture.resolve()
    if not fixture_path.is_relative_to(root / "outputs/validation/P5/admin"):
        raise SystemExit("unexpected_fixture")
    fixture = json.loads(fixture_path.read_text(encoding="utf-8-sig"))
    values = dotenv_values(fixture["env_file"])
    require_isolated_database(
        values["FLOWTRACE_TEST_DATABASE_URL"], values["FLOWTRACE_ENVIRONMENT"]
    )
    credentials_path = Path(fixture["credentials_path"]).resolve()
    if not credentials_path.is_relative_to(root / "work/flowtrace-dev"):
        raise SystemExit("unexpected_private_fixture")
    credentials = json.loads(credentials_path.read_text(encoding="utf-8-sig"))
    settings = Settings(
        _env_file=None,
        database_url=values["FLOWTRACE_TEST_DATABASE_URL"],
        data_directory=Path(values["FLOWTRACE_DATA_DIRECTORY"]),
        environment="test",
    )
    engine = build_engine(settings)
    try:
        with Session(engine) as session:
            head = session.get(ConfigurationHead, 1)
            revisions = list(
                session.scalars(
                    select(ConfigurationRevision).order_by(
                        ConfigurationRevision.version
                    )
                )
            )
            assert head.current_version == 5 and len(revisions) == 5
            first, deleted, restored, reset, service = revisions
            original_ref = first.secret_refs["ai_api_key"]
            assert original_ref is not None
            assert deleted.secret_refs["ai_api_key"] is None
            assert restored.secret_refs["ai_api_key"] == original_ref
            assert reset.secret_refs["ai_api_key"] is None
            assert service.actor_user_id == UUID(
                fixture["identities"]["service"]["user_id"]
            )
            assert head.public_values["invitation_default_days"] == 8
            assert head.public_values["registration_enabled"] is True
            private = SecretVault(settings.data_directory)
            secret = private.read(UUID(original_ref), "ai_api_key")
            assert secrets.compare_digest(
                secret.get_secret_value(), credentials["configuration_ai_secret"]
            )
            archived = (private.root / f"{original_ref}.json").read_text(
                encoding="utf-8"
            )
            if os.name == "nt":
                assert credentials["configuration_ai_secret"] not in archived
            audits = list(
                session.scalars(
                    select(AdminAudit).where(AdminAudit.action.like("configuration.%"))
                )
            )
            assert all(
                all(type(value) in (bool, int) for value in item.summary.values())
                for item in audits
            )
            assert credentials["configuration_ai_secret"] not in str(
                [item.summary for item in audits]
            )
            connections = [
                item
                for item in audits
                if item.action == "configuration.connection_check"
                and item.summary.get("succeeded")
            ]
            assert len(connections) == 1
            assert connections[0].summary["version"] == 1
            assert (
                len([item for item in audits if item.summary.get("succeeded") is False])
                >= 2
            )
        events = [
            json.loads(line)
            for line in (fixture_path.parent / "configuration-provider-events.jsonl")
            .read_text()
            .splitlines()
        ]
        assert events == [
            {"fixed_models_path": True, "authorized": True, "status": 200}
        ]
        result = {
            "kind": "configuration-real-browser-postconditions",
            "final_version": 5,
            "revision_count": 5,
            "same_historical_secret_restored": True,
            "historical_secret_retained_after_default_rollback": True,
            "host_protection": "dpapi-current-user"
            if os.name == "nt"
            else "posix-private-file",
            "service_role_created_final_revision": True,
            "real_fixed_provider_calls": len(events),
            "successful_connection_audits": len(connections),
            "audit_summaries_are_fixed_metadata": True,
        }
        output = fixture_path.parent / f"configuration-postconditions-{uuid4()}.json"
        output.write_text(
            json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(json.dumps({"receipt": str(output), **result}, ensure_ascii=False))
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
