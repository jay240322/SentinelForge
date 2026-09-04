from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import SecurityAlert


async def create_security_alert(
    db: AsyncSession,
    user_id: int | None,
    alert_type: str,
    severity: str,
    description: str,
    ip_address: str | None = None,
) -> SecurityAlert:

    alert = SecurityAlert(
        user_id=user_id,
        alert_type=alert_type,
        severity=severity,
        description=description,
        status="open",
        ip_address=ip_address,
    )

    db.add(alert)

    await db.commit()
    await db.refresh(alert)

    return alert


async def get_security_alerts(
    db: AsyncSession,
) -> list[SecurityAlert]:

    result = await db.execute(
        select(SecurityAlert)
        .order_by(SecurityAlert.created_at.desc())
    )

    return list(result.scalars().all())


async def resolve_security_alert(
    db: AsyncSession,
    alert_id: int,
) -> SecurityAlert | None:

    result = await db.execute(
        select(SecurityAlert).where(
            SecurityAlert.id == alert_id
        )
    )

    alert = result.scalar_one_or_none()

    if alert is None:
        return None

    alert.status = "resolved"
    alert.resolved_at = datetime.now()

    await db.commit()
    await db.refresh(alert)

    return alert