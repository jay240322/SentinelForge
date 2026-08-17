import uuid
from datetime import datetime, timedelta, timezone

import jwt
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.auth.jwt import create_access_token
from app.core.config import settings
from app.db.session import AsyncSessionLocal
from app.main import app
from app.models import User


@pytest.mark.asyncio
async def test_me_with_valid_access_token():
    email = f"me-{uuid.uuid4()}@sentinelforge.com"
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

        user = register_response.json()

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
            "/api/v1/auth/me",
            headers={
                "Authorization": f"Bearer {access_token}",
            },
        )

    assert response.status_code == 200

    data = response.json()

    assert data["id"] == user["id"]
    assert data["email"] == email
    assert data["is_active"] is True
    assert data["is_verified"] is False
    assert data["role"] == "user"

    assert "password" not in data
    assert "password_hash" not in data


@pytest.mark.asyncio
async def test_me_without_token():
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.get(
            "/api/v1/auth/me"
        )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_me_with_invalid_token():
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.get(
            "/api/v1/auth/me",
            headers={
                "Authorization": "Bearer invalid-token",
            },
        )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_me_with_expired_access_token():
    email = f"expired-{uuid.uuid4()}@sentinelforge.com"

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        register_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "password": "StrongPassword123!",
            },
        )

        assert register_response.status_code == 201

        user_id = register_response.json()["id"]

        now = datetime.now(timezone.utc)

        expired_token = jwt.encode(
            {
                "sub": str(user_id),
                "type": "access",
                "iat": now - timedelta(hours=2),
                "exp": now - timedelta(hours=1),
            },
            settings.JWT_SECRET_KEY,
            algorithm=settings.JWT_ALGORITHM,
        )

        response = await client.get(
            "/api/v1/auth/me",
            headers={
                "Authorization": f"Bearer {expired_token}",
            },
        )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_me_with_refresh_token():
    email = f"refresh-{uuid.uuid4()}@sentinelforge.com"
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

        refresh_token = login_response.json()["refresh_token"]

        response = await client.get(
            "/api/v1/auth/me",
            headers={
                "Authorization": f"Bearer {refresh_token}",
            },
        )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_me_with_nonexistent_user_token():
    nonexistent_user_id = 999999999

    token = create_access_token(nonexistent_user_id)

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.get(
            "/api/v1/auth/me",
            headers={
                "Authorization": f"Bearer {token}",
            },
        )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_me_with_inactive_user():
    email = f"inactive-{uuid.uuid4()}@sentinelforge.com"
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

        user_id = register_response.json()["id"]

        login_response = await client.post(
            "/api/v1/auth/login",
            json={
                "email": email,
                "password": password,
            },
        )

        assert login_response.status_code == 200

        access_token = login_response.json()["access_token"]

    async with AsyncSessionLocal() as session:
        result = await session.execute(
            select(User).where(User.id == user_id)
        )

        user = result.scalar_one()

        user.is_active = False

        await session.commit()

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.get(
            "/api/v1/auth/me",
            headers={
                "Authorization": f"Bearer {access_token}",
            },
        )

    assert response.status_code == 403
    assert response.json()["detail"] == "User account is inactive"