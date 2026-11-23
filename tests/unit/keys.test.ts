/**
 * Supabase's new API keys (plan item 1.10): every Edge Function takes its keys from supabase/functions/_shared/keys.ts,
 * which prefers the new publishable and secret keys (SUPABASE_PUBLISHABLE_KEYS / SUPABASE_SECRET_KEYS, JSON by name)
 * and falls back to the legacy anon and service_role keys, so the move needs no redeploy (AK01–AK04).
 */
import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { projectKey, keyHeaders } from "../../supabase/functions/_shared/keys";

const env = (vars: Record<string, string>) => (k: string) => vars[k];

describe("AK — the project's keys in the Edge Functions", () => {
  it("AK01 the new key when the project has one, by the name «default»", () => {
    const e = env({ SUPABASE_SECRET_KEYS: JSON.stringify({ default: "sb_secret_abc", billing: "sb_secret_x" }), SUPABASE_SERVICE_ROLE_KEY: "eyJ.legacy.jwt",
      SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: "sb_publishable_abc" }), SUPABASE_ANON_KEY: "eyJ.anon.jwt" });
    expect(projectKey("secret", e)).toBe("sb_secret_abc");
    expect(projectKey("publishable", e)).toBe("sb_publishable_abc");
  });

  it("AK02 the legacy key before the move, or when the new variable is empty or not JSON; none at all is an error", () => {
    expect(projectKey("secret", env({ SUPABASE_SERVICE_ROLE_KEY: "eyJ.legacy.jwt" }))).toBe("eyJ.legacy.jwt");
    expect(projectKey("publishable", env({ SUPABASE_PUBLISHABLE_KEYS: "{}", SUPABASE_ANON_KEY: "eyJ.anon.jwt" }))).toBe("eyJ.anon.jwt");
    expect(projectKey("secret", env({ SUPABASE_SECRET_KEYS: "not json", SUPABASE_SERVICE_ROLE_KEY: "eyJ.legacy.jwt" }))).toBe("eyJ.legacy.jwt");
    expect(() => projectKey("secret", env({}))).toThrow(/no secret key/);
  });

  it("AK03 a new key travels in apikey only; a legacy JWT also in Authorization", () => {
    expect(keyHeaders("sb_secret_abc")).toEqual({ apikey: "sb_secret_abc" });
    expect(keyHeaders("eyJ.legacy.jwt")).toEqual({ apikey: "eyJ.legacy.jwt", authorization: "Bearer eyJ.legacy.jwt" });
  });

  it("AK04 no Edge Function reads the legacy variables itself, and every one is typechecked by the edge gate", () => {
    const root = join(__dirname, "..", "..", "supabase", "functions");
    const fns = readdirSync(root, { withFileTypes: true }).filter((d) => d.isDirectory() && d.name !== "_shared").map((d) => d.name);
    const edge = JSON.parse(readFileSync(join(__dirname, "..", "edge", "tsconfig.json"), "utf8")).files as string[];
    for (const fn of fns) {
      const src = readFileSync(join(root, fn, "index.ts"), "utf8");
      expect(src, fn).not.toMatch(/Deno\.env\.get\("SUPABASE_(ANON|SERVICE_ROLE)_KEY"\)/);
      expect(edge, fn).toContain(`../../supabase/functions/${fn}/index.ts`);
    }
    for (const f of readdirSync(join(root, "_shared")).filter((f) => f.endsWith(".ts") && f !== "keys.ts")) {
      expect(readFileSync(join(root, "_shared", f), "utf8"), f).not.toMatch(/authorization: `Bearer \$\{env\.serviceKey\}`/);
    }
  });
});
