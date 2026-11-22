import uuid
from datetime import datetime, timedelta, timezone

import pytest
from pika.exceptions import AMQPConnectionError
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app import events
from app.models import Base, Receipt

NOW = datetime(2026, 11, 22, 12, 0)  # naive: SQLite returns naive datetimes


@pytest.fixture
def session():
    engine = create_engine("sqlite://")
    Base.metadata.create_all(engine)
    with sessionmaker(engine, expire_on_commit=False)() as s:
        yield s


def add(session, status="uploaded", attempts=1, age=timedelta(minutes=5)):
    r = Receipt(id=uuid.uuid4(), object_key=f"k/{uuid.uuid4()}.png", content_type="image/png",
                status=status, ocr_attempts=attempts, updated_at=NOW - age)
    session.add(r)
    session.commit()
    return r


def test_apply_parsed_result(session):
    r = add(session)
    ok = events.apply_result(session, {"id": str(r.id), "status": "parsed", "merchant": "CÀ PHÊ SÁNG",
                                       "total_vnd": 125000, "purchased_at": "2026-11-20T09:30:00+07:00",
                                       "raw_text": "...", "confidence": 0.98})
    assert ok and r.status == "parsed" and r.total_vnd == 125000 and r.merchant == "CÀ PHÊ SÁNG"


def test_result_never_overwrites_a_user_correction(session):
    r = add(session, status="corrected")
    assert not events.apply_result(session, {"id": str(r.id), "status": "parsed", "total_vnd": 1})
    assert r.status == "corrected"


def test_failed_result_and_bad_total(session):
    r = add(session)
    events.apply_result(session, {"id": str(r.id), "status": "failed", "error": "unreadable image"})
    assert r.status == "failed" and "unreadable image" in r.raw_text
    r2 = add(session)
    events.apply_result(session, {"id": str(r2.id), "status": "parsed", "total_vnd": -5})
    assert r2.total_vnd is None  # out-of-range value from the worker is dropped, not stored


def test_sweep_resends_stale_and_gives_up(session, monkeypatch):
    sent = []
    monkeypatch.setattr(events, "request_ocr", lambda r: sent.append(r.id))
    fresh = add(session, age=timedelta(seconds=30))
    stale = add(session, attempts=1)
    exhausted_recent = add(session, attempts=3, age=timedelta(minutes=5))
    exhausted_old = add(session, attempts=3, age=timedelta(minutes=15))
    resent, failed = events.sweep(session, now=NOW)
    assert sent == [stale.id] and resent == 1 and stale.ocr_attempts == 2
    assert failed == 1 and exhausted_old.status == "failed"
    assert fresh.status == exhausted_recent.status == "uploaded"


def test_sweep_stops_when_broker_is_down(session, monkeypatch):
    def down(_r):
        raise AMQPConnectionError("down")
    monkeypatch.setattr(events, "request_ocr", down)
    r = add(session)
    assert events.sweep(session, now=NOW) == (0, 0)
    assert r.ocr_attempts == 1  # not counted, retried next sweep
