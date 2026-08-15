import pytest

from app.services.redis import redis_client


@pytest.mark.asyncio
async def test_redis_connection():
    result = await redis_client.ping()

    assert result is True