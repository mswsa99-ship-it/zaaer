/** Guest-site identity comes from the address, never the first branch in a global list. */
export interface GuestScope { slug: string | null; token: string | null; base: string; guest: boolean }
export function parseGuestScope(path: string, buildBase = "/"): GuestScope {
  const base = buildBase.replace(/\/+$/, "");
  const local = base && path.startsWith(base + "/") ? path.slice(base.length) : path;
  const hotel = local.match(/^\/h\/([a-z0-9][a-z0-9-]{0,79})(?=\/|$)/);
  const inner = hotel ? local.slice(hotel[0].length) || "/" : local;
  const booking = inner.match(/^\/(?:booking\/(?:registration|status|payment|summary|review)|checkin)\/([^/?#]+)/);
  return { slug: hotel?.[1] ?? null, token: booking?.[1] ?? null, base: base + (hotel?.[0] ?? ""), guest: !/^\/(?:staff|admin)(?:\/|$)/.test(inner) };
}
export function currentGuestScope(): GuestScope {
  if (typeof window === "undefined" || !window.location) return parseGuestScope("/");
  const demo = import.meta.env.VITE_DEMO === "1";
  return parseGuestScope(demo ? window.location.hash.slice(1) || "/" : window.location.pathname || "/", demo ? "/" : import.meta.env.BASE_URL ?? "/");
}
export function guestHeaders(): Record<string, string> {
  const s = currentGuestScope();
  return { ...(s.slug ? { "x-hotel-slug": s.slug } : {}), ...(s.token ? { "x-guest-token": s.token } : {}) };
}
export function guestScopeKey(): string { const s = currentGuestScope(); return s.slug ?? s.token ?? "legacy"; }
