from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.dependencies import get_current_user
from app.auth.jwt import (
    create_access_token,
    create_email_verification_token,
    create_password_reset_token,
    create_refresh_token,
    decode_email_verification_token,
    decode_password_reset_token,
    decode_refresh_token,
    get_token_remaining_seconds,
)
from app.auth.security import hash_password
from app.auth.service import (
    InvalidCredentialsError,
    UserAlreadyExistsError,
    authenticate_user,
    register_user,
)
from app.db.dependencies import get_db
from app.models import User
from app.schemas.auth import (
    EmailVerificationRequest,
    ForgotPasswordRequest,
    LoginRequest,
    LoginResponse,
    RefreshTokenRequest,
    ResetPasswordRequest,
    TokenResponse,
    RegisterRequest,
    UserResponse,
)
from app.services.redis import (
    is_refresh_token_revoked,
    revoke_refresh_token,
)


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

    if await is_refresh_token_revoked(request.refresh_token):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Refresh token has been revoked",
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


@router.post(
    "/verify-email",
    response_model=UserResponse,
)
async def verify_email(
    request: EmailVerificationRequest,
    db: AsyncSession = Depends(get_db),
):
    user_id = decode_email_verification_token(request.token)

    if user_id is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired verification token",
        )

    result = await db.execute(
        select(User).where(User.id == user_id)
    )

    user = result.scalar_one_or_none()

    if user is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found",
        )

    user.is_verified = True

    await db.commit()
    await db.refresh(user)

    return user


@router.post(
    "/forgot-password",
)
async def forgot_password(
    request: ForgotPasswordRequest,
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(User).where(User.email == request.email)
    )

    user = result.scalar_one_or_none()

    if user is not None:
        reset_token = create_password_reset_token(user.id)

        # Email sending will be added later.
        # For now, return the token so we can test the flow.
        return {
            "message": "Password reset token generated",
            "reset_token": reset_token,
        }

    return {
        "message": (
            "If the email exists, a password reset link will be sent"
        ),
    }


@router.post(
    "/reset-password",
)
async def reset_password(
    request: ResetPasswordRequest,
    db: AsyncSession = Depends(get_db),
):
    user_id = decode_password_reset_token(request.token)

    if user_id is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired password reset token",
        )

    result = await db.execute(
        select(User).where(User.id == user_id)
    )

    user = result.scalar_one_or_none()

    if user is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found",
        )

    user.password_hash = hash_password(
        request.new_password
    )

    await db.commit()

    return {
        "message": "Password reset successful",
    }