from datetime import UTC, datetime, timedelta, timezone
from types import SimpleNamespace
from uuid import uuid4

import pytest

from flowtrace_server.admin.router import templates, utc_time


def test_utc_time_normalizes_database_session_timezone():
    instant = datetime(2026, 10, 21, 10, 8, 9, tzinfo=timezone(timedelta(hours=8)))
    assert utc_time(instant) == "2026-10-21 02:08 UTC"
    assert utc_time(instant, seconds=True) == "2026-10-21 02:08:09 UTC"
    assert utc_time(instant.astimezone(UTC)) == utc_time(instant)
    with pytest.raises(ValueError, match="aware timestamp"):
        utc_time(instant.replace(tzinfo=None))


@pytest.mark.parametrize("page", ["users", "sessions", "invites", "audit"])
def test_admin_templates_render_timestamps_as_utc_and_audit_actor(page):
    instant = datetime(2026, 10, 21, 10, 8, 9, tzinfo=timezone(timedelta(hours=8)))
    actor_id = uuid4()
    item = SimpleNamespace(
        id=uuid4(),
        username="synthetic_user",
        enabled=True,
        created_at=instant,
        expires_at=instant + timedelta(days=7),
        revoked_at=None,
        consumed_by=None,
        device_name="Synthetic device",
        purpose="api_native",
        actor_id=actor_id,
        action="invite.create",
        target_id=uuid4(),
    )
    html = templates.env.get_template("panel.html").render(
        page=page,
        csrf_token="synthetic-csrf",
        current_time=instant,
        users=[item],
        sessions=[item],
        invites=[item],
        audits=[item],
        target=item,
        token=None,
    )
    assert "10:08 UTC" not in html
    assert "02:08:09 UTC" in html if page == "audit" else "02:08 UTC" in html
    if page == "audit":
        assert str(actor_id) in html
