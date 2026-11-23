/**
 * Accounts (0074): the pieces of the «staff-invite» edge function that need no network, kept here so the unit tests
 * can run them.
 */

/** The page an invitation's or a reset's link opens: APP_BASE_URL (the app's address, with its sub-path) + staff/reset-password. */
export function resetUrl(base: string | undefined | null): string | undefined {
  if (!base || !/^https:\/\//.test(base)) return undefined;
  try { return new URL("staff/reset-password", base.endsWith("/") ? base : base + "/").toString(); } catch { return undefined; }
}

/** Supabase Auth's error for an invitation, as one of the function's error codes. */
export function inviteError(e: { message?: string; code?: string; status?: number } | null | undefined): string {
  const m = `${e?.code ?? ""} ${e?.message ?? ""}`.toLowerCase();
  if (m.includes("not authorized") || m.includes("email_address_not_authorized")) return "smtp_not_configured";
  if (m.includes("rate limit") || m.includes("over_email_send_rate_limit") || e?.status === 429) return "rate_limited";
  if (m.includes("already") && (m.includes("registered") || m.includes("exists"))) return "already_registered";
  return "failed";
}
