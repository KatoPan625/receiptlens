"""Week 0 spike: OCR real receipts locally with PaddleOCR and guess the total.

Usage: python ocr_worker/spike_ocr.py samples
First run downloads the OCR models. Runs on CPU; no cloud account needed.
Writes raw text and a summary to spike_output/ (git-ignored: may contain personal data).
"""
import json
import sys
from pathlib import Path

from paddleocr import PaddleOCR

from receipt_parser import guess_total

EXTS = {".jpg", ".jpeg", ".png", ".webp"}


def main(folder: str) -> None:
    images = sorted(p for p in Path(folder).iterdir() if p.suffix.lower() in EXTS)
    if not images:
        sys.exit(f"No images in {folder}")
    out = Path("spike_output")
    out.mkdir(exist_ok=True)
    # Vietnamese uses the Latin PP-OCRv5 recognition model.
    ocr = PaddleOCR(
        lang="vi",
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_textline_orientation=False,
        enable_mkldnn=False,  # PaddlePaddle 3.3 + oneDNN crashes on these models on CPU
    )
    summary = []
    for img in images:
        try:
            res = ocr.predict(str(img))[0]
        except Exception as e:  # keep going so one bad photo doesn't stop the batch
            print(f"{img.name}: ERROR {e}")
            summary.append({"file": img.name, "error": str(e)})
            continue
        lines, scores = res["rec_texts"], res["rec_scores"]
        text = "\n".join(lines)
        (out / f"{img.stem}.txt").write_text(text, encoding="utf-8")
        total = guess_total(text)
        avg = round(sum(scores) / len(scores), 3) if scores else None
        print(f"{img.name}: total guess = {total}  (lines={len(lines)}, avg score={avg})")
        summary.append({"file": img.name, "total_guess": total, "lines": len(lines), "avg_score": avg})
    (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nRaw text and summary saved to {out.resolve()}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "samples")
