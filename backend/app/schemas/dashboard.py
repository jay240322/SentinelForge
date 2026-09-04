from app.schemas.audit import AuditLogResponse
from app.schemas.security_alert import SecurityAlertResponse
from pydantic import BaseModel


class DashboardResponse(BaseModel):
    total_users: int
    open_security_alerts: int
    resolved_security_alerts: int
    total_audit_logs: int

    recent_security_alerts: list[SecurityAlertResponse]
    recent_audit_logs: list[AuditLogResponse]