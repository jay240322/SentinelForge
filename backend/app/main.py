from fastapi import FastAPI

app = FastAPI(
    title="SentinelForge API",
    description="Cloud-native security platform",
    version="0.1.0",
)


@app.get("/health")
async def health():
    return {
        "status": "healthy",
        "service": "SentinelForge API",
        "version": "0.1.0",
    }