/**
 * The reception computer's WhatsApp, as an employee would work it — the decisions, with WhatsApp and the server
 * passed in (so the tests drive it with fakes):
 *
 *  - every new message from a guest (one-to-one chats only) goes to the server (wa-bridge), in order per chat;
 *    the answer is typed back like a person: mark as read, "typing…", a pause that grows with the length, send
 *  - a silent answer (auto-reply off, a receptionist on the chat, an old message) leaves the chat UNREAD for staff
 *  - what a receptionist types in WhatsApp itself (phone or this window) is reported: the assistant then steps back
 *    in that chat, and the reply appears in the inbox. The program's own messages are recognised and not reported.
 *  - staff replies from the inbox are picked up (poll) and typed the same way, then confirmed (ack)
 *  - unread chats waiting when the program starts are answered (recent messages only)
 *
 * Limits keep the number safe: replies only to people who wrote, at human speed, at most a few per chat per minute
 * and 20 per minute in all; a chat that floods (another bot, a loop) is left to staff for a while.
 */

/** chats that are one person: their number (…@c.us) or WhatsApp's privacy id (…@lid) */
export const PERSON_CHAT = /^\d{5,20}@(c\.us|lid)$/;
/** whatsapp-web.js message types → what the server understands; anything else is never answered */
export const TYPE_MAP = {
  chat: "text", image: "image", video: "video", audio: "audio", ptt: "voice", document: "document",
  sticker: "sticker", location: "location", vcard: "contacts", multi_vcard: "contacts",
};
export const DEFAULTS = {
  maxAgeMs: 12 * 3600_000,          // older messages (computer was off) are left to staff
  perChatPerMinute: 6,              // bot messages per chat per minute
  globalPerMinute: 20,              // bot messages per minute in all
  floodMessages: 12,                // more than this many guest messages …
  floodWindowMs: 2 * 60_000,        // … in this window → the chat is left to staff …
  floodPauseMs: 15 * 60_000,        // … for this long
  catchUpPerChat: 5,
  pollWaitS: 25,
};

const sleepReal = (ms) => new Promise((r) => setTimeout(r, ms));

export class Bridge {
  /**
   * @param {{ api: any, log: any, version?: string, now?: () => number, sleep?: (ms: number) => Promise<void>, random?: () => number, limits?: Partial<typeof DEFAULTS> }} o
   */
  constructor({ api, log, version = "dev", now = () => Date.now(), sleep = sleepReal, random = Math.random, limits = {} }) {
    this.api = api; this.log = log; this.version = version; this.now = now; this.sleep = sleep; this.random = random;
    this.limits = { ...DEFAULTS, ...limits };
    this.wa = null;
    this.status = "starting"; this.detail = null;
    this.me = { phone: null, name: null };
    this.server = { enabled: null, auto_reply: null };
    this.keyRejected = false;
    this.queues = new Map();          // chatId → tail of that chat's work
    this.pendingOwn = new Map();      // chatId + text → count of messages being typed by the program
    this.ownIds = new Set();          // ids of messages the program sent
    this.inbound = new Map();         // chatId → recent guest message times
    this.floodUntil = new Map();
    this.sentAt = [];                 // all bot messages in the last minute
    this.sentPerChat = new Map();
    this.phones = new Map();          // @lid → number (or null)
    this.stopped = false;
  }

  attach(wa) { this.wa = wa; }
  setMe(me) { this.me = { phone: me?.phone ?? null, name: me?.name ?? null }; }
  setStatus(status, detail = null) {
    if (this.status === status && this.detail === detail) return;
    this.status = status; this.detail = detail;
    this.log.info(`الحالة: ${STATUS_AR[status] ?? status}${detail ? ` (${detail})` : ""}`, `Status: ${STATUS_EN[status] ?? status}${detail ? ` (${detail})` : ""}`);
    this.beatSoon = true;
  }

  // ---------------------------------------------------------------- guest messages
  /** a message arrived (whatsapp-web.js "message", or found unread at start) */
  onIncoming(msg) {
    if (!this.answerable(msg)) return Promise.resolve();
    const chat = msg.chatId;
    const t = this.now();
    if ((this.floodUntil.get(chat) ?? 0) > t) return Promise.resolve();
    const times = (this.inbound.get(chat) ?? []).filter((x) => t - x < this.limits.floodWindowMs);
    times.push(t);
    this.inbound.set(chat, times);
    if (times.length > this.limits.floodMessages) {
      this.floodUntil.set(chat, t + this.limits.floodPauseMs);
      this.log.warn(`محادثة ${mask(chat)} أرسلت رسائل كثيرة بسرعة؛ تُترك للموظف ${Math.round(this.limits.floodPauseMs / 60000)} دقيقة.`, `Chat ${mask(chat)} is flooding; left to staff for ${Math.round(this.limits.floodPauseMs / 60000)} min.`);
      return Promise.resolve();
    }
    return this.enqueue(chat, () => this.handle(msg));
  }

  answerable(msg) {
    if (!msg || msg.fromMe || !msg.id || !PERSON_CHAT.test(msg.chatId ?? "")) return false;   // groups, status, channels, broadcasts
    if (msg.isStatus || msg.broadcast) return false;
    if (!TYPE_MAP[msg.type]) return false;                                                      // system notices, reactions, deleted …
    if (msg.timestamp && this.now() - msg.timestamp * 1000 > this.limits.maxAgeMs) return false;
    return true;
  }

  async handle(msg) {
    if (this.keyRejected || this.stopped) return;
    const phone = await this.phoneOf(msg.chatId);
    let res;
    try {
      res = await this.withRetry(() => this.api.message({ id: msg.id, chat: msg.chatId, phone, name: msg.name ?? null, type: TYPE_MAP[msg.type], text: msg.body ?? "", ts: msg.timestamp ? msg.timestamp * 1000 : null }));
    } catch (e) {
      this.serverError(e, "message");
      return;                                                     // left unread: staff see it in WhatsApp
    }
    const replies = Array.isArray(res?.replies) ? res.replies.filter((x) => typeof x === "string" && x.trim()) : [];
    if (!replies.length) {
      if (res?.silent) this.log.info(`رسالة من ${mask(msg.chatId)} سُجّلت للموظفين دون رد آلي (${SILENT_AR[res.silent] ?? res.silent}).`, `Message from ${mask(msg.chatId)} left for staff (${res.silent}).`);
      return;
    }
    await this.safe(() => this.wa.markSeen(msg.chatId));
    for (const text of replies) {
      const ok = await this.type(msg.chatId, text);
      if (!ok) break;
    }
  }

  /** types one message into a chat like a person; false when it was not sent */
  async type(chatId, text) {
    if (!(await this.slot(chatId))) return false;
    await this.safe(() => this.wa.typing(chatId));
    await this.sleep(this.typingDelay(text));
    const key = chatId + "\u0000" + text;
    this.pendingOwn.set(key, (this.pendingOwn.get(key) ?? 0) + 1);
    try {
      const sent = await this.wa.sendText(chatId, text);
      if (sent?.id) this.remember(sent.id);
      this.sentAt.push(this.now());
      const per = this.sentPerChat.get(chatId) ?? []; per.push(this.now()); this.sentPerChat.set(chatId, per);
      return sent?.id ?? true;
    } catch (e) {
      this.unpend(key);
      this.log.error(`تعذّر إرسال رسالة إلى ${mask(chatId)}: ${short(e)}`, `Could not send to ${mask(chatId)}: ${short(e)}`);
      return false;
    } finally {
      await this.safe(() => this.wa.clearTyping(chatId));
    }
  }

  typingDelay(text) {
    const base = 1200 + 35 * String(text).length;
    const jitter = 0.85 + this.random() * 0.3;
    return Math.round(Math.min(7000, base) * jitter);
  }

  /** waits for room under the limits; false if this chat already had its share (a loop) */
  async slot(chatId) {
    const minute = () => this.now() - 60_000;
    const per = (this.sentPerChat.get(chatId) ?? []).filter((x) => x > minute());
    this.sentPerChat.set(chatId, per);
    if (per.length >= this.limits.perChatPerMinute) {
      this.floodUntil.set(chatId, this.now() + this.limits.floodPauseMs);
      this.log.warn(`تجاوزت محادثة ${mask(chatId)} حد الردود في الدقيقة؛ تُترك للموظف.`, `Chat ${mask(chatId)} reached the replies-per-minute limit; left to staff.`);
      return false;
    }
    for (;;) {
      this.sentAt = this.sentAt.filter((x) => x > minute());
      if (this.sentAt.length < this.limits.globalPerMinute) return true;
      await this.sleep(Math.max(500, this.sentAt[0] + 60_000 - this.now()));
    }
  }

  // ---------------------------------------------------------------- what staff type in WhatsApp itself
  /** whatsapp-web.js "message_create" with fromMe: the program's own message, or a receptionist's */
  async onOwnMessage(msg) {
    if (!msg?.fromMe || !msg.id || !PERSON_CHAT.test(msg.chatId ?? "") || !TYPE_MAP[msg.type]) return;
    if (this.isOwn(msg)) return;
    await this.sleep(1500);                                          // the send may still be returning its id
    if (this.isOwn(msg)) return;
    if (this.keyRejected || this.stopped) return;
    const phone = await this.phoneOf(msg.chatId);
    try {
      await this.withRetry(() => this.api.human({ id: msg.id, chat: msg.chatId, phone, type: TYPE_MAP[msg.type], text: msg.body ?? "" }));
      this.log.info(`رد موظف من واتساب في ${mask(msg.chatId)}: المساعد يتوقف في هذه المحادثة.`, `Staff replied in ${mask(msg.chatId)}: the assistant pauses there.`);
    } catch (e) { this.serverError(e, "human"); }
  }

  isOwn(msg) {
    if (this.ownIds.has(msg.id)) return true;
    const key = msg.chatId + "\u0000" + (msg.body ?? "");
    if (this.pendingOwn.get(key)) { this.unpend(key); return true; }
    return false;
  }
  unpend(key) { const n = (this.pendingOwn.get(key) ?? 1) - 1; if (n > 0) this.pendingOwn.set(key, n); else this.pendingOwn.delete(key); }
  remember(id) { this.ownIds.add(id); if (this.ownIds.size > 2000) this.ownIds.delete(this.ownIds.values().next().value); }

  // ---------------------------------------------------------------- start: chats waiting unread
  async catchUp() {
    let chats = [];
    try { chats = await this.wa.unreadChats(this.limits.catchUpPerChat); } catch (e) { this.log.warn(`تعذّر قراءة المحادثات غير المقروءة: ${short(e)}`, `Could not read unread chats: ${short(e)}`); return 0; }
    const work = [];
    for (const c of chats) {
      for (const m of c.messages ?? []) { if (this.answerable(m)) work.push(this.onIncoming(m)); }
    }
    if (work.length) this.log.info(`رسائل كانت بانتظار الرد عند التشغيل: ${work.length}`, `Answering ${work.length} message(s) that were waiting.`);
    await Promise.all(work);
    return work.length;
  }

  // ---------------------------------------------------------------- heartbeat + staff replies from the inbox
  async pollOnce() {
    const connected = this.status === "connected";
    this.beatSoon = false;
    const res = await this.api.poll({ status: this.status, phone: this.me.phone, name: this.me.name, version: this.version, detail: this.detail, wait: connected ? this.limits.pollWaitS : 0 });
    this.keyRejected = false;
    if (res?.enabled !== this.server.enabled || res?.auto_reply !== this.server.auto_reply) {
      this.server = { enabled: res?.enabled ?? null, auto_reply: res?.auto_reply ?? null };
      this.log.info(`إعدادات الفرع: واتساب ${res?.enabled ? "مفعّل" : "غير مفعّل"} · الرد الآلي ${res?.auto_reply ? "يعمل" : "متوقف"}`, `Branch settings: WhatsApp ${res?.enabled ? "on" : "off"} · auto-reply ${res?.auto_reply ? "on" : "off"}`);
    }
    const items = Array.isArray(res?.outbox) ? res.outbox : [];
    await Promise.all(items.map((it) => this.enqueue(it.chat_id, () => this.typeStaffReply(it))));
    return items.length;
  }

  async typeStaffReply(it) {
    if (!PERSON_CHAT.test(it.chat_id ?? "") || !it.text) { await this.ack(it.id, false, null, "bad_item"); return; }
    let sent = false;
    try { sent = await this.type(it.chat_id, it.text); } catch { sent = false; }
    await this.ack(it.id, !!sent, typeof sent === "string" ? sent : null, sent ? null : "send_failed");
    if (sent) this.log.info(`رد من الوارد أُرسل إلى ${mask(it.chat_id)}.`, `Inbox reply sent to ${mask(it.chat_id)}.`);
  }

  async ack(id, ok, waId, error) {
    try { await this.withRetry(() => this.api.ack({ id, ok, wa_id: waId, error })); } catch (e) { this.serverError(e, "ack"); }
  }

  /** runs until stop(): long polls while connected, a heartbeat every 15 s otherwise, backs off on errors */
  async runPollLoop() {
    let backoff = 5000;
    while (!this.stopped) {
      try {
        await this.pollOnce();
        backoff = 5000;
        if (this.status !== "connected") await this.idle(15_000);
      } catch (e) {
        this.serverError(e, "poll");
        await this.idle(this.keyRejected ? 60_000 : backoff);
        backoff = Math.min(backoff * 2, 60_000);
      }
    }
  }

  /** sleeps up to ms, waking early when the status changed (so the owner's page updates at once) */
  async idle(ms) {
    const end = this.now() + ms;
    while (!this.stopped && !this.beatSoon && this.now() < end) await this.sleep(Math.min(1000, end - this.now()));
  }

  stop() { this.stopped = true; }

  // ---------------------------------------------------------------- helpers
  enqueue(chatId, job) {
    const prev = this.queues.get(chatId) ?? Promise.resolve();
    const next = prev.then(job, job).catch((e) => this.log.error(`خطأ في معالجة ${mask(chatId)}: ${short(e)}`, `Error handling ${mask(chatId)}: ${short(e)}`));
    this.queues.set(chatId, next);
    next.then(() => { if (this.queues.get(chatId) === next) this.queues.delete(chatId); });
    return next;
  }

  async phoneOf(chatId) {
    if (chatId.endsWith("@c.us")) return chatId.split("@")[0];
    if (this.phones.has(chatId)) return this.phones.get(chatId);
    let p = null;
    try { p = await this.wa.resolvePhone(chatId); } catch { p = null; }
    p = p && /^\d{8,15}$/.test(p) ? p : null;
    this.phones.set(chatId, p);
    return p;
  }

  async withRetry(fn) {
    let wait = 1000;
    for (let i = 0; ; i++) {
      try { return await fn(); } catch (e) {
        if (e?.status === 401 || e?.status === 400 || i >= 2) throw e;
        await this.sleep(wait); wait *= 3;
      }
    }
  }

  serverError(e, what) {
    if (e?.status === 401) {
      if (!this.keyRejected) this.log.error("مفتاح الربط مرفوض: أُنشئ مفتاح جديد أو تغيّرت طريقة الربط. نزّل ملف bridge-config.json الجديد من صفحة «واتساب الفروع» وضعه في مجلد البرنامج ثم أعد تشغيله.", "The branch key was refused (a new key was made, or the branch no longer uses this computer). Put the new bridge-config.json in this folder and restart.");
      this.keyRejected = true;
      return;
    }
    this.log.warn(`تعذّر الاتصال بالخادم (${what}): ${short(e)}`, `Server unreachable (${what}): ${short(e)}`);
  }

  async safe(fn) { try { return await fn(); } catch { return undefined; } }
}

export const STATUS_AR = { starting: "بدء التشغيل", qr: "بانتظار مسح رمز QR", connected: "متصل", disconnected: "غير مربوط", stopped: "متوقف" };
export const STATUS_EN = { starting: "starting", qr: "waiting for the QR code to be scanned", connected: "connected", disconnected: "not linked", stopped: "stopped" };
const SILENT_AR = { human: "موظف يتابع المحادثة", auto_reply_off: "الرد الآلي متوقف", disabled: "واتساب الفرع غير مفعّل", too_old: "رسالة قديمة", ignored: "نوع غير مدعوم" };

/** numbers never reach the log in full */
export const mask = (s) => String(s ?? "").replace(/\d{5,}/g, (d) => "••••" + d.slice(-4));
const short = (e) => mask(String(e?.message ?? e)).slice(0, 200);
