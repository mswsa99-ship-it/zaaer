/**
 * whatsapp-send — staff side of WhatsApp (signed-in staff only; verify_jwt).
 *
 * POST { mode: "reply", conversation_id, text }   a supervisor answers a guest's WhatsApp thread from the inbox
 *   → { ok, delivered, error? }   the message is stored either way; "delivered" says whether WhatsApp accepted it
 *     (WhatsApp only allows free text within 24 hours of the guest's last message)
 * POST { mode: "check", branch_id }               the owner's connection test for a branch number
 *   → { ok, verified_name?, display_phone_number?, quality_rating?, matches_number?, error? }
 *
 * Who may do what is decided by the database as the caller: the conversation must be visible to them (RLS on their
 * branches), and the check runs only for the owner (fn_admin_whatsapp_channels). The service role only reads the
 * branch's credentials and records the outcome.
 */
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { textPayload, usable, waCheck, waSend, type WaChannel } from "../_shared/whatsapp.ts";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const auth = req.headers.get("authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) return json({ error: "unauthorized" }, 401);
  const url = Deno.env.get("SUPABASE_URL")!;
  const user = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "bad_json" }, 400); }

  if (body.mode === "check") {
    const { data: list, error } = await user.rpc("fn_admin_whatsapp_channels");          // owner only
    if (error) return json({ ok: false, error: "forbidden" }, 403);
    const row = (list as Array<{ branch_id: string; display_phone: string | null }>).find((b) => b.branch_id === body.branch_id);
    if (!row) return json({ ok: false, error: "not_found" }, 404);
    const { data: ch } = await admin.rpc("fn_whatsapp_channel", { p_branch: row.branch_id });
    const c = ch as WaChannel | null;
    if (!c || !c.phone_number_id || !c.access_token) return json({ ok: false, error: "channel_incomplete" });
    const r = await waCheck(c);
    const digits = (r.display_phone_number ?? "").replace(/\D/g, "");
    const matches = !!digits && !!c.display_phone && digits === c.display_phone;
    await admin.rpc("fn_whatsapp_mark", { p_branch: c.branch_id, p_status: r.ok ? "active" : "error", p_error: r.error ?? null, p_verified_name: r.verified_name ?? null });
    return json({ ...r, matches_number: matches });
  }

  // ---- a supervisor's reply ----
  const text = String(body.text ?? "").trim();
  if (!text || text.length > 4000) return json({ ok: false, error: "invalid_text" }, 400);
  const { data: conv } = await user.from("conversations").select("id, channel, branch_id, wa_contact").eq("id", String(body.conversation_id ?? "")).maybeSingle();
  if (!conv) return json({ ok: false, error: "forbidden" }, 403);
  const { data: msg, error: insErr } = await user.from("conversation_messages").insert({ conversation_id: conv.id, sender: "supervisor", content: text }).select("id").single();
  if (insErr || !msg) return json({ ok: false, error: "forbidden" }, 403);
  await admin.from("conversations").update({ last_message_at: new Date().toISOString() }).eq("id", conv.id);
  if (conv.channel !== "whatsapp" || !conv.wa_contact) return json({ ok: true, delivered: false, error: "not_whatsapp" });

  const { data: ch } = await admin.rpc("fn_whatsapp_channel", { p_branch: conv.branch_id });
  const c = ch as WaChannel | null;
  if (!usable(c)) {
    await admin.from("conversation_messages").update({ meta: { channel: "whatsapp", delivery: "failed", error: "channel_unavailable" } }).eq("id", msg.id);
    return json({ ok: true, delivered: false, error: "channel_unavailable" });
  }
  const r = await waSend(c, textPayload(conv.wa_contact, text));
  // 131047: more than 24 hours since the guest's last message — WhatsApp accepts only approved templates then
  const error = r.ok ? undefined : r.code === 131047 ? "window_closed" : (r.error ?? "send_failed");
  await admin.from("conversation_messages").update({ meta: { channel: "whatsapp", delivery: r.ok ? "sent" : "failed", ...(r.id ? { wa_id: r.id } : {}), ...(error ? { error } : {}) } }).eq("id", msg.id);
  return json({ ok: true, delivered: r.ok, error });
});
