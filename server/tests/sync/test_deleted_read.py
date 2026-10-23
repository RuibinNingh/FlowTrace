"""Current deletion reads expose an authorized tombstone, never its old body."""

from uuid import UUID

import pytest

from .helpers import account, expense, operation, push, revoke, share
from .test_book_move import create_bill, move_command, new_book

pytestmark = pytest.mark.postgres


def test_deleted_current_is_minimal_for_owner_viewer_and_revoked_or_foreign_is_denied(
    actors, postgres_engine, sync_http
):
    alice, bob, carol = actors
    share(postgres_engine, alice, bob, "viewer")
    private = account(postgres_engine, alice)
    bill_id = create_bill(
        postgres_engine,
        alice,
        expense(alice.book_id, private, note="合成删除前不可返回的备注"),
    )
    remove = operation(alice.book_id, "bill", {}, identifier=bill_id, action="delete", revision="1")
    assert push(postgres_engine, alice, remove)[0]["status"] == "applied"
    route = f"/api/v1/sync/entities/bill/{bill_id}?scope_id={alice.book_id}"
    for member in [alice, bob]:
        response = sync_http.get(route, headers={"authorization": "Bearer " + member.token})
        assert response.status_code == 200, response.text
        data = response.json()
        assert data["editable_payload"] is None
        assert data["event"]["scope_id"] == str(alice.book_id)
        assert data["event"]["entity_id"] == str(bill_id)
        assert data["event"]["revision"] == "2"
        assert data["event"]["deleted"] is True and data["event"]["data"] is None
        assert str(private) not in response.text and "不可返回" not in response.text
    foreign = sync_http.get(route, headers={"authorization": "Bearer " + carol.token})
    assert foreign.status_code == 403 and "不可返回" not in foreign.text
    revoke(postgres_engine, alice, bob)
    revoked = sync_http.get(route, headers={"authorization": "Bearer " + bob.token})
    assert revoked.status_code == 403 and "不可返回" not in revoked.text
    anonymous = sync_http.get(route)
    assert anonymous.status_code == 401


def test_move_then_delete_does_not_turn_old_scope_into_current_tombstone_read(
    actors, postgres_engine, sync_http
):
    alice, bob, _ = actors
    share(postgres_engine, alice, bob, "viewer")
    target = new_book(postgres_engine, alice)
    bill_id = create_bill(postgres_engine, alice)
    assert (
        push(postgres_engine, alice, move_command(postgres_engine, bill_id, target))[0]["status"]
        == "applied"
    )
    remove = operation(
        target.book_id, "bill", {}, identifier=bill_id, action="delete", revision="2"
    )
    assert push(postgres_engine, alice, remove)[0]["status"] == "applied"
    base = f"/api/v1/sync/entities/bill/{bill_id}"
    owner = {"authorization": "Bearer " + alice.token}
    reader = {"authorization": "Bearer " + bob.token}
    assert (
        sync_http.get(base, params={"scope_id": str(alice.book_id)}, headers=owner).status_code
        == 404
    )
    assert (
        sync_http.get(base, params={"scope_id": str(alice.book_id)}, headers=reader).status_code
        == 404
    )
    assert (
        sync_http.get(base, params={"scope_id": str(target.book_id)}, headers=reader).status_code
        == 403
    )
    current = sync_http.get(base, params={"scope_id": str(target.book_id)}, headers=owner)
    assert current.status_code == 200
    event = current.json()["event"]
    assert UUID(event["entity_id"]) == bill_id
    assert event["deleted"] is True and event["data"] is None and event["revision"] == "3"
    assert current.json()["editable_payload"] is None
