"""Week 0 spike: OCR real receipts with Cloud Vision and guess the total.

Usage: python ocr_worker/spike_ocr.py samples
Needs `gcloud auth application-default login` and the Vision API enabled.
Writes raw text and a summary to spike_output/ (git-ignored: may contain personal data).
"""
import json
import sys
from pathlib import Path

from google.cloud import vision

from receipt_parser import guess_total

EXTS = {".jpg", ".jpeg", ".png", ".webp"}


def main(folder: str) -> None:
    images = sorted(p for p in Path(folder).iterdir() if p.suffix.lower() in EXTS)
    if not images:
        sys.exit(f"No images in {folder}")
    out = Path("spike_output")
    out.mkdir(exist_ok=True)
    client = vision.ImageAnnotatorClient()
    summary = []
    for img in images:
        resp = client.document_text_detection(
            image=vision.Image(content=img.read_bytes()),
            image_context={"language_hints": ["vi"]},
        )
        if resp.error.message:
            print(f"{img.name}: ERROR {resp.error.message}")
            summary.append({"file": img.name, "error": resp.error.message})
            continue
        text = resp.full_text_annotation.text
        (out / f"{img.stem}.txt").write_text(text, encoding="utf-8")
        total = guess_total(text)
        print(f"{img.name}: total guess = {total}")
        summary.append({"file": img.name, "total_guess": total, "chars": len(text)})
    (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nRaw text and summary saved to {out.resolve()}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "samples")
