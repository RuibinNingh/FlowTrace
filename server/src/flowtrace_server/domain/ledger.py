"""Small, deterministic ledger reference; not a database or authorization service.

All commands run against isolated in-memory state. P2 must provide real
transactions, current resource authorization and operation/revision receipts.
The fixture aliases used here are not permission to accept non-UUID API IDs.
"""

from __future__ import annotations

from copy import deepcopy

from .calendar_rules import business_date, recurrence_dates
from .money import (
    DomainError,
    Money,
    allocate_last,
    checked_minor,
    convert_money,
    parse_minor,
    parse_rate,
    round_half_up,
)


class ReferenceLedger:
    def __init__(self, setup: dict):
        self.setup = deepcopy(setup)
        self.accounts = {row["id"]: deepcopy(row) for row in setup.get("accounts", [])}
        self.bills: dict[str, dict] = {}
        self.budgets = {row["id"]: deepcopy(row) for row in setup.get("budgets", [])}
        self.rates = {setup["report_currency"]: "1", **setup.get("valuation_rates", {})}
        self.plans: dict[str, dict] = {}
        self.rules: dict[str, dict] = {}
        self.savings: dict[str, dict] = {}
        self.saving_records: dict[str, dict] = {}
        for account in self.accounts.values():
            Money(
                account["currency"],
                account["currency_scale"],
                parse_minor(account["opening_minor"]),
            )
        for query in setup.get("period_queries", []):
            if business_date(query["start_date"]) >= business_date(query["end_date_exclusive"]):
                raise DomainError("date.invalid_period")
        for budget in self.budgets.values():
            self._validate_budget(budget)

    def execute(self, command: dict) -> dict:
        previous = deepcopy(self.__dict__)
        try:
            result = self._apply(deepcopy(command))
            return {"result": result, "state": self.project()}
        except DomainError as error:
            self.__dict__.clear()
            self.__dict__.update(previous)
            return {"result": "rejected", "error_code": error.code, "state": self.project()}
        except Exception:
            # Programming/schema failures must not leave half a local command.
            # They are re-raised, not disguised as business-rule rejections.
            self.__dict__.clear()
            self.__dict__.update(previous)
            raise

    def _apply(self, command: dict) -> str:
        action = command.get("action")
        if action == "create_bill":
            self._create_bill(command["bill"])
        elif action == "update_bill":
            current = self._bill(command["bill_id"])
            changes = command["changes"]
            if self._allocated(current["id"]) and set(changes) & {
                "money",
                "bill_type",
                "account_id",
                "business_date",
            }:
                raise DomainError("bill.has_allocations")
            if "id" in changes or "book_id" in changes:
                raise DomainError("bill.immutable_identity")
            updated = {**current, **changes}
            preserved_adjustment = None
            if current["bill_type"] == "balance_adjustment" and all(
                current.get(field) == updated.get(field)
                for field in ("bill_type", "account_id", "money", "target_balance_minor")
            ):
                preserved_adjustment = parse_minor(current["_adjustment_minor"])
            del self.bills[current["id"]]
            self._create_bill(updated, preserved_adjustment=preserved_adjustment)
        elif action == "delete_bill":
            bill = self._bill(command["bill_id"])
            if self._allocated(bill["id"]):
                raise DomainError("bill.has_allocations")
            del self.bills[bill["id"]]
            self.saving_records = {
                key: value
                for key, value in self.saving_records.items()
                if value.get("bill_id") != bill["id"]
            }
        elif action == "set_valuation_rate":
            parse_rate(command["rate"])
            self.rates[command["currency"]] = command["rate"]
        elif action == "set_budget":
            budget = {
                "id": command["budget_id"],
                "total_limit_minor": command["total_limit_minor"],
                "categories": command["categories"],
            }
            self._validate_budget(budget)
            self.budgets[budget["id"]] = budget
        elif action == "create_installment_plan":
            if command["mode"] != "expense_schedule":
                raise DomainError("schedule.unsupported_mode")
            if command["plan_id"] in self.plans:
                raise DomainError("schedule.id_conflict")
            money = Money.from_json(command["money"], positive=True)
            fee = parse_minor(command["total_fee_minor"])
            if fee < 0:
                raise DomainError("money.must_be_positive")
            business_date(command["start_date"])
            count = command["count"]
            principal = allocate_last(str(money.minor), count)
            fees = allocate_last(str(fee), count) if fee else ["0"] * count
            self.plans[command["plan_id"]] = {
                **command,
                "principal": principal,
                "fees": fees,
                "executed": [],
                "status": "active",
            }
        elif action == "execute_occurrence":
            plan = self.plans[command["plan_id"]]
            index = command["occurrence_index"]
            if type(index) is not int or not 1 <= index <= plan["count"]:
                raise DomainError("schedule.invalid_occurrence")
            if index in plan["executed"]:
                return "replayed"
            if plan["status"] != "active":
                raise DomainError("schedule.cancelled_occurrence")
            date = recurrence_dates(plan["start_date"], "monthly", index)[-1]
            amount = parse_minor(plan["principal"][index - 1]) + parse_minor(
                plan["fees"][index - 1]
            )
            if amount:
                self._generated_expense(
                    f"installment:{plan['plan_id']}:{index}",
                    plan,
                    str(checked_minor(amount)),
                    date,
                    "installment",
                )
            plan["executed"].append(index)
            if len(plan["executed"]) == plan["count"]:
                plan["status"] = "completed"
        elif action == "settle_installment":
            plan = self.plans[command["plan_id"]]
            if plan["status"] != "active":
                raise DomainError("schedule.cancelled_occurrence")
            remaining = self._remaining_plan(plan)
            if parse_minor(command["remaining_principal_minor"]) != remaining:
                raise DomainError("schedule.remaining_mismatch")
            fee = parse_minor(command["actual_fee_minor"])
            if fee < 0:
                raise DomainError("money.must_be_positive")
            if remaining + fee:
                self._generated_expense(
                    f"settlement:{plan['plan_id']}",
                    plan,
                    str(checked_minor(remaining + fee)),
                    command["settlement_date"],
                    "installment",
                )
            plan["status"] = "settled"
        elif action == "create_recurring_rule":
            if command["rule_id"] in self.rules:
                raise DomainError("schedule.id_conflict")
            dates = recurrence_dates(command["anchor_date"], command["frequency"], command["count"])
            Money.from_json(command["bill_template"]["money"], positive=True)
            self.rules[command["rule_id"]] = {**command, "dates": dates, "executed": []}
        elif action == "execute_recurring":
            rule = self.rules[command["rule_id"]]
            day = command["occurrence_date"]
            if day not in rule["dates"]:
                raise DomainError("schedule.invalid_occurrence")
            if day in rule["executed"]:
                return "replayed"
            template = rule["bill_template"]
            bill = self._generated_bill(
                f"recurring:{rule['rule_id']}:{day}", template, day, "recurring"
            )
            self._create_bill(bill)
            rule["executed"].append(day)
        elif action == "create_saving_plan":
            if command["plan_id"] in self.savings:
                raise DomainError("schedule.id_conflict")
            Money.from_json(command["money"], positive=True)
            self.savings[command["plan_id"]] = command
        elif action == "record_saving":
            plan = self.savings[command["plan_id"]]
            amount = Money.from_json(command["money"], positive=True)
            target = Money.from_json(plan["money"])
            if (amount.currency, amount.currency_scale) != (target.currency, target.currency_scale):
                raise DomainError("money.currency_mismatch")
            if command["record_id"] in self.saving_records:
                raise DomainError("saving.id_conflict")
            if command["mode"] == "linked_transfer":
                day = command.get("business_date")
                business_date(day)
                bill = self._generated_bill(
                    command["bill_id"], {**command, "bill_type": "transfer"}, day, "manual"
                )
                self._create_bill(bill)
            elif command["mode"] != "progress_only":
                raise DomainError("saving.invalid_mode")
            self.saving_records[command["record_id"]] = command
        elif action == "delete_saving_record":
            record = self.saving_records.pop(command["record_id"])
            if record.get("bill_id"):
                self.bills.pop(record["bill_id"])
        else:
            raise DomainError("command.unsupported")
        return "applied"

    def _bill(self, bill_id: str) -> dict:
        try:
            return self.bills[bill_id]
        except KeyError as error:
            raise DomainError("bill.not_found") from error

    def _generated_bill(self, bill_id: str, template: dict, day: str, source: str) -> dict:
        return {
            **template,
            "id": bill_id,
            "book_id": self.setup["book_id"],
            "business_date": day,
            "business_timezone": template.get("business_timezone", "Asia/Shanghai"),
            "source": source,
            "account_id": template.get("account_id"),
            "flags": template.get(
                "flags", {"exclude_from_statistics": False, "exclude_from_budget": False}
            ),
            "category_id": template.get("category_id", "uncategorized"),
        }

    def _generated_expense(
        self, bill_id: str, plan: dict, amount: str, day: str, source: str
    ) -> None:
        template = {
            **plan,
            "bill_type": "expense",
            "money": {**plan["money"], "amount_minor": amount},
        }
        self._create_bill(self._generated_bill(bill_id, template, day, source))

    @staticmethod
    def _remaining_plan(plan: dict) -> int:
        if plan["status"] == "settled":
            return 0
        return sum(
            parse_minor(amount)
            for index, amount in enumerate(plan["principal"], 1)
            if index not in plan["executed"]
        )

    def _account(self, account_id: str, money: Money) -> dict:
        account = self.accounts.get(account_id)
        if account is None:
            raise DomainError("account.not_found")
        if (account["currency"], account["currency_scale"]) != (
            money.currency,
            money.currency_scale,
        ):
            raise DomainError("money.currency_mismatch")
        return account

    def _create_bill(self, source: dict, *, preserved_adjustment: int | None = None) -> None:
        bill = deepcopy(source)
        if not isinstance(bill.get("id"), str) or not bill["id"]:
            raise DomainError("bill.invalid_id")
        if bill["id"] in self.bills:
            raise DomainError("bill.id_conflict")
        money = Money.from_json(bill["money"], positive=True)
        business_date(bill["business_date"])
        flags = bill.get("flags", {})
        if any(
            type(flags.get(name, False)) is not bool
            for name in ("exclude_from_statistics", "exclude_from_budget")
        ):
            raise DomainError("bill.invalid_flags")
        bill["flags"] = {
            name: flags.get(name, False)
            for name in ("exclude_from_statistics", "exclude_from_budget")
        }
        kind = bill["bill_type"]
        if kind in {"income", "expense", "refund", "reimbursement", "balance_adjustment"}:
            if bill.get("account_id") is not None:
                self._account(bill["account_id"], money)
        elif kind in {
            "transfer",
            "credit_repayment",
            "loan_borrow",
            "loan_lend",
            "loan_collect",
            "loan_repay",
        }:
            first = self._account(bill.get("from_account_id"), money)
            target = Money.from_json(bill.get("target_money", bill["money"]), positive=True)
            second = self._account(bill.get("to_account_id"), target)
            if first["id"] == second["id"]:
                raise DomainError("transfer.same_account")
            if kind == "transfer" and any(
                account["kind"] in {"loan_payable", "loan_receivable"}
                for account in (first, second)
            ):
                raise DomainError("transfer.debt_account_forbidden")
        else:
            raise DomainError("bill.unsupported_type")
        if "gross_amount_minor" in bill or "discount_minor" in bill:
            gross = parse_minor(bill.get("gross_amount_minor"))
            discount = parse_minor(bill.get("discount_minor"))
            if discount < 0 or discount > gross or gross - discount != money.minor:
                raise DomainError("bill.discount_invalid")
        if bill.get("fee"):
            fee = bill["fee"]
            self._account(fee["account_id"], Money.from_json(fee["money"], positive=True))
            self._report_amount({**fee, "bill_type": "expense"})
        if kind in {"refund", "reimbursement"}:
            allocated_receipt = 0
            per_source: dict[str, int] = {}
            for allocation in bill.get("allocations", []):
                original = self._bill(allocation["source_bill_id"])
                if original["bill_type"] != "expense":
                    raise DomainError("allocation.invalid_source")
                original_money = Money.from_json(original["money"])
                source_amount = parse_minor(allocation["source_amount_minor"], positive=True)
                receipt_amount = parse_minor(allocation["receipt_amount_minor"], positive=True)
                if (original_money.currency, original_money.currency_scale) == (
                    money.currency,
                    money.currency_scale,
                ):
                    if source_amount != receipt_amount:
                        raise DomainError("allocation.amount_mismatch")
                else:
                    if "rate" not in allocation:
                        raise DomainError("fx.rate_required")
                    converted = convert_money(
                        Money(
                            original_money.currency, original_money.currency_scale, source_amount
                        ),
                        allocation["rate"],
                        money.currency,
                        money.currency_scale,
                    )
                    if converted.minor != receipt_amount:
                        raise DomainError("allocation.amount_mismatch")
                per_source[original["id"]] = per_source.get(original["id"], 0) + source_amount
                if (
                    self._allocated(original["id"]) + per_source[original["id"]]
                    > original_money.minor
                ):
                    raise DomainError("allocation.exceeds_remaining")
                allocated_receipt += receipt_amount
            income = parse_minor(bill.get("income_component_minor", "0"))
            if (
                income < 0
                or (kind == "reimbursement" and income)
                or income + allocated_receipt != money.minor
            ):
                raise DomainError("allocation.amount_mismatch")
        self._report_amount(bill)
        if kind == "balance_adjustment":
            current = self._balances()[bill["account_id"]]
            target = parse_minor(bill["target_balance_minor"])
            delta = (
                checked_minor(target - current)
                if preserved_adjustment is None
                else preserved_adjustment
            )
            if delta == 0 or abs(delta) != money.minor:
                raise DomainError("adjustment.amount_mismatch")
            bill["_adjustment_minor"] = str(delta)
        self.bills[bill["id"]] = bill

    def _report_amount(self, bill: dict) -> int:
        money = Money.from_json(bill["money"])
        if (money.currency, money.currency_scale) == (
            self.setup["report_currency"],
            self.setup["report_scale"],
        ):
            return money.minor
        reporting = bill.get("reporting")
        if not reporting:
            raise DomainError("fx.rate_required")
        converted = convert_money(
            money, reporting["rate"], self.setup["report_currency"], self.setup["report_scale"]
        )
        if converted.minor != parse_minor(reporting["report_amount_minor"]):
            raise DomainError("fx.amount_mismatch")
        return converted.minor

    def _allocated(self, bill_id: str) -> int:
        return sum(
            parse_minor(allocation["source_amount_minor"])
            for bill in self.bills.values()
            for allocation in bill.get("allocations", [])
            if allocation["source_bill_id"] == bill_id
        )

    def _effective_bills(self):
        for bill in self.bills.values():
            yield bill
            if bill.get("fee"):
                yield {
                    **bill,
                    **bill["fee"],
                    "id": bill["id"] + ":fee",
                    "bill_type": "expense",
                    "fee": None,
                }

    def _balances(self) -> dict[str, int]:
        balances = {
            key: parse_minor(account["opening_minor"]) for key, account in self.accounts.items()
        }
        for bill in self._effective_bills():
            kind, amount = bill["bill_type"], Money.from_json(bill["money"]).minor
            if kind in {
                "transfer",
                "credit_repayment",
                "loan_borrow",
                "loan_lend",
                "loan_collect",
                "loan_repay",
            }:
                balances[bill["from_account_id"]] -= amount
                balances[bill["to_account_id"]] += Money.from_json(
                    bill.get("target_money", bill["money"])
                ).minor
            elif bill.get("account_id") is not None:
                delta = (
                    parse_minor(bill["_adjustment_minor"])
                    if kind == "balance_adjustment"
                    else -amount
                    if kind == "expense"
                    else amount
                )
                balances[bill["account_id"]] += delta
        return {key: checked_minor(value) for key, value in balances.items()}

    @staticmethod
    def _validate_budget(budget: dict) -> None:
        categories = [parse_minor(value) for value in budget["categories"].values()]
        if any(value < 0 for value in categories):
            raise DomainError("money.must_be_positive")
        if budget["total_limit_minor"] is not None and parse_minor(
            budget["total_limit_minor"]
        ) < sum(categories):
            raise DomainError("budget.total_below_categories")

    def project(self) -> dict:
        balances = self._balances()
        positive = negative = 0
        for key, balance in balances.items():
            account = self.accounts[key]
            if not account.get("include_in_net_assets", True):
                continue
            rate = self.rates.get(account["currency"])
            if rate is None:
                raise DomainError("fx.rate_required")
            value = convert_money(
                Money(account["currency"], account["currency_scale"], balance),
                rate,
                self.setup["report_currency"],
                self.setup["report_scale"],
            ).minor
            positive += max(value, 0)
            negative += max(-value, 0)
        periods = {}
        for query in self.setup.get("period_queries", []):
            income = 0
            categories: dict[str, int] = {}
            budget_categories: dict[str, int] = {}
            for bill in self._effective_bills():
                if not query["start_date"] <= bill["business_date"] < query["end_date_exclusive"]:
                    continue
                flags, kind = bill["flags"], bill["bill_type"]
                if kind == "income" and not flags["exclude_from_statistics"]:
                    income += self._report_amount(bill)
                elif kind == "expense":
                    money = Money.from_json(bill["money"])
                    report = self._report_amount(bill)
                    amount = report - round_half_up(
                        report * self._allocated(bill["id"]), money.minor
                    )
                    category = bill["category_id"]
                    if amount and not flags["exclude_from_statistics"]:
                        categories[category] = categories.get(category, 0) + amount
                    if amount and not flags["exclude_from_budget"]:
                        budget_categories[category] = budget_categories.get(category, 0) + amount
                elif kind == "refund" and not flags["exclude_from_statistics"]:
                    component = parse_minor(bill.get("income_component_minor", "0"))
                    original_money = Money.from_json(bill["money"])
                    income += round_half_up(
                        self._report_amount(bill) * component, original_money.minor
                    )
            expense, eligible = sum(categories.values()), sum(budget_categories.values())
            periods[query["period_id"]] = {
                "income_minor": str(checked_minor(income)),
                "expense_minor": str(checked_minor(expense)),
                "net_minor": str(checked_minor(income - expense)),
                "budget_eligible_minor": str(checked_minor(eligible)),
                "category_expense_minor": {
                    key: str(checked_minor(value)) for key, value in categories.items()
                },
                "budget_category_expense_minor": {
                    key: str(checked_minor(value)) for key, value in budget_categories.items()
                },
            }
        result = {
            "account_balances_minor": {key: str(value) for key, value in balances.items()},
            "periods": periods,
            "assets": {
                "currency": self.setup["report_currency"],
                "assets_minor": str(checked_minor(positive)),
                "liabilities_minor": str(checked_minor(negative)),
                "net_minor": str(checked_minor(positive - negative)),
            },
        }
        if self.budgets:
            # A reference budget is attached to a declared query; one-query
            # fixtures may omit period_id. Never select a period from the clock.
            result["budgets"] = {}
            for key, budget in self.budgets.items():
                period_id = budget.get("period_id")
                if period_id is None:
                    if len(periods) != 1:
                        raise DomainError("budget.period_required")
                    period_id = next(iter(periods))
                period = periods[period_id]
                subtotal = sum(parse_minor(value) for value in budget["categories"].values())
                total = (
                    parse_minor(budget["total_limit_minor"])
                    if budget["total_limit_minor"] is not None
                    else subtotal
                )
                if not budget["categories"] or (
                    budget["total_limit_minor"] is not None and total > subtotal
                ):
                    spent = parse_minor(period["budget_eligible_minor"])
                else:
                    spent = sum(
                        parse_minor(value)
                        for category, value in period["budget_category_expense_minor"].items()
                        if category in budget["categories"]
                    )
                result["budgets"][key] = {
                    "limit_minor": str(checked_minor(total)),
                    "spent_minor": str(checked_minor(spent)),
                    "remaining_minor": str(checked_minor(total - spent)),
                }
        if any(bill["bill_type"] == "expense" for bill in self.bills.values()):
            result["remaining_allocatable_minor"] = {
                key: str(Money.from_json(bill["money"]).minor - self._allocated(key))
                for key, bill in self.bills.items()
                if bill["bill_type"] == "expense"
            }
        if self.plans:
            result["plans"] = {
                key: {
                    "remaining_principal_minor": str(self._remaining_plan(plan)),
                    "status": plan["status"],
                }
                for key, plan in self.plans.items()
            }
        if self.savings:
            result["savings"] = {
                key: {
                    "progress_minor": str(
                        checked_minor(
                            sum(
                                Money.from_json(record["money"]).minor
                                for record in self.saving_records.values()
                                if record["plan_id"] == key
                            )
                        )
                    ),
                    "target_minor": plan["money"]["amount_minor"],
                }
                for key, plan in self.savings.items()
            }
        return result
