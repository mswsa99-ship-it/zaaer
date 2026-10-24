/**
 * The reception computer's side of WhatsApp — everything behind the wa-bridge function, free of Deno so the demo's
 * WhatsApp simulator and the tests run the very same code:
 *   - who wrote (the chat, and the number behind it when WhatsApp shows it)
 *   - whether the assistant answers at all (branch off, auto-reply off, a receptionist on the chat, an old message)
 *   - what the guest's text means (a number from the last numbered options is that option)
 *   - the actions of the program: poll (heartbeat + staff replies to type), message, human (a receptionist typed in
 *     WhatsApp itself), ack (a staff reply was typed), undelivered (the assistant's reply could not be typed)
 *   - the program says which number it is linked to (`linked`); a number other than the branch's is refused, so a
 *     personal phone linked by mistake never has its chats answered or copied into the inbox
 */
import type { WaInbound } from "./whatsapp.ts";
import { dbPorts, findWaThread, type WaContact, type WaEnv } from "./wa_db.ts";
import { runWaFlow } from "./wa_flow.ts";
import { pickOption, renderPayloads, type WaMenu } from "./wa_text.ts";
import { gateInput } from "./guardrails.ts";

/** WhatsApp Web chat ids of one person: 9665…@c.us (the number) or …@lid (WhatsApp's privacy id, number hidden) */
const CHAT_RE = /^(\d{5,20})@(c\.us|lid)$/;

/** message kinds a guest sends; anything else (system notices, reactions, deleted messages, calls) is never answered */
export const GUEST_TYPES = new Set(["text", "image", "video", "audio", "voice", "document", "sticker", "location", "contacts"]);

/** a message this old (the computer was off) is recorded for staff but not answered automatically */
export const BRIDGE_REPLY_MAX_AGE_MS = 12 * 3600_000;

export function contactOf(chat: string, phone?: string | null): WaContact | null {
  const m = CHAT_RE.exec(String(chat ?? ""));
  if (!m) return null;
  if (m[2] === "c.us") return { key: m[1], phone: m[1], chatId: chat };
  const p = String(phone ?? "").replace(/\D/g, "");
  return /^\d{8,15}$/.test(p) ? { key: p, phone: p, chatId: chat } : { key: "lid:" + m[1], phone: null, chatId: chat };
}

export interface BridgeChannel {
  branch_id: string; organization_id: string; enabled: boolean; auto_reply: boolean; human_pause_minutes: number;
  status?: string; display_phone?: string | null; branch_name?: string;
}
export interface BridgeThreadState { status?: string | null; human_active_until?: string | null; wa_menu?: unknown }

/** "paused": the program asked for no answer (a chat it is keeping quiet: a flood, a loop) — recorded for staff only */
export type SilentReason = "disabled" | "auto_reply_off" | "human" | "too_old" | "paused";

/** null → the assistant answers; otherwise the message is only recorded for staff (and stays unread in WhatsApp) */
export function silentReason(ch: BridgeChannel, thread: BridgeThreadState | null, ts: number | null | undefined, now = Date.now()): SilentReason | null {
  if (!ch.enabled) return "disabled";
  if (!ch.auto_reply) return "auto_reply_off";
  if (thread?.human_active_until && Date.parse(thread.human_active_until) > now) return "human";
  if (ts && now - ts > BRIDGE_REPLY_MAX_AGE_MS) return "too_old";
  return null;
}

export interface BridgeIncoming { id: string; chat: string; phone?: string | null; name?: string | null; type: string; text: string; ts?: number | null }

/** the message as the conversation flow reads it; a choice from the last numbered options becomes that option */
export function toInbound(msg: BridgeIncoming, contact: WaContact, menu: unknown, now = Date.now()): WaInbound {
  const type = msg.type === "text" ? "text" : msg.type;
  const text = String(msg.text ?? "").slice(0, 2000);
  if (type === "text") {
    const opt = pickOption(text, isMenu(menu) ? menu : null, now);
    if (opt) return { phoneNumberId: "web", from: contact.key, id: msg.id, type: "interactive", text: opt.title, replyId: opt.id, name: msg.name ?? undefined };
  }
  return { phoneNumberId: "web", from: contact.key, id: msg.id, type, text, name: msg.name ?? undefined };
}

function isMenu(x: unknown): x is WaMenu {
  return !!x && typeof x === "object" && Array.isArray((x as WaMenu).options) && typeof (x as WaMenu).at === "string";
}

/** sha-256 hex — message ids are stored hashed (a WhatsApp Web id carries the sender's number) */
export async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ---------------------------------------------------------------------------
// The program's requests (wa-bridge)
// ---------------------------------------------------------------------------
// deno-lint-ignore no-explicit-any
type Db = any;
export interface BridgeResult { status: number; body: Record<string, unknown> }
export interface BridgeOptions { sleep?: (ms: number) => Promise<void> }

const STATUSES = new Set(["starting", "qr", "connected", "disconnected", "stopped"]);
/** guest messages one branch may hand in per minute (a stolen key cannot be used to sweep the bookings) */
export const BRANCH_PER_MINUTE = 120;
const ok = (body: Record<string, unknown>, status = 200): BridgeResult => ({ status, body });

const digits = (s: unknown) => String(s ?? "").replace(/\D/g, "");

/** the number the program says it is linked to, when it is not the branch's own (null: same number, or unknown) */
export function wrongNumber(ch: Pick<BridgeChannel, "display_phone">, linked: unknown): string | null {
  const l = digits(linked), b = digits(ch.display_phone);
  return l && b && l !== b ? l : null;
}

export async function handleBridge(db: Db, key: string, body: Record<string, unknown>, env: WaEnv, opts: BridgeOptions = {}): Promise<BridgeResult> {
  if (!/^zb_[0-9a-f]{64}$/.test(key)) return ok({ error: "bad_key" }, 401);
  const { data: chData } = await db.rpc("fn_wa_bridge_auth", { p_key: key });
  const ch = chData as BridgeChannel | null;
  if (!ch) return ok({ error: "bad_key" }, 401);                // unknown, replaced, or the branch is not in bridge mode
  // a phone other than the branch's is linked (a receptionist scanned with a personal phone): nothing is taken from it
  if ((body.action === "message" || body.action === "human") && wrongNumber(ch, body.linked)) return ok({ error: "wrong_number" }, 409);
  switch (body.action) {
    case "poll": return bridgePoll(db, ch, body, opts);
    case "message": return bridgeMessage(db, ch, body, env);
    case "human": return bridgeHuman(db, ch, body, env);
    case "ack": {
      const { data } = await db.rpc("fn_wa_bridge_ack", { p_branch: ch.branch_id, p_id: String(body.id ?? ""), p_ok: body.ok === true,
        p_wa_id: body.wa_id ? String(body.wa_id).slice(0, 200) : null, p_error: body.error ? String(body.error).slice(0, 200) : null });
      return ok({ ok: data === true });
    }
    case "undelivered": return bridgeUndelivered(db, ch, body);
    default: return ok({ error: "unknown_action" }, 400);
  }
}

async function bridgePoll(db: Db, ch: BridgeChannel, body: Record<string, unknown>, opts: BridgeOptions): Promise<BridgeResult> {
  const status = String(body.status ?? "");
  if (!STATUSES.has(status)) return ok({ error: "bad_status" }, 400);
  const { data: beat, error } = await db.rpc("fn_wa_bridge_beat", { p_branch: ch.branch_id, p_status: status,
    p_phone: body.phone ? String(body.phone).slice(0, 30) : null, p_name: body.name ? String(body.name).slice(0, 80) : null,
    p_version: body.version ? String(body.version).slice(0, 40) : null, p_detail: body.detail ? String(body.detail).slice(0, 300) : null });
  if (error) return ok({ error: "server_error" }, 500);
  const head = { ok: true, enabled: beat?.enabled ?? ch.enabled, auto_reply: beat?.auto_reply ?? ch.auto_reply, branch_name: ch.branch_name ?? null, display_phone: ch.display_phone ?? null };
  if (status !== "connected") return ok({ ...head, outbox: [] });     // nothing can be typed until WhatsApp is linked

  // long poll: a staff reply from the inbox goes out within seconds, at one call per ~25 s when idle
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const deadline = Date.now() + Math.min(Math.max(Number(body.wait) || 0, 0), 25) * 1000;
  for (;;) {
    const { data: items } = await db.rpc("fn_wa_bridge_poll", { p_branch: ch.branch_id, p_limit: 5 });
    if ((items ?? []).length || Date.now() + 2500 > deadline) return ok({ ...head, outbox: items ?? [] });
    await sleep(2500);
  }
}

function incoming(body: Record<string, unknown>): BridgeIncoming | null {
  const id = String(body.id ?? "");
  if (!id || id.length > 300) return null;
  return {
    id, chat: String(body.chat ?? ""), phone: body.phone ? String(body.phone) : null, name: body.name ? String(body.name).slice(0, 80) : null,
    type: String(body.type ?? "text"), text: String(body.text ?? "").slice(0, 4000), ts: Number(body.ts) > 0 ? Number(body.ts) : null,
  };
}

/** each WhatsApp message once (the program may hand one in again after a restart); kept hashed, never the raw id */
const dedupeKey = async (id: string) => "web:" + (await sha256Hex(id)).slice(0, 40);
async function firstTime(db: Db, branchId: string, id: string): Promise<boolean> {
  const { error } = await db.from("whatsapp_inbound_messages").insert({ wa_message_id: await dedupeKey(id), branch_id: branchId });
  return !error;
}
/** handling failed half-way: the message may be handed in again (the program retries), so it is not "seen" yet */
async function forget(db: Db, branchId: string, id: string): Promise<void> {
  await db.from("whatsapp_inbound_messages").delete().eq("wa_message_id", await dedupeKey(id)).eq("branch_id", branchId);
}

async function bridgeMessage(db: Db, ch: BridgeChannel, body: Record<string, unknown>, env: WaEnv): Promise<BridgeResult> {
  const msg = incoming(body);
  const contact = msg ? contactOf(msg.chat, msg.phone) : null;
  if (!msg || !contact) return ok({ error: "bad_message" }, 400);
  if (!GUEST_TYPES.has(msg.type)) return ok({ ok: true, replies: [], silent: "ignored" });
  if (!ch.enabled) return ok({ ok: true, replies: [], silent: "disabled" });   // WhatsApp switched off for this branch

  const since = new Date(Date.now() - 60_000).toISOString();
  const { count } = await db.from("whatsapp_inbound_messages").select("wa_message_id", { count: "exact", head: true }).eq("branch_id", ch.branch_id).gte("received_at", since);
  if ((count ?? 0) >= BRANCH_PER_MINUTE) return ok({ ok: false, error: "rate_limited" }, 429);
  if (!(await firstTime(db, ch.branch_id, msg.id))) return ok({ ok: true, replies: [], duplicate: true });

  try {
    const collected: Array<Record<string, unknown>> = [];
    const ports = dbPorts(db, ch, contact, async (p) => { collected.push(p); return { ok: true }; }, env);
    const thread = await findWaThread(db, ch.branch_id, contact.key);
    const silent: SilentReason | null = body.answer === false ? "paused" : silentReason(ch, thread, msg.ts);
    if (silent) {
      // recorded for staff, nothing typed: the chat stays unread in WhatsApp for the receptionist
      const t = thread ?? await ports.newThread();
      await ports.save(t.id, "guest", gateInput(msg.type === "text" ? msg.text : `[${msg.type}]${msg.text ? " " + msg.text : ""}`).redacted,
        { channel: "whatsapp", wa_type: msg.type, unanswered: silent });
      await db.from("conversations").update({ last_message_at: new Date().toISOString(), wa_chat_id: contact.chatId }).eq("id", t.id);
      return ok({ ok: true, replies: [], silent });
    }

    // the assistant's last message before this turn (database time, so no clock is compared with another)
    const before = thread ? await lastAssistantAt(db, thread.id) : null;
    await runWaFlow(toInbound(msg, contact, thread?.wa_menu ?? null), ports);
    const { texts, options } = renderPayloads(collected);
    const threadId = ports.lastThreadId();
    if (threadId) {
      await db.from("conversations").update({ wa_chat_id: contact.chatId, wa_menu: options.length ? { at: new Date().toISOString(), options } : null }).eq("id", threadId);
    }
    // `turn` lets the program say these replies were not typed after all (action "undelivered")
    return ok({ ok: true, replies: texts, ...(threadId && texts.length ? { turn: { thread: threadId, after: threadId === thread?.id ? before : null } } : {}) });
  } catch (e) {
    await forget(db, ch.branch_id, msg.id).catch(() => {});
    throw e;
  }
}

async function lastAssistantAt(db: Db, threadId: string): Promise<string | null> {
  const { data } = await db.from("conversation_messages").select("created_at").eq("conversation_id", threadId).eq("sender", "assistant")
    .order("created_at", { ascending: false }).limit(1).maybeSingle();
  return (data as { created_at?: string } | null)?.created_at ?? null;
}

/** the program could not type this turn's replies: the inbox shows them as not delivered, and their numbered options
 *  no longer stand (a "1" from the guest must not pick an option the guest never saw) */
async function bridgeUndelivered(db: Db, ch: BridgeChannel, body: Record<string, unknown>): Promise<BridgeResult> {
  const turn = (body.turn ?? {}) as { thread?: unknown; after?: unknown };
  const thread = String(turn.thread ?? ""), after = turn.after == null ? null : String(turn.after);
  if (!/^[0-9a-f-]{36}$/i.test(thread) || (after !== null && !Number.isFinite(Date.parse(after)))) return ok({ error: "bad_turn" }, 400);
  const { data: cv } = await db.from("conversations").select("id").eq("id", thread).eq("branch_id", ch.branch_id).maybeSingle();
  if (!cv) return ok({ error: "bad_turn" }, 400);                                // another branch's conversation: refused
  const reason = String(body.reason ?? "send_failed").replace(/[^a-z_]/g, "").slice(0, 40) || "send_failed";
  let q = db.from("conversation_messages").select("id, meta").eq("conversation_id", thread).eq("sender", "assistant");
  if (after !== null) q = q.gt("created_at", after);
  const { data: rows } = await q.order("created_at", { ascending: true }).limit(10);
  for (const r of (rows ?? []) as Array<{ id: string; meta: Record<string, unknown> | null }>) {
    await db.from("conversation_messages").update({ meta: { ...(r.meta ?? {}), channel: "whatsapp", delivery: "failed", error: reason } }).eq("id", r.id);
  }
  await db.from("conversations").update({ wa_menu: null }).eq("id", thread);
  return ok({ ok: true, marked: (rows ?? []).length });
}

async function bridgeHuman(db: Db, ch: BridgeChannel, body: Record<string, unknown>, env: WaEnv): Promise<BridgeResult> {
  const msg = incoming(body);
  const contact = msg ? contactOf(msg.chat, msg.phone) : null;
  if (!msg || !contact) return ok({ error: "bad_message" }, 400);
  if (!(await firstTime(db, ch.branch_id, msg.id))) return ok({ ok: true, duplicate: true });
  const t = (await findWaThread(db, ch.branch_id, contact.key)) ?? await dbPorts(db, ch, contact, async () => ({ ok: true }), env).newThread();
  await db.from("conversation_messages").insert({ conversation_id: t.id, sender: "supervisor", content: msg.text || `[${msg.type}]`,
    meta: { channel: "whatsapp", via: "whatsapp_app", delivery: "sent" } });
  const until = new Date(Date.now() + Math.max(5, ch.human_pause_minutes || 60) * 60_000).toISOString();
  await db.from("conversations").update({ human_active_until: until, last_message_at: new Date().toISOString(), wa_chat_id: contact.chatId, wa_menu: null }).eq("id", t.id);
  return ok({ ok: true, human_active_until: until });
}
