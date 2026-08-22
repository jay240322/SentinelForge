from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.routes.admin import router as admin_router
from app.api.routes.auth import router as auth_router
from app.db.dependencies import get_db
from app.db.health import check_database
from app.services.redis import check_redis, close_redis


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    await close_redis()


app = FastAPI(
    title="SentinelForge API",
    description="Cloud-native security platform",
    version="0.1.0",
    lifespan=lifespan,
)


app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


app.include_router(auth_router)
app.include_router(admin_router)


@app.get("/health")
async def health(db: AsyncSession = Depends(get_db)):
    database_healthy = await check_database(db)
    redis_healthy = await check_redis()

    all_healthy = database_healthy and redis_healthy

    return {
        "status": "healthy" if all_healthy else "degraded",
        "service": "SentinelForge API",
        "version": "0.1.0",
        "dependencies": {
            "database": (
                "healthy" if database_healthy else "unhealthy"
            ),
            "redis": (
                "healthy" if redis_healthy else "unhealthy"
            ),
        },
    }