"""Configuration never exposes database credentials in its public representation."""

import os
from pathlib import Path
from typing import Literal
from urllib.parse import urlsplit
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy.engine import make_url


class RestoreTargetConfig(BaseModel):
    """OS-only isolated rehearsal target; never an HTML/public JSON input."""

    model_config = ConfigDict(extra="forbid", hide_input_in_errors=True, frozen=True)
    label: str = Field(min_length=1, max_length=80)
    database_url: SecretStr = Field(exclude=True, repr=False)
    data_directory: Path = Field(exclude=True, repr=False)
    pg_restore_executable: Path = Field(exclude=True, repr=False)

    @model_validator(mode="after")
    def isolated_target(self):
        from flowtrace_server.persistence.testing import require_isolated_database

        try:
            url = require_isolated_database(self.database_url.get_secret_value(), "test")
            if (
                not self.label.strip()
                or any(ord(char) < 32 or ord(char) == 127 for char in self.label)
                or not self.data_directory.is_absolute()
                or not self.pg_restore_executable.is_absolute()
                or (
                    "hostaddr" in url.query
                    and url.query["hostaddr"] not in {"localhost", "127.0.0.1", "::1"}
                )
            ):
                raise ValueError
        except ValueError:
            raise ValueError("restore_target_configuration_invalid") from None
        return self


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="FLOWTRACE_", env_file=".env", extra="ignore", hide_input_in_errors=True
    )

    environment: Literal["development", "test", "production"] = "development"
    database_url: SecretStr | None = None
    database_connect_timeout: int = Field(default=3, ge=1, le=30)
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    allowed_hosts: list[str] = ["localhost", "127.0.0.1", "testserver"]
    cors_origins: list[str] = []
    data_directory: Path = Path("var")
    diagnostics_enabled: bool = True
    provider_endpoints: dict[Literal["ocr_primary", "ai_primary"], SecretStr] = Field(
        default_factory=dict, exclude=True, repr=False
    )
    pg_dump_executable: Path | None = Field(default=None, exclude=True, repr=False)
    restore_targets: dict[UUID, RestoreTargetConfig] = Field(
        default_factory=dict, exclude=True, repr=False
    )

    @field_validator("restore_targets")
    @classmethod
    def separate_restore_targets(cls, values, info):
        # All registered targets are loopback test databases. Normalize their
        # localhost aliases and reject source/target and target/target overlap.
        source = info.data.get("database_url")
        source_url = make_url(source.get_secret_value()) if source is not None else None
        source_directory = info.data.get("data_directory")
        if source_directory is None:
            raise ValueError("restore_targets_must_be_separate")
        roots = [Path(os.path.abspath(source_directory))]
        database_keys = set()
        if source_url is not None and source_url.query.get("hostaddr", source_url.host) in {
            "localhost",
            "127.0.0.1",
            "::1",
        }:
            database_keys.add((source_url.port or 5432, source_url.database))
        for target in values.values():
            url = make_url(target.database_url.get_secret_value())
            key = (url.port or 5432, url.database)
            directory = Path(os.path.abspath(target.data_directory))
            if key in database_keys or any(
                directory == old or directory in old.parents or old in directory.parents
                for old in roots
            ):
                raise ValueError("restore_targets_must_be_separate")
            database_keys.add(key)
            roots.append(directory)
        return values

    @field_validator("pg_dump_executable")
    @classmethod
    def absolute_dump_executable(cls, value):
        if value is not None and not value.is_absolute():
            raise ValueError("pg_dump_executable_requires_absolute_path")
        return value

    @field_validator("provider_endpoints")
    @classmethod
    def registered_provider_endpoints(cls, values, info):
        for value in values.values():
            try:
                endpoint = value.get_secret_value()
                parsed = urlsplit(endpoint)
                if (
                    len(endpoint) > 2048
                    or not parsed.hostname
                    or parsed.username is not None
                    or parsed.password is not None
                    or "?" in endpoint
                    or "#" in endpoint
                    or parsed.query
                    or parsed.fragment
                    or parsed.port == 0
                    or any(
                        char.isspace() or ord(char) < 32 or ord(char) == 127 for char in endpoint
                    )
                    or (
                        parsed.scheme != "https"
                        and not (
                            info.data.get("environment") == "test"
                            and parsed.scheme == "http"
                            and parsed.hostname in {"127.0.0.1", "localhost", "::1"}
                        )
                    )
                ):
                    raise ValueError
            except (ValueError, AttributeError):
                raise ValueError("provider_endpoint_invalid") from None
        return values

    @field_validator("database_url")
    @classmethod
    def postgres_only(cls, value: SecretStr | None) -> SecretStr | None:
        if value is not None:
            try:
                parsed = make_url(value.get_secret_value())
                if parsed.drivername != "postgresql+psycopg" or not parsed.database:
                    raise ValueError
            except Exception:
                raise ValueError("database_url_requires_postgresql_psycopg") from None
        return value

    @field_validator("cors_origins")
    @classmethod
    def explicit_origins(cls, value: list[str]) -> list[str]:
        if any(origin == "*" or not origin.startswith(("https://", "http://")) for origin in value):
            raise ValueError("cors_origins_require_explicit_origins")
        return value
