"""Guess the total amount (VND) from OCR text of a Vietnamese receipt.

Week 0 version: keyword + amount heuristics, reused and extended by the OCR worker in week 4.
"""
import re
import unicodedata

# Higher number wins: "amount to pay" beats "subtotal".
KEYWORDS = {
    "khach can tra": 3, "khach phai tra": 3, "tong thanh toan": 3, "can thanh toan": 3,
    "thanh toan": 2, "tong cong": 2, "tong tien": 1, "total": 1,
}
# Lines that look like totals but are not what the customer paid.
EXCLUDE = ("tien khach dua", "tien thua", "tra lai", "giam gia", "chiet khau")

AMOUNT = re.compile(r"\d{1,3}(?:[.,]\d{3})+|\d{4,}")


def fold(text: str) -> str:
    """Lowercase and strip Vietnamese diacritics so 'TỔNG CỘNG' matches 'tong cong'."""
    text = text.lower().replace("đ", "d")
    return "".join(c for c in unicodedata.normalize("NFD", text) if unicodedata.category(c) != "Mn")


def amounts(line: str) -> list[int]:
    return [int(re.sub(r"[.,]", "", m)) for m in AMOUNT.findall(line)]


def guess_total(text: str) -> int | None:
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    best = None  # (priority, line index, amount)
    for i, line in enumerate(lines):
        f = fold(line)
        if any(x in f for x in EXCLUDE):
            continue
        prio = max((p for k, p in KEYWORDS.items() if k in f), default=0)
        if not prio:
            continue
        # Amount usually sits on the same line, sometimes on the next one.
        found = amounts(line) or (amounts(lines[i + 1]) if i + 1 < len(lines) else [])
        if found:
            cand = (prio, i, max(found))
            if best is None or cand[:2] > best[:2]:
                best = cand
    return best[2] if best else None
