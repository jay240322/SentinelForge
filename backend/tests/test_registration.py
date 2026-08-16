import uuid

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.auth.security import verify_password
from app.db.session import AsyncSessionLocal
from app.main import app
from app.models import User


@pytest.mark.asyncio
async def test_register_user():
    email = f"registration-{uuid.uuid4()}@sentinelforge.com"

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

    data = response.json()

    assert data["email"] == email
    assert data["is_active"] is True
    assert data["is_verified"] is False
    assert data["role"] == "user"

    assert "password" not in data
    assert "password_hash" not in data


@pytest.mark.asyncio
async def test_duplicate_email_registration():
    email = f"duplicate-{uuid.uuid4()}@sentinelforge.com"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        first_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": "StrongPassword123!",
            },
        )

        assert first_response.status_code == 201

        second_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": "AnotherPassword123!",
            },
        )

    assert second_response.status_code == 409


@pytest.mark.asyncio
async def test_invalid_email():
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": "not-an-email",
                "password": "StrongPassword123!",
            },
        )

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_short_password():
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": "short-password@sentinelforge.com",
                "password": "123",
            },
        )

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_password_is_hashed_in_database():
    email = f"hash-test-{uuid.uuid4()}@sentinelforge.com"
    password = "StrongPassword123!"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": password,
            },
        )

    assert response.status_code == 201

    async with AsyncSessionLocal() as session:
        result = await session.execute(
            select(User).where(User.email == email)
        )

        user = result.scalar_one()

    assert user.password_hash != password
    assert user.password_hash.startswith("$argon2")
    assert verify_password(password, user.password_hash)