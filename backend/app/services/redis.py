import redis.asyncio as redis

from app.core.config import settings


redis_client = redis.from_url(
    settings.REDIS_URL,
    decode_responses=True,
)


async def check_redis() -> bool:
    try:
        return await redis_client.ping()
    except redis.RedisError:
        return False

async def revoke_refresh_token(
    token: str,
    expires_in: int,
) -> None:
    await redis_client.set(
        f"revoked_refresh_token:{token}",
        "revoked",
        ex=expires_in,
    )

async def is_refresh_token_revoked(token: str) -> bool:
    result = await redis_client.exists(
        f"revoked_refresh_token:{token}"
    )

    return result == 1