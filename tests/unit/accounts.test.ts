/**
 * Accounts (0074, owner's decisions of 23 Nov 2026): the password rule the screens check before Supabase Auth does
 * (at least 6 characters with English letters and digits), the «staff-invite» function's pieces that need no network,
 * and the demo's copy of the account events, the invitation and the password calls (AU20–AU27).
 */
import { describe, it, expect, beforeAll, beforeEach } from "vitest";
import { passwordProblem, newPasswordProblem, PASSWORD_MIN, PASSWORD_MAX } from "../../src/lib/password";
import { resetUrl, inviteError } from "../../supabase/functions/_shared/accounts";

describe("AU — the password rule", () => {
  it("AU20 six characters at least, with an English letter and a digit; nothing else is asked", () => {
    expect(PASSWORD_MIN).toBe(6);
    for (const ok of ["abc123", "A1b2c3", "room2026", "x9y8z7!", "123abc"]) expect(passwordProblem(ok), ok).toBeNull();
    expect(passwordProblem("ab12c")).toMatch(/6 أحرف/);           // five characters
    expect(passwordProblem("abcdef")).toMatch(/رقمًا/);            // no digit
    expect(passwordProblem("123456")).toMatch(/حرفًا إنجليزيًا/);   // no letter
  });

  it("AU21 Arabic letters and Arabic-Indic digits do not count (Supabase's «letters and digits» checks a–z and 0–9), spaces are refused", () => {
    expect(passwordProblem("كلمة123")).toMatch(/حرفًا إنجليزيًا/);
    expect(passwordProblem("abc١٢٣")).toMatch(/رقمًا/);
    expect(passwordProblem("abc 123")).toMatch(/مسافات/);
  });

  it("AU22 bcrypt's limit is 72 bytes, not 72 characters, and the confirmation must match", () => {
    expect(passwordProblem("a1" + "x".repeat(PASSWORD_MAX - 2))).toBeNull();
    expect(passwordProblem("a1" + "x".repeat(PASSWORD_MAX - 1))).toMatch(/أطول/);
    expect(passwordProblem("a1" + "é".repeat(36))).toMatch(/أطول/);   // 38 characters, 74 bytes
    expect(newPasswordProblem("abc123", "abc124")).toMatch(/غير متطابقتين/);
    expect(newPasswordProblem("abc123", "abc123")).toBeNull();
    expect(newPasswordProblem("abc", "abc")).toMatch(/6 أحرف/);      // the rule first, then the match
  });
});

describe("AU — the invitation's pieces (supabase/functions/_shared/accounts.ts)", () => {
  it("AU23 the link opens «تعيين كلمة المرور» under the app's own sub-path, only over https", () => {
    expect(resetUrl("https://mswsa99-ship-it.github.io/zaaer/")).toBe("https://mswsa99-ship-it.github.io/zaaer/staff/reset-password");
    expect(resetUrl("https://mswsa99-ship-it.github.io/zaaer")).toBe("https://mswsa99-ship-it.github.io/zaaer/staff/reset-password");
    expect(resetUrl("https://hotel.example")).toBe("https://hotel.example/staff/reset-password");
    expect(resetUrl("http://hotel.example/")).toBeUndefined();
    expect(resetUrl("")).toBeUndefined();
    expect(resetUrl(undefined)).toBeUndefined();
  });

  it("AU24 Supabase Auth's refusals become the function's codes (the screen words each in Arabic)", () => {
    expect(inviteError({ message: "Email address not authorized" })).toBe("smtp_not_configured");
    expect(inviteError({ code: "email_address_not_authorized" })).toBe("smtp_not_configured");
    expect(inviteError({ code: "over_email_send_rate_limit", message: "email rate limit exceeded" })).toBe("rate_limited");
    expect(inviteError({ status: 429 })).toBe("rate_limited");
    expect(inviteError({ message: "A user with this email address has already been registered" })).toBe("already_registered");
    expect(inviteError(null)).toBe("failed");
    expect(inviteError({ message: "something else" })).toBe("failed");
  });
});

// ---------------------------------------------------------------- the demo's copy (src/demo/client.ts)
type Client = ReturnType<typeof import("../../src/demo/client")["createDemoClient"]>;
let client: Client;
let resetDemo: () => void;
const memStorage = () => {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, String(v)), removeItem: (k: string) => void m.delete(k), clear: () => m.clear(), key: () => null, length: 0 };
};
async function login(email: string) { await client.auth.signInWithPassword({ email, password: "demo" }); }
async function rpc<T = any>(fn: string, args: Record<string, unknown> = {}): Promise<{ data: T; error: { message: string } | null }> {
  const { data, error } = await client.rpc(fn, args);
  return { data: data as T, error: error as { message: string } | null };
}
async function staffId(email: string): Promise<string> {
  const r = await client.from("staff_profiles").select("id, email");
  return ((r.data as any[]) ?? []).find((x) => x.email === email).id;
}

beforeAll(async () => {
  (globalThis as any).window = globalThis;
  (globalThis as any).localStorage = memStorage();
  (globalThis as any).sessionStorage = memStorage();
  const mod = await import("../../src/demo/client");
  client = mod.createDemoClient();
  resetDemo = mod.resetDemo;
});
beforeEach(async () => { resetDemo(); await login("owner@demo.sa"); });

describe("AU — the demo keeps the same rules", () => {
  it("AU25 the account events go to the owner's «security» log; a target is allowed only for the e-mailed link and the invitation", async () => {
    expect((await rpc("fn_auth_event", { p_action: "security.signed_in" })).data).toEqual({ ok: true });
    expect((await rpc("fn_auth_event", { p_action: "staff.activated" })).error?.message).toMatch(/VALIDATION/);
    const manager = await staffId("manager@demo.sa");
    expect((await rpc("fn_auth_event", { p_action: "security.password_changed", p_target: manager })).error?.message).toMatch(/VALIDATION: target/);
    expect((await rpc("fn_auth_event", { p_action: "security.password_link_sent", p_target: manager })).data).toEqual({ ok: true });
    const log = (await client.from("audit_events").select("action, category, entity_id")).data as any[];
    const mine = log.filter((a) => String(a.action).startsWith("security."));
    expect(mine.map((a) => a.action).sort()).toEqual(["security.password_link_sent", "security.signed_in"]);
    expect(mine.every((a) => a.category === "security")).toBe(true);
    expect(mine.find((a) => a.action === "security.password_link_sent").entity_id).toBe(manager);
  });

  it("AU26 a manager sends a link to a supervisor but not to another manager or the owner; only the owner reads who has an account and invites", async () => {
    const owner = await staffId("owner@demo.sa"), supervisor = await staffId("reception@demo.sa");
    await login("manager@demo.sa");
    expect((await rpc("fn_auth_event", { p_action: "security.password_link_sent", p_target: supervisor })).data).toEqual({ ok: true });
    expect((await rpc("fn_auth_event", { p_action: "security.password_link_sent", p_target: owner })).error?.message).toMatch(/FORBIDDEN/);
    expect(((await rpc<any[]>("fn_admin_staff_auth_status")).data ?? []).length).toBeGreaterThan(3);
    expect((await rpc("fn_admin_staff_invite_target", { p_staff: supervisor })).error?.message).toMatch(/FORBIDDEN/);
    expect((await client.functions.invoke("staff-invite", { body: { staff_id: supervisor } })).data).toEqual({ ok: false, error: "forbidden" });
    await login("reception@demo.sa");
    expect((await rpc("fn_admin_staff_auth_status")).error?.message).toMatch(/FORBIDDEN/);
  });

  it("AU27 the invitation goes only to an active person without an account; the password calls keep the rule and «others» keeps this device signed in", async () => {
    const linked = await staffId("manager@demo.sa");
    expect((await client.functions.invoke("staff-invite", { body: { staff_id: linked } })).data).toEqual({ ok: false, error: "already_linked" });
    const inv = await rpc<{ ok: boolean; staff_id: string }>("fn_admin_invite_staff", { p: { email: "new.person@demo.sa", full_name: "موظف جديد", role: "supervisor", branch_ids: [(await client.from("branches").select("id")).data[0].id] } });
    expect(inv.error).toBeNull();
    expect((await client.functions.invoke("staff-invite", { body: { staff_id: inv.data.staff_id } })).data).toEqual({ ok: true });
    const log = (await client.from("audit_events").select("action, entity_id")).data as any[];
    expect(log.some((a) => a.action === "security.invite_sent" && a.entity_id === inv.data.staff_id)).toBe(true);
    expect((await client.auth.updateUser({ password: "abcdef" })).error?.message).toMatch(/0123456789/);
    expect((await client.auth.updateUser({ password: "abc123" })).error).toBeNull();
    expect((await client.auth.resetPasswordForEmail("owner@demo.sa", { redirectTo: "https://x.example/staff/reset-password" })).error).toBeNull();
    await client.auth.signOut({ scope: "others" });
    expect((await client.auth.getSession()).data.session).not.toBeNull();
    await client.auth.signOut({ scope: "global" });
    expect((await client.auth.getSession()).data.session).toBeNull();
    expect((await client.auth.updateUser({ password: "abc123" })).error?.message).toMatch(/session/i);
  });
});
