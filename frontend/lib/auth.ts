export function getAccessToken(): string | null {
  return sessionStorage.getItem("access_token");
}

export function clearSession(): void {
  sessionStorage.removeItem("access_token");
  sessionStorage.removeItem("refresh_token");
}

export function isAuthenticationError(message: string): boolean {
  const normalizedMessage = message.toLowerCase();

  return (
    normalizedMessage.includes("not authenticated") ||
    normalizedMessage.includes("unauthorized")
  );
}