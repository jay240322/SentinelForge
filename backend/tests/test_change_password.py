import uuid

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app


@pytest.mark.asyncio
async def test_change_password_success():
    email = f"change-{uuid.uuid4()}@sentinelforge.com"
    old_password = "OldPassword123!"
    new_password = "NewPassword456!"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        # Register
        response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": old_password,
            },
        )

        assert response.status_code == 201

        # Login and get access token
        login_response = await client.post(
            "/api/v1/auth/login",
            json={
                "email": email,
                "password": old_password,
            },
        )

        assert login_response.status_code == 200

        access_token = login_response.json()["access_token"]

        # Change password
        change_response = await client.post(
            "/api/v1/auth/change-password",
            json={
                "current_password": old_password,
                "new_password": new_password,
            },
            headers={
                "Authorization": f"Bearer {access_token}",
            },
        )

        assert change_response.status_code == 200
        assert change_response.json()["message"] == (
            "Password changed successfully"
        )

        # Old password should fail
        old_login = await client.post(
            "/api/v1/auth/login",
            json={
                "email": email,
                "password": old_password,
            },
        )

        assert old_login.status_code == 401

        # New password should work
        new_login = await client.post(
            "/api/v1/auth/login",
            json={
                "email": email,
                "password": new_password,
            },
        )

        assert new_login.status_code == 200


@pytest.mark.asyncio
async def test_change_password_wrong_current_password():
    email = f"wrong-password-{uuid.uuid4()}@sentinelforge.com"
    password = "CorrectPassword123!"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": password,
            },
        )

        login_response = await client.post(
            "/api/v1/auth/login",
            json={
                "email": email,
                "password": password,
            },
        )

        access_token = login_response.json()["access_token"]

        response = await client.post(
            "/api/v1/auth/change-password",
            json={
                "current_password": "WrongPassword123!",
                "new_password": "NewPassword456!",
            },
            headers={
                "Authorization": f"Bearer {access_token}",
            },
        )

        assert response.status_code == 401
        assert response.json()["detail"] == (
            "Current password is incorrect"
        )


@pytest.mark.asyncio
async def test_change_password_requires_authentication():
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.post(
            "/api/v1/auth/change-password",
            json={
                "current_password": "OldPassword123!",
                "new_password": "NewPassword456!",
            },
        )

    assert response.status_code == 401