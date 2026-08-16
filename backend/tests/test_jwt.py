import jwt

from app.auth.jwt import (
    create_access_token,
    create_refresh_token,
)
from app.core.config import settings


def test_access_token():
    token = create_access_token(1)

    payload = jwt.decode(
        token,
        settings.JWT_SECRET_KEY,
        algorithms=[settings.JWT_ALGORITHM],
    )

    assert payload["sub"] == "1"
    assert payload["type"] == "access"


def test_refresh_token():
    token = create_refresh_token(1)

    payload = jwt.decode(
        token,
        settings.JWT_SECRET_KEY,
        algorithms=[settings.JWT_ALGORITHM],
    )

    assert payload["sub"] == "1"
    assert payload["type"] == "refresh"