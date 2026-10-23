from datetime import date
from decimal import Decimal
from uuid import UUID

from sqlalchemy import BigInteger, CheckConstraint, Date, ForeignKey, Index, Numeric, String, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from flowtrace_server.persistence.models import Base


class CurrencyPreferences(Base):
    __tablename__ = "currency_preferences"
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    base_currency: Mapped[str] = mapped_column(String(3))
    enabled_codes: Mapped[list] = mapped_column(JSONB)
    valuation_policy: Mapped[str] = mapped_column(String(24))


class ValuationRate(Base):
    __tablename__ = "valuation_rates"
    __table_args__ = (
        CheckConstraint("rate > 0 AND rate < 100000000000000000000", name="ck_valuation_rate"),
        CheckConstraint("from_currency <> to_currency", name="ck_valuation_pair"),
        CheckConstraint("revision > 0", name="ck_valuation_revision"),
        Index(
            "uq_valuation_pair_date",
            "user_id",
            "from_currency",
            "to_currency",
            "effective_date",
            unique=True,
            postgresql_where=text("NOT deleted"),
        ),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    from_currency: Mapped[str] = mapped_column(String(3))
    to_currency: Mapped[str] = mapped_column(String(3))
    effective_date: Mapped[date] = mapped_column(Date)
    rate: Mapped[Decimal] = mapped_column(Numeric(38, 18))
    rate_text: Mapped[str] = mapped_column(String(39))
    rate_source: Mapped[str] = mapped_column(String(80))
    revision: Mapped[int] = mapped_column(BigInteger)
    deleted: Mapped[bool] = mapped_column(default=False)
