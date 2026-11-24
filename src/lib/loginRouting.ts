import { PAGES, homeFor, pageAllowed, pageFor, type Allows } from "./nav";
import type { StaffProfile } from "./auth";

/** Only app-relative, known routes. Reject encodings and normalization tricks rather than repairing them. */
export function safeReturnPath(value: string | null): string | null {
  if (!value || value.length > 600 || /\s/.test(value) || !/^\/(staff|admin)\/[a-z0-9/-]+$/.test(value)) return value === "/platform" ? value : null;
  if (value.includes("//") || value.includes("..")) return null;
  return pageFor(value) ? value : null;
}

export function loginDestination(input: {
  loading: boolean; hasSession: boolean; error: string | null;
  operator: boolean; entry?: "hotel" | "platform"; profile: StaffProfile | null; allows: Allows; returnTo: string | null;
}): string | null {
  if (input.loading || !input.hasSession || input.error) return null;
  const wanted = safeReturnPath(input.returnTo);
  if (input.entry === "platform") return input.operator ? "/platform" : null;
  if (input.operator) return null;
  if (!input.profile) return "/owner/setup";
  if (!input.profile.is_active || input.profile.role === "guest") return null;
  const allowed = (path: string) => { const page = pageFor(path); return !!page && pageAllowed(page, input.profile!.role, input.allows); };
  if (wanted && allowed(wanted)) return wanted;
  const preferred = homeFor(input.profile.role);
  return allowed(preferred) ? preferred : PAGES.find(p => !p.hidden && !p.path.includes(":") && allowed(p.path))?.path ?? null;
}
