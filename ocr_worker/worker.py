"""OCR worker: consume `ocr.requests`, read the image from S3, OCR it, publish `receipt.parsed`.

Runs in the internal `data` network (no Internet); models are baked into the image at build time.
The `ocr` RabbitMQ user may only read `ocr.requests` and publish to `receipts`; the S3 key is read-only.
"""
import json
import logging
import os
import time
from pathlib import Path

import boto3
import cv2
import numpy as np
import pika
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError
from pika.exceptions import AMQPError

from receipt_parser import guess_date, guess_merchant, guess_total

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logging.getLogger("pika").setLevel(logging.WARNING)  # pika logs every connection step at INFO
log = logging.getLogger("ocr-worker")
HEARTBEAT = Path("/tmp/heartbeat")


def make_ocr():
    from paddleocr import PaddleOCR  # slow import; keep out of module import for tests
    # enable_mkldnn=False: PaddlePaddle 3.3 + oneDNN fails on these models on CPU
    # ("ConvertPirAttribute2RuntimeAttribute not support").
    return PaddleOCR(lang="vi", use_doc_orientation_classify=False, use_doc_unwarping=False,
                     use_textline_orientation=False, enable_mkldnn=False)


def to_result(receipt_id: str, lines: list[str], scores: list[float]) -> dict:
    text = "\n".join(lines)
    date = guess_date(text)
    return {"id": receipt_id, "status": "parsed", "total_vnd": guess_total(text), "merchant": guess_merchant(text),
            "purchased_at": date.isoformat() if date else None, "raw_text": text,
            "confidence": round(sum(scores) / len(scores), 3) if scores else None}


def main() -> None:
    ocr = make_ocr()
    s3 = boto3.client("s3", endpoint_url=os.environ.get("S3_ENDPOINT", "http://storage:8333"),
                      aws_access_key_id=os.environ["S3_KEY"], aws_secret_access_key=os.environ["S3_SECRET"],
                      region_name="us-east-1", config=Config(s3={"addressing_style": "path"}))
    bucket = os.environ.get("S3_BUCKET", "receipts-raw")
    params = pika.ConnectionParameters(
        host=os.environ.get("RABBIT_HOST", "rabbitmq"), heartbeat=60, blocked_connection_timeout=30,
        credentials=pika.PlainCredentials(os.environ.get("RABBIT_USER", "ocr"), os.environ["RABBIT_PASSWORD"]))
    log.info("OCR model loaded, waiting for work")
    while True:
        try:
            conn = pika.BlockingConnection(params)
            chan = conn.channel()
            chan.confirm_delivery()
            chan.basic_qos(prefetch_count=1)  # OCR is CPU-heavy: one at a time per worker
            for method, _props, body in chan.consume("ocr.requests", inactivity_timeout=20):
                HEARTBEAT.touch()
                if method is None:
                    continue
                try:
                    msg = json.loads(body)
                    rid, key = msg["id"], msg["object_key"]
                except (ValueError, KeyError, TypeError):
                    log.error("malformed request, dead-lettering")
                    chan.basic_reject(method.delivery_tag, requeue=False)
                    continue
                try:
                    data = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
                except (BotoCoreError, ClientError) as e:
                    # Transient (storage down) or missing object: requeue; after 5 tries the queue dead-letters it.
                    log.warning("%s: cannot read %s: %s", rid, key, e)
                    chan.basic_nack(method.delivery_tag, requeue=True)
                    time.sleep(2)
                    continue
                started = time.perf_counter()
                image = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
                if image is None:
                    result = {"id": rid, "status": "failed", "error": "image could not be decoded"}
                else:
                    try:
                        res = ocr.predict(image)[0]
                        result = to_result(rid, list(res["rec_texts"]), [float(s) for s in res["rec_scores"]])
                    except Exception as e:  # a bad image must not kill the worker
                        log.exception("%s: OCR failed", rid)
                        result = {"id": rid, "status": "failed", "error": f"OCR error: {type(e).__name__}"}
                chan.basic_publish("receipts", "receipt.parsed", json.dumps(result).encode(), mandatory=True,
                                   properties=pika.BasicProperties(delivery_mode=pika.DeliveryMode.Persistent,
                                                                   content_type="application/json"))
                chan.basic_ack(method.delivery_tag)  # only after the result is safely published
                log.info("%s: %s total=%s in %.1fs", rid, result["status"], result.get("total_vnd"),
                         time.perf_counter() - started)
        except AMQPError as e:
            log.warning("RabbitMQ connection lost (%s), retrying in 5 s", e)
            time.sleep(5)


if __name__ == "__main__":
    main()
