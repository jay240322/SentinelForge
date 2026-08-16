import pytest_asyncio

from app.db.session import engine


@pytest_asyncio.fixture(autouse=True)
async def reset_database_connections():
    yield
    await engine.dispose()