"""receipts table

Revision ID: 0001
"""

import sqlalchemy as sa
from alembic import op

revision = "0001"
down_revision = None


def upgrade() -> None:
    op.create_table(
        "receipts",
        sa.Column("id", sa.Uuid, primary_key=True),
        sa.Column("object_key", sa.String(200), nullable=False, unique=True),
        sa.Column("content_type", sa.String(50), nullable=False),
        sa.Column("status", sa.String(20), nullable=False, server_default="uploaded"),
        sa.Column("merchant", sa.String(200)),
        sa.Column("total_vnd", sa.BigInteger),
        sa.Column("purchased_at", sa.DateTime(timezone=True)),
        sa.Column("raw_text", sa.Text),
        sa.Column("confidence", sa.Float),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.CheckConstraint("status IN ('uploaded', 'parsed', 'failed', 'corrected')", name="ck_receipts_status"),
        sa.CheckConstraint("total_vnd IS NULL OR total_vnd >= 0", name="ck_receipts_total_nonneg"),
    )
    op.create_index("ix_receipts_status", "receipts", ["status"])
    op.create_index("ix_receipts_created_at", "receipts", ["created_at"])


def downgrade() -> None:
    op.drop_table("receipts")
