"""One-shot setup run by the `migrate` service after `alembic upgrade head`.

Uses the DB owner, S3 admin and RabbitMQ admin credentials so the long-running services never need them:
- creates/updates the least-privilege role `api_rw` (no DELETE, no DDL)
- creates the receipts bucket
- declares the RabbitMQ topology and two users that may only use their own queue
"""

import base64
import json
import os
import urllib.request
from urllib.parse import quote

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError
from psycopg import connect, sql

from .config import get_settings

API_ROLE = "api_rw"


def ensure_db_role(s) -> None:
    if not s.api_db_password:
        raise SystemExit("API_DB_PASSWORD is empty; run scripts/init-env.ps1")
    with connect(host=s.db_host, dbname=s.db_name, user=s.db_user, password=s.db_password, autocommit=True) as c:
        exists = c.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (API_ROLE,)).fetchone()
        verb = "ALTER" if exists else "CREATE"
        c.execute(
            sql.SQL(f"{verb} ROLE {{}} LOGIN PASSWORD {{}}").format(sql.Identifier(API_ROLE), sql.Literal(s.api_db_password))
        )
        c.execute(sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(sql.Identifier(s.db_name), sql.Identifier(API_ROLE)))
        c.execute(sql.SQL("GRANT USAGE ON SCHEMA public TO {}").format(sql.Identifier(API_ROLE)))
        c.execute(sql.SQL("GRANT SELECT, INSERT, UPDATE ON receipts TO {}").format(sql.Identifier(API_ROLE)))
    print(f"DB role {API_ROLE}: {'updated' if exists else 'created'}, granted SELECT/INSERT/UPDATE on receipts")


def ensure_bucket(s) -> None:
    s3 = boto3.client(
        "s3",
        endpoint_url=s.s3_endpoint,
        aws_access_key_id=s.s3_key,
        aws_secret_access_key=s.s3_secret,
        region_name="us-east-1",
        config=Config(s3={"addressing_style": "path"}),
    )
    try:
        s3.head_bucket(Bucket=s.s3_bucket)
        print(f"Bucket {s.s3_bucket}: exists")
    except ClientError:
        s3.create_bucket(Bucket=s.s3_bucket)
        print(f"Bucket {s.s3_bucket}: created")


# Topology. Quorum queues dead-letter a message after 5 failed deliveries (x-delivery-limit).
EXCHANGE, DLX = "receipts", "receipts.dlx"
QUEUES = {  # queue -> routing key on the main exchange
    "ocr.requests": "receipt.uploaded",  # consumed by ocr-worker
    "api.results": "receipt.parsed",  # consumed by the api replicas
}
# user -> (env var holding its password, queue it may read). Both may only publish to `receipts`.
RABBIT_USERS = {"api": ("RABBITMQ_API_PASSWORD", "api.results"), "ocr": ("RABBITMQ_OCR_PASSWORD", "ocr.requests")}


def _mgmt(method: str, path: str, body: dict | None = None) -> None:
    url = f"http://{os.environ.get('RABBITMQ_HOST', 'rabbitmq')}:15672/api/{path}"
    auth = base64.b64encode(f"{os.environ['RABBITMQ_ADMIN_USER']}:{os.environ['RABBITMQ_ADMIN_PASSWORD']}".encode()).decode()
    req = urllib.request.Request(
        url,
        method=method,
        data=json.dumps(body or {}).encode(),
        headers={"Authorization": f"Basic {auth}", "Content-Type": "application/json"},
    )
    urllib.request.urlopen(req, timeout=10).close()  # noqa: S310 - fixed http:// URL to the internal broker


def ensure_rabbit() -> None:
    v = quote("/", safe="")
    _mgmt("PUT", f"exchanges/{v}/{EXCHANGE}", {"type": "direct", "durable": True})
    _mgmt("PUT", f"exchanges/{v}/{DLX}", {"type": "direct", "durable": True})
    for queue, key in QUEUES.items():
        _mgmt(
            "PUT",
            f"queues/{v}/{queue}",
            {
                "durable": True,
                "arguments": {
                    "x-queue-type": "quorum",
                    "x-delivery-limit": 5,
                    "x-dead-letter-exchange": DLX,
                    "x-dead-letter-routing-key": queue,
                },
            },
        )
        _mgmt("POST", f"bindings/{v}/e/{EXCHANGE}/q/{queue}", {"routing_key": key})
        _mgmt("PUT", f"queues/{v}/{queue}.dead", {"durable": True, "arguments": {"x-queue-type": "quorum"}})
        _mgmt("POST", f"bindings/{v}/e/{DLX}/q/{queue}.dead", {"routing_key": queue})
    for user, (env, queue) in RABBIT_USERS.items():
        password = os.environ.get(env)
        if not password:
            raise SystemExit(f"{env} is empty; run scripts/init-env.ps1")
        _mgmt("PUT", f"users/{user}", {"password": password, "tags": ""})
        # configure: nothing (topology is created here); write: the exchange; read: its own queue
        _mgmt(
            "PUT",
            f"permissions/{v}/{user}",
            {"configure": "^$", "write": f"^{EXCHANGE}$", "read": f"^{queue.replace('.', '[.]')}$"},
        )
    print(f"RabbitMQ: exchanges {EXCHANGE}/{DLX}, quorum queues {', '.join(QUEUES)} (+ .dead), users {', '.join(RABBIT_USERS)}")


if __name__ == "__main__":
    settings = get_settings()
    ensure_db_role(settings)
    ensure_bucket(settings)
    ensure_rabbit()
