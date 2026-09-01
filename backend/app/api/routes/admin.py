from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from datetime import datetime

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
    event_type: str | None = Query(default=None),
    user_id: int | None = Query(default=None),
    start_date: datetime | None = Query(default=None),
    end_date: datetime | None = Query(default=None),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(require_role("admin")),
):
    query = select(AuditLog)

    if event_type is not None:
        query = query.where(
            AuditLog.event_type == event_type
        )

    if user_id is not None:
        query = query.where(
            AuditLog.user_id == user_id
        )

    if start_date is not None:
        query = query.where(
            AuditLog.created_at >= start_date
        )

    if end_date is not None:
        query = query.where(
            AudiLog.created_at <= end_date
        )

    query = query.order_by(
        AuditLog.created_at.desc()
    )
    
    result = await db.execute(query)

    audit_logs = result.scalars().all()

    return audit_logs