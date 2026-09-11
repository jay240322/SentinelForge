"use client";

import { useEffect, useState } from "react";
import {
  AlertTriangle,
  CheckCircle,
  FileText,
  Loader2,
  LogOut,
  RefreshCw,
  ShieldCheck,
  Users,
} from "lucide-react";
import { getDashboard, type DashboardData } from "@/lib/api";
import { useRouter } from "next/navigation";

export default function Home() {
  const router = useRouter();

  const [dashboard, setDashboard] = useState<DashboardData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const loadDashboard = async () => {
    const accessToken = sessionStorage.getItem("access_token");

    if (!accessToken) {
      router.push("/login");
      return;
    }

    try {
      setLoading(true);
      setError(null);

      const data = await getDashboard(accessToken);

      setDashboard(data);
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Unable to load dashboard";

      if (
        message.toLowerCase().includes("not authenticated") ||
        message.toLowerCase().includes("unauthorized")
      ) {
        sessionStorage.removeItem("access_token");
        sessionStorage.removeItem("refresh_token");
        router.push("/login");
        return;
      }

      setError(message);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    loadDashboard();
  }, []);

  const handleLogout = () => {
    sessionStorage.removeItem("access_token");
    sessionStorage.removeItem("refresh_token");

    router.push("/login");
  };

  if (loading && !dashboard) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-slate-950 text-white">
        <div className="text-center">
          <Loader2 className="mx-auto h-8 w-8 animate-spin text-cyan-400" />

          <p className="mt-4 text-slate-400">
            Loading SentinelForge...
          </p>
        </div>
      </main>
    );
  }

  if (error && !dashboard) {
    return (
      <main className="min-h-screen bg-slate-950 px-6 py-10 text-white">
        <div className="mx-auto max-w-7xl">
          <div className="rounded-xl border border-red-900 bg-red-950/40 p-6">
            <div className="flex items-center gap-3">
              <AlertTriangle className="h-6 w-6 text-red-400" />

              <div>
                <h1 className="font-semibold text-red-300">
                  Dashboard unavailable
                </h1>

                <p className="mt-1 text-sm text-red-400">
                  {error}
                </p>
              </div>
            </div>

            <button
              onClick={loadDashboard}
              className="mt-5 inline-flex items-center gap-2 rounded-lg border border-slate-700 bg-slate-900 px-4 py-2 text-sm hover:bg-slate-800"
            >
              <RefreshCw className="h-4 w-4" />
              Try again
            </button>
          </div>
        </div>
      </main>
    );
  }

  if (!dashboard) {
    return null;
  }

  return (
    <main className="min-h-screen bg-slate-950 text-white">
      <div className="mx-auto max-w-7xl px-6 py-10">
        <header className="flex flex-col gap-6 border-b border-slate-800 pb-8 md:flex-row md:items-center md:justify-between">
          <div>
            <div className="flex items-center gap-3">
              <ShieldCheck className="h-8 w-8 text-cyan-400" />

              <h1 className="text-3xl font-bold tracking-tight">
                SentinelForge
              </h1>
            </div>

            <p className="mt-2 text-slate-400">
              Security Operations Dashboard
            </p>
          </div>

          <div className="flex gap-3">
            <button
              onClick={loadDashboard}
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

        <section className="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <StatCard
            title="Total Users"
            value={dashboard.total_users}
            icon={<Users className="h-5 w-5" />}
          />

          <StatCard
            title="Open Alerts"
            value={dashboard.open_security_alerts}
            icon={<AlertTriangle className="h-5 w-5" />}
          />

          <StatCard
            title="Resolved Alerts"
            value={dashboard.resolved_security_alerts}
            icon={<CheckCircle className="h-5 w-5" />}
          />

          <StatCard
            title="Audit Logs"
            value={dashboard.total_audit_logs}
            icon={<FileText className="h-5 w-5" />}
          />
        </section>

        <section className="mt-8 grid gap-6 lg:grid-cols-2">
          <div className="rounded-xl border border-slate-800 bg-slate-900">
            <div className="border-b border-slate-800 p-5">
              <h2 className="font-semibold">
                Recent Security Alerts
              </h2>

              <p className="mt-1 text-sm text-slate-400">
                Latest security events
              </p>
            </div>

            <div className="divide-y divide-slate-800">
              {dashboard.recent_security_alerts.length === 0 ? (
                <p className="p-5 text-sm text-slate-400">
                  No recent security alerts.
                </p>
              ) : (
                dashboard.recent_security_alerts.map((alert) => (
                  <div key={alert.id} className="p-5">
                    <div className="flex items-start justify-between gap-4">
                      <div>
                        <p className="font-medium">
                          {alert.alert_type}
                        </p>

                        <p className="mt-1 text-sm text-slate-400">
                          {alert.description}
                        </p>
                      </div>

                      <SeverityBadge severity={alert.severity} />
                    </div>

                    <div className="mt-3 flex flex-wrap gap-4 text-xs text-slate-500">
                      <span>Status: {alert.status}</span>

                      {alert.ip_address && (
                        <span>IP: {alert.ip_address}</span>
                      )}

                      <span>
                        {new Date(
                          alert.created_at,
                        ).toLocaleString()}
                      </span>
                    </div>
                  </div>
                ))
              )}
            </div>
          </div>

          <div className="rounded-xl border border-slate-800 bg-slate-900">
            <div className="border-b border-slate-800 p-5">
              <h2 className="font-semibold">
                Recent Audit Logs
              </h2>

              <p className="mt-1 text-sm text-slate-400">
                Latest recorded security activity
              </p>
            </div>

            <div className="divide-y divide-slate-800">
              {dashboard.recent_audit_logs.length === 0 ? (
                <p className="p-5 text-sm text-slate-400">
                  No recent audit logs.
                </p>
              ) : (
                dashboard.recent_audit_logs.map((log) => (
                  <div key={log.id} className="p-5">
                    <div className="flex items-start justify-between gap-4">
                      <div>
                        <p className="font-medium">
                          {log.event_type}
                        </p>

                        <p className="mt-1 text-sm text-slate-400">
                          User ID: {log.user_id ?? "System"}
                        </p>
                      </div>

                      <span className="text-xs text-slate-500">
                        {new Date(
                          log.created_at,
                        ).toLocaleString()}
                      </span>
                    </div>

                    {log.ip_address && (
                      <p className="mt-2 text-xs text-slate-500">
                        IP: {log.ip_address}
                      </p>
                    )}
                  </div>
                ))
              )}
            </div>
          </div>
        </section>
      </div>
    </main>
  );
}

function StatCard({
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