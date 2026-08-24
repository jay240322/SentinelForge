"""add brute force protection fields

Revision ID: daadd39a25fe
Revises: ec3ad0794a3b
Create Date: 2026-08-24 12:41:01.342648

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "daadd39a25fe"
down_revision: Union[str, Sequence[str], None] = "ec3ad0794a3b"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "users",
        sa.Column(
            "failed_login_attempts",
            sa.Integer(),
            nullable=False,
            server_default="0",
        ),
    )

    op.add_column(
        "users",
        sa.Column(
            "locked_until",
            sa.DateTime(),
            nullable=True,
        ),
    )

    op.alter_column(
        "users",
        "failed_login_attempts",
        server_default=None,
    )


def downgrade() -> None:
    op.drop_column("users", "locked_until")
    op.drop_column("users", "failed_login_attempts")