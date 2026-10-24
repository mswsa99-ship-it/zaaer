/**
 * Trace codes (decisions 39 and 60).
 *
 * Every operation the app sends to the server carries a short code in the `x-correlation-id` header. The server
 * stamps it on every audit row the operation writes (migration 0026), and when the operation fails the employee
 * sees the same code next to the Arabic message ("رمز التتبع: K7Q2M9XA"), so support can find the request.
 * The code is random and carries no personal data.
 */
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O or 1/I: easy to read aloud over the phone

export function newTraceId(length = 8): string {
  const bytes = new Uint8Array(length);
  if (typeof crypto !== "undefined" && typeof crypto.getRandomValues === "function") crypto.getRandomValues(bytes);
  else for (let i = 0; i < length; i++) bytes[i] = Math.floor(Math.random() * 256);
  let out = "";
  for (let i = 0; i < length; i++) out += ALPHABET[bytes[i] % ALPHABET.length];
  return out;
}

/** Where the request comes from, for the audit trail (attribution only; the server never trusts it for access). */
export function clientSource(pathname: string = typeof location !== "undefined" ? location.hash.replace(/^#/, "") || location.pathname : ""): string {
  if (pathname.startsWith("/admin")) return "admin-app";
  if (pathname.startsWith("/staff")) return "staff-app";
  if (pathname.startsWith("/kiosk")) return "kiosk";
  return "guest-app";
}

/** A code as the employee read it out or pasted it: the "رمز التتبع:" label, brackets, spaces and lower case are tolerated. */
export function normalizeTrace(code: string): string {
  const t = code.trim().replace(/^.*:\s*/, "").replace(/[\s()]/g, "");
  return /^tx-/i.test(t) ? "tx-" + t.slice(3) : t.toUpperCase();
}

/**
 * The leading code of a server error, never its free text: "ALLOCATION_CONFLICT", or "VALIDATION: amount" when the
 * whole message is a code and one field name; anything after that ("FORBIDDEN: requires one of …") is dropped.
 */
export function errorCode(message: string): string {
  const whole = message.trim().match(/^([A-Z][A-Z0-9_]{2,48}):\s*([a-z_0-9]{1,48})$/);
  if (whole) return `${whole[1]}: ${whole[2]}`;
  const lead = message.match(/^([A-Z][A-Z0-9_]{2,48})(?=$|[:\s])/);
  return lead ? lead[1] : "UNKNOWN";
}
