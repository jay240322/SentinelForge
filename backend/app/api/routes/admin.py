from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession
from datetime import datetime

from app.auth.permissions import require_role
from app.db.dependencies import get_db
from app.schemas.auth import UserResponse
from app.models.audit_log import AuditLog
from app.models import User, SecurityAlert
from app.schemas.security_alert import SecurityAlertResponse
from app.services.security_alert import (
    get_security_alerts,
    resolve_security_alert,
)
from app.schemas.audit import (
    AuditLogResponse,
    AuditLogListResponse,
)

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
    response_model=AuditLogListResponse,
)
async def get_audit_logs(
    event_type: str | None = Query(default=None),
    user_id: int | None = Query(default=None),
    start_date: datetime | None = Query(default=None),
    end_date: datetime | None = Query(default=None),
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=20, ge=1, le=100),
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
            AuditLog.created_at <= end_date
        )

    # Total number of matching audit logs
    count_query = select(func.count()).select_from(
        query.subquery()
    )

    total_result = await db.execute(count_query)
    total = total_result.scalar_one()

    # Apply pagination
    offset = (page - 1) * limit

    query = (
        query
        .order_by(AuditLog.created_at.desc())
        .offset(offset)
        .limit(limit)
    )

    result = await db.execute(query)
    audit_logs = result.scalars().all()

    pages = (total + limit - 1) // limit

    return {
        "items": audit_logs,
        "total": total,
        "page": page,
        "limit": limit,
        "pages": pages,
    }

@router.get(
    "/security-alerts",
    response_model=list[SecurityAlertResponse],
)
async def get_all_security_alerts(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(require_role("admin")),
):
    alerts = await get_security_alerts(db)

    return alerts


@router.patch(
    "/security-alerts/{alert_id}/resolve",
    response_model=SecurityAlertResponse,
)
async def resolve_alert(
    alert_id: int,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(require_role("admin")),
):
    alert = await resolve_security_alert(
        db=db,
        alert_id=alert_id,
    )

    if alert is None:
        raise HTTPException(
            status_code=404,
            detail="Security alert not found",
        )

    return alert