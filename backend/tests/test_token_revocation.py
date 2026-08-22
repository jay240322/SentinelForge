import uuid

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app


@pytest.mark.asyncio
async def test_logout_revokes_refresh_token():
    email = f"logout-{uuid.uuid4()}@sentinelforge.com"
    password = "StrongPassword123!"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        # Register
        register_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": password,
            },
        )

        assert register_response.status_code == 201

        # Login
        login_response = await client.post(
            "/api/v1/auth/login",
            json={
                "email": email,
                "password": password,
            },
        )

        assert login_response.status_code == 200

        refresh_token = login_response.json()["refresh_token"]

        # Logout
        logout_response = await client.post(
            "/api/v1/auth/logout",
            json={
                "refresh_token": refresh_token,
            },
        )

        assert logout_response.status_code == 204

        # Try using the revoked token
        refresh_response = await client.post(
            "/api/v1/auth/refresh",
            json={
                "refresh_token": refresh_token,
            },
        )

    assert refresh_response.status_code == 401
    assert refresh_response.json()["detail"] == "Refresh token has been revoked"


@pytest.mark.asyncio
async def test_logout_with_invalid_token():
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.post(
            "/api/v1/auth/logout",
            json={
                "refresh_token": "invalid-token",
            },
        )

    assert response.status_code == 401
    assert response.json()["detail"] == "Invalid or expired refresh token"