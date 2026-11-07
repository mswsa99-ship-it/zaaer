/**
 * bank-mail — reads the bank mailbox (A6, migration 0066). Each email the phone app relayed is handed whole to
 * fn_bank_ingest, which keeps the raw text first, accepts only the app's signed mail and reads the movement (A7).
 *
 * POST { action: "poll" }
 *   called by the schedule with `x-cron-key` (checked against the Vault by fn_bank_cron_ok), or by a signed-in staff
 *   member who holds «bank.manage» (the owner's «اقرأ البريد الآن») → { configured, fetched, results[], error? }
 * verify_jwt is off: the cron key or the staff member's session is checked here.
 */
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { pollMailbox } from "../_shared/bank_mail.ts";
import type { Wire } from "../_shared/imap.ts";

const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, x-client-info, apikey, content-type, x-cron-key" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "content-type": "application/json" } });

async function tls(host: string, port: number): Promise<Wire> {
  const conn = await Deno.connectTls({ hostname: host, port });
  const deadline = Date.now() + 25_000;
  return {
    async read() {
      if (Date.now() > deadline) throw new Error("IMAP_TIMEOUT");
      const buf = new Uint8Array(64 * 1024);
      const n = await conn.read(buf);
      return n === null ? null : buf.subarray(0, n);
    },
    async write(data: Uint8Array) { let off = 0; while (off < data.length) off += await conn.write(data.subarray(off)); },
    close() { try { conn.close(); } catch { /* closed */ } },
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!; const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const db = createClient(url, service, { auth: { persistSession: false } });
  const cronKey = req.headers.get("x-cron-key");
  let allowed = false;
  if (cronKey) {
    const r = await db.rpc("fn_bank_cron_ok", { p_key: cronKey });
    allowed = r.data === true;
  } else {
    const auth = req.headers.get("authorization") ?? "";
    if (auth.toLowerCase().startsWith("bearer ")) {
      const user = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { authorization: auth } }, auth: { persistSession: false } });
      const r = await user.rpc("fn_bank_poll_allowed");
      allowed = r.data === true;
    }
  }
  if (!allowed) return json({ error: "forbidden" }, 403);
  try {
    return json(await pollMailbox(db, tls));
  } catch (e) {
    console.error("bank-mail", String(e).slice(0, 200));
    return json({ error: "server_error" }, 500);
  }
});
