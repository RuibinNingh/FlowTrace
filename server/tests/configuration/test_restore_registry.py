"""Only operator-registered isolated targets, without public secrets/paths."""

from uuid import uuid4

import pytest
from pydantic import ValidationError

from flowtrace_server.config import RestoreTargetConfig, Settings


def target(tmp_path, **changes):
    return {
        "label": "隔离恢复测试",
        "database_url": "postgresql+psycopg://fixture:synthetic-secret@localhost:55432/flowtrace_test_restore_registry",
        "data_directory": tmp_path / "isolated-target",
        "pg_restore_executable": tmp_path / "trusted-pg-restore.exe",
        **changes,
    }


def test_target_is_os_only_and_not_part_of_public_settings_or_backup(tmp_path):
    config = target(tmp_path)
    settings = Settings(
        _env_file=None, data_directory=tmp_path / "source", restore_targets={uuid4(): config}
    )
    assert "restore_targets" not in settings.model_dump()
    assert "synthetic-secret" not in repr(settings)
    item = next(iter(settings.restore_targets.values()))
    assert item.model_dump() == {"label": "隔离恢复测试"}
    assert "fixture" not in repr(item) and str(tmp_path) not in repr(item)


@pytest.mark.parametrize(
    "value",
    [
        "postgresql+psycopg://fixture:synthetic-secret@localhost:55432/production",
        "postgresql+psycopg://fixture:synthetic-secret@198.51.100.1/flowtrace_test_restore_registry",
        "postgresql+psycopg://fixture:synthetic-secret@localhost/flowtrace_test_restore_registry?hostaddr=198.51.100.1",
    ],
)
def test_nonisolated_targets_cannot_be_registered_or_echo_credentials(tmp_path, value):
    with pytest.raises(ValidationError) as error:
        RestoreTargetConfig(**target(tmp_path, database_url=value))
    assert "synthetic-secret" not in str(error.value)
    assert value not in str(error.value)


def test_source_database_alias_duplicate_targets_and_overlapping_directories_are_rejected(tmp_path):
    raw = target(tmp_path)
    source = raw["database_url"].replace("localhost", "127.0.0.1")
    with pytest.raises(ValidationError):
        Settings(
            _env_file=None,
            database_url=source,
            data_directory=tmp_path / "source",
            restore_targets={uuid4(): raw},
        )
    with pytest.raises(ValidationError):
        Settings(
            _env_file=None,
            data_directory=tmp_path / "source",
            restore_targets={uuid4(): raw, uuid4(): target(tmp_path, label="second")},
        )
    for directory in (tmp_path / "source", tmp_path, tmp_path / "source/child"):
        with pytest.raises(ValidationError):
            Settings(
                _env_file=None,
                data_directory=tmp_path / "source",
                restore_targets={uuid4(): target(tmp_path, data_directory=directory)},
            )


@pytest.mark.parametrize(
    "changes",
    [
        {"label": "\nprivate"},
        {"label": "\x7f"},
        {"label": "   "},
        {"data_directory": "relative"},
        {"pg_restore_executable": "relative"},
        {"extra_path": "never-accepted"},
    ],
)
def test_closed_target_requires_safe_label_and_explicit_absolute_paths(tmp_path, changes):
    with pytest.raises(ValidationError):
        RestoreTargetConfig(**target(tmp_path, **changes))
