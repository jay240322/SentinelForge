import uuid

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.main import app
from app.db.session import AsyncSessionLocal
from app.models.audit_log import AuditLog


@pytest.mark.asyncio
async def test_user_registration_creates_audit_log():
    email = f"audit-{uuid.uuid4()}@sentinelforge.com"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": "StrongPassword123!",
            },
        )

    assert response.status_code == 201

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(AuditLog).where(
                AuditLog.event_type == "USER_REGISTERED"
            )
        )

        audit_log = result.scalars().first()

        assert audit_log is not None
        assert audit_log.description == "New user registered"
        assert audit_log.user_id is not None