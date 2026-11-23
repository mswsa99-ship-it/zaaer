/**
 * The project's API keys inside an Edge Function (plan item 1.10: Supabase retires the legacy anon and service_role
 * keys by the end of 2026). When the project has the new keys, the platform gives every function
 * SUPABASE_PUBLISHABLE_KEYS and SUPABASE_SECRET_KEYS — JSON objects keyed by the key's name, «default» for the first —
 * next to the legacy SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY. A function asks here, and gets the new key when
 * there is one and the legacy key otherwise, so the same code runs before, during and after the move.
 */

type Env = (name: string) => string | undefined;
const denoEnv: Env = (name) => (globalThis as unknown as { Deno?: { env: { get(k: string): string | undefined } } }).Deno?.env.get(name);

/** The publishable key (was anon) or the secret key (was service_role). Throws when the project gives neither. */
export function projectKey(kind: "publishable" | "secret", env: Env = denoEnv): string {
  const raw = env(kind === "publishable" ? "SUPABASE_PUBLISHABLE_KEYS" : "SUPABASE_SECRET_KEYS");
  if (raw) {
    try {
      const v = (JSON.parse(raw) as Record<string, unknown>)?.["default"];
      if (typeof v === "string" && v.trim()) return v.trim();
    } catch { /* not JSON: fall back to the legacy key */ }
  }
  const legacy = env(kind === "publishable" ? "SUPABASE_ANON_KEY" : "SUPABASE_SERVICE_ROLE_KEY");
  if (!legacy) throw new Error(`no ${kind} key in this function's environment`);
  return legacy;
}

/**
 * The headers that carry a key to another Edge Function. A legacy key is a JWT and also rides in Authorization; a new
 * key (sb_…) is not a JWT and goes in apikey only — in Authorization the platform would try to read it as a JWT and
 * answer «Invalid JWT».
 */
export function keyHeaders(key: string): Record<string, string> {
  return key.startsWith("sb_") ? { apikey: key } : { apikey: key, authorization: `Bearer ${key}` };
}
