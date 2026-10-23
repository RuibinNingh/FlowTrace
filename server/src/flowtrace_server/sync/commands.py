"""Authorized typed commands and exact postings, executed under caller-held locks."""

from collections import defaultdict
from copy import deepcopy
from uuid import UUID, uuid4

from pydantic import ValidationError
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import now
from flowtrace_server.books.models import Book, BookMembership, SyncScope
from flowtrace_server.books.permissions import authorize_scope
from flowtrace_server.domain.calendar_rules import business_date
from flowtrace_server.domain.money import checked_minor, convert_money, parse_minor

from .common import (
    CURRENCY_SCALES,
    CommandRejected,
    PendingEvent,
    RetryScopeSet,
    checked_currency,
    current_entity,
    visible_entity,
)
from .models import LedgerEntry, SyncEntity
from .projections import (
    NONFINANCIAL_FIELDS,
    account_links,
    allocated_to,
    entity_event,
    private_finance,
    public_bill,
)
from .schemas import (
    BOOK_CORE_FIELDS,
    MANAGEMENT_NEW_FIELDS,
    BillPayload,
    Operation,
    bill_storage_payload,
    management_payload,
)

TWO_ACCOUNT_KINDS = {
    "transfer",
    "credit_repayment",
    "loan_borrow",
    "loan_lend",
    "loan_collect",
    "loan_repay",
}


def all_live_bills(session: Session):
    return session.scalars(
        select(SyncEntity).where(SyncEntity.entity_type == "bill", SyncEntity.deleted.is_(False))
    )


def financial_source_ids(payload: dict | None) -> set[UUID]:
    return {UUID(item["source_bill_id"]) for item in (payload or {}).get("allocations", [])}


def scope_set(session: Session, principal: Principal, operation: Operation) -> set[UUID]:
    """Discover before locking, then repeat after locks to detect a changed set."""
    ids = {UUID(operation.scope_id)}
    entity = current_entity(session, UUID(operation.entity_id))
    if entity is not None:
        if operation.entity_type == "book" and operation.action == "create":
            visible_entity(session, principal, entity.id, "book", active=False)
            ids.add(entity.scope_id)
        elif entity.scope_id != UUID(operation.scope_id):
            # Book creation uses a user scope; all existing objects use their
            # actual domain. Guessing a UUID in another scope never discloses it.
            raise ApiError("not_found", 404)
    if operation.entity_type == "book" and operation.action == "delete" and entity is not None:
        members = session.scalars(
            select(BookMembership.user_id).where(
                BookMembership.book_id == entity.id, BookMembership.active.is_(True)
            )
        )
        ids.update(members)
    if operation.entity_type != "bill":
        return ids
    if operation.move is not None:
        ids.add(UUID(operation.move.target_scope_id))
    payloads = []
    if entity is not None:
        payloads.append(entity.payload)
    if operation.action != "delete":
        payloads.append(operation.payload.model_dump(exclude={"preserve_hidden_financial_links"}))
    for payload in payloads:
        for account_id in account_links(payload).values():
            account = current_entity(session, account_id)
            if account is not None and account.entity_type == "account":
                scope = session.get(SyncScope, account.scope_id)
                # A public metadata edit does not acquire another person's
                # private domain; final checks prohibit touching its finances.
                if scope.kind != "user" or scope.owner_user_id == principal.user_id:
                    ids.add(scope.id)
        if operation.action == "update" and operation.payload.preserve_hidden_financial_links:
            continue
        for source_id in financial_source_ids(payload):
            source = visible_entity(session, principal, source_id, "bill", active=False)
            ids.add(source.scope_id)
    return ids


def _account(
    session: Session,
    principal: Principal,
    identifier: UUID,
    book_id: UUID,
    money: dict,
    scopes: dict[UUID, SyncScope],
) -> SyncEntity:
    account = visible_entity(session, principal, identifier, "account")
    if account.scope_id not in scopes:
        raise RetryScopeSet
    grant = authorize_scope(session, principal, account.scope_id, write=True)
    if grant.scope.kind == "book" and grant.scope.book_id != book_id:
        raise CommandRejected("account.wrong_book")
    actual, expected = checked_currency(money), checked_currency(account.payload["opening"])
    if (actual.currency, actual.currency_scale) != (expected.currency, expected.currency_scale):
        raise CommandRejected("money.currency_mismatch")
    return account


def _same_book_reference(session: Session, principal: Principal, value, kind: str, scope_id: UUID):
    if value is None:
        return None
    target = visible_entity(session, principal, UUID(value), kind)
    if target.scope_id != scope_id:
        raise ApiError("not_found", 404)
    return target


def _children(session: Session, entity: SyncEntity, link_field: str) -> list[SyncEntity]:
    return list(
        session.scalars(
            select(SyncEntity).where(
                SyncEntity.scope_id == entity.scope_id,
                SyncEntity.entity_type == entity.entity_type,
                SyncEntity.deleted.is_(False),
                SyncEntity.payload[link_field].astext == str(entity.id),
            )
        )
    )


def _archived(session: Session, entity: SyncEntity) -> bool:
    if entity.payload.get("archived", False):
        return True
    link = "parent_id" if entity.entity_type == "category" else "group_id"
    parent_id = entity.payload.get(link)
    if parent_id is None:
        return False
    parent = session.get(SyncEntity, UUID(parent_id))
    return parent is None or parent.deleted or parent.payload.get("archived", False)


def _new_reference_is_active(session: Session, target: SyncEntity | None, previous_id) -> None:
    # Archive preserves history. Existing references may remain during an edit;
    # adding an archived item to a new/different record is a separate choice.
    if target is not None and str(target.id) != previous_id and _archived(session, target):
        raise CommandRejected(f"{target.entity_type}.archived", 409)


def _category_budget_move(session: Session, entity: SyncEntity, parent_id: str | None):
    if parent_id is None or parent_id == entity.payload["parent_id"]:
        return
    for budget in session.scalars(
        select(SyncEntity).where(
            SyncEntity.scope_id == entity.scope_id,
            SyncEntity.entity_type == "budget",
            SyncEntity.deleted.is_(False),
        )
    ):
        selected = {item["category_id"] for item in budget.payload["categories"]}
        if str(entity.id) in selected and parent_id in selected:
            raise CommandRejected("category.budget_overlap", 409)


def _validate_reporting(payload: dict, book: Book) -> None:
    amount = checked_currency(payload["money"])
    expected_scale = CURRENCY_SCALES.get(book.currency)
    if expected_scale is None:
        raise CommandRejected("currency.unsupported")
    reporting = payload.get("reporting")
    if amount.currency != book.currency and reporting is None:
        raise CommandRejected("fx.rate_required")
    if reporting is not None:
        if (reporting["report_currency"], reporting["report_scale"]) != (
            book.currency,
            expected_scale,
        ):
            raise CommandRejected("fx.report_currency_mismatch")
        converted = convert_money(amount, reporting["rate"], book.currency, expected_scale)
        if converted.minor != parse_minor(reporting["report_amount_minor"]):
            raise CommandRejected("fx.amount_mismatch")


def _reconcile_attachments(session, principal, entity_id, scope_id, previous, current):
    if not previous and not current:
        return
    try:
        from flowtrace_server.attachments.service import reconcile_bill_attachments
    except ModuleNotFoundError as error:
        if error.name not in {
            "flowtrace_server.attachments",
            "flowtrace_server.attachments.service",
        }:
            raise
        raise CommandRejected("attachment_not_ready") from None
    reconcile_bill_attachments(
        session,
        principal,
        entity_id,
        scope_id,
        [UUID(value) for value in previous],
        [UUID(value) for value in current],
    )


def _preserve_hidden(session: Session, entity: SyncEntity, incoming: dict) -> dict:
    public = public_bill(session, entity)
    if not public["hidden_account_fields"] and not public["hidden_allocation_count"]:
        raise CommandRejected("no_hidden_financial_links")
    visible = public["payload"]
    comparable = {key for key in visible if key not in NONFINANCIAL_FIELDS}
    if any(incoming[key] != visible[key] for key in comparable):
        raise CommandRejected("hidden_financial_fields_changed", 403)
    merged = deepcopy(entity.payload)
    for key in NONFINANCIAL_FIELDS:
        if key in incoming:
            merged[key] = incoming[key]
    # Revalidate the merged complete business command; the hint is never stored.
    return bill_storage_payload(BillPayload.model_validate(merged))


def _validate_sources(session: Session, principal: Principal, entity_id: UUID, payload: dict):
    if payload["bill_type"] not in {"refund", "reimbursement"}:
        return
    receipt = checked_currency(payload["money"])
    for item in payload["allocations"]:
        original = visible_entity(session, principal, UUID(item["source_bill_id"]), "bill")
        authorize_scope(session, principal, original.scope_id, write=True)
        if original.payload["bill_type"] != "expense":
            raise CommandRejected("allocation.invalid_source")
        source = checked_currency(original.payload["money"])
        amount = parse_minor(item["source_amount_minor"], positive=True)
        received = parse_minor(item["receipt_amount_minor"], positive=True)
        if amount + allocated_to(session, original.id, exclude=entity_id) > source.minor:
            raise CommandRejected("allocation.exceeds_remaining")
        if (source.currency, source.currency_scale) == (receipt.currency, receipt.currency_scale):
            if amount != received:
                raise CommandRejected("allocation.amount_mismatch")
        else:
            if item["rate"] is None:
                raise CommandRejected("fx.rate_required")
            converted = convert_money(
                type(source)(source.currency, source.currency_scale, amount),
                item["rate"],
                receipt.currency,
                receipt.currency_scale,
            )
            if converted.minor != received:
                raise CommandRejected("allocation.amount_mismatch")


def _account_postings(
    session,
    principal,
    entity_id,
    scope_id,
    payload,
    scopes,
    *,
    previous_payload=None,
    historical_adjustment_minor=None,
):
    money = checked_currency(payload["money"])
    kind = payload["bill_type"]
    accounts, postings = {}, []

    def add(identifier, value, component, amount):
        account = _account(session, principal, UUID(identifier), scope_id, value, scopes)
        previous_ids = set(account_links(previous_payload or {}).values())
        if account.payload.get("archived", False) and account.id not in previous_ids:
            raise CommandRejected("account.archived", 409)
        opening_date = account.payload.get("opening_date")
        if opening_date is not None and payload["business_date"] < opening_date:
            raise CommandRejected("account.before_opening", 409)
        accounts[account.id] = account
        if amount:
            postings.append((account, component, checked_minor(amount), value))
        return account

    if kind in TWO_ACCOUNT_KINDS:
        target_value = payload["target_money"] or payload["money"]
        target = checked_currency(target_value)
        first = add(payload["from_account_id"], payload["money"], "principal", -money.minor)
        second = add(payload["to_account_id"], target_value, "principal", target.minor)
        first_kind, second_kind = first.payload["kind"], second.payload["kind"]
        if kind == "transfer" and {first_kind, second_kind} & {"loan_payable", "loan_receivable"}:
            raise CommandRejected("transfer.debt_account_forbidden")
        funds = {"cash", "bank", "prepaid", "investment"}
        expected = {
            "credit_repayment": (funds, {"credit_card"}),
            "loan_borrow": ({"loan_payable"}, funds),
            "loan_lend": (funds, {"loan_receivable"}),
            "loan_collect": ({"loan_receivable"}, funds),
            "loan_repay": (funds, {"loan_payable"}),
        }.get(kind)
        if expected and (first_kind not in expected[0] or second_kind not in expected[1]):
            raise CommandRejected("account.invalid_kind")
    elif payload["account_id"] is not None:
        sign = -1 if kind == "expense" else 1
        if kind == "balance_adjustment":
            account = _account(
                session, principal, UUID(payload["account_id"]), scope_id, payload["money"], scopes
            )
            old = sum(
                session.scalars(
                    select(LedgerEntry.amount_minor).where(
                        LedgerEntry.bill_id == entity_id, LedgerEntry.account_id == account.id
                    )
                )
            )
            same_definition = previous_payload is not None and all(
                previous_payload.get(field) == payload.get(field)
                for field in ("bill_type", "account_id", "money", "target_balance_minor")
            )
            # A historical target is not a live balance invariant. Editing a
            # note/date/flag must retain the original signed movement even
            # after later income changed the account's current balance.
            delta = (
                historical_adjustment_minor
                if historical_adjustment_minor is not None
                else old
                if same_definition
                else checked_minor(
                    parse_minor(payload["target_balance_minor"]) - (account.balance_minor - old)
                )
            )
            if delta == 0 or abs(delta) != money.minor:
                raise CommandRejected("adjustment.amount_mismatch")
            add(payload["account_id"], payload["money"], "principal", delta)
        else:
            add(payload["account_id"], payload["money"], "principal", sign * money.minor)
    if payload["fee"] is not None:
        fee = payload["fee"]
        fee_amount = checked_currency(fee["money"])
        add(fee["account_id"], fee["money"], "fee", -fee_amount.minor)
    return accounts, postings


def _touch(entity: SyncEntity) -> None:
    entity.revision = checked_minor(entity.revision + 1)
    entity.updated_at = now()


def _bill_command(
    session, principal, operation, entity, scopes, *, historical_adjustment_minor=None
):
    if operation.move is not None:
        from .book_move import move_bill_command

        return move_bill_command(session, principal, operation, entity, scopes)
    scope_id, entity_id = UUID(operation.scope_id), UUID(operation.entity_id)
    scope = scopes[scope_id]
    if scope.kind != "book":
        raise CommandRejected("bill.book_scope_required")
    book = session.get(Book, scope.book_id)
    old = deepcopy(entity.payload) if entity else None
    old_links = account_links(old or {})
    preserve = operation.action == "update" and operation.payload.preserve_hidden_financial_links
    payload = None
    if operation.action != "delete":
        payload = bill_storage_payload(operation.payload, previous=old)
        if old is not None and "transfer_fx" not in operation.payload.model_fields_set:
            payload["transfer_fx"] = old.get("transfer_fx")
        if old is not None and old.get("transfer_fx") is not None:
            if payload["transfer_fx"] is None:
                raise CommandRejected("fx.frozen_rate_required")
        # A preserved optional frozen fact must still match changed amounts.
        try:
            payload = bill_storage_payload(
                BillPayload.model_validate(
                    {
                        **payload,
                        "preserve_hidden_financial_links": preserve,
                    }
                )
            )
        except ValidationError:
            raise CommandRejected("fx.frozen_rate_mismatch") from None
        payload["book_id"] = payload["book_id"] or str(scope.book_id)
        if payload["book_id"] != str(scope.book_id):
            raise ApiError("not_found", 404)
        if preserve:
            payload = _preserve_hidden(session, entity, payload)
    if not preserve:
        for account_id in old_links.values():
            account = visible_entity(session, principal, account_id, "account")
            authorize_scope(session, principal, account.scope_id, write=True)

    # Monetary writes cannot be smuggled through the metadata-only path. Old
    # private account links are retained there, so no balance/entry is touched.
    if payload is not None:
        category = _same_book_reference(
            session, principal, payload["category_id"], "category", scope_id
        )
        _new_reference_is_active(session, category, (old or {}).get("category_id"))
        if category is not None and payload["bill_type"] in {"income", "expense"}:
            if category.payload["kind"] != payload["bill_type"]:
                raise CommandRejected("category.kind_mismatch")
        for tag_id in payload["tag_ids"]:
            tag = _same_book_reference(session, principal, tag_id, "tag", scope_id)
            if tag.payload.get("kind", "tag") != "tag":
                raise CommandRejected("tag.group_not_selectable")
            previous = tag_id if tag_id in (old or {}).get("tag_ids", []) else None
            _new_reference_is_active(session, tag, previous)
        _validate_reporting(payload, book)
        if payload["fee"] is not None:
            _validate_reporting(payload["fee"], book)
            fee_category = _same_book_reference(
                session, principal, payload["fee"]["category_id"], "category", scope_id
            )
            _new_reference_is_active(
                session, fee_category, ((old or {}).get("fee") or {}).get("category_id")
            )
            if fee_category is not None and fee_category.payload["kind"] != "expense":
                raise CommandRejected("category.kind_mismatch")
        if not preserve:
            _validate_sources(session, principal, entity_id, payload)

    if entity is not None and old["bill_type"] == "expense":
        allocated = allocated_to(session, entity.id)
        if allocated and (payload is None or payload["bill_type"] != "expense"):
            raise CommandRejected("bill.has_allocations")
        if allocated and payload is not None:
            if (
                payload["money"]["currency"] != old["money"]["currency"]
                or parse_minor(payload["money"]["amount_minor"]) < allocated
            ):
                raise CommandRejected("allocation.exceeds_remaining")

    if entity is None:
        entity = SyncEntity(
            id=entity_id,
            scope_id=scope_id,
            entity_type="bill",
            revision=1,
            deleted=False,
            payload=payload,
            balance_minor=None,
            created_at=now(),
            updated_at=now(),
        )
        session.add(entity)
        session.flush()
    else:
        _touch(entity)
    _reconcile_attachments(
        session,
        principal,
        entity_id,
        scope_id,
        (old or {}).get("attachment_ids", []),
        (payload or {}).get("attachment_ids", []),
    )
    sources = set() if preserve else financial_source_ids(old) | financial_source_ids(payload)
    private_scopes = set()
    accounts = {}
    if not preserve:
        old_entries = list(
            session.scalars(select(LedgerEntry).where(LedgerEntry.bill_id == entity_id))
        )
        deltas = defaultdict(int)
        for row in old_entries:
            deltas[row.account_id] -= row.amount_minor
            accounts[row.account_id] = current_entity(session, row.account_id)
        postings = []
        if payload is not None:
            new_accounts, postings = _account_postings(
                session,
                principal,
                entity_id,
                scope_id,
                payload,
                scopes,
                previous_payload=old,
                historical_adjustment_minor=historical_adjustment_minor,
            )
            accounts.update(new_accounts)
        session.execute(delete(LedgerEntry).where(LedgerEntry.bill_id == entity_id))
        for account, component, amount, value in postings:
            deltas[account.id] += amount
            session.add(
                LedgerEntry(
                    id=uuid4(),
                    bill_id=entity_id,
                    account_id=account.id,
                    book_id=scope.book_id,
                    component=component,
                    amount_minor=amount,
                    currency=value["currency"],
                    currency_scale=value["currency_scale"],
                    business_date=business_date(payload["business_date"]),
                )
            )
        for account_id, delta in deltas.items():
            account = accounts[account_id]
            account.balance_minor = checked_minor(account.balance_minor + delta)
            _touch(account)
            account_scope = scopes[account.scope_id]
            if account_scope.kind == "user":
                private_scopes.add(account_scope.id)
        entity.payload = payload if payload is not None else old
    else:
        entity.payload = payload
    entity.deleted = operation.action == "delete"
    session.flush()
    events = [entity_event(session, entity)]
    for account in accounts.values():
        events.append(entity_event(session, account))
    for source_id in sorted(sources):
        source = visible_entity(session, principal, source_id, "bill")
        _touch(source)
        events.append(entity_event(session, source))
    for user_id in sorted(private_scopes):
        data = None if entity.deleted else private_finance(session, entity, user_id)
        # Clearing the last private link also emits a private tombstone.
        events.append(PendingEvent(user_id, "bill", entity.id, entity.revision, data is None, data))
    return entity, events


def _has_reference(session: Session, entity: SyncEntity) -> bool:
    for bill in all_live_bills(session):
        data = bill.payload
        if entity.entity_type == "account" and entity.id in account_links(data).values():
            return True
        if entity.entity_type == "category" and (
            data["category_id"] == str(entity.id)
            or (data.get("fee") and data["fee"]["category_id"] == str(entity.id))
        ):
            return True
        if entity.entity_type == "tag" and str(entity.id) in data["tag_ids"]:
            return True
    if entity.entity_type == "category":
        for other in session.scalars(
            select(SyncEntity).where(
                SyncEntity.scope_id == entity.scope_id, SyncEntity.deleted.is_(False)
            )
        ):
            if other.entity_type == "category" and other.payload["parent_id"] == str(entity.id):
                return True
            if other.entity_type == "budget" and any(
                item["category_id"] == str(entity.id) for item in other.payload["categories"]
            ):
                return True
    return False


def apply_command(
    session: Session,
    principal: Principal,
    operation: Operation,
    entity,
    scopes,
    *,
    historical_adjustment_minor: int | None = None,
):
    # Only the import service supplies a verified historical posting. A past
    # absolute target cannot be recalculated against a reconstructed balance
    # after other historical bills have been edited. Ordinary sync never passes
    # this argument, and retains its current target-minus-balance validation.
    if historical_adjustment_minor is not None:
        if (
            operation.entity_type != "bill"
            or operation.action != "create"
            or entity is not None
            or operation.move is not None
            or operation.payload.bill_type != "balance_adjustment"
        ):
            raise CommandRejected("import.historical_posting_invalid")
        checked_minor(historical_adjustment_minor)
        if (
            historical_adjustment_minor == 0
            or abs(historical_adjustment_minor)
            != checked_currency(operation.payload.money.model_dump()).minor
        ):
            raise CommandRejected("adjustment.amount_mismatch")
    scope = scopes[UUID(operation.scope_id)]
    grant = authorize_scope(session, principal, scope.id, write=True)
    kind, action = operation.entity_type, operation.action
    if kind == "bill":
        return _bill_command(
            session,
            principal,
            operation,
            entity,
            scopes,
            historical_adjustment_minor=historical_adjustment_minor,
        )
    if kind == "book" and action == "create":
        if scope.kind != "user" or scope.owner_user_id != principal.user_id:
            raise CommandRejected("book.user_scope_required")
        payload = operation.payload.model_dump()
        if payload["currency"] not in CURRENCY_SCALES:
            raise CommandRejected("currency.unsupported")
        book = Book(
            id=UUID(operation.entity_id),
            owner_user_id=principal.user_id,
            shared=False,
            deleted=False,
            created_at=now(),
            **{key: payload[key] for key in BOOK_CORE_FIELDS},
        )
        session.add(book)
        session.flush()
        session.add_all(
            [
                BookMembership(
                    book_id=book.id, user_id=principal.user_id, role="owner", active=True
                ),
                SyncScope(
                    id=book.id,
                    kind="book",
                    owner_user_id=principal.user_id,
                    book_id=book.id,
                    revision=0,
                    permission_version=1,
                ),
            ]
        )
        session.flush()
        scopes[book.id] = session.get(SyncScope, book.id)
        scope.permission_version = checked_minor(scope.permission_version + 1)
        from .service import initialize_book_sync

        entity = initialize_book_sync(session, book, emit_change=False, locked_scopes=scopes)
        # Extra metadata belongs to the sync JSON. Book ORM remains the single
        # source of truth for its four existing identity/permission core fields.
        entity.payload = payload
        return entity, [entity_event(session, entity)]
    if kind == "book" and grant.role != "owner":
        raise ApiError("book_owner_required", 403)
    if kind != "account" and scope.kind != "book":
        raise CommandRejected("entity.book_scope_required")
    if action == "delete":
        if kind == "tag" and _children(session, entity, "group_id"):
            raise CommandRejected("tag.group_not_empty", 409)
        if kind in {"account", "category", "tag"} and _has_reference(session, entity):
            raise CommandRejected("entity_in_use", 409)
        if kind == "book":
            if (
                session.scalar(
                    select(SyncEntity.id)
                    .where(
                        SyncEntity.scope_id == entity.scope_id,
                        SyncEntity.id != entity.id,
                        SyncEntity.deleted.is_(False),
                    )
                    .limit(1)
                )
                is not None
            ):
                raise CommandRejected("book_not_empty", 409)
            # Private accounts are not children of this book. A live bill
            # referring to one is nevertheless a child and blocks deletion.
            book = session.get(Book, entity.id)
            book.deleted = True
            members = list(
                session.scalars(
                    select(BookMembership).where(
                        BookMembership.book_id == entity.id, BookMembership.active.is_(True)
                    )
                )
            )
            for member in members:
                scopes[member.user_id].permission_version = checked_minor(
                    scopes[member.user_id].permission_version + 1
                )
            scope.permission_version = checked_minor(scope.permission_version + 1)
        _touch(entity)
        entity.deleted = True
        events = [entity_event(session, entity)]
        if kind == "book":
            events.extend(
                PendingEvent(member.user_id, "book", entity.id, entity.revision, True, None)
                for member in members
            )
        return entity, events
    payload = operation.payload.model_dump()
    if entity is not None and kind in MANAGEMENT_NEW_FIELDS:
        # Old v1 clients replace all fields they know. Newly optional metadata
        # omitted by such a client must not erase a newer client's settings.
        previous = management_payload(kind, entity.payload)
        for key in MANAGEMENT_NEW_FIELDS[kind] - operation.payload.model_fields_set:
            payload[key] = previous[key]
    if kind == "account":
        opening = checked_currency(payload["opening"])
        from flowtrace_server.assets.validation import validate_account_metadata

        validate_account_metadata(session, principal, scope, payload)
        if entity is not None:
            old = entity.payload["opening"]
            posted = _has_reference(session, entity)
            if posted and (
                old["currency"] != opening.currency
                or old["currency_scale"] != opening.currency_scale
                or entity.payload["kind"] != payload["kind"]
                or old["amount_minor"] != opening.to_json()["amount_minor"]
                or entity.payload.get("opening_date") != payload["opening_date"]
            ):
                raise CommandRejected("account.definition_in_use", 409)
            delta = opening.minor - parse_minor(old["amount_minor"])
            entity.balance_minor = checked_minor(entity.balance_minor + delta)
    elif kind == "category":
        parent = _same_book_reference(
            session, principal, payload["parent_id"], "category", scope.id
        )
        if parent is not None and (
            parent.payload["parent_id"] is not None or parent.payload["kind"] != payload["kind"]
        ):
            raise CommandRejected("category.invalid_parent")
        if (
            entity is not None
            and payload["kind"] != entity.payload["kind"]
            and _has_reference(session, entity)
        ):
            raise CommandRejected("category.definition_in_use", 409)
        if entity is not None and payload["parent_id"] is not None:
            if _children(session, entity, "parent_id"):
                raise CommandRejected("category.invalid_parent")
        if entity is not None:
            _category_budget_move(session, entity, payload["parent_id"])
    elif kind == "tag":
        group = _same_book_reference(session, principal, payload["group_id"], "tag", scope.id)
        if payload["kind"] == "group" and payload["group_id"] is not None:
            raise CommandRejected("tag.group_must_be_root")
        if group is not None and group.payload.get("kind", "tag") != "group":
            raise CommandRejected("tag.invalid_group")
        if entity is not None and payload["kind"] != entity.payload.get("kind", "tag"):
            if _children(session, entity, "group_id"):
                raise CommandRejected("tag.group_not_empty", 409)
            if _has_reference(session, entity):
                raise CommandRejected("tag.definition_in_use", 409)
    elif kind == "budget":
        book = session.get(Book, scope.book_id)
        limits = ([payload["total"]] if payload["total"] is not None else []) + [
            item["limit"] for item in payload["categories"]
        ]
        for value in limits:
            if checked_currency(value).currency != book.currency:
                raise CommandRejected("budget.currency_mismatch")
        selected = {item["category_id"] for item in payload["categories"]}
        previous = (
            {item["category_id"] for item in entity.payload["categories"]}
            if entity is not None
            else set()
        )
        for item in payload["categories"]:
            category = _same_book_reference(
                session, principal, item["category_id"], "category", scope.id
            )
            if category.payload["kind"] != "expense" or category.payload["parent_id"] in selected:
                raise CommandRejected("budget.category_overlap")
            _new_reference_is_active(
                session, category, item["category_id"] if item["category_id"] in previous else None
            )
    elif kind == "book":
        book = session.get(Book, entity.id)
        if payload["currency"] not in CURRENCY_SCALES:
            raise CommandRejected("currency.unsupported")
        if (
            payload["currency"] != book.currency
            and session.scalar(
                select(SyncEntity.id)
                .where(
                    SyncEntity.scope_id == scope.id,
                    SyncEntity.id != entity.id,
                    SyncEntity.deleted.is_(False),
                )
                .limit(1)
            )
            is not None
        ):
            raise CommandRejected("book_currency_in_use", 409)
        for key in BOOK_CORE_FIELDS:
            setattr(book, key, payload[key])
    if entity is None:
        entity = SyncEntity(
            id=UUID(operation.entity_id),
            scope_id=scope.id,
            entity_type=kind,
            revision=1,
            deleted=False,
            payload=payload,
            balance_minor=parse_minor(payload["opening"]["amount_minor"])
            if kind == "account"
            else None,
            created_at=now(),
            updated_at=now(),
        )
        session.add(entity)
    else:
        _touch(entity)
        entity.payload = payload
    session.flush()
    return entity, [entity_event(session, entity)]
