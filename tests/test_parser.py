import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ocr_worker"))
from receipt_parser import guess_date, guess_merchant, guess_total, skeleton  # noqa: E402

VN = timezone(timedelta(hours=7))


def test_total_on_same_line():
    assert guess_total("CAFE ABC\nTỔNG CỘNG: 125.000đ") == 125000


def test_amount_on_next_line():
    assert guess_total("Tổng tiền\n89,000") == 89000


def test_pay_amount_beats_subtotal():
    text = "Tổng tiền hàng 200.000\nGiảm giá 20.000\nKhách cần trả 180.000"
    assert guess_total(text) == 180000


def test_ignores_cash_given_and_change():
    text = "Thanh toán 75.000\nTiền khách đưa 100.000\nTiền thừa 25.000"
    assert guess_total(text) == 75000


def test_payment_method_line_without_amount_uses_next_line():
    assert guess_total("Thanh toán\n45.500") == 45500


def test_no_total_found():
    assert guess_total("Cảm ơn quý khách") is None


def test_skeleton_survives_dropped_vowels():
    # Real PaddleOCR (PP-OCRv6) output: "Tiền" -> "Tin", "Tổng" -> "Tồng"
    assert skeleton("Tiền khách đưa") == skeleton("Tin khách đưa") == "tn khch d"
    assert skeleton("TỔNG CỘNG") == skeleton("TÔNG CÔNG") == "tng cng"


def test_real_ocr_output_of_synthetic_receipt():
    # Text exactly as PaddleOCR PP-OCRv6 returned it for tests/fixtures/make_receipt.py
    text = "\n".join([
        "CÀ PHÊ SÁNG", "12 Nguyn Hu, Qun 1, TP.HCM", "Ngày: 20/11/2026 09:30",
        "Cà phê sũa đá x2", "70.000", "Bánh mì tht x1", "30.000", "Tồng tin hàng", "100.000",
        "Phí dch v", "25.000", "TÔNG CÔNG: 125.000đ", "Tin khách đưa", "500.000",
        "Tièn thùa", "375.000", "Cm on quý khách!",
    ])
    assert guess_total(text) == 125000
    assert guess_date(text) == datetime(2026, 11, 20, 9, 30, tzinfo=VN)
    assert guess_merchant(text) == "CÀ PHÊ SÁNG"


def test_cash_given_with_dropped_vowel_is_still_excluded():
    # "Tiền khách đưa" read as "Tin khách đưa" must not be taken as the total
    assert guess_total("Thanh toán 80.000\nTin khách đưa 200.000") == 80000


def test_date_formats_and_invalid_dates():
    assert guess_date("HD 05-01-26") == datetime(2026, 1, 5, tzinfo=VN)
    assert guess_date("31/02/2026 then 01/03/2026") == datetime(2026, 3, 1, tzinfo=VN)
    assert guess_date("no date here") is None


def test_merchant_skips_numeric_lines():
    assert guess_merchant("0901234567\nWinMart+ Q1\n...") == "WinMart+ Q1"
    assert guess_merchant("123\n456") is None
