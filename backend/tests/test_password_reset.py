import uuid

import pytest
from httpx import ASGITransport, AsyncClient

from app.auth.jwt import create_access_token
from app.main import app


@pytest.mark.asyncio
async def test_password_reset_success_and_login():
    email = f"reset-{uuid.uuid4()}@sentinelforge.com"
    old_password = "OldPassword123!"
    new_password = "NewPassword456!"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        # Register user
        register_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": old_password,
            },
        )

        assert register_response.status_code == 201

        # Request password reset token
        forgot_response = await client.post(
            "/api/v1/auth/forgot-password",
            json={
                "email": email,
            },
        )

        assert forgot_response.status_code == 200

        forgot_data = forgot_response.json()

        assert "reset_token" in forgot_data

        reset_token = forgot_data["reset_token"]

        # Reset password
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

        # Old password should no longer work
        old_login_response = await client.post(
            "/api/v1/auth/login",
            json={
                "email": email,
                "password": old_password,
            },
        )

        assert old_login_response.status_code == 401

        # New password should work
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
            json={
                "email": email,
            },
        )

    assert response.status_code == 200
    assert response.json()["message"] == (
        "If the email exists, a password reset link will be sent"
    )