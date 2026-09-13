"use client";

import { useCallback, useEffect, useState } from "react";
import {
  AlertTriangle,
  CheckCircle,
  Loader2,
  LogOut,
  RefreshCw,
  ShieldAlert,
} from "lucide-react";
import {
  getSecurityAlerts,
  resolveSecurityAlert,
  type SecurityAlert,
} from "@/lib/api";
import {
  clearSession,
  getAccessToken,
  isAuthenticationError,
} from "@/lib/auth";
import { useRouter } from "next/navigation";

export default function SecurityAlertsPage() {
  const router = useRouter();

  const [alerts, setAlerts] = useState<SecurityAlert[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [resolvingId, setResolvingId] = useState<number | null>(null);

  const loadAlerts = useCallback(async () => {
    const accessToken = getAccessToken();

    if (!accessToken) {
      router.push("/login");
      return;
    }

    try {
      setLoading(true);
      setError(null);

      const data = await getSecurityAlerts(accessToken);

      setAlerts(data);
    } catch (err) {
      const message =
        err instanceof Error
          ? err.message
          : "Unable to load security alerts";

      if (isAuthenticationError(message)) {
        clearSession();
        router.push("/login");
        return;
      }

      setError(message);
    } finally {
      setLoading(false);
    }
  }, [router]);

  useEffect(() => {
    const timeoutId = window.setTimeout(() => {
      void loadAlerts();
    }, 0);

    return () => window.clearTimeout(timeoutId);
  }, [loadAlerts]);

  const handleResolve = async (alertId: number) => {
    const accessToken = getAccessToken();

    if (!accessToken) {
      router.push("/login");
      return;
    }

    try {
      setResolvingId(alertId);
      setError(null);

      const updatedAlert = await resolveSecurityAlert(
        accessToken,
        alertId,
      );

      setAlerts((currentAlerts) =>
        currentAlerts.map((alert) =>
          alert.id === updatedAlert.id ? updatedAlert : alert,
        ),
      );
    } catch (err) {
      const message =
        err instanceof Error
          ? err.message
          : "Unable to resolve security alert";

      if (isAuthenticationError(message)) {
        clearSession();
        router.push("/login");
        return;
      }

      setError(message);
    } finally {
      setResolvingId(null);
    }
  };

  const handleLogout = () => {
    clearSession();
    router.push("/login");
  };

  const openAlerts = alerts.filter(
    (alert) => alert.status.toLowerCase() === "open",
  ).length;

  const resolvedAlerts = alerts.filter(
    (alert) => alert.status.toLowerCase() === "resolved",
  ).length;

  if (loading && alerts.length === 0) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-slate-950 text-white">
        <div className="text-center">
          <Loader2 className="mx-auto h-8 w-8 animate-spin text-cyan-400" />

          <p className="mt-4 text-slate-400">
            Loading security alerts...
          </p>
        </div>
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-slate-950 text-white">
      <div className="mx-auto max-w-7xl px-6 py-10">
        <header className="flex flex-col gap-6 border-b border-slate-800 pb-8 md:flex-row md:items-center md:justify-between">
          <div>
            <div className="flex items-center gap-3">
              <ShieldAlert className="h-8 w-8 text-red-400" />

              <div>
                <h1 className="text-3xl font-bold tracking-tight">
                  Security Alerts
                </h1>

                <p className="mt-2 text-slate-400">
                  Monitor and resolve security incidents
                </p>
              </div>
            </div>
          </div>

          <div className="flex gap-3">
            <button
              onClick={() => void loadAlerts()}
              disabled={loading}
              className="inline-flex items-center gap-2 rounded-lg border border-slate-700 bg-slate-900 px-4 py-2 text-sm font-medium transition hover:bg-slate-800 disabled:opacity-50"
            >
              <RefreshCw
                className={`h-4 w-4 ${
                  loading ? "animate-spin" : ""
                }`}
              />

              Refresh
            </button>

            <button
              onClick={handleLogout}
              className="inline-flex items-center gap-2 rounded-lg border border-red-900 bg-red-950/30 px-4 py-2 text-sm font-medium text-red-300 transition hover:bg-red-950/60"
            >
              <LogOut className="h-4 w-4" />

              Logout
            </button>
          </div>
        </header>

        <section className="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <MetricCard
            title="Total Alerts"
            value={alerts.length}
            icon={<AlertTriangle className="h-5 w-5" />}
          />

          <MetricCard
            title="Open Alerts"
            value={openAlerts}
            icon={<ShieldAlert className="h-5 w-5" />}
          />

          <MetricCard
            title="Resolved Alerts"
            value={resolvedAlerts}
            icon={<CheckCircle className="h-5 w-5" />}
          />
        </section>

        {error && (
          <div className="mt-6 rounded-xl border border-red-900 bg-red-950/40 p-5">
            <div className="flex items-start gap-3">
              <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-red-400" />

              <div>
                <h2 className="font-semibold text-red-300">
                  Security alert operation failed
                </h2>

                <p className="mt-1 text-sm text-red-400">
                  {error}
                </p>
              </div>
            </div>
          </div>
        )}

        <section className="mt-8 overflow-hidden rounded-xl border border-slate-800 bg-slate-900">
          <div className="border-b border-slate-800 p-5">
            <h2 className="font-semibold">
              Security Incidents
            </h2>

            <p className="mt-1 text-sm text-slate-400">
              Review detected security events and their current status.
            </p>
          </div>

          {alerts.length === 0 ? (
            <div className="p-10 text-center">
              <CheckCircle className="mx-auto h-10 w-10 text-emerald-400" />

              <p className="mt-4 font-medium">
                No security alerts
              </p>

              <p className="mt-1 text-sm text-slate-400">
                SentinelForge has not detected any security incidents.
              </p>
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full min-w-[1000px] text-left text-sm">
                <thead className="border-b border-slate-800 bg-slate-950/50 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-5 py-4">Alert</th>
                    <th className="px-5 py-4">Severity</th>
                    <th className="px-5 py-4">User</th>
                    <th className="px-5 py-4">IP Address</th>
                    <th className="px-5 py-4">Status</th>
                    <th className="px-5 py-4">Created</th>
                    <th className="px-5 py-4">Action</th>
                  </tr>
                </thead>

                <tbody className="divide-y divide-slate-800">
                  {alerts.map((alert) => (
                    <tr
                      key={alert.id}
                      className="transition hover:bg-slate-800/40"
                    >
                      <td className="px-5 py-4">
                        <div>
                          <p className="font-medium text-white">
                            {alert.alert_type}
                          </p>

                          <p className="mt-1 max-w-md text-xs text-slate-500">
                            {alert.description}
                          </p>
                        </div>
                      </td>

                      <td className="px-5 py-4">
                        <SeverityBadge severity={alert.severity} />
                      </td>

                      <td className="px-5 py-4 text-slate-300">
                        {alert.user_id ?? "System"}
                      </td>

                      <td className="px-5 py-4 font-mono text-xs text-slate-400">
                        {alert.ip_address ?? "—"}
                      </td>

                      <td className="px-5 py-4">
                        <StatusBadge status={alert.status} />
                      </td>

                      <td className="px-5 py-4 whitespace-nowrap text-xs text-slate-500">
                        {new Date(alert.created_at).toLocaleString()}
                      </td>

                      <td className="px-5 py-4">
                        {alert.status.toLowerCase() === "open" ? (
                          <button
                            onClick={() => void handleResolve(alert.id)}
                            disabled={resolvingId === alert.id}
                            className="inline-flex items-center gap-2 rounded-lg border border-emerald-800 bg-emerald-950/30 px-3 py-2 text-xs font-medium text-emerald-300 transition hover:bg-emerald-950/60 disabled:cursor-not-allowed disabled:opacity-50"
                          >
                            {resolvingId === alert.id ? (
                              <Loader2 className="h-4 w-4 animate-spin" />
                            ) : (
                              <CheckCircle className="h-4 w-4" />
                            )}

                            {resolvingId === alert.id
                              ? "Resolving..."
                              : "Resolve"}
                          </button>
                        ) : (
                          <span className="text-xs text-slate-600">
                            No action
                          </span>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      </div>
    </main>
  );
}

function MetricCard({
  title,
  value,
  icon,
}: {
  title: string;
  value: number;
  icon: React.ReactNode;
}) {
  return (
    <div className="rounded-xl border border-slate-800 bg-slate-900 p-5">
      <div className="flex items-center justify-between">
        <span className="text-sm text-slate-400">
          {title}
        </span>

        <div className="text-cyan-400">{icon}</div>
      </div>

      <p className="mt-4 text-3xl font-bold">{value}</p>
    </div>
  );
}

function SeverityBadge({ severity }: { severity: string }) {
  const normalizedSeverity = severity.toLowerCase();

  const classes =
    normalizedSeverity === "critical"
      ? "border-red-800 bg-red-950 text-red-300"
      : normalizedSeverity === "high"
        ? "border-orange-800 bg-orange-950 text-orange-300"
        : normalizedSeverity === "medium"
          ? "border-yellow-800 bg-yellow-950 text-yellow-300"
          : "border-slate-700 bg-slate-800 text-slate-300";

  return (
    <span
      className={`rounded-full border px-2.5 py-1 text-xs font-medium ${classes}`}
    >
      {severity}
    </span>
  );
}

function StatusBadge({ status }: { status: string }) {
  const normalizedStatus = status.toLowerCase();

  const classes =
    normalizedStatus === "open"
      ? "border-red-800 bg-red-950 text-red-300"
      : "border-emerald-800 bg-emerald-950 text-emerald-300";

  return (
    <span
      className={`rounded-full border px-2.5 py-1 text-xs font-medium ${classes}`}
    >
      {status}
    </span>
  );
}