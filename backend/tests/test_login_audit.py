import uuid

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.main import app
from app.db.session import AsyncSessionLocal
from app.models.audit_log import AuditLog


@pytest.mark.asyncio
async def test_successful_login_creates_audit_log():
    email = f"login-audit-{uuid.uuid4()}@sentinelforge.com"
    password = "StrongPassword123!"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:

        # Register a new user
        register_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": password,
            },
        )

        assert register_response.status_code == 201

        # Login with that user
        login_response = await client.post(
            "/api/v1/auth/login",
            json={
                "email": email,
                "password": password,
            },
        )

    assert login_response.status_code == 200

    # Check USER_LOGIN audit log
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(AuditLog).where(
                AuditLog.user_id.is_not(None),
                AuditLog.event_type == "USER_LOGIN",
            )
        )

        audit_log = result.scalars().first()

        assert audit_log is not None
        assert audit_log.description == "User logged in successfully"