from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.permissions import require_role
from app.db.dependencies import get_db
from app.models import User
from app.schemas.auth import UserResponse
from app.models.audit_log import AuditLog
from app.schemas.audit import AuditLogResponse

router = APIRouter(
    prefix="/api/v1/admin",
    tags=["Admin"],
)


@router.get(
    "/users",
    response_model=list[UserResponse],
)
async def get_all_users(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(require_role("admin")),
):
    result = await db.execute(select(User))
    users = result.scalars().all()

    return users

@router.get(
    "/audit-logs",
    response_model=list[AuditLogResponse],
)
async def get_audit_logs(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(require_role("admin")),
):
    result = await db.execute(
        select(AuditLog).order_by(
            AuditLog.created_at.desc()
        )
    )

    audit_logs = result.scalars().all()

    return audit_logs