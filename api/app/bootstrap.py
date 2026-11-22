"""One-shot setup run by the `migrate` service after `alembic upgrade head`.

Uses the DB owner and S3 admin credentials so the long-running API never needs them:
- creates/updates the least-privilege role `api_rw` (no DELETE, no DDL)
- creates the receipts bucket
"""
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
        c.execute(sql.SQL(f"{verb} ROLE {{}} LOGIN PASSWORD {{}}").format(
            sql.Identifier(API_ROLE), sql.Literal(s.api_db_password)))
        c.execute(sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(sql.Identifier(s.db_name), sql.Identifier(API_ROLE)))
        c.execute(sql.SQL("GRANT USAGE ON SCHEMA public TO {}").format(sql.Identifier(API_ROLE)))
        c.execute(sql.SQL("GRANT SELECT, INSERT, UPDATE ON receipts TO {}").format(sql.Identifier(API_ROLE)))
    print(f"DB role {API_ROLE}: {verb.lower()}d, granted SELECT/INSERT/UPDATE on receipts")


def ensure_bucket(s) -> None:
    s3 = boto3.client("s3", endpoint_url=s.s3_endpoint, aws_access_key_id=s.s3_key,
                      aws_secret_access_key=s.s3_secret, region_name="us-east-1",
                      config=Config(s3={"addressing_style": "path"}))
    try:
        s3.head_bucket(Bucket=s.s3_bucket)
        print(f"Bucket {s.s3_bucket}: exists")
    except ClientError:
        s3.create_bucket(Bucket=s.s3_bucket)
        print(f"Bucket {s.s3_bucket}: created")


if __name__ == "__main__":
    settings = get_settings()
    ensure_db_role(settings)
    ensure_bucket(settings)
