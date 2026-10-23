/**
 * guest-otp — sends the 6-digit «حجوزاتي» code to a guest's phone by WhatsApp (website path).
 *
 * POST { phone, client_fingerprint? } → { status: "sent" | "channel_unavailable" | "throttled" | "invalid" | "send_failed" }
 *
 * The code is created in the database (fn_guest_phone_start, service role only) and goes straight to WhatsApp; it is
 * never returned to the browser. It is sent from the WhatsApp number of the branch of the guest's latest booking
 * (branch_whatsapp_channels, set up by the owner on /admin/whatsapp), with that branch's approved Authentication
 * template. "sent" is also the answer for a phone with no bookings (nothing is sent then), so this endpoint does not
 * reveal who has a booking. A branch without a usable channel answers "channel_unavailable" and the page asks for a
 * booking number instead — never a pretend "sent".
 */
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { otpTemplatePayload, usable, waSend, type WaChannel } from "../_shared/whatsapp.ts";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ status: "invalid" }, 400); }

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  // no branch has a usable number with a code template → the page goes straight to the booking-number path
  const { count } = await db.from("branch_whatsapp_channels").select("branch_id", { count: "exact", head: true }).eq("enabled", true).not("otp_template", "is", null);
  if (!count) return json({ status: "channel_unavailable" });

  const fingerprint = String(body.client_fingerprint ?? req.headers.get("x-forwarded-for") ?? "").slice(0, 120) || null;
  const { data, error } = await db.rpc("fn_guest_phone_start", { p_phone: String(body.phone ?? ""), p_fingerprint: fingerprint });
  if (error || !data) return json({ status: "send_failed" }, 500);
  if (data.status === "invalid" || data.status === "throttled") return json({ status: data.status });
  if (data.status !== "ok") return json({ status: "sent" });          // no bookings on this phone: nothing sent, same answer

  const { data: ch } = await db.rpc("fn_whatsapp_channel", { p_branch: data.branch_id });
  const channel = ch as WaChannel | null;
  if (!usable(channel) || !channel.otp_template) return json({ status: "channel_unavailable" });

  const r = await waSend(channel, otpTemplatePayload(data.phone, data.code, channel.otp_template, channel.template_lang || "ar"));
  // the outcome is kept for the owner (no code, no full phone)
  await db.from("integration_events").insert({
    organization_id: channel.organization_id, source: "whatsapp", external_event_id: String(data.challenge_id), kind: "guest.otp",
    reference: "••••" + String(data.phone).slice(-4), state: r.ok ? "processed" : "rejected", result: r.ok ? { sent: true, branch_id: channel.branch_id } : { error: r.error, branch_id: channel.branch_id },
  });
  if (!r.ok) await db.rpc("fn_whatsapp_mark", { p_branch: channel.branch_id, p_status: "error", p_error: r.error ?? "send failed" });
  return json({ status: r.ok ? "sent" : "send_failed" });
});
