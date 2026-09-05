from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException, Request, status
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
from app.auth.security import (
    hash_password,
    verify_password,
)
from app.auth.service import (
    InvalidCredentialsError,
    UserAlreadyExistsError,
    authenticate_user,
    register_user,
)
from app.core.limiter import limiter
from app.db.dependencies import get_db
from app.models import User
from app.schemas.auth import (
    ChangePasswordRequest,
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

from app.services.audit import create_audit_log
from app.services.security_alert import create_security_alert

router = APIRouter(
    prefix="/api/v1/auth",
    tags=["Authentication"],
)


MAX_FAILED_ATTEMPTS = 5
LOCK_DURATION_MINUTES = 15


# REGISTER

@router.post(
    "/register",
    response_model=UserResponse,
    status_code=status.HTTP_201_CREATED,
)
async def register(
    request: RegisterRequest,
    http_request: Request,
    db: AsyncSession = Depends(get_db),
):
    try:
        user = await register_user(
            db=db,
            email=request.email,
            password=request.password,
        )

        ip_address = (
            http_request.client.host
            if http_request.client
            else None
        )

        await create_audit_log(
            db=db,
            user_id=user.id,
            event_type="USER_REGISTERED",
            description="New user registered",
            ip_address=ip_address,
        )

        return user

    except UserAlreadyExistsError:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="A user with this email already exists",
        )


# LOGIN WITH BRUTE-FORCE PROTECTION + RATE LIMITING

@router.post(
    "/login",
    response_model=LoginResponse,
)
@limiter.limit("100/minute")
async def login(
    request: Request,
    login_request: LoginRequest,
    db: AsyncSession = Depends(get_db),
):
    # Find the user first
    result = await db.execute(
        select(User).where(
            User.email == login_request.email
        )
    )

    existing_user = result.scalar_one_or_none()

    # Check whether the account is currently locked
    if (
        existing_user is not None
        and existing_user.locked_until is not None
    ):
        now = datetime.now()

        if existing_user.locked_until > now:
            ip_address = (
                request.client.host
                if request.client
                else None
            )

            await create_security_alert(
                db=db,
                user_id=existing_user.id,
                alert_type="LOCKED_ACCOUNT_ACCESS",
                severity="medium",
                description=(
                    "Login attempt detected on a locked account."
                ),
                ip_address=ip_address,
            )

            raise HTTPException(
                status_code=status.HTTP_423_LOCKED,
                detail="Account is temporarily locked. Please try again later."
            )

        # Lock period has expired
        existing_user.locked_until = None
        existing_user.failed_login_attempts = 0

        await db.commit()

    # Authenticate the user
    try:
        user = await authenticate_user(
            db=db,
            email=login_request.email,
            password=login_request.password,
        )

    except InvalidCredentialsError:
        # Only track failed attempts if the user exists
        if existing_user is not None:
            existing_user.failed_login_attempts += 1

            # Lock account after 5 failed attempts
            if (
                existing_user.failed_login_attempts
                >= MAX_FAILED_ATTEMPTS
            ):
                existing_user.locked_until = (
                    datetime.now()
                    + timedelta(
                        minutes=LOCK_DURATION_MINUTES
                    )
                )

                await db.commit()

                ip_address = (
                    request.client.host
                    if request.client
                    else None
                )

                await create_security_alert(
                    db=db,
                    user_id=existing_user.id,
                    alert_type="BRUTE_FORCE_ATTACK",
                    severity="high",
                    description=(
                        "Account was locked after multiple failed"
                        "login attempts."
                    ),
                    ip_address=ip_address,
                )

                raise HTTPException(
                    status_code=status.HTTP_423_LOCKED,
                    detail=(
                        "Too many failed login attempts. "
                        "Account locked for 15 minutes."
                    ),
                )

            # Save failed attempt count
            await db.commit()

        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid email or password",
            headers={
                "WWW-Authenticate": "Bearer"
            },
        )

    # Successful login resets failed attempts
    if (
        user.failed_login_attempts != 0
        or user.locked_until is not None
    ):
        user.failed_login_attempts = 0
        user.locked_until = None

        await db.commit()

    ip_address = (
        request.client.host
        if request.client
        else None
    )

    await create_audit_log(
        db=db,
        user_id=user.id,
        event_type="USER_LOGIN",
        description="User logged in successfully",
        ip_address=ip_address,
    )

    return LoginResponse(
        access_token=create_access_token(user.id),
        refresh_token=create_refresh_token(user.id),
        token_type="bearer",
    )


# CURRENT USER

@router.get(
    "/me",
    response_model=UserResponse,
)
async def get_me(
    current_user: User = Depends(get_current_user),
):
    return current_user


# REFRESH ACCESS TOKEN

@router.post(
    "/refresh",
    response_model=TokenResponse,
)
async def refresh_access_token(
    request: RefreshTokenRequest,
):
    user_id = decode_refresh_token(
        request.refresh_token
    )

    if user_id is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired refresh token",
        )

    if await is_refresh_token_revoked(
        request.refresh_token
    ):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Refresh token has been revoked",
        )

    access_token = create_access_token(user_id)

    return TokenResponse(
        access_token=access_token,
        token_type="bearer",
    )


# LOGOUT

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


# VERIFY EMAIL

@router.post(
    "/verify-email",
    response_model=UserResponse,
)
async def verify_email(
    request: EmailVerificationRequest,
    db: AsyncSession = Depends(get_db),
):
    user_id = decode_email_verification_token(
        request.token
    )

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

    await create_audit_log(
        db=db,
        user_id=user.id,
        event_type="EMAIL_VERIFIED",
        description="User email verified successfully",
    )

    return user


# FORGOT PASSWORD

@router.post("/forgot-password")
async def forgot_password(
    request: ForgotPasswordRequest,
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(User).where(
            User.email == request.email
        )
    )

    user = result.scalar_one_or_none()

    if user is not None:
        reset_token = create_password_reset_token(
            user.id
        )

        # Email sending will be added later.
        # For now, return the token for testing.
        return {
            "message": "Password reset token generated",
            "reset_token": reset_token,
        }

    return {
        "message": (
            "If the email exists, "
            "a password reset link will be sent"
        ),
    }


# RESET PASSWORD

@router.post("/reset-password")
async def reset_password(
    request: ResetPasswordRequest,
    db: AsyncSession = Depends(get_db),
):
    user_id = decode_password_reset_token(
        request.token
    )

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

    await create_audit_log(
        db=db,
        user_id=user.id,
        event_type="PASSWORD_RESET",
        description="User password reset successfully",
    )

    return {
        "message": "Password reset successful",
    }


# CHANGE PASSWORD

@router.post("/change-password")
async def change_password(
    request: ChangePasswordRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    password_is_valid = verify_password(
        request.current_password,
        current_user.password_hash,
    )

    if not password_is_valid:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Current password is incorrect",
        )

    current_user.password_hash = hash_password(
        request.new_password
    )

    await db.commit()

    await create_audit_log(
        db=db,
        user_id=current_user.id,
        event_type="PASSWORD_CHANGED",
        description="User changed password successfully",
    )

    return {
        "message": "Password changed successfully",
    }