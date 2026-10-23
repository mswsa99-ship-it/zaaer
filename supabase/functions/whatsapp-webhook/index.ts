/**
 * whatsapp-webhook — the whole guest reception inside WhatsApp, one number per branch (Cloud API mode).
 *
 * GET  ?hub.mode=subscribe&hub.verify_token=…&hub.challenge=…   Meta's subscription check (the branch's verify token)
 * POST (Meta)                                                    guest messages, signed with the branch's app secret
 *
 * Each WhatsApp message id is handled once (Meta retries). The conversation itself is _shared/wa_flow.ts — the same
 * code the reception computer (wa-bridge), the demo's WhatsApp simulator and the unit tests run; this file only
 * connects it to the database (_shared/wa_db.ts), to ai-reception and to the WhatsApp Cloud API. The answer to Meta is
 * immediate (200); the reply is sent in the background. A branch set to the reception computer ignores Meta.
 */
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { parseInbound, usable, verifySignature, waSend, type WaChannel, type WaInbound } from "../_shared/whatsapp.ts";
import { runWaFlow } from "../_shared/wa_flow.ts";
import { dbPorts } from "../_shared/wa_db.ts";

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  // ---- Meta's subscription check ----
  if (req.method === "GET") {
    const token = url.searchParams.get("hub.verify_token") ?? "";
    if (url.searchParams.get("hub.mode") !== "subscribe" || token.length < 16) return new Response("forbidden", { status: 403 });
    const { data: ch } = await db.rpc("fn_whatsapp_channel", { p_verify_token: token });
    if (!ch) return new Response("forbidden", { status: 403 });
    return new Response(url.searchParams.get("hub.challenge") ?? "", { status: 200, headers: { "content-type": "text/plain" } });
  }
  if (req.method !== "POST") return new Response("method", { status: 405 });

  const raw = await req.text();
  let body: unknown;
  try { body = JSON.parse(raw); } catch { return new Response("bad json", { status: 400 }); }
  const phoneNumberId = String((body as any)?.entry?.[0]?.changes?.[0]?.value?.metadata?.phone_number_id ?? ""); // deno-lint-ignore no-explicit-any
  if (!phoneNumberId) return new Response("ok");
  const { data: chData } = await db.rpc("fn_whatsapp_channel", { p_phone_number_id: phoneNumberId });
  const channel = chData as WaChannel | null;
  if (!channel) return new Response("ok");                       // a number this system does not manage
  if (!(await verifySignature(channel.app_secret ?? "", raw, req.headers.get("x-hub-signature-256")))) {
    return new Response("bad signature", { status: 401 });
  }
  if (channel.mode === "web_bridge") return new Response("ok");   // this branch answers from the reception computer
  if (channel.status === "configured") await db.rpc("fn_whatsapp_mark", { p_branch: channel.branch_id, p_status: "active" });
  if (!usable(channel)) return new Response("ok");                // switched off by the owner: nothing is answered

  const messages = parseInbound(body).filter((m) => m.phoneNumberId === phoneNumberId);
  const work = (async () => { for (const m of messages) { try { await handle(db, channel, m); } catch (e) { console.error("wa handle", String(e).slice(0, 200)); } } })();
  const rt = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(work); else await work;
  return new Response("ok");
});

// deno-lint-ignore no-explicit-any
type Db = any;

async function handle(db: Db, ch: WaChannel, m: WaInbound) {
  // each WhatsApp message once (Meta re-delivers when an answer is slow)
  const { error: dup } = await db.from("whatsapp_inbound_messages").insert({ wa_message_id: m.id, branch_id: ch.branch_id });
  if (dup) return;
  const send = async (payload: Record<string, unknown>) => {
    const r = await waSend(ch, payload);
    if (!r.ok) {
      await db.from("integration_events").insert({ organization_id: ch.organization_id, source: "whatsapp", external_event_id: m.id, kind: "whatsapp.outbound",
        reference: "••••" + m.from.slice(-4), state: "rejected", result: { error: r.error, code: r.code, branch_id: ch.branch_id } });
      if (r.status === 401 || r.code === 190) await db.rpc("fn_whatsapp_mark", { p_branch: ch.branch_id, p_status: "error", p_error: r.error ?? "auth" });
    }
    return r;
  };
  const ports = dbPorts(db, ch, { key: m.from, phone: m.from }, send, {
    appBaseUrl: Deno.env.get("APP_BASE_URL") ?? "", supabaseUrl: Deno.env.get("SUPABASE_URL")!, serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  });
  await runWaFlow(m, ports);
}
