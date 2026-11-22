"""Pull total (VND), date and merchant out of OCR text from a Vietnamese receipt.

PaddleOCR often drops vowels that carry two diacritics (ề, ễ, ệ, ụ...): "Tiền" comes back
as "Tin". Keywords are therefore compared on a consonant skeleton: diacritics removed,
then vowels removed, so "tiền", "tien" and "tin" all become "tn".
"""
import re
import unicodedata
from datetime import datetime, timedelta, timezone

VN_TZ = timezone(timedelta(hours=7))

# Higher number wins: "amount to pay" beats "subtotal".
KEYWORDS = {
    "khach can tra": 3, "khach phai tra": 3, "tong thanh toan": 3, "can thanh toan": 3,
    "thanh toan": 2, "tong cong": 2, "tong tien": 1, "total": 1,
}
# Lines that look like totals but are not what the customer paid.
EXCLUDE = ("tien khach dua", "tien thua", "tra lai", "giam gia", "chiet khau", "tong tien hang")

AMOUNT = re.compile(r"\d{1,3}(?:[.,]\d{3})+|\d{4,}")
DATE = re.compile(r"(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})(?:\D{1,3}(\d{1,2}):(\d{2}))?")
VOWELS = re.compile(r"[aeiouy]")


def fold(text: str) -> str:
    """Lowercase and strip Vietnamese diacritics so 'TỔNG CỘNG' matches 'tong cong'."""
    text = text.lower().replace("đ", "d")
    return "".join(c for c in unicodedata.normalize("NFD", text) if unicodedata.category(c) != "Mn")


def skeleton(text: str) -> str:
    """Consonants only, single-spaced: robust to vowels the OCR dropped."""
    return " ".join(VOWELS.sub("", w) for w in re.findall(r"[a-z]+", fold(text)))


KEY_SK = {skeleton(k): p for k, p in KEYWORDS.items()}
EXCL_SK = tuple(skeleton(e) for e in EXCLUDE)


def amounts(line: str) -> list[int]:
    return [int(re.sub(r"[.,]", "", m)) for m in AMOUNT.findall(line)]


def guess_total(text: str) -> int | None:
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    best = None  # (priority, line index, amount)
    for i, line in enumerate(lines):
        sk = f" {skeleton(line)} "
        if any(f" {x} " in sk for x in EXCL_SK):
            continue
        prio = max((p for k, p in KEY_SK.items() if f" {k} " in sk), default=0)
        if not prio:
            continue
        # Amount usually sits on the same line, sometimes on the next one.
        found = amounts(line) or (amounts(lines[i + 1]) if i + 1 < len(lines) else [])
        if found:
            cand = (prio, i, max(found))
            if best is None or cand[:2] > best[:2]:
                best = cand
    return best[2] if best else None


def guess_date(text: str) -> datetime | None:
    """First plausible dd/mm/yyyy (or dd-mm-yy) with optional HH:MM, in Vietnam time."""
    for m in DATE.finditer(text):
        d, mo, y, hh, mm = m.groups()
        year = int(y) + (2000 if len(y) == 2 else 0)
        try:
            return datetime(year, int(mo), int(d), int(hh or 0), int(mm or 0), tzinfo=VN_TZ)
        except ValueError:
            continue  # e.g. 31/02 or a phone number that looked like a date
    return None


def guess_merchant(text: str) -> str | None:
    """First of the top 3 lines that is mostly letters (shop names lead the receipt)."""
    for line in [l.strip() for l in text.splitlines() if l.strip()][:3]:
        letters = sum(c.isalpha() for c in line)
        if letters >= 3 and letters > 2 * sum(c.isdigit() for c in line):
            return line[:200]
    return None
