import asyncio

from sqlalchemy import select

from app.db.session import AsyncSessionLocal
from app.models import User
from app.auth.security import hash_password


ADMIN_EMAIL = "adminsentinelforge@2403.com"
ADMIN_PASSWORD = "Admin@12345"


async def create_admin():
    async with AsyncSessionLocal() as db:

        result = await db.execute(
            select(User).where(
                User.email == ADMIN_EMAIL
            )
        )

        existing_user = result.scalar_one_or_none()

        if existing_user:
            print("Admin user already exists.")
            print(f"Email: {ADMIN_EMAIL}")
            return

        admin = User(
            email=ADMIN_EMAIL,
            password_hash=hash_password(
                ADMIN_PASSWORD
            ),
            is_active=True,
            is_verified=True,
            role="admin",
        )

        db.add(admin)
        await db.commit()
        await db.refresh(admin)

        print("Admin user created successfully!")
        print(f"Email: {ADMIN_EMAIL}")
        print(f"Password: {ADMIN_PASSWORD}")
        print(f"User ID: {admin.id}")


if __name__ == "__main__":
    asyncio.run(create_admin())