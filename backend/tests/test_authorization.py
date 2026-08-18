import uuid

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app


@pytest.mark.asyncio
async def test_normal_user_cannot_access_admin_endpoint():
    email = f"user-{uuid.uuid4()}@sentinelforge.com"
    password = "StrongPassword123!"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        register_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": password,
            },
        )

        assert register_response.status_code == 201

        login_response = await client.post(
            "/api/v1/auth/login",
            json={
                "email": email,
                "password": password,
            },
        )

        assert login_response.status_code == 200

        access_token = login_response.json()["access_token"]

        response = await client.get(
            "/api/v1/auth/admin-test",
            headers={
                "Authorization": f"Bearer {access_token}",
            },
        )

    assert response.status_code == 403
    assert response.json()["detail"] == (
        "You do not have permission to perform this action"
    )


@pytest.mark.asyncio
async def test_admin_can_access_admin_endpoint():
    # We will make a normal user first, then promote it to admin
    email = f"admin-{uuid.uuid4()}@sentinelforge.com"
    password = "StrongPassword123!"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        register_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": password,
            },
        )

        assert register_response.status_code == 201
