import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ocr_worker"))
from receipt_parser import guess_total  # noqa: E402


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
