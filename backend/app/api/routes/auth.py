from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.dependencies import get_current_user
from app.auth.jwt import (
    create_access_token,
    create_refresh_token,
    decode_refresh_token,
    get_token_remaining_seconds,
)
from app.auth.service import (
    InvalidCredentialsError,
    UserAlreadyExistsError,
    authenticate_user,
    register_user,
)
from app.db.dependencies import get_db
from app.models import User
from app.schemas.auth import (
    LoginRequest,
    LoginResponse,
    RefreshTokenRequest,
    TokenResponse,
    RegisterRequest,
    UserResponse,
)

from app.auth.jwt import get_token_remaining_seconds
from app.services.redis import revoke_refresh_token

router = APIRouter(
    prefix="/api/v1/auth",
    tags=["Authentication"],
)


@router.post(
    "/register",
    response_model=UserResponse,
    status_code=status.HTTP_201_CREATED,
)
async def register(
    request: RegisterRequest,
    db: AsyncSession = Depends(get_db),
):
    try:
        return await register_user(
            db=db,
            email=request.email,
            password=request.password,
        )
    except UserAlreadyExistsError:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="A user with this email already exists",
        )


@router.post(
    "/login",
    response_model=LoginResponse,
)
async def login(
    request: LoginRequest,
    db: AsyncSession = Depends(get_db),
):
    try:
        user = await authenticate_user(
            db=db,
            email=request.email,
            password=request.password,
        )
    except InvalidCredentialsError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )

    return LoginResponse(
        access_token=create_access_token(user.id),
        refresh_token=create_refresh_token(user.id),
        token_type="bearer",
    )


@router.get(
    "/me",
    response_model=UserResponse,
)
async def get_me(
    current_user: User = Depends(get_current_user),
):
    return current_user


@router.post(
    "/refresh",
    response_model=TokenResponse,
)
async def refresh_access_token(
    request: RefreshTokenRequest,
):
    user_id = decode_refresh_token(request.refresh_token)

    if user_id is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired refresh token",
        )

    access_token = create_access_token(user_id)

    return TokenResponse(
        access_token=access_token,
        token_type="bearer",
    )

@router.post(
    "/logout",
    status_code=status.HTTP_204_NO_CONTENT,
)
async def logout(
    request: RefreshTokenRequest,
):
    remaining_seconds = get_token_remaining_seconds(
        request.refresh_token
    )

    if remaining_seconds is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired refresh token",
        )

    await revoke_refresh_token(
        token=request.refresh_token,
        expires_in=remaining_seconds,
    )