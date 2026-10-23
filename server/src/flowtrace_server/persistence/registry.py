"""Load model metadata for migration review without starting an application."""

import flowtrace_server.assets.models  # noqa: F401
import flowtrace_server.attachments.models  # noqa: F401
import flowtrace_server.backups.retention_models  # noqa: F401
import flowtrace_server.configuration.models  # noqa: F401
import flowtrace_server.currencies.models  # noqa: F401
import flowtrace_server.imports.models  # noqa: F401
import flowtrace_server.imports.staging_models  # noqa: F401
import flowtrace_server.jobs.models  # noqa: F401
import flowtrace_server.sync.group_models  # noqa: F401
from flowtrace_server.admin import models as admin_models
from flowtrace_server.auth import models as auth_models
from flowtrace_server.books import models as book_models
from flowtrace_server.persistence.models import Base
from flowtrace_server.sync import models as sync_models  # noqa: F401

__all__ = ["Base", "admin_models", "auth_models", "book_models"]
