from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.security import hash_password, verify_password
from app.models import User


class UserAlreadyExistsError(Exception):
    pass

class InvalidCredentialsError(Exception):
    pass

async def register_user(
    db: AsyncSession,
    email: str,
    password: str,
) -> User:
    result = await db.execute(
        select(User).where(User.email == email)
    )

    existing_user = result.scalar_one_or_none()

    if existing_user:
        raise UserAlreadyExistsError

    user = User(
        email=email,
        password_hash=hash_password(password),
        is_active=True,
        is_verified=False,
        role="user",
    )

    db.add(user)
    await db.commit()
    await db.refresh(user)

    return user

async def authenticate_user(
    db: AsyncSession,
    email: str,
    password: str,
) -> User:
    result = await db.execute(
        select(User).where(User.email == email)
    )

    user = result.scalar_one_or_none()

    if not user:
        raise InvalidCredentialsError

    if not verify_password(password, user.password_hash):
        raise InvalidCredentialsError

    if not user.is_active:
        raise InvalidCredentialsError

    return user