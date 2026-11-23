/**
 * staff-invite — the owner invites a staff member by e-mail (signed-in staff only; verify_jwt).
 *
 * POST { staff_id }  → { ok: true } | { ok: false, error }
 *   The database decides, as the caller, who may invite and to which address (fn_admin_staff_invite_target: the owner,
 *   a staff member of their own organisation). The invitation is Supabase Auth's own e-mail; its link opens the app's
 *   «تعيين كلمة المرور» page, where the person chooses their password — nobody else ever knows it — and their first
 *   sign-in links the account to the profile the owner prepared (fn_claim_staff_profile). The event is recorded as
 *   the caller (fn_auth_event «security.invite_sent»).
 *
 * Errors: forbidden (not the owner), not_found, inactive, already_linked (the person has an account: send a reset
 * link instead), already_registered (an account exists for the e-mail but is not linked yet), smtp_not_configured
 * (Supabase's built-in mail sends only to the project's team until a custom SMTP is set), rate_limited, failed.
 */
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { projectKey } from "../_shared/keys.ts";
import { inviteError, resetUrl } from "../_shared/accounts.ts";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-correlation-id, x-client-source", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const auth = req.headers.get("authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) return json({ ok: false, error: "unauthorized" }, 401);
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ ok: false, error: "bad_json" }, 400); }
  const staffId = typeof body.staff_id === "string" && /^[0-9a-f-]{36}$/i.test(body.staff_id) ? body.staff_id : null;
  if (!staffId) return json({ ok: false, error: "staff_id" }, 400);

  const url = Deno.env.get("SUPABASE_URL")!;
  const headers: Record<string, string> = { Authorization: auth };
  for (const h of ["x-correlation-id", "x-client-source"]) { const v = req.headers.get(h); if (v) headers[h] = v; }
  const user = createClient(url, projectKey("publishable"), { global: { headers }, auth: { persistSession: false } });
  const admin = createClient(url, projectKey("secret"), { auth: { persistSession: false } });

  const { data: target, error: te } = await user.rpc("fn_admin_staff_invite_target", { p_staff: staffId });
  if (te) return json({ ok: false, error: /FORBIDDEN/.test(te.message) ? "forbidden" : /NOT_FOUND/.test(te.message) ? "not_found" : "failed" }, /FORBIDDEN/.test(te.message) ? 403 : 200);
  const t = target as { email: string; full_name: string; is_active: boolean; linked: boolean };
  if (!t.is_active) return json({ ok: false, error: "inactive" });
  if (t.linked) return json({ ok: false, error: "already_linked" });

  const redirectTo = resetUrl(Deno.env.get("APP_BASE_URL"));
  const { error: ie } = await admin.auth.admin.inviteUserByEmail(t.email, { redirectTo, data: { full_name: t.full_name } });
  if (ie) return json({ ok: false, error: inviteError(ie) });
  await user.rpc("fn_auth_event", { p_action: "security.invite_sent", p_target: staffId });
  return json({ ok: true });
});
