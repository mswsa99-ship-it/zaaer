/**
 * guest-otp — sends the 6-digit booking code to a guest's phone by WhatsApp.
 *
 * POST { phone, client_fingerprint? } → { status: "sent" | "channel_unavailable" | "throttled" | "invalid" | "send_failed" }
 *
 * The code is created in the database (fn_guest_phone_start, service role only) and goes straight to WhatsApp; it is
 * never returned to the browser. "sent" is also the answer for a phone with no bookings (nothing is sent then), so
 * this endpoint does not reveal who has a booking. Without WhatsApp credentials the answer is "channel_unavailable"
 * and the page asks for a booking number instead — never a pretend "sent".
 *
 * Secrets: WHATSAPP_ACCESS_TOKEN, WHATSAPP_PHONE_NUMBER_ID, WHATSAPP_OTP_TEMPLATE (an approved Authentication
 * template with a copy-code button), optional WHATSAPP_TEMPLATE_LANG (default ar), WHATSAPP_API_VERSION (default v23.0).
 */
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "content-type": "application/json" } });

/** The WhatsApp Cloud API request for an Authentication template: the code in the body and in the copy-code button. */
export function otpTemplatePayload(to: string, code: string, template: string, lang: string) {
  return {
    messaging_product: "whatsapp", to, type: "template",
    template: {
      name: template, language: { code: lang },
      components: [
        { type: "body", parameters: [{ type: "text", text: code }] },
        { type: "button", sub_type: "url", index: "0", parameters: [{ type: "text", text: code }] },
      ],
    },
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ status: "invalid" }, 400); }

  const token = Deno.env.get("WHATSAPP_ACCESS_TOKEN");
  const phoneNumberId = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID");
  const template = Deno.env.get("WHATSAPP_OTP_TEMPLATE");
  if (!token || !phoneNumberId || !template) return json({ status: "channel_unavailable" });

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const fingerprint = String(body.client_fingerprint ?? req.headers.get("x-forwarded-for") ?? "").slice(0, 120) || null;
  const { data, error } = await db.rpc("fn_guest_phone_start", { p_phone: String(body.phone ?? ""), p_fingerprint: fingerprint });
  if (error || !data) return json({ status: "send_failed" }, 500);
  if (data.status === "invalid" || data.status === "throttled") return json({ status: data.status });
  if (data.status !== "ok") return json({ status: "sent" });          // no bookings on this phone: nothing sent, same answer

  const version = Deno.env.get("WHATSAPP_API_VERSION") ?? "v23.0";
  const lang = Deno.env.get("WHATSAPP_TEMPLATE_LANG") ?? "ar";
  let ok = false; let detail = "";
  try {
    const res = await fetch(`https://graph.facebook.com/${version}/${encodeURIComponent(phoneNumberId)}/messages`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
      body: JSON.stringify(otpTemplatePayload(data.phone, data.code, template, lang)),
      signal: AbortSignal.timeout(10000),
    });
    ok = res.ok;
    if (!ok) detail = (await res.text().catch(() => "")).replace(/EAA[A-Za-z0-9]+/g, "[token]").slice(0, 300);
  } catch (e) { detail = String(e).slice(0, 200); }

  // the outcome is kept for the owner (no code, no full phone)
  const { data: org } = await db.from("organizations").select("id").limit(1).maybeSingle();
  if (org) {
    await db.from("integration_events").insert({
      organization_id: org.id, source: "whatsapp", external_event_id: String(data.challenge_id), kind: "guest.otp",
      reference: "••••" + String(data.phone).slice(-4), state: ok ? "processed" : "rejected", result: ok ? { sent: true } : { error: detail },
    });
  }
  return json({ status: ok ? "sent" : "send_failed" });
});
