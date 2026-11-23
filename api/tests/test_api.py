import io
from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db import get_session
from app.main import app, sniff_image
from app.models import Base
from app.storage import get_storage

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 64


class FakeStorage:
    def __init__(self):
        self.objects: dict[str, bytes] = {}

    def put(self, key, data, content_type):
        self.objects[key] = data

    def stream(self, key) -> Iterator[bytes]:
        yield self.objects[key]

    def delete(self, key):
        self.objects.pop(key, None)


@pytest.fixture
def client():
    engine = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    maker = sessionmaker(engine, expire_on_commit=False)
    storage = FakeStorage()

    def session_override():
        with maker() as s:
            yield s

    app.dependency_overrides[get_session] = session_override
    app.dependency_overrides[get_storage] = lambda: storage
    with TestClient(app) as c:
        c.storage = storage
        yield c
    app.dependency_overrides.clear()


def upload(client, data=PNG, name="r.png"):
    return client.post("/receipts", files={"file": (name, io.BytesIO(data), "image/png")})


def test_sniff_image():
    assert sniff_image(PNG[:16]) == ("image/png", "png")
    assert sniff_image(JPEG[:16]) == ("image/jpeg", "jpg")
    assert sniff_image(b"RIFF\x00\x00\x00\x00WEBPVP8 ") == ("image/webp", "webp")
    assert sniff_image(b"%PDF-1.7") is None


def test_upload_list_get_image(client):
    r = upload(client)
    assert r.status_code == 201
    rid = r.json()["id"]
    assert r.json()["status"] == "uploaded"
    assert len(client.storage.objects) == 1

    assert [x["id"] for x in client.get("/receipts").json()] == [rid]
    assert client.get(f"/receipts/{rid}").json()["raw_text"] is None
    img = client.get(f"/receipts/{rid}/image")
    assert img.status_code == 200 and img.content == PNG and img.headers["content-type"] == "image/png"


def test_rejects_non_image_even_with_image_content_type(client):
    r = upload(client, data=b"<?php echo 1; ?>" + b"\x00" * 64, name="evil.png")
    assert r.status_code == 415
    assert client.storage.objects == {}


def test_rejects_oversized_upload(client, monkeypatch):
    from app import config

    monkeypatch.setattr(config.get_settings(), "max_upload_mb", 1)
    r = upload(client, data=PNG + b"\x00" * (1024 * 1024))
    assert r.status_code == 413


def test_patch_marks_corrected_and_feeds_stats(client):
    rid = upload(client).json()["id"]
    r = client.patch(
        f"/receipts/{rid}", json={"merchant": "Cafe ABC", "total_vnd": 125000, "purchased_at": "2026-11-20T09:30:00+07:00"}
    )
    assert r.status_code == 200
    assert r.json()["status"] == "corrected" and r.json()["total_vnd"] == 125000
    assert client.get("/stats/monthly").json() == [{"month": "2026-11", "count": 1, "total_vnd": 125000}]


def test_patch_validation(client):
    rid = upload(client).json()["id"]
    assert client.patch(f"/receipts/{rid}", json={"total_vnd": -5}).status_code == 422
    assert client.patch(f"/receipts/{rid}", json={"status": "parsed"}).status_code == 422  # not editable
    assert client.patch(f"/receipts/{rid}", json={}).status_code == 422


def test_unknown_receipt_is_404(client):
    assert client.get("/receipts/00000000-0000-0000-0000-000000000000").status_code == 404


def test_metrics_and_replica_header(client):
    r = client.get("/receipts")
    assert r.headers["X-Served-By"]
    body = client.get("/metrics").text
    assert 'http_requests_total{method="GET",route="/receipts",status="200"}' in body
    assert "http_request_duration_seconds_bucket" in body


def test_month_filter_validated(client):
    assert client.get("/receipts", params={"month": "2026-13"}).status_code == 422
