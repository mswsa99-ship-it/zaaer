/**
 * The WhatsApp conversation's ports on the database (service role): the branch's threads with this sender, the
 * guest's bookings found by the sender's verified number, and the reception assistant (ai-reception).
 *
 * whatsapp-webhook (Cloud API) and wa-bridge (the reception computer) differ only in how a message leaves (`send`)
 * and in what is known about the sender (`contact`); the conversation itself is wa_flow.ts.
 */
import { WA_THREAD_HOURS, type WaBooking, type WaFlowPorts, type WaThread } from "./wa_flow.ts";

export interface WaContact {
  /** conversations.wa_contact: the international number, or "lid:<id>" when WhatsApp hides the number */
  key: string;
  /** the number WhatsApp verified (digits), when known — the guest's bookings are found by it */
  phone: string | null;
  /** the WhatsApp Web chat the replies go to (reception computer) */
  chatId?: string | null;
}
export interface WaBranch { branch_id: string; organization_id: string }
export interface WaEnv { appBaseUrl: string; supabaseUrl: string; serviceKey: string; fetcher?: typeof fetch }

// deno-lint-ignore no-explicit-any
type Db = any;

/** the sender's open thread with the branch (a message in the last WA_THREAD_HOURS), or null */
export async function findWaThread(db: Db, branchId: string, contactKey: string): Promise<(WaThread & { human_active_until?: string | null; wa_menu?: unknown; status?: string }) | null> {
  const since = new Date(Date.now() - WA_THREAD_HOURS * 3600_000).toISOString();
  const { data } = await db.from("conversations").select("id, guest_token, status, human_active_until, wa_menu")
    .eq("branch_id", branchId).eq("wa_contact", contactKey).neq("status", "closed").gte("last_message_at", since)
    .order("last_message_at", { ascending: false }).limit(1).maybeSingle();
  return data ?? null;
}

export function dbPorts(db: Db, ch: WaBranch, c: WaContact, send: (payload: Record<string, unknown>) => Promise<unknown>, env: WaEnv): WaFlowPorts & { lastThreadId(): string | null } {
  const now = () => new Date().toISOString();
  let last: string | null = null;
  return {
    appBaseUrl: env.appBaseUrl.replace(/\/$/, ""),
    lastThreadId: () => last,
    async bookingUrl() {
      const { data } = await db.rpc("fn_public_branch", { p_branch: ch.branch_id });
      return (data as { booking_platform_url?: string | null } | null)?.booking_platform_url ?? null;
    },

    async findThread() {
      const t = await findWaThread(db, ch.branch_id, c.key);
      if (t) last = t.id;
      return t ? { id: t.id, guest_token: t.guest_token } : null;
    },
    async newThread() {
      const { data } = await db.from("conversations")
        .insert({ channel: "whatsapp", status: "active", branch_id: ch.branch_id, wa_contact: c.key, wa_chat_id: c.chatId ?? null,
                  client_fingerprint: "wa:" + c.key.slice(-4), last_message_at: now() })
        .select("id, guest_token").single();
      last = (data as WaThread).id;
      return data as WaThread;
    },
    async closeThread(id) { await db.from("conversations").update({ status: "closed", wa_menu: null }).eq("id", id); },
    async touch(id) { await db.from("conversations").update({ last_message_at: now() }).eq("id", id); },
    async save(id, sender, content, meta) { last = id; await db.from("conversation_messages").insert({ conversation_id: id, sender, content, meta }); },

    async bookings() {
      if (!c.phone) return { token: "", list: [] };                 // a hidden number: nothing is looked up
      const { data: token } = await db.rpc("fn_whatsapp_phone_session", { p_phone: c.phone });
      if (!token) return { token: "", list: [] };
      const { data } = await db.rpc("fn_guest_phone_reservations", { p_token: token });
      return { token: String(token), list: ((data?.reservations ?? []) as WaBooking[]) };
    },
    async openBooking(token, internalRef) {
      if (!token) return null;
      const { data, error } = await db.rpc("fn_guest_phone_open", { p_token: token, p_internal_ref: internalRef });
      return error || !data?.token ? null : String(data.token);
    },
    async bindThread(id, guestToken) { await db.from("conversations").update({ guest_token: guestToken, last_message_at: now() }).eq("id", id); },
    async recentBot(id, withinMs) {
      const { data } = await db.from("conversation_messages").select("content").eq("conversation_id", id).eq("sender", "assistant")
        .gte("created_at", new Date(Date.now() - withinMs).toISOString()).order("created_at", { ascending: false }).limit(5);
      return ((data ?? []) as Array<{ content: string }>).map((r) => r.content);
    },

    async ask(thread, message) {
      try {
        const res = await (env.fetcher ?? fetch)(`${env.supabaseUrl}/functions/v1/ai-reception`, {
          method: "POST",
          headers: { "content-type": "application/json", authorization: `Bearer ${env.serviceKey}`, apikey: env.serviceKey },
          body: JSON.stringify({ message, conversation_id: thread.id, guest_token: thread.guest_token, branch_id: ch.branch_id, channel: "whatsapp", client_fingerprint: "wa:" + c.key.slice(-4) }),
          signal: AbortSignal.timeout(25000),
        });
        const out = await res.json();
        return out?.reply ? { reply: String(out.reply), actions: Array.isArray(out.actions) ? out.actions : [] } : null;
      } catch {
        return null;
      }
    },

    send,
  };
}
