from datetime import datetime, timedelta, timezone

import jwt

from app.core.config import settings

def create_access_token(user_id: int) -> str:
    now = datetime.now(timezone.utc)

    payload = {
        "sub": str(user_id),
        "type": "access",
        "iat": now,
        "exp": now
        + timedelta(
            minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES
        ),
    }

    return jwt.encode(
        payload,
        settings.JWT_SECRET_KEY,
        algorithm=settings.JWT_ALGORITHM,
    )

def create_refresh_token(user_id: int) -> str:
    now = datetime.now(timezone.utc)

    payload = {
        "sub": str(user_id),
        "type": "refresh",
        "iat": now,
        "exp": now
        + timedelta(
            days=settings.REFRESH_TOKEN_EXPIRE_DAYS
        ),
    }

    return jwt.encode(
        payload,
        settings.JWT_SECRET_KEY,
        algorithm=settings.JWT_ALGORITHM,
    )

def decode_refresh_token(token: str) -> int | None:
    try:
        payload = jwt.decode(
            token,
            settings.JWT_SECRET_KEY,
            algorithms=[settings.JWT_ALGORITHM],
        )

        if payload.get("type") != "refresh":
            return None

        user_id = payload.get("sub")

        if user_id is None:
            return None

        return int(user_id)

    except (jwt.PyJWTError, ValueError):
        return None

def get_token_remaining_seconds(token: str) -> int | None:
    try:
        payload = jwt.decode(
            token,
            settings.JWT_SECRET_KEY,
            algorithms=[settings.JWT_ALGORITHM],
        )

        exp = payload.get("exp")

        if exp is None:
            return None

        now = datetime.now(timezone.utc).timestamp()
        remaining_seconds = int(exp - now)

        if remaining_seconds <= 0:
            return None

        return remaining_seconds

    except jwt.PyJWTError:
        return None

def create_email_verification_token(user_id: int) -> str:
    now = datetime.now(timezone.utc)

    payload = {
        "sub": str(user_id),
        "type": "email_verification",
        "iat": now,
        "exp": now + timedelta(hours=24),
    }

    return jwt.encode(
        payload,
        settings.JWT_SECRET_KEY,
        algorithm=settings.JWT_ALGORITHM,
    )


def decode_email_verification_token(
    token: str,
) -> int | None:
    try:
        payload = jwt.decode(
            token,
            settings.JWT_SECRET_KEY,
            algorithms=[settings.JWT_ALGORITHM],
        )

        if payload.get("type") != "email_verification":
            return None

        user_id = payload.get("sub")

        if user_id is None:
            return None

        return int(user_id)

    except (jwt.PyJWTError, ValueError, TypeError):
        return None

def create_password_reset_token(user_id: int) -> str:
    now = datetime.now(timezone.utc)

    payload = {
        "sub": str(user_id),
        "type": "password_reset",
        "iat": now,
        "exp": now + timedelta(hours=1),
    }

    return jwt.encode(
        payload,
        settings.JWT_SECRET_KEY,
        algorithm=settings.JWT_ALGORITHM,
    )


def decode_password_reset_token(token: str) -> int | None:
    try:
        payload = jwt.decode(
            token,
            settings.JWT_SECRET_KEY,
            algorithms=[settings.JWT_ALGORITHM],
        )

        if payload.get("type") != "password_reset":
            return None

        user_id = payload.get("sub")

        if user_id is None:
            return None

        return int(user_id)

    except (jwt.PyJWTError, ValueError, TypeError):
        return None