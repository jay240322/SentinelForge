const API_URL = "http://localhost:8000";

export type LoginResponse = {
  access_token: string;
  refresh_token: string;
  token_type: string;
};

export type DashboardData = {
  total_users: number;
  open_security_alerts: number;
  resolved_security_alerts: number;
  total_audit_logs: number;
  recent_security_alerts: SecurityAlert[];
  recent_audit_logs: AuditLog[];
};

export type SecurityAlert = {
  id: number;
  user_id: number | null;
  alert_type: string;
  severity: string;
  description: string;
  status: string;
  ip_address: string | null;
  created_at: string;
  resolved_at: string | null;
};

export type AuditLog = {
  id: number;
  user_id: number | null;
  event_type: string;
  ip_address: string | null;
  created_at: string;
};

export async function login(
  email: string,
  password: string,
): Promise<LoginResponse> {
  const response = await fetch(`${API_URL}/api/v1/auth/login`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      email,
      password,
    }),
  });

  if (!response.ok) {
    const data = await response.json().catch(() => null);

    throw new Error(data?.detail || "Login failed");
  }

  return response.json();
}

export async function getDashboard(
  accessToken: string,
): Promise<DashboardData> {
  const response = await fetch(`${API_URL}/api/v1/admin/dashboard`, {
    headers: {
      Authorization: `Bearer ${accessToken}`,
    },
  });

  if (!response.ok) {
    const data = await response.json().catch(() => null);

    throw new Error(data?.detail || "Unable to load dashboard");
  }

  return response.json();
}
export type User = {
  id: number;
  email: string;
  is_active: boolean;
  is_verified: boolean;
  role: string;
};

export async function getUsers(accessToken: string): Promise<User[]> {
  const response = await fetch(`${API_URL}/api/v1/admin/users`, {
    headers: {
      Authorization: `Bearer ${accessToken}`,
    },
  });

  if (!response.ok) {
    const data = await response.json().catch(() => null);

    throw new Error(data?.detail || "Unable to load users");
  }

  return response.json();
}