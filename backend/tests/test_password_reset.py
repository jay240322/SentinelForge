import uuid

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.auth.jwt import create_access_token
from app.db.session import AsyncSessionLocal
from app.main import app
from app.models.audit_log import AuditLog


@pytest.mark.asyncio
async def test_password_reset_success_and_login():
    email = f"reset-{uuid.uuid4()}@sentinelforge.com"
    old_password = "OldPassword123!"
    new_password = "NewPassword456!"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        register_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": old_password,
            },
        )

        assert register_response.status_code == 201

        forgot_response = await client.post(
            "/api/v1/auth/forgot-password",
            json={"email": email},
        )

        assert forgot_response.status_code == 200
        reset_token = forgot_response.json()["reset_token"]

        reset_response = await client.post(
            "/api/v1/auth/reset-password",
            json={
                "token": reset_token,
                "new_password": new_password,
            },
        )

        assert reset_response.status_code == 200
        assert reset_response.json()["message"] == (
            "Password reset successful"
        )

        old_login_response = await client.post(
            "/api/v1/auth/login",
            json={
                "email": email,
                "password": old_password,
            },
        )

        assert old_login_response.status_code == 401

        new_login_response = await client.post(
            "/api/v1/auth/login",
            json={
                "email": email,
                "password": new_password,
            },
        )

        assert new_login_response.status_code == 200
        assert "access_token" in new_login_response.json()


@pytest.mark.asyncio
async def test_password_reset_with_invalid_token():
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.post(
            "/api/v1/auth/reset-password",
            json={
                "token": "invalid-token",
                "new_password": "NewPassword456!",
            },
        )

    assert response.status_code == 401
    assert response.json()["detail"] == (
        "Invalid or expired password reset token"
    )


@pytest.mark.asyncio
async def test_access_token_cannot_reset_password():
    access_token = create_access_token(1)

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.post(
            "/api/v1/auth/reset-password",
            json={
                "token": access_token,
                "new_password": "NewPassword456!",
            },
        )

    assert response.status_code == 401
    assert response.json()["detail"] == (
        "Invalid or expired password reset token"
    )


@pytest.mark.asyncio
async def test_forgot_password_unknown_email():
    email = f"unknown-{uuid.uuid4()}@sentinelforge.com"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.post(
            "/api/v1/auth/forgot-password",
            json={"email": email},
        )

    assert response.status_code == 200
    assert response.json()["message"] == (
        "If the email exists, a password reset link will be sent"
    )


@pytest.mark.asyncio
async def test_password_reset_creates_audit_log():
    email = f"reset-audit-{uuid.uuid4()}@sentinelforge.com"
    old_password = "OldPassword123!"
    new_password = "NewPassword456!"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        # Register the user
        register_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": old_password,
            },
        )

        assert register_response.status_code == 201

        user_id = register_response.json()["id"]

        # Get password reset token
        forgot_response = await client.post(
            "/api/v1/auth/forgot-password",
            json={"email": email},
        )

        assert forgot_response.status_code == 200

        reset_token = forgot_response.json()["reset_token"]

        # Reset password
        reset_response = await client.post(
            "/api/v1/auth/reset-password",
            json={
                "token": reset_token,
                "new_password": new_password,
            },
        )

    assert reset_response.status_code == 200

    # Verify the audit event was created
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(AuditLog).where(
                AuditLog.user_id == user_id,
                AuditLog.event_type == "PASSWORD_RESET",
            )
        )

        audit_log = result.scalar_one_or_none()

    assert audit_log is not None
    assert audit_log.description == (
        "User password reset successfully"
    )