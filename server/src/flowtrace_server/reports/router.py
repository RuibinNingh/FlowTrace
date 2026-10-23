from uuid import UUID

from fastapi import APIRouter, Depends, Request, Response
from sqlalchemy.orm import Session

from flowtrace_server.auth.dependencies import authenticated_request, get_session
from flowtrace_server.sync.schemas import BusinessDate, Identifier

from .schemas import BookReportResponse
from .service import read_book_report

router = APIRouter(prefix="/api/v1/books", tags=["reports"])


@router.get("/{book_id}/report", response_model=BookReportResponse, operation_id="book_report")
def book_report_route(
    book_id: Identifier,
    start_date: BusinessDate,
    end_date_exclusive: BusinessDate,
    request: Request,
    response: Response,
    budget_id: Identifier | None = None,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    result = read_book_report(
        session,
        principal,
        UUID(book_id),
        start_date,
        end_date_exclusive,
        UUID(budget_id) if budget_id is not None else None,
    )
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    return result
