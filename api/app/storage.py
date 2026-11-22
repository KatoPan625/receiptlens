"""Thin S3 wrapper so routes don't depend on boto3 directly (tests swap in a fake)."""
from collections.abc import Iterator
from functools import lru_cache
from typing import Protocol

import boto3
from botocore.config import Config

from .config import get_settings


class Storage(Protocol):
    def put(self, key: str, data: bytes, content_type: str) -> None: ...
    def stream(self, key: str) -> Iterator[bytes]: ...
    def delete(self, key: str) -> None: ...


class S3Storage:
    def __init__(self, endpoint: str, key: str, secret: str, bucket: str):
        self.bucket = bucket
        self.client = boto3.client(
            "s3",
            endpoint_url=endpoint,
            aws_access_key_id=key,
            aws_secret_access_key=secret,
            region_name="us-east-1",
            config=Config(s3={"addressing_style": "path"}, signature_version="s3v4",
                          retries={"max_attempts": 3}, connect_timeout=3, read_timeout=10),
        )

    def put(self, key: str, data: bytes, content_type: str) -> None:
        self.client.put_object(Bucket=self.bucket, Key=key, Body=data, ContentType=content_type)

    def stream(self, key: str) -> Iterator[bytes]:
        body = self.client.get_object(Bucket=self.bucket, Key=key)["Body"]
        yield from body.iter_chunks(64 * 1024)

    def delete(self, key: str) -> None:
        self.client.delete_object(Bucket=self.bucket, Key=key)


@lru_cache
def get_storage() -> Storage:
    s = get_settings()
    return S3Storage(s.s3_endpoint, s.s3_key, s.s3_secret, s.s3_bucket)
