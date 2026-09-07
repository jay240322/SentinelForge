from app.models.audit_log import AuditLog
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

async def create_audit_log(
    db: AsyncSession,
    event_type: str,
    description: str,
    user_id: int | None = None,
    ip_address: str | None = None,
) -> AuditLog:
    audit_log = AuditLog(
        user_id=user_id,
        event_type=event_type,
        description=description,
        ip_address=ip_address,
    )

    db.add(audit_log)
    await db.commit()
    await db.refresh(audit_log)

    return audit_log

async def has_user_logged_in_from_ip(
    db: AsyncSession,
    user_id: int,
    ip_address: str | None,
) -> bool:

    if ip_address is None:
        return False

    result = await db.execute(
        select(AuditLog).where(
            AuditLog.user_id == user_id,
            AuditLog.event_type == "USER_LOGIN",
            AuditLog.ip_address == ip_address,
        )
    )

    existing_login = result.scalar_one_or_none()

    return existing_login is not None