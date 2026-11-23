"""Render a synthetic Vietnamese receipt (PNG) for pipeline tests.

It is NOT a substitute for real receipts: clean digital text is far easier than a crumpled
thermal print. Accuracy claims must come from samples/ (real photos), not from this.

Usage: python tests/fixtures/make_receipt.py out.png [total_vnd]
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FONTS = [  # first one that exists; all cover Vietnamese
    "C:/Windows/Fonts/arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]


def render(path: Path, total: int = 125000) -> None:
    font_file = next((f for f in FONTS if Path(f).exists()), None)
    if font_file is None:
        raise SystemExit("No font with Vietnamese glyphs found")
    big, small = ImageFont.truetype(font_file, 34), ImageFont.truetype(font_file, 26)
    sub = total - 25000
    lines = [
        (big, "CÀ PHÊ SÁNG"),
        (small, "12 Nguyễn Huệ, Quận 1, TP.HCM"),
        (small, "Ngày: 20/11/2026  09:30"),
        (small, "--------------------------------"),
        (small, f"Cà phê sữa đá   x2      {sub - 30000:,}".replace(",", ".")),
        (small, "Bánh mì thịt    x1       30.000"),
        (small, f"Tổng tiền hàng          {sub:,}".replace(",", ".")),
        (small, "Phí dịch vụ              25.000"),
        (big, f"TỔNG CỘNG: {total:,}đ".replace(",", ".")),
        (small, "Tiền khách đưa          500.000"),
        (small, f"Tiền thừa               {500000 - total:,}".replace(",", ".")),
        (small, "Cảm ơn quý khách!"),
    ]
    img = Image.new("RGB", (620, 60 + 52 * len(lines)), "white")
    d = ImageDraw.Draw(img)
    y = 30
    for font, text in lines:
        d.text((30, y), text, fill="black", font=font)
        y += 52
    img.save(path)


if __name__ == "__main__":
    render(Path(sys.argv[1]), int(sys.argv[2]) if len(sys.argv) > 2 else 125000)
