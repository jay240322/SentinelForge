from app.models.audit_log import AuditLog
from sqlalchemy.ext.asyncio import AsyncSession

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