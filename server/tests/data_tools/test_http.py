import hashlib
import io
import json
import zipfile
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session
from sync.helpers import account, actor, expense, operation, push, revoke, share

from flowtrace_server.auth.models import User
from flowtrace_server.auth.service import issue_session
from flowtrace_server.config import Settings
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.main import create_app
from flowtrace_server.sync.models import SyncEntity

from .test_import_attachments import new_book_request, ready_image
from .test_import_transactions import request
from .test_parsers import table

pytestmark = pytest.mark.postgres
PREFIX = "/api/v1/data-tools"


@pytest.fixture
def data_http(postgres_engine, tmp_path):
    app = create_app(
        Settings(
            _env_file=None,
            environment="test",
            data_directory=tmp_path,
            database_url=postgres_engine.url.render_as_string(hide_password=False),
            diagnostics_enabled=False,
        )
    )
    app.state.engine = postgres_engine
    with TestClient(app) as client:
        yield client


def headers(owner):
    return {"authorization": "Bearer " + owner.token}


def test_parse_preview_apply_history_and_undo_over_authenticated_http(data_http, postgres_engine):
    owner = actor(postgres_engine)
    cash = account(postgres_engine, owner, opening="10000")
    body = request(postgres_engine, owner, [expense(owner.book_id, cash, "125")])
    response = data_http.post(
        PREFIX + "/imports/parse",
        headers=headers(owner),
        data={"format": "flowtrace_json", "options": "{}"},
        files={
            "file": (
                "../../unused-path.json",
                canonical(body.document.model_dump()),
                "application/json",
            )
        },
    )
    assert response.status_code == 200, response.text
    parsed = response.json()
    assert (
        not parsed["errors"]
        and parsed["document"]["rows"][0]["payload"]["money"]["amount_minor"] == "125"
    )
    assert "no-store" in response.headers["cache-control"]
    before = data_http.post(
        PREFIX + "/imports/preview", headers=headers(owner), json=body.model_dump()
    )
    assert before.status_code == 200 and before.json()["can_apply"]
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, cash).balance_minor == 10000
    applied = data_http.post(
        PREFIX + "/imports/apply", headers=headers(owner), json=body.model_dump()
    )
    assert applied.status_code == 200, applied.text
    assert len(applied.json()["created"]) == 1
    assert data_http.post(
        PREFIX + "/imports/apply", headers=headers(owner), json=body.model_dump()
    ).json()["replayed"]
    history = data_http.get(
        PREFIX + "/imports/history", headers=headers(owner), params={"limit": 1}
    )
    assert history.status_code == 200, history.text
    assert history.json()["batches"][0]["batch_id"] == body.batch_id
    assert not history.json()["has_more"] and history.json()["next_cursor"] is None
    preview = data_http.get(
        PREFIX + f"/imports/{body.batch_id}/undo-preview", headers=headers(owner)
    )
    assert preview.status_code == 200 and preview.json()["can_undo"]
    undone = data_http.post(
        PREFIX + f"/imports/{body.batch_id}/undo",
        headers=headers(owner),
        json={
            "client_id": body.client_id,
            "sync_epoch": body.sync_epoch,
        },
    )
    assert undone.status_code == 200, undone.text
    assert undone.json()["status"] == "undone"
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, cash).balance_minor == 10000


def test_chinese_mapping_duplicate_options_extra_parts_and_file_limit(data_http, postgres_engine):
    owner = actor(postgres_engine)
    cash = account(postgres_engine, owner)
    options = {
        "template_mapping": {
            "scope_id": str(owner.book_id),
            "timezone": "Asia/Shanghai",
            "account_names": {"合成现金": str(cash)},
        }
    }
    file = (
        "synthetic.csv",
        "时间,类型,金额,账户1\n2026-10-21,支出,1.25,合成现金\n".encode(),
        "text/csv",
    )
    response = data_http.post(
        PREFIX + "/imports/parse",
        headers=headers(owner),
        data={"format": "qianji_csv", "options": json.dumps(options, ensure_ascii=False)},
        files={"file": file},
    )
    assert response.status_code == 200, response.text
    assert response.json()["document"]["rows"][0]["payload"]["account_id"] == str(cash)
    duplicate = data_http.post(
        PREFIX + "/imports/parse",
        headers=headers(owner),
        data={"format": "qianji_csv", "options": '{"source_namespace":"x","source_namespace":"y"}'},
        files={"file": file},
    )
    assert (
        duplicate.status_code == 422
        and duplicate.json()["error"]["code"] == "import_options_invalid"
    )
    extra = data_http.post(
        PREFIX + "/imports/parse",
        headers=headers(owner),
        data={"format": "qianji_csv", "options": "{}", "path": "C:/private/never-read"},
        files={"file": file},
    )
    assert extra.status_code == 422 and "never-read" not in extra.text
    large = data_http.post(
        PREFIX + "/imports/parse",
        headers=headers(owner),
        data={"format": "flowtrace_json"},
        files={"file": ("too-large.json", b" " * (5 * 1024 * 1024 + 1), "application/json")},
    )
    assert large.status_code == 413


def test_file_larger_than_generic_json_limit_stays_bounded_and_parser_errors_located(
    data_http, postgres_engine
):
    owner = actor(postgres_engine)
    body = request(postgres_engine, owner, [expense(owner.book_id, None, "125")])
    content = b" " * (1024 * 1024) + canonical(body.document.model_dump())
    response = data_http.post(
        PREFIX + "/imports/parse",
        headers=headers(owner),
        data={"format": "flowtrace_json"},
        files={"file": ("one-row.json", content, "application/json")},
    )
    assert response.status_code == 200 and response.json()["document"] is not None
    malformed = data_http.post(
        PREFIX + "/imports/parse",
        headers=headers(owner),
        data={"format": "flowtrace_csv"},
        files={"file": ("bad.csv", b"arbitrary,headers\nsecret,never-echo\n", "text/csv")},
    )
    assert malformed.status_code == 200
    assert malformed.json()["document"] is None and malformed.json()["errors"][0]["row"] == 1
    assert "never-echo" not in malformed.text


def test_duplicate_json_and_web_csrf_are_rejected_before_any_formal_write(
    data_http, postgres_engine
):
    owner = actor(postgres_engine)
    body = request(postgres_engine, owner, [expense(owner.book_id, None, "125")])
    raw = json.dumps(body.model_dump()).replace(
        '"batch_id":', '"batch_id":"' + str(uuid4()) + '","batch_id":', 1
    )
    response = data_http.post(
        PREFIX + "/imports/apply",
        content=raw,
        headers={**headers(owner), "content-type": "application/json"},
    )
    assert response.status_code == 400
    with Session(postgres_engine) as session:
        _, tokens = issue_session(
            session,
            session.get(User, owner.principal.user_id),
            uuid4(),
            "合成Web数据工具",
            "api_web",
        )
        session.commit()
    web_headers = {
        "authorization": "Bearer " + tokens["access_token"],
        "origin": "http://testserver",
    }
    forbidden = data_http.post(
        PREFIX + "/exports/json", headers=web_headers, json={"scope_ids": [str(owner.book_id)]}
    )
    assert forbidden.status_code == 403 and forbidden.json()["error"]["code"] == "csrf_invalid"
    permitted = data_http.post(
        PREFIX + "/exports/json",
        headers={**web_headers, "x-csrf-token": tokens["csrf_token"]},
        json={"scope_ids": [str(owner.book_id)]},
    )
    assert permitted.status_code == 200, permitted.text
    assert (
        permitted.headers["content-disposition"] == 'attachment; filename="flowtrace-export.json"'
    )


def test_history_keyset_pagination_has_no_duplicate_or_truncated_batches(
    data_http, postgres_engine
):
    owner = actor(postgres_engine)
    expected = set()
    for _ in range(3):
        body = request(postgres_engine, owner, [expense(owner.book_id, None, "125")])
        response = data_http.post(
            PREFIX + "/imports/apply", headers=headers(owner), json=body.model_dump()
        )
        assert response.status_code == 200
        expected.add(body.batch_id)
    seen, cursor = [], None
    for page in range(3):
        params = {"limit": 1, **({"cursor": cursor} if cursor else {})}
        response = data_http.get(PREFIX + "/imports/history", params=params, headers=headers(owner))
        assert response.status_code == 200, response.text
        result = response.json()
        seen.extend(item["batch_id"] for item in result["batches"])
        assert result["has_more"] == (page < 2)
        cursor = result["next_cursor"]
    assert len(seen) == len(set(seen)) == 3 and set(seen) == expected
    assert (
        data_http.get(
            PREFIX + "/imports/history", params={"cursor": "bad-cursor"}, headers=headers(owner)
        ).status_code
        == 422
    )


def test_history_batch_filter_returns_only_exact_own_metadata(data_http, postgres_engine):
    owner, foreign = actor(postgres_engine), actor(postgres_engine)
    bodies = [
        request(postgres_engine, owner, [expense(owner.book_id, None, amount)])
        for amount in ("125", "75")
    ]
    for body in bodies:
        assert (
            data_http.post(
                PREFIX + "/imports/apply", headers=headers(owner), json=body.model_dump()
            ).status_code
            == 200
        )
    target = bodies[0].batch_id
    response = data_http.get(
        PREFIX + "/imports/history", headers=headers(owner), params={"batch_id": target, "limit": 1}
    )
    assert response.status_code == 200
    assert [item["batch_id"] for item in response.json()["batches"]] == [target]
    assert not response.json()["has_more"] and response.json()["next_cursor"] is None
    denied = data_http.get(
        PREFIX + "/imports/history",
        headers=headers(foreign),
        params={"batch_id": target, "limit": 1},
    )
    assert denied.status_code == 200 and denied.json()["batches"] == []
    assert target not in denied.text and str(owner.book_id) not in denied.text
    assert (
        data_http.get(
            PREFIX + "/imports/history", headers=headers(owner), params={"batch_id": "invalid"}
        ).status_code
        == 422
    )


def test_authorized_json_xlsx_image_download_and_private_scope_denial(data_http, postgres_engine):
    owner, viewer = actor(postgres_engine), actor(postgres_engine)
    cash = account(postgres_engine, owner, opening="10000")
    identifier, _, original, _ = ready_image(
        postgres_engine,
        owner,
        data_http.app.state.settings.data_directory / "attachments",
        scope_id=owner.book_id,
    )
    assert (
        push(
            postgres_engine,
            owner,
            operation(
                owner.book_id,
                "bill",
                expense(owner.book_id, cash, "125", attachment_ids=[str(identifier)]),
            ),
        )[0]["status"]
        == "applied"
    )
    query = {
        "scope_ids": [str(owner.principal.user_id), str(owner.book_id)],
        "include_images": "embedded",
    }
    response = data_http.post(PREFIX + "/exports/xlsx", headers=headers(owner), json=query)
    assert response.status_code == 200, response.text
    with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
        media = [name for name in archive.namelist() if name.startswith("xl/media/")]
        assert len(media) == 1 and archive.read(media[0]) == original
    query["include_images"] = "links"
    exported = data_http.post(PREFIX + "/exports/json", headers=headers(owner), json=query)
    assert exported.status_code == 200
    assert exported.json()["attachments"][0]["href"] == f"/api/v1/attachments/{identifier}/content"
    for format_name, content in (
        ("flowtrace_json", exported.content),
        ("flowtrace_xlsx", response.content),
    ):
        parsed = data_http.post(
            PREFIX + "/imports/parse",
            headers=headers(owner),
            data={"format": format_name},
            files={"file": ("synthetic", content, "application/octet-stream")},
        )
        assert parsed.status_code == 200, parsed.text
        assert parsed.json()["document"] is not None and not parsed.json()["errors"]
        assert parsed.json()["attachment_sources"] == [
            {
                "source_id": str(identifier),
                "sha256": hashlib.sha256(original).hexdigest(),
                "size_bytes": len(original),
                "media_type": "image/png",
            }
        ]
    share(postgres_engine, owner, viewer, "viewer")
    denied = data_http.post(
        PREFIX + "/exports/json", headers=headers(viewer), json={"scope_ids": [str(owner.book_id)]}
    )
    assert denied.status_code == 403 and str(cash) not in denied.text
    assert data_http.get(PREFIX + "/imports/history").status_code == 401


@pytest.mark.parametrize("invalid", ["url", "missing", "duplicate", "size", "unknown"])
def test_original_image_manifest_is_closed_and_never_fetches_urls(
    data_http, postgres_engine, invalid
):
    owner = actor(postgres_engine)
    identifier = str(uuid4())
    body = request(
        postgres_engine, owner, [expense(owner.book_id, None, "125", attachment_ids=[identifier])]
    )
    manifest = {
        "attachment_id": identifier,
        "sha256": "a" * 64,
        "size_bytes": 77,
        "media_type": "image/png",
        "href": f"/api/v1/attachments/{identifier}/content",
        "authorization": "current_session_and_scope_required",
    }
    envelope = {
        "format": "flowtrace-export-v1",
        "document": body.document.model_dump(),
        "attachments": [manifest],
    }
    if invalid == "url":
        manifest["href"] = "http://127.0.0.1:1/never-fetch"
    elif invalid == "missing":
        envelope["attachments"] = []
    elif invalid == "duplicate":
        envelope["attachments"].append(manifest)
    elif invalid == "size":
        manifest["size_bytes"] = True
    else:
        manifest["local_path"] = "C:/private/never-read"
    result = data_http.post(
        PREFIX + "/imports/parse",
        headers=headers(owner),
        data={"format": "flowtrace_json"},
        files={"file": ("synthetic.json", canonical(envelope), "application/json")},
    )
    assert result.status_code == 200
    assert result.json()["document"] is None
    assert result.json()["attachment_sources"] == []
    assert result.json()["errors"] == [
        {"row": None, "field": "attachments", "code": "invalid_attachment_manifest"}
    ]
    assert "never-fetch" not in result.text and "never-read" not in result.text


def test_native_document_without_manifest_requires_explicit_manual_image_mapping(
    data_http, postgres_engine
):
    owner = actor(postgres_engine)
    body = request(
        postgres_engine, owner, [expense(owner.book_id, None, "125", attachment_ids=[str(uuid4())])]
    )
    result = data_http.post(
        PREFIX + "/imports/parse",
        headers=headers(owner),
        data={"format": "flowtrace_json"},
        files={
            "file": ("synthetic.json", canonical(body.document.model_dump()), "application/json")
        },
    )
    assert result.status_code == 200 and result.json()["document"] is not None
    assert result.json()["attachment_sources"] == []


def test_own_operation_history_survives_undo_deleted_book_without_entity_or_scope_leak(
    data_http, postgres_engine
):
    owner = actor(postgres_engine)
    uploaded, _, _, _ = ready_image(
        postgres_engine, owner, data_http.app.state.settings.data_directory / "attachments"
    )
    body, _, _ = new_book_request(postgres_engine, owner, uploaded)
    response = data_http.post(
        PREFIX + "/imports/apply", headers=headers(owner), json=body.model_dump()
    )
    assert response.status_code == 200, response.text
    entity_ids = response.json()["created"]
    undo_body = {"client_id": body.client_id, "sync_epoch": body.sync_epoch}
    assert (
        data_http.post(
            PREFIX + f"/imports/{body.batch_id}/undo", headers=headers(owner), json=undo_body
        ).status_code
        == 200
    )
    history = data_http.get(
        PREFIX + "/imports/history",
        headers=headers(owner),
        params={"batch_id": body.batch_id, "limit": 1},
    )
    assert history.status_code == 200
    assert history.json()["batches"][0]["status"] == "undone"
    preview = data_http.get(
        PREFIX + f"/imports/{body.batch_id}/undo-preview", headers=headers(owner)
    )
    assert preview.status_code == 200 and not preview.json()["can_undo"]
    replay = data_http.post(
        PREFIX + f"/imports/{body.batch_id}/undo", headers=headers(owner), json=undo_body
    )
    assert replay.status_code == 200
    assert replay.json() == {"batch_id": body.batch_id, "status": "undone", "replayed": True}
    for identifier in entity_ids:
        assert (
            identifier not in history.text
            and identifier not in preview.text
            and identifier not in replay.text
        )


def test_revoked_active_import_keeps_only_own_operation_metadata_and_cannot_undo(
    data_http, postgres_engine
):
    owner, member = actor(postgres_engine), actor(postgres_engine)
    share(postgres_engine, owner, member, "editor")
    body = request(postgres_engine, member, [expense(owner.book_id, None, "125")])
    body.document.rows[0].scope_id = str(owner.book_id)
    applied = data_http.post(
        PREFIX + "/imports/apply", headers=headers(member), json=body.model_dump()
    )
    assert applied.status_code == 200, applied.text
    revoke(postgres_engine, owner, member)
    history = data_http.get(
        PREFIX + "/imports/history",
        headers=headers(member),
        params={"batch_id": body.batch_id, "limit": 1},
    )
    assert history.status_code == 200 and history.json()["batches"][0]["batch_id"] == body.batch_id
    assert (
        str(owner.book_id) not in history.text
        and "scope_ids" not in history.text
        and "payload" not in history.text
    )
    assert (
        data_http.get(
            PREFIX + f"/imports/{body.batch_id}/undo-preview", headers=headers(member)
        ).status_code
        == 403
    )
    assert (
        data_http.post(
            PREFIX + f"/imports/{body.batch_id}/undo",
            headers=headers(member),
            json={"client_id": body.client_id, "sync_epoch": body.sync_epoch},
        ).status_code
        == 403
    )
    assert (
        data_http.get(
            PREFIX + f"/imports/{body.batch_id}/undo-preview", headers=headers(owner)
        ).status_code
        == 404
    )


def test_mapping_requirements_are_deduplicated_names_only_and_resolve_after_selection(
    data_http, postgres_engine
):
    owner = actor(postgres_engine)
    record = {
        "时间": "2026-10-21",
        "类型": "支出",
        "金额": "1.25",
        "账户1": "现金",
        "分类": "旧分类",
        "二级分类": "三餐",
        "标签": "旅行#午饭",
        "账单图片": "http://127.0.0.1:55432/not-fetched",
        "备注": "private_note_not_a_mapping",
    }
    content = table([record, record], tuple(record))
    mapping = {"scope_id": str(owner.book_id), "timezone": "Asia/Shanghai"}

    def parse(value):
        return data_http.post(
            PREFIX + "/imports/parse",
            headers=headers(owner),
            data={
                "format": "qianji_csv",
                "options": json.dumps({"template_mapping": value}, ensure_ascii=False),
            },
            files={"file": ("mapping.csv", content, "text/csv")},
        )

    missing = parse(mapping)
    assert missing.status_code == 200, missing.text
    assert missing.json()["document"] is None
    required = missing.json()["mapping_requirements"]
    assert {item["kind"] for item in required} == {"account", "category", "tag", "image"}
    assert all(item["rows"] == [2, 3] for item in required)
    assert len(required) == 5
    assert "private_note_not_a_mapping" not in json.dumps(required)
    assert "1.25" not in json.dumps(required) and "旧分类" not in json.dumps(
        required, ensure_ascii=False
    )
    mapping.update(
        account_names={"现金": str(uuid4())},
        category_names={"三餐": str(uuid4())},
        tag_names={"旅行": str(uuid4()), "午饭": str(uuid4())},
        image_urls={record["账单图片"]: str(uuid4())},
    )
    complete = parse(mapping)
    assert complete.status_code == 200 and not complete.json()["errors"]
    assert len(complete.json()["document"]["rows"]) == 2
    assert complete.json()["mapping_requirements"] == required


def test_valid_large_document_is_explicitly_rejected_when_parse_response_exceeds_one_mib(
    data_http, postgres_engine
):
    owner = actor(postgres_engine)
    payload = expense(
        owner.book_id,
        None,
        "100",
        bill_type="reimbursement",
        note="x" * 2000,
        tag_ids=[str(uuid4()) for _ in range(100)],
        attachment_ids=[str(uuid4()) for _ in range(20)],
        allocations=[
            {
                "source_bill_id": str(uuid4()),
                "source_amount_minor": "1",
                "receipt_amount_minor": "1",
                "rate": "1.000000000000000000",
            }
            for _ in range(100)
        ],
    )
    body = request(postgres_engine, owner, [payload] * 50)
    content = canonical(body.document.model_dump())
    assert 1024 * 1024 < len(content) < 5 * 1024 * 1024
    response = data_http.post(
        PREFIX + "/imports/parse",
        headers=headers(owner),
        data={"format": "flowtrace_json"},
        files={"file": ("bounded.json", content, "application/json")},
    )
    assert response.status_code == 413
    assert response.json()["error"]["code"] == "import_response_too_large"
