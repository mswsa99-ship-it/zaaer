/**
 * wa-bridge — the reception computer's WhatsApp (WhatsApp Web, no Meta API). Called only by the bridge program
 * (bridge/ in this repository), authenticated by the branch's bridge key in `x-bridge-key` (fn_wa_bridge_auth; only
 * its SHA-256 is stored). verify_jwt is off: the key is the credential, and it works for one branch only.
 *
 * POST { action: "poll", status, phone?, name?, version?, detail?, wait? }
 *   heartbeat + the staff replies waiting to be typed (long poll, up to `wait` seconds, ≤ 25)
 *   → { ok, enabled, auto_reply, branch_name, display_phone, outbox: [{ id, chat_id, text }] }
 * POST { action: "message", id, chat, phone?, name?, type, text, ts? }      a guest wrote
 *   → { ok, replies: string[], silent?: reason, duplicate?: true }
 *     The same conversation as on the Cloud API (_shared/wa_flow.ts + ai-reception), typed as plain text with
 *     numbered options (_shared/wa_text.ts). "silent": recorded for staff only — the owner switched auto-reply off,
 *     a receptionist is handling this chat, or the message is from long ago.
 * POST { action: "human", id, chat, phone?, text }   a receptionist answered in WhatsApp itself → the assistant steps
 *   back in that chat for the branch's pause, and the reply appears in the inbox → { ok }
 * POST { action: "ack", id, ok, wa_id?, error? }      a staff reply was typed (or could not be) → { ok }
 *
 * The logic is _shared/wa_bridge.ts (the demo's WhatsApp simulator runs the same code against its own store).
 */
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { handleBridge } from "../_shared/wa_bridge.ts";

const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method" }, 405);
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "bad_json" }, 400); }
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  try {
    const r = await handleBridge(db, req.headers.get("x-bridge-key") ?? "", body ?? {}, {
      appBaseUrl: Deno.env.get("APP_BASE_URL") ?? "", supabaseUrl: Deno.env.get("SUPABASE_URL")!, serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    });
    return json(r.body, r.status);
  } catch (e) {
    console.error("wa-bridge", String(e).slice(0, 300));
    return json({ error: "server_error" }, 500);
  }
});
