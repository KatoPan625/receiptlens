"""RabbitMQ glue for the API: publish OCR requests, apply OCR results, re-publish lost requests.

Topology and users are created by bootstrap.py; the `api` user can only publish to the
`receipts` exchange and read `api.results`.
"""
import json
import logging
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone

import pika
from pika.exceptions import AMQPError
from sqlalchemy import select

from .config import get_settings
from .db import _sessionmaker
from .models import Receipt

log = logging.getLogger("receiptlens.events")
EXCHANGE = "receipts"
MAX_ATTEMPTS = 3          # OCR requests per receipt before giving up
RESEND_AFTER = timedelta(minutes=2)
GIVE_UP_AFTER = timedelta(minutes=10)


def _params() -> pika.ConnectionParameters:
    s = get_settings()
    return pika.ConnectionParameters(host=s.rabbit_host, credentials=pika.PlainCredentials(s.rabbit_user, s.rabbit_password),
                                     heartbeat=30, blocked_connection_timeout=10, connection_attempts=2, retry_delay=1)


class Publisher:
    """One confirmed channel shared by request threads (pika is not thread-safe, hence the lock)."""

    def __init__(self):
        self._lock = threading.Lock()
        self._conn = self._chan = None

    def publish(self, routing_key: str, message: dict) -> None:
        body = json.dumps(message).encode()
        with self._lock:
            for attempt in (1, 2):  # reconnect once if the cached connection went stale
                try:
                    if self._chan is None or self._chan.is_closed:
                        self._conn = pika.BlockingConnection(_params())
                        self._chan = self._conn.channel()
                        self._chan.confirm_delivery()
                    # mandatory + confirms: raises if the broker can't route or store it
                    self._chan.basic_publish(EXCHANGE, routing_key, body, mandatory=True, properties=pika.BasicProperties(
                        delivery_mode=pika.DeliveryMode.Persistent, content_type="application/json",
                        message_id=str(uuid.uuid4())))
                    return
                except AMQPError:
                    self._chan = None
                    if attempt == 2:
                        raise


publisher = Publisher()


def request_ocr(receipt: Receipt) -> None:
    publisher.publish("receipt.uploaded", {"id": str(receipt.id), "object_key": receipt.object_key,
                                           "content_type": receipt.content_type})


def apply_result(session, msg: dict) -> bool:
    """Store an OCR result. Returns False if it was ignored (unknown receipt or already handled)."""
    receipt = session.get(Receipt, uuid.UUID(msg["id"]))
    # Only 'uploaded' receipts take results: a user's correction always wins, duplicates are no-ops.
    if receipt is None or receipt.status != "uploaded":
        return False
    if msg.get("status") == "parsed":
        receipt.status = "parsed"
        receipt.merchant = (msg.get("merchant") or None) and msg["merchant"][:200]
        total = msg.get("total_vnd")
        receipt.total_vnd = total if isinstance(total, int) and 0 <= total <= 10**12 else None
        receipt.purchased_at = datetime.fromisoformat(msg["purchased_at"]) if msg.get("purchased_at") else None
        receipt.raw_text = msg.get("raw_text")
        receipt.confidence = msg.get("confidence")
    else:
        receipt.status = "failed"
        receipt.raw_text = f"OCR failed: {msg.get('error', 'unknown error')}"[:2000]
    session.commit()
    return True


def _consume_results(stop: threading.Event) -> None:
    while not stop.is_set():
        try:
            conn = pika.BlockingConnection(_params())
            chan = conn.channel()
            chan.basic_qos(prefetch_count=10)
            for method, _props, body in chan.consume("api.results", inactivity_timeout=5):
                if stop.is_set():
                    break
                if method is None:  # idle tick
                    continue
                try:
                    msg = json.loads(body)
                    with _sessionmaker()() as session:
                        apply_result(session, msg)
                    chan.basic_ack(method.delivery_tag)
                except (ValueError, KeyError, TypeError):
                    log.exception("malformed result, dead-lettering")
                    chan.basic_reject(method.delivery_tag, requeue=False)
                except Exception:
                    log.exception("could not store result, will be redelivered")
                    chan.basic_nack(method.delivery_tag, requeue=True)
            conn.close()
        except AMQPError:
            log.warning("result consumer lost RabbitMQ, retrying in 5 s")
            stop.wait(5)


def sweep(session, now: datetime | None = None) -> tuple[int, int]:
    """Re-publish OCR requests that never got an answer; give up after MAX_ATTEMPTS.

    Rows are locked with SKIP LOCKED so several API replicas never resend the same receipt.
    """
    now = now or datetime.now(timezone.utc)
    stale = session.scalars(select(Receipt).where(
        Receipt.status == "uploaded", Receipt.updated_at < now - RESEND_AFTER).with_for_update(skip_locked=True).limit(50))
    resent = failed = 0
    for receipt in stale:
        if receipt.ocr_attempts >= MAX_ATTEMPTS:
            if receipt.updated_at < now - GIVE_UP_AFTER:
                receipt.status = "failed"
                receipt.raw_text = f"OCR gave no result after {MAX_ATTEMPTS} attempts"
                failed += 1
            continue
        try:
            request_ocr(receipt)
        except AMQPError:
            break  # broker down: try again next sweep
        receipt.ocr_attempts += 1
        receipt.updated_at = now
        resent += 1
    session.commit()
    return resent, failed


def _sweep_loop(stop: threading.Event) -> None:
    while not stop.wait(60):
        try:
            with _sessionmaker()() as session:
                resent, failed = sweep(session)
            if resent or failed:
                log.warning("sweep: re-published %d OCR request(s), marked %d failed", resent, failed)
        except Exception:
            log.exception("sweep failed")


def start_background() -> threading.Event:
    stop = threading.Event()
    for target in (_consume_results, _sweep_loop):
        threading.Thread(target=target, args=(stop,), daemon=True, name=target.__name__).start()
    return stop
