import pytest
from sqlalchemy import select

from app.db.session import AsyncSessionLocal
from app.models import User


@pytest.mark.asyncio
async def test_user_crud():
    async with AsyncSessionLocal() as session:
        user = User(
            email="database-test@sentinelforge.local",
            password_hash="test-hash",
        )

        session.add(user)
        await session.commit()
        await session.refresh(user)

        assert user.id is not None
        assert user.email == "database-test@sentinelforge.local"

        result = await session.execute(
            select(User).where(
                User.email == "database-test@sentinelforge.local"
            )
        )

        saved_user = result.scalar_one()

        assert saved_user.id == user.id
        assert saved_user.email == user.email

        await session.delete(saved_user)
        await session.commit()