"""count OCR requests per receipt (re-publish sweep gives up after 3)

Revision ID: 0002
"""

import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"


def upgrade() -> None:
    op.add_column("receipts", sa.Column("ocr_attempts", sa.Integer, nullable=False, server_default="0"))


def downgrade() -> None:
    op.drop_column("receipts", "ocr_attempts")
