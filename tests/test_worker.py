import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ocr_worker"))
from worker import to_result  # noqa: E402


def test_to_result_builds_message_from_ocr_lines():
    lines = ["CÀ PHÊ SÁNG", "Ngày: 20/11/2026 09:30", "TÔNG CÔNG: 125.000đ"]
    r = to_result("abc", lines, [0.9, 1.0, 0.95])
    assert r == {
        "id": "abc",
        "status": "parsed",
        "total_vnd": 125000,
        "merchant": "CÀ PHÊ SÁNG",
        "purchased_at": "2026-11-20T09:30:00+07:00",
        "raw_text": "\n".join(lines),
        "confidence": 0.95,
    }


def test_to_result_with_nothing_found():
    r = to_result("abc", [], [])
    assert r["status"] == "parsed" and r["total_vnd"] is None and r["confidence"] is None
