import uuid

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.main import app
from app.db.session import AsyncSessionLocal
from app.models import User


async def create_user_and_get_token(
    email_prefix: str = "user",
):
    email = f"{email_prefix}-{uuid.uuid4()}@sentinelforge.com"
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

    return email, password, access_token


async def create_admin_and_get_token(
    email_prefix: str = "admin",
):
    email = f"{email_prefix}-{uuid.uuid4()}@sentinelforge.com"
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

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(User).where(User.email == email)
        )

        user = result.scalar_one()
        user.role = "admin"

        await db.commit()

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        login_response = await client.post(
            "/api/v1/auth/login",
            json={
                "email": email,
                "password": password,
            },
        )

        assert login_response.status_code == 200

        access_token = login_response.json()["access_token"]

    return email, access_token


@pytest.mark.asyncio
async def test_normal_user_cannot_get_all_users():
    _, _, access_token = await create_user_and_get_token()

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.get(
            "/api/v1/admin/users",
            headers={
                "Authorization": f"Bearer {access_token}",
            },
        )

    assert response.status_code == 403


@pytest.mark.asyncio
async def test_admin_can_get_all_users():
    email, access_token = await create_admin_and_get_token()

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.get(
            "/api/v1/admin/users",
            headers={
                "Authorization": f"Bearer {access_token}",
            },
        )

    assert response.status_code == 200

    data = response.json()

    assert isinstance(data, list)
    assert len(data) > 0
    assert any(user["email"] == email for user in data)


@pytest.mark.asyncio
async def test_admin_can_get_audit_logs():
    _, access_token = await create_admin_and_get_token(
        "audit-admin"
    )

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.get(
            "/api/v1/admin/audit-logs",
            headers={
                "Authorization": f"Bearer {access_token}",
            },
        )

    assert response.status_code == 200

    data = response.json()

    assert isinstance(data, dict)
    assert "items" in data
    assert "total" in data
    assert "page" in data
    assert "limit" in data
    assert "pages" in data

    audit_logs = data["items"]

    assert isinstance(audit_logs, list)
    assert len(audit_logs) > 0


@pytest.mark.asyncio
async def test_normal_user_cannot_get_audit_logs():
    _, _, access_token = await create_user_and_get_token(
        "audit-user"
    )

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.get(
            "/api/v1/admin/audit-logs",
            headers={
                "Authorization": f"Bearer {access_token}",
            },
        )

    assert response.status_code == 403


@pytest.mark.asyncio
async def test_admin_can_filter_audit_logs_by_event_type():
    _, access_token = await create_admin_and_get_token(
        "filter-event"
    )

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.get(
            "/api/v1/admin/audit-logs",
            params={
                "event_type": "USER_LOGIN",
            },
            headers={
                "Authorization": f"Bearer {access_token}",
            },
        )

    assert response.status_code == 200

    data = response.json()

    assert isinstance(data, dict)
    assert "items" in data

    audit_logs = data["items"]

    assert isinstance(audit_logs, list)

    for log in audit_logs:
        assert log["event_type"] == "USER_LOGIN"


@pytest.mark.asyncio
async def test_admin_can_filter_audit_logs_by_user_id():
    email, access_token = await create_admin_and_get_token(
        "filter-user"
    )

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(User).where(User.email == email)
        )

        user = result.scalar_one()
        user_id = user.id

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.get(
            "/api/v1/admin/audit-logs",
            params={
                "user_id": user_id,
            },
            headers={
                "Authorization": f"Bearer {access_token}",
            },
        )

    assert response.status_code == 200

    data = response.json()

    assert isinstance(data, dict)
    assert "items" in data

    audit_logs = data["items"]

    assert isinstance(audit_logs, list)

    for log in audit_logs:
        assert log["user_id"] == user_id


@pytest.mark.asyncio
async def test_normal_user_cannot_get_security_alerts():
    _, _, access_token = await create_user_and_get_token(
        "alert-user"
    )

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.get(
            "/api/v1/admin/security-alerts",
            headers={
                "Authorization": f"Bearer {access_token}",
            },
        )

    assert response.status_code == 403


@pytest.mark.asyncio
async def test_admin_can_get_security_alerts():
    _, access_token = await create_admin_and_get_token(
        "alert-admin"
    )

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        response = await client.get(
            "/api/v1/admin/security-alerts",
            headers={
                "Authorization": f"Bearer {access_token}",
            },
        )

    assert response.status_code == 200

    data = response.json()

    assert isinstance(data, list)