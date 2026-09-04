from datetime import datetime

from pydantic import BaseModel, ConfigDict


class SecurityAlertResponse(BaseModel):
    id: int
    user_id: int | None
    alert_type: str
    severity: str
    description: str
    status: str
    ip_address: str | None
    created_at: datetime
    resolved_at: datetime | None

    model_config = ConfigDict(
        from_attributes=True
    )