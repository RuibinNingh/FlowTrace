import json
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from uuid import uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from sync.helpers import actor, money, operation, push

from flowtrace_server.assets.models import AssetConfigReceipt, AssetConfigState, AssetGroup
from flowtrace_server.auth.models import User
from flowtrace_server.auth.service import issue_session
from flowtrace_server.currencies.models import ValuationRate
from flowtrace_server.sync.models import SyncClient

from .helpers import config_post, envelope, headers, new_account, payload

pytestmark = pytest.mark.postgres


def test_group_frozen_replay_conflict_and_current_authorization(assets_http, postgres_engine):
    who = actor(postgres_engine)
    group_id = str(uuid4())
    before = assets_http.get("/api/v1/assets/groups", headers=headers(who)).json()
    assert before["revision"] == "0" and before["groups"] == []
    body = envelope(postgres_engine, who, group={"id": group_id, "name": "空组", "sort_order": 4})
    first = assets_http.post("/api/v1/assets/groups", json=body, headers=headers(who))
    assert first.status_code == 200, first.text
    replay = assets_http.post("/api/v1/assets/groups", json=body, headers=headers(who))
    assert replay.json() == first.json()
    assert first.json()["revision"] == "1"
    assert first.json()["groups"][0]["id"] == group_id
    assert first.headers["x-request-id"] != replay.headers["x-request-id"]
    assert "private" in first.headers["cache-control"]
    changed = deepcopy(body)
    changed["group"]["name"] = "不应覆盖"
    conflict = assets_http.post("/api/v1/assets/groups", json=changed, headers=headers(who))
    assert (
        conflict.status_code == 409 and conflict.json()["error"]["code"] == "idempotency_conflict"
    )
    stale = config_post(
        assets_http,
        postgres_engine,
        who,
        "/api/v1/assets/groups",
        {"group": {"id": str(uuid4()), "name": "过期", "sort_order": 0}},
    )
    assert stale.status_code == 409 and stale.json()["error"]["code"] == "asset_config_conflict"
    with Session(postgres_engine) as session:
        assert (
            session.scalar(
                select(func.count())
                .select_from(AssetConfigReceipt)
                .where(AssetConfigReceipt.user_id == who.principal.user_id)
            )
            == 1
        )
        assert session.get(AssetConfigState, who.principal.user_id).revision == 1
        user = session.get(User, who.principal.user_id)
        user.enabled = False
        session.commit()
    denied = assets_http.post("/api/v1/assets/groups", json=body, headers=headers(who))
    assert denied.status_code == 401


@pytest.mark.parametrize(
    "field,code",
    [
        ("client_id", "client_mismatch"),
        ("instance_id", "instance_changed"),
        ("sync_epoch", "epoch_changed"),
    ],
)
def test_envelope_identity_guards_precede_receipt(assets_http, postgres_engine, field, code):
    who = actor(postgres_engine)
    body = envelope(postgres_engine, who, group={"id": str(uuid4()), "name": "组", "sort_order": 0})
    assert (
        assets_http.post("/api/v1/assets/groups", json=body, headers=headers(who)).status_code
        == 200
    )
    body[field] = str(uuid4())
    denied = assets_http.post("/api/v1/assets/groups", json=body, headers=headers(who))
    assert denied.json()["error"]["code"] == code


def test_groups_require_owner_reject_live_references_and_preserve_old_metadata(
    assets_http,
    postgres_engine,
):
    owner, stranger = actor(postgres_engine), actor(postgres_engine)
    group_id = str(uuid4())
    created = config_post(
        assets_http,
        postgres_engine,
        owner,
        "/api/v1/assets/groups",
        {"group": {"id": group_id, "name": "日常", "sort_order": 0}},
    )
    assert created.status_code == 200
    account_id = new_account(
        postgres_engine,
        owner,
        group_id=group_id,
        note="保留",
        provider_id="wechat",
        icon="wallet",
        hidden=True,
    )
    shared = operation(
        owner.book_id,
        "account",
        {
            "name": "共享不可借私人组",
            "kind": "cash",
            "opening": money("0"),
            "hidden": False,
            "include_in_net_assets": True,
            "group_id": group_id,
        },
    )
    assert (
        push(postgres_engine, owner, shared)[0]["error"]["code"] == "account.private_group_required"
    )
    deletion = assets_http.request(
        "DELETE",
        f"/api/v1/assets/groups/{group_id}",
        json=envelope(postgres_engine, owner, "1"),
        headers=headers(owner),
    )
    assert deletion.status_code == 409 and deletion.json()["error"]["code"] == "asset_group_in_use"
    foreign = assets_http.patch(
        f"/api/v1/assets/groups/{group_id}",
        headers=headers(stranger),
        json=envelope(postgres_engine, stranger, group={"name": "越权", "sort_order": 5}),
    )
    assert foreign.status_code == 404
    legacy = {
        key: value
        for key, value in payload(postgres_engine, account_id).items()
        if key in {"name", "kind", "opening", "hidden", "include_in_net_assets"}
    }
    legacy["name"] = "旧客户端改名"
    updated = operation(
        owner.principal.user_id,
        "account",
        legacy,
        identifier=account_id,
        revision="1",
        action="update",
    )
    assert push(postgres_engine, owner, updated)[0]["status"] == "applied"
    actual = payload(postgres_engine, account_id)
    assert actual["group_id"] == group_id and actual["note"] == "保留"
    assert actual["provider_id"] == "wechat" and actual["opening_date"] == "2026-01-01"
    actual["group_id"] = None
    assert (
        push(
            postgres_engine,
            owner,
            operation(
                owner.principal.user_id,
                "account",
                actual,
                identifier=account_id,
                revision="2",
                action="update",
            ),
        )[0]["status"]
        == "applied"
    )
    deletion = assets_http.request(
        "DELETE",
        f"/api/v1/assets/groups/{group_id}",
        json=envelope(postgres_engine, owner, "1"),
        headers=headers(owner),
    )
    assert deletion.status_code == 200 and deletion.json()["groups"] == []


def test_shared_revision_rates_exact_precision_and_immutable_pair_date(
    assets_http, postgres_engine
):
    who = actor(postgres_engine)
    pref = envelope(
        postgres_engine,
        who,
        preferences={
            "base_currency": "CNY",
            "enabled_codes": ["CNY", "EUR"],
            "valuation_policy": "latest_on_or_before",
        },
    )
    result = assets_http.put("/api/v1/currencies/preferences", json=pref, headers=headers(who))
    assert result.status_code == 200 and result.json()["revision"] == "1"
    rate_id = str(uuid4())
    rate = {
        "id": rate_id,
        "from_currency": "EUR",
        "to_currency": "CNY",
        "effective_date": "2026-10-20",
        "rate": "8.000000000000000001",
        "rate_source": "manual",
    }
    body = envelope(postgres_engine, who, "1", rate=rate)
    created = assets_http.post("/api/v1/currencies/rates", json=body, headers=headers(who))
    assert created.status_code == 200, created.text
    assert created.json()["revision"] == "2"
    assert created.json()["rates"][0]["rate"] == rate["rate"]
    assert assets_http.post("/api/v1/currencies/rates", json=body, headers=headers(who)).json() == (
        created.json()
    )
    duplicate = config_post(
        assets_http,
        postgres_engine,
        who,
        "/api/v1/currencies/rates",
        {"rate": {**rate, "id": str(uuid4())}},
        "2",
    )
    assert (
        duplicate.status_code == 409
        and duplicate.json()["error"]["code"] == "valuation_rate_exists"
    )
    other = actor(postgres_engine)
    assert assets_http.get("/api/v1/currencies/rates", headers=headers(other)).json()["rates"] == []
    forbidden = assets_http.request(
        "DELETE",
        f"/api/v1/currencies/rates/{rate_id}",
        json=envelope(postgres_engine, other),
        headers=headers(other),
    )
    assert forbidden.status_code == 404
    deleted = assets_http.request(
        "DELETE",
        f"/api/v1/currencies/rates/{rate_id}",
        json=envelope(postgres_engine, who, "2"),
        headers=headers(who),
    )
    assert deleted.status_code == 200 and deleted.json()["revision"] == "3"
    with Session(postgres_engine) as session:
        assert session.get(ValuationRate, rate_id).deleted


def test_config_concurrent_same_frozen_operation_is_one_commit(assets_http, postgres_engine):
    from flowtrace_server.assets.configuration import mutate_configuration
    from flowtrace_server.assets.schemas import GroupCreate

    who = actor(postgres_engine)
    body = GroupCreate.model_validate(
        envelope(postgres_engine, who, group={"id": str(uuid4()), "name": "并发", "sort_order": 0})
    )

    def once():
        with Session(postgres_engine) as session:
            return mutate_configuration(session, who.principal, "groups.create", body)

    with ThreadPoolExecutor(max_workers=2) as pool:
        one, two = list(pool.map(lambda _: once(), range(2)))
    assert one == two and one["revision"] == "1"
    with Session(postgres_engine) as session:
        assert (
            session.scalar(
                select(func.count())
                .select_from(AssetGroup)
                .where(AssetGroup.user_id == who.principal.user_id)
            )
            == 1
        )


def test_catalog_search_partial_credit_and_strict_json(assets_http, postgres_engine):
    who = actor(postgres_engine)
    catalog = assets_http.get("/api/v1/currencies/catalog", headers=headers(who)).json()
    assert len(catalog["currencies"]) == 165
    assert {row["code"]: row["scale"] for row in catalog["currencies"]}["CLF"] == 4
    banks = assets_http.get(
        "/api/v1/assets/banks", params={"q": "招商"}, headers=headers(who)
    ).json()
    assert banks["banks"] == [{"id": "cmb", "name": "招商银行"}]
    new_account(
        postgres_engine, who, kind="credit_card", bank_id=None, credit={"limit": money("200000")}
    )
    body = envelope(postgres_engine, who, group={"id": str(uuid4()), "name": "x", "sort_order": 0})
    raw = json.dumps(body)[:-1] + ',"base_revision":"0"}'
    response = assets_http.post(
        "/api/v1/assets/groups",
        content=raw,
        headers={**headers(who), "Content-Type": "application/json"},
    )
    assert response.status_code == 422
    with Session(postgres_engine) as session:
        user = session.get(User, who.principal.user_id)
        record, tokens = issue_session(session, user, uuid4(), "合成后台", "admin")
        session.commit()
    admin = assets_http.get(
        "/api/v1/assets/groups", headers={"Authorization": f"Bearer {tokens['access_token']}"}
    )
    assert admin.status_code in {401, 403}


def test_frozen_sync_client_cannot_replay_configuration(assets_http, postgres_engine):
    who = actor(postgres_engine)
    body = envelope(postgres_engine, who, group={"id": str(uuid4()), "name": "组", "sort_order": 0})
    assert (
        assets_http.post("/api/v1/assets/groups", json=body, headers=headers(who)).status_code
        == 200
    )
    with Session(postgres_engine) as session:
        session.get(SyncClient, (who.principal.user_id, who.principal.client_id)).frozen = True
        session.commit()
    result = assets_http.post("/api/v1/assets/groups", json=body, headers=headers(who))
    assert result.status_code == 410


def test_web_configuration_requires_origin_and_session_bound_csrf(assets_http, postgres_engine):
    from dataclasses import replace

    from sync.helpers import Actor

    original = actor(postgres_engine)
    with Session(postgres_engine) as session:
        user = session.get(User, original.principal.user_id)
        record, tokens = issue_session(session, user, uuid4(), "合成Web", "api_web")
        who = Actor(
            replace(
                original.principal,
                session_id=record.id,
                client_id=record.client_id,
                purpose="api_web",
            ),
            tokens["access_token"],
            original.book_id,
        )
        session.commit()
    body = envelope(
        postgres_engine, who, group={"id": str(uuid4()), "name": "Web组", "sort_order": 0}
    )
    assert (
        assets_http.post("/api/v1/assets/groups", json=body, headers=headers(who)).status_code
        == 403
    )
    without_csrf = {**headers(who), "Origin": "http://testserver"}
    assert (
        assets_http.post("/api/v1/assets/groups", json=body, headers=without_csrf).status_code
        == 403
    )
    mismatched = {**without_csrf, "X-CSRF-Token": "wrong"}
    assert (
        assets_http.post("/api/v1/assets/groups", json=body, headers=mismatched).status_code == 403
    )
    valid = {**without_csrf, "X-CSRF-Token": tokens["csrf_token"]}
    assert assets_http.post("/api/v1/assets/groups", json=body, headers=valid).status_code == 200
