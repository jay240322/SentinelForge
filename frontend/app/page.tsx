"use client";

import { useEffect, useState } from "react";

type ApiStatus = {
  status: string;
  service: string;
  version: string;
};

export default function Home() {
  const [apiStatus, setApiStatus] = useState<ApiStatus | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const checkApi = async () => {
      try {
        const response = await fetch("http://localhost:8000/health");

        if (!response.ok) {
          throw new Error("API request failed");
        }

        const data = await response.json();
        setApiStatus(data);
      } catch {
        setError("Unable to connect to SentinelForge API");
      }
    };

    checkApi();
  }, []);

  return (
    <main className="min-h-screen bg-slate-950 text-white">
      <div className="mx-auto max-w-6xl px-6 py-16">
        <header>
          <p className="text-sm font-medium text-cyan-400">
            SECURITY PLATFORM
          </p>

          <h1 className="mt-3 text-4xl font-bold tracking-tight">
            SentinelForge
          </h1>

          <p className="mt-3 max-w-2xl text-slate-400">
            Cloud-native security from source code to Kubernetes runtime.
          </p>
        </header>

        <section className="mt-12 rounded-xl border border-slate-800 bg-slate-900 p-6">
          <h2 className="text-lg font-semibold">System Status</h2>

          <div className="mt-6">
            {apiStatus && (
              <div className="flex items-center gap-3">
                <div className="h-3 w-3 rounded-full bg-green-400" />

                <div>
                  <p className="font-medium">API Healthy</p>

                  <p className="text-sm text-slate-400">
                    {apiStatus.service} · v{apiStatus.version}
                  </p>
                </div>
              </div>
            )}

            {error && (
              <div className="flex items-center gap-3">
                <div className="h-3 w-3 rounded-full bg-red-400" />

                <p className="text-red-400">{error}</p>
              </div>
            )}

            {!apiStatus && !error && (
              <p className="text-slate-400">Checking API...</p>
            )}
          </div>
        </section>
      </div>
    </main>
  );
}