import uuid

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app


@pytest.mark.asyncio
async def test_account_locks_after_five_failed_attempts():
    email = f"brute-{uuid.uuid4()}@sentinelforge.com"
    correct_password = "CorrectPassword123!"
    wrong_password = "WrongPassword123!"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:

        # Register user
        register_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": correct_password,
            },
        )

        assert register_response.status_code == 201

        # First 4 failed attempts
        for _ in range(4):
            response = await client.post(
                "/api/v1/auth/login",
                json={
                    "email": email,
                    "password": wrong_password,
                },
            )

            assert response.status_code == 401
            assert response.json()["detail"] == "Invalid email or password"

        # 5th failed attempt should lock the account
        response = await client.post(
            "/api/v1/auth/login",
            json={
                "email": email,
                "password": wrong_password,
            },
        )

        assert response.status_code == 423
        assert response.json()["detail"] == (
            "Too many failed login attempts. Account locked for 15 minutes."
        )


@pytest.mark.asyncio
async def test_locked_account_cannot_login_with_correct_password():
    email = f"locked-{uuid.uuid4()}@sentinelforge.com"
    correct_password = "CorrectPassword123!"
    wrong_password = "WrongPassword123!"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:

        # Register user
        register_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": correct_password,
            },
        )

        assert register_response.status_code == 201

        # Lock the account
        for _ in range(5):
            await client.post(
                "/api/v1/auth/login",
                json={
                    "email": email,
                    "password": wrong_password,
                },
            )

        # Even the correct password should not work while locked
        response = await client.post(
            "/api/v1/auth/login",
            json={
                "email": email,
                "password": correct_password,
            },
        )

        assert response.status_code == 423
        assert response.json()["detail"] == (
            "Account is temporarily locked. Please try again later."
        )


@pytest.mark.asyncio
async def test_successful_login_resets_failed_attempts():
    email = f"reset-attempts-{uuid.uuid4()}@sentinelforge.com"
    correct_password = "CorrectPassword123!"
    wrong_password = "WrongPassword123!"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:

        # Register user
        register_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": correct_password,
            },
        )

        assert register_response.status_code == 201

        # Make 3 failed attempts
        for _ in range(3):
            response = await client.post(
                "/api/v1/auth/login",
                json={
                    "email": email,
                    "password": wrong_password,
                },
            )

            assert response.status_code == 401

        # Successful login should reset the counter
        success_response = await client.post(
            "/api/v1/auth/login",
            json={
                "email": email,
                "password": correct_password,
            },
        )

        assert success_response.status_code == 200

        # Four more failures should still return 401,
        # proving the previous counter was reset
        for _ in range(4):
            response = await client.post(
                "/api/v1/auth/login",
                json={
                    "email": email,
                    "password": wrong_password,
                },
            )

            assert response.status_code == 401