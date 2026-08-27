import uuid

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.auth.jwt import (
    create_access_token,
    create_email_verification_token,
)
from app.db.session import AsyncSessionLocal
from app.main import app
from app.models.audit_log import AuditLog


@pytest.mark.asyncio
async def test_email_verification_success():
    email = f"verify-{uuid.uuid4()}@sentinelforge.com"
    password = "StrongPassword123!"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        # Register user
        register_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": password,
            },
        )

        assert register_response.status_code == 201

        user = register_response.json()

        # User should initially be unverified
        assert user["is_verified"] is False

        # Create verification token
        verification_token = create_email_verification_token(
            user["id"]
        )

        # Verify email
        response = await client.post(
            "/api/v1/auth/verify-email",
            json={
                "token": verification_token,
            },
        )

    assert response.status_code == 200

    data = response.json()

    assert data["id"] == user["id"]
    assert data["email"] == email
    assert data["is_verified"] is True


@pytest.mark.asyncio
async def test_email_verification_with_invalid_token():
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.post(
            "/api/v1/auth/verify-email",
            json={
                "token": "invalid-token",
            },
        )

    assert response.status_code == 401

    assert response.json()["detail"] == (
        "Invalid or expired verification token"
    )


@pytest.mark.asyncio
async def test_access_token_cannot_verify_email():
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        access_token = create_access_token(1)

        response = await client.post(
            "/api/v1/auth/verify-email",
            json={
                "token": access_token,
            },
        )

    assert response.status_code == 401

    assert response.json()["detail"] == (
        "Invalid or expired verification token"
    )


@pytest.mark.asyncio
async def test_email_verification_creates_audit_log():
    email = f"verify-audit-{uuid.uuid4()}@sentinelforge.com"
    password = "StrongPassword123!"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        # Register user
        register_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": password,
            },
        )

        assert register_response.status_code == 201

        user_id = register_response.json()["id"]

        # Create verification token
        verification_token = create_email_verification_token(
            user_id
        )

        # Verify email
        response = await client.post(
            "/api/v1/auth/verify-email",
            json={
                "token": verification_token,
            },
        )

    assert response.status_code == 200

    # Check EMAIL_VERIFIED audit log
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(AuditLog).where(
                AuditLog.user_id == user_id,
                AuditLog.event_type == "EMAIL_VERIFIED",
            )
        )

        audit_log = result.scalar_one_or_none()

        assert audit_log is not None
        assert audit_log.description == (
            "User email verified successfully"
        )