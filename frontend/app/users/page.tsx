"use client";

import { useEffect, useState } from "react";
import {
  ArrowLeft,
  CheckCircle,
  Loader2,
  ShieldCheck,
  UserX,
  Users as UsersIcon,
  XCircle,
} from "lucide-react";
import { useRouter } from "next/navigation";
import { getUsers, type User } from "@/lib/api";

export default function UsersPage() {
  const router = useRouter();

  const [users, setUsers] = useState<User[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const loadUsers = async () => {
      const accessToken = sessionStorage.getItem("access_token");

      if (!accessToken) {
        router.push("/login");
        return;
      }

      try {
        const data = await getUsers(accessToken);
        setUsers(data);
      } catch (err) {
        setError(
          err instanceof Error
            ? err.message
            : "Unable to load users",
        );
      } finally {
        setLoading(false);
      }
    };

    loadUsers();
  }, [router]);

  if (loading) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-slate-950 text-white">
        <div className="text-center">
          <Loader2 className="mx-auto h-8 w-8 animate-spin text-cyan-400" />

          <p className="mt-4 text-slate-400">
            Loading users...
          </p>
        </div>
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-slate-950 text-white">
      <div className="mx-auto max-w-7xl px-6 py-10">
        <header className="flex flex-col gap-5 border-b border-slate-800 pb-8 md:flex-row md:items-center md:justify-between">
          <div className="flex items-center gap-4">
            <button
              onClick={() => router.push("/")}
              className="rounded-lg border border-slate-700 bg-slate-900 p-2 transition hover:bg-slate-800"
              aria-label="Back to dashboard"
            >
              <ArrowLeft className="h-5 w-5" />
            </button>

            <div>
              <div className="flex items-center gap-3">
                <ShieldCheck className="h-7 w-7 text-cyan-400" />

                <h1 className="text-3xl font-bold">
                  Users
                </h1>
              </div>

              <p className="mt-1 text-slate-400">
                Manage SentinelForge users and account status.
              </p>
            </div>
          </div>

          <div className="flex items-center gap-2 rounded-lg border border-slate-800 bg-slate-900 px-4 py-3">
            <UsersIcon className="h-5 w-5 text-cyan-400" />

            <span className="text-sm text-slate-400">
              Total
            </span>

            <span className="font-semibold">
              {users.length}
            </span>
          </div>
        </header>

        {error && (
          <div className="mt-8 rounded-xl border border-red-900 bg-red-950/40 p-5 text-red-300">
            {error}
          </div>
        )}

        {!error && (
          <div className="mt-8 overflow-hidden rounded-xl border border-slate-800 bg-slate-900">
            <div className="overflow-x-auto">
              <table className="w-full text-left">
                <thead className="border-b border-slate-800 bg-slate-950/60">
                  <tr>
                    <th className="px-5 py-4 text-sm font-medium text-slate-400">
                      ID
                    </th>

                    <th className="px-5 py-4 text-sm font-medium text-slate-400">
                      Email
                    </th>

                    <th className="px-5 py-4 text-sm font-medium text-slate-400">
                      Role
                    </th>

                    <th className="px-5 py-4 text-sm font-medium text-slate-400">
                      Account
                    </th>

                    <th className="px-5 py-4 text-sm font-medium text-slate-400">
                      Verification
                    </th>
                  </tr>
                </thead>

                <tbody className="divide-y divide-slate-800">
                  {users.map((user) => (
                    <tr
                      key={user.id}
                      className="transition hover:bg-slate-800/40"
                    >
                      <td className="px-5 py-4 text-sm text-slate-400">
                        #{user.id}
                      </td>

                      <td className="px-5 py-4">
                        <span className="font-medium">
                          {user.email}
                        </span>
                      </td>

                      <td className="px-5 py-4">
                        <RoleBadge role={user.role} />
                      </td>

                      <td className="px-5 py-4">
                        {user.is_active ? (
                          <span className="inline-flex items-center gap-2 text-sm text-green-400">
                            <CheckCircle className="h-4 w-4" />
                            Active
                          </span>
                        ) : (
                          <span className="inline-flex items-center gap-2 text-sm text-red-400">
                            <UserX className="h-4 w-4" />
                            Inactive
                          </span>
                        )}
                      </td>

                      <td className="px-5 py-4">
                        {user.is_verified ? (
                          <span className="inline-flex items-center gap-2 text-sm text-green-400">
                            <CheckCircle className="h-4 w-4" />
                            Verified
                          </span>
                        ) : (
                          <span className="inline-flex items-center gap-2 text-sm text-yellow-400">
                            <XCircle className="h-4 w-4" />
                            Unverified
                          </span>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {users.length === 0 && (
              <div className="p-10 text-center text-slate-400">
                No users found.
              </div>
            )}
          </div>
        )}
      </div>
    </main>
  );
}

function RoleBadge({ role }: { role: string }) {
  const normalizedRole = role.toLowerCase();

  const classes =
    normalizedRole === "admin"
      ? "border-cyan-800 bg-cyan-950 text-cyan-300"
      : "border-slate-700 bg-slate-800 text-slate-300";

  return (
    <span
      className={`rounded-full border px-2.5 py-1 text-xs font-medium ${classes}`}
    >
      {role}
    </span>
  );
}