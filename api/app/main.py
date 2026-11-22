import socket
import time
import uuid
from datetime import datetime, timezone
from typing import Annotated

from botocore.exceptions import BotoCoreError, ClientError
from fastapi import Depends, FastAPI, HTTPException, Query, Request, UploadFile
from fastapi.responses import Response, StreamingResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select, text
from sqlalchemy.orm import Session

from .config import get_settings
from .db import get_session
from .models import Receipt
from .storage import Storage, get_storage

# Served under /api by the edge; the prefix is set with uvicorn --root-path (see Dockerfile).
app = FastAPI(title="ReceiptLens API")

REPLICA = socket.gethostname()  # container ID; shows which replica HAProxy picked
REQUESTS = Counter("http_requests_total", "HTTP requests", ["method", "route", "status"])
LATENCY = Histogram("http_request_duration_seconds", "Request latency", ["route"],
                    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5))


@app.middleware("http")
async def observe(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    # Route template (e.g. /receipts/{receipt_id}) keeps label cardinality low.
    route = getattr(request.scope.get("route"), "path", "unmatched")
    if route != "/metrics":
        REQUESTS.labels(request.method, route, str(response.status_code)).inc()
        LATENCY.labels(route).observe(time.perf_counter() - start)
    response.headers["X-Served-By"] = REPLICA
    return response


@app.get("/metrics", include_in_schema=False)
def metrics() -> Response:
    # Not reachable from outside: the edge returns 404 for /api/metrics; Prometheus scrapes replicas directly.
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

SessionDep = Annotated[Session, Depends(get_session)]
StorageDep = Annotated[Storage, Depends(get_storage)]

# Magic bytes: trust the file content, not the client's Content-Type header.
SIGNATURES = (
    (b"\xff\xd8\xff", "image/jpeg", "jpg"),
    (b"\x89PNG\r\n\x1a\n", "image/png", "png"),
)


def sniff_image(head: bytes) -> tuple[str, str] | None:
    for sig, ctype, ext in SIGNATURES:
        if head.startswith(sig):
            return ctype, ext
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp", "webp"
    return None


class ReceiptOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    status: str
    merchant: str | None
    total_vnd: int | None
    purchased_at: datetime | None
    confidence: float | None
    created_at: datetime
    updated_at: datetime


class ReceiptDetail(ReceiptOut):
    raw_text: str | None


class ReceiptPatch(BaseModel):
    model_config = ConfigDict(extra="forbid")
    merchant: str | None = Field(default=None, max_length=200)
    total_vnd: int | None = Field(default=None, ge=0, le=10**12)
    purchased_at: datetime | None = None


class MonthStat(BaseModel):
    month: str
    count: int
    total_vnd: int


@app.get("/healthz", include_in_schema=False)
def healthz(session: SessionDep) -> dict:
    session.execute(text("SELECT 1"))
    return {"status": "ok"}


@app.post("/receipts", status_code=201, response_model=ReceiptOut)
async def upload_receipt(file: UploadFile, session: SessionDep, storage: StorageDep) -> Receipt:
    limit = get_settings().max_upload_mb * 1024 * 1024
    data = await file.read(limit + 1)
    if len(data) > limit:
        raise HTTPException(413, f"File larger than {get_settings().max_upload_mb} MB")
    kind = sniff_image(data[:16])
    if kind is None:
        raise HTTPException(415, "Only JPEG, PNG or WebP images are accepted")
    ctype, ext = kind
    rid = uuid.uuid4()
    now = datetime.now(timezone.utc)
    key = f"{now:%Y/%m}/{rid}.{ext}"
    try:
        storage.put(key, data, ctype)
    except (BotoCoreError, ClientError) as e:
        raise HTTPException(502, "Object storage unavailable") from e
    receipt = Receipt(id=rid, object_key=key, content_type=ctype, status="uploaded")
    session.add(receipt)
    try:
        session.commit()
    except Exception:
        session.rollback()
        try:  # don't leave an orphan object behind
            storage.delete(key)
        except (BotoCoreError, ClientError):
            pass
        raise
    session.refresh(receipt)
    return receipt


@app.get("/receipts", response_model=list[ReceiptOut])
def list_receipts(
    session: SessionDep,
    month: Annotated[str | None, Query(pattern=r"^\d{4}-(0[1-9]|1[0-2])$")] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> list[Receipt]:
    q = select(Receipt).order_by(Receipt.created_at.desc()).limit(limit).offset(offset)
    if month:
        y, m = map(int, month.split("-"))
        start = datetime(y, m, 1, tzinfo=timezone.utc)
        end = datetime(y + (m == 12), m % 12 + 1, 1, tzinfo=timezone.utc)
        q = q.where(Receipt.created_at >= start, Receipt.created_at < end)
    return list(session.scalars(q))


def _get(session: Session, receipt_id: uuid.UUID) -> Receipt:
    receipt = session.get(Receipt, receipt_id)
    if receipt is None:
        raise HTTPException(404, "Receipt not found")
    return receipt


@app.get("/receipts/{receipt_id}", response_model=ReceiptDetail)
def get_receipt(receipt_id: uuid.UUID, session: SessionDep) -> Receipt:
    return _get(session, receipt_id)


@app.get("/receipts/{receipt_id}/image")
def get_image(receipt_id: uuid.UUID, session: SessionDep, storage: StorageDep) -> StreamingResponse:
    receipt = _get(session, receipt_id)
    try:
        chunks = storage.stream(receipt.object_key)
        first = next(chunks, b"")  # fail here (502), not halfway through the response
    except (BotoCoreError, ClientError) as e:
        raise HTTPException(502, "Object storage unavailable") from e

    def body():
        yield first
        yield from chunks

    return StreamingResponse(body(), media_type=receipt.content_type,
                             headers={"Cache-Control": "private, max-age=300"})


@app.patch("/receipts/{receipt_id}", response_model=ReceiptDetail)
def correct_receipt(receipt_id: uuid.UUID, patch: ReceiptPatch, session: SessionDep) -> Receipt:
    receipt = _get(session, receipt_id)
    changes = patch.model_dump(exclude_unset=True)
    if not changes:
        raise HTTPException(422, "Nothing to update")
    for field, value in changes.items():
        setattr(receipt, field, value)
    receipt.status = "corrected"
    session.commit()
    session.refresh(receipt)
    return receipt


@app.get("/stats/monthly", response_model=list[MonthStat])
def monthly_stats(session: SessionDep) -> list[MonthStat]:
    # shortcut: aggregates in Python over receipts with a total; move to SQL GROUP BY once data grows past a few thousand rows.
    rows = session.execute(
        select(Receipt.purchased_at, Receipt.created_at, Receipt.total_vnd).where(Receipt.total_vnd.is_not(None))
    )
    agg: dict[str, list[int]] = {}
    for purchased_at, created_at, total in rows:
        month = f"{(purchased_at or created_at):%Y-%m}"
        bucket = agg.setdefault(month, [0, 0])
        bucket[0] += 1
        bucket[1] += total
    return [MonthStat(month=m, count=c, total_vnd=t) for m, (c, t) in sorted(agg.items(), reverse=True)]
