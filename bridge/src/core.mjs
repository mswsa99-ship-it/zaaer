/**
 * The reception computer's WhatsApp, as an employee would work it — the decisions, with WhatsApp and the server
 * passed in (so the tests drive it with fakes):
 *
 *  - every new message from a guest (one-to-one chats only) goes to the server (wa-bridge), in order per chat;
 *    the answer is typed back like a person: "typing…", a pause that grows with the length, send — one message at a
 *    time on this computer — and the chat is marked read only once the guest really got the answer
 *  - a silent answer (auto-reply off, a receptionist on the chat, an old message) leaves the chat UNREAD for staff
 *  - what a receptionist types in WhatsApp itself (phone or this window) is reported: the assistant then steps back
 *    in that chat, and the reply appears in the inbox. The program's own messages are recognised and not reported.
 *  - staff replies from the inbox are picked up (poll) and typed the same way, then confirmed (ack); a confirmation
 *    that cannot reach the server is kept and sent again later (never typed twice)
 *  - unread chats waiting when the program starts are answered one chat after another, once per chat (all the
 *    waiting messages of a chat go in together, as a person reading the backlog would answer)
 *  - only the branch's own number is ever worked: if another phone was linked (a receptionist scanned with a personal
 *    phone), nothing is answered, reported or typed from it until the branch phone is linked
 *
 * Limits keep the number safe: replies only to people who wrote, at human speed, at most a few per chat per minute
 * and 20 per minute in all. A chat that floods (another bot, a loop) is kept quiet for a while: its messages still
 * reach the inbox (up to a number), but nothing is typed into it.
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
  perChatPerMinute: 6,              // assistant messages per chat per minute
  globalPerMinute: 20,              // messages per minute in all
  floodMessages: 12,                // more than this many guest messages …
  floodWindowMs: 2 * 60_000,        // … in this window → the chat is kept quiet …
  floodPauseMs: 15 * 60_000,        // … for this long
  quietRecordMax: 10,               // messages of a quiet chat still handed in for the inbox, per quiet spell
  catchUpPerChat: 5,
  pollWaitS: 25,
  sendFailuresBeforeReopen: 3,      // consecutive failed sends → WhatsApp Web is reopened
  ackKeepMs: 3600_000,              // a confirmation the server did not get is retried this long
};

const sleepReal = (ms) => new Promise((r) => setTimeout(r, ms));
const digits = (s) => String(s ?? "").replace(/\D/g, "");

/** several unread messages of one chat (the computer was off) → one message, answered once */
export function combine(msgs) {
  const last = msgs[msgs.length - 1];
  const lines = msgs.map((m) => (m.type === "chat" ? (m.body ?? "") : `[${TYPE_MAP[m.type] ?? m.type}]${m.body ? " " + m.body : ""}`)).filter((l) => l.trim());
  const anyText = msgs.some((m) => m.type === "chat" && (m.body ?? "").trim());
  return { ...last, type: anyText ? "chat" : last.type, body: lines.join("\n").slice(0, 3000) };
}

export class Bridge {
  /**
   * @param {{ api: any, log: any, version?: string, branchPhone?: string | null, now?: () => number, sleep?: (ms: number) => Promise<void>, random?: () => number, limits?: Partial<typeof DEFAULTS> }} o
   */
  constructor({ api, log, version = "dev", branchPhone = null, now = () => Date.now(), sleep = sleepReal, random = Math.random, limits = {} }) {
    this.api = api; this.log = log; this.version = version; this.now = now; this.sleep = sleep; this.random = random;
    this.limits = { ...DEFAULTS, ...limits };
    this.wa = null;
    this.status = "starting"; this.detail = null;
    this.me = { phone: null, name: null };
    this.expected = digits(branchPhone) || null;   // the branch number (settings file, then what the server says)
    this.blocked = null;                           // "wrong_number": another phone is linked — nothing is worked
    this.server = { enabled: null, auto_reply: null };
    this.keyRejected = false;
    this.queues = new Map();          // chatId → tail of that chat's work
    this.typingTail = Promise.resolve();   // one message typed at a time on this computer
    this.pendingOwn = new Map();      // chatId + text → count of messages being typed by the program
    this.ownIds = new Set();          // ids of messages the program sent
    this.inbound = new Map();         // chatId → recent guest message times
    this.quietUntil = new Map();      // chatId → nothing is typed into it until then
    this.quietCount = new Map();      // chatId → messages handed in during this quiet spell
    this.sentAt = [];                 // all messages typed in the last minute
    this.sentPerChat = new Map();     // assistant messages per chat in the last minute
    this.phones = new Map();          // @lid → number (or null)
    this.pendingAcks = new Map();     // outbox id → confirmation not yet received by the server
    this.sendFailures = 0;
    this.onTrouble = null;            // (why) => void — set by index.mjs: reopen WhatsApp Web
    this.catching = false;
    this.stopped = false;
  }

  attach(wa) { this.wa = wa; }
  setMe(me) { this.me = { phone: me?.phone ?? null, name: me?.name ?? null }; return this.checkLink(); }
  setStatus(status, detail = null) {
    if (this.status === status && this.detail === detail) return;
    this.status = status; this.detail = detail;
    this.log.info(`الحالة: ${STATUS_AR[status] ?? status}${detail ? ` (${detail})` : ""}`, `Status: ${STATUS_EN[status] ?? status}${detail ? ` (${detail})` : ""}`);
    this.beatSoon = true;
  }

  // ---------------------------------------------------------------- the branch's own number only
  /** "blocked" | "unblocked" (the right phone now) | "ok" */
  checkLink() {
    const linked = digits(this.me.phone), expected = digits(this.expected);
    const wrong = !!(linked && expected && linked !== expected);
    if (wrong) { this.blockWrongNumber(); return "blocked"; }
    if (this.blocked === "wrong_number" && linked && expected) {
      this.blocked = null;
      this.log.info("الرقم المربوط هو رقم الفرع — الرد يعمل.", "The linked number is the branch number — answering is on.");
      this.beatSoon = true;
      return "unblocked";
    }
    return this.blocked ? "blocked" : "ok";
  }

  blockWrongNumber() {
    if (this.blocked === "wrong_number") return;
    this.blocked = "wrong_number";
    const l = digits(this.me.phone).slice(-4), b = digits(this.expected).slice(-4);
    this.log.error(
      `الرقم المربوط${l ? ` (••••${l})` : ""} ليس رقم الفرع${b ? ` (••••${b})` : ""}: لا يرد البرنامج على أي رسالة ولا ينقل شيئًا من هذا الجوال. من ذلك الجوال: واتساب ← الأجهزة المرتبطة ← هذا الكمبيوتر ← تسجيل الخروج، ثم امسح الرمز من جوال الفرع.`,
      `The linked number${l ? ` (••••${l})` : ""} is not the branch number${b ? ` (••••${b})` : ""}: nothing is answered or reported from this phone. On that phone: WhatsApp → Linked devices → this computer → Log out, then scan the code with the branch phone.`);
    this.beatSoon = true;
  }

  // ---------------------------------------------------------------- guest messages
  /** a message arrived (whatsapp-web.js "message", or found unread at start) */
  onIncoming(msg) {
    if (this.blocked || !this.answerable(msg)) return Promise.resolve();
    const chat = msg.chatId;
    const t = this.now();
    const times = (this.inbound.get(chat) ?? []).filter((x) => t - x < this.limits.floodWindowMs);
    times.push(t);
    this.inbound.set(chat, times);
    if (times.length > this.limits.floodMessages && !this.isQuiet(chat)) this.quiet(chat, "flood");
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
    if (this.keyRejected || this.stopped || this.blocked) return;
    const chat = msg.chatId;
    const answer = !this.isQuiet(chat);
    if (!answer && !this.takeQuietSlot(chat)) return;          // a chat that keeps flooding: WhatsApp still has it, unread
    const phone = await this.phoneOf(chat);
    const body = { id: msg.id, chat, phone, linked: this.me.phone, name: msg.name ?? null, type: TYPE_MAP[msg.type] ?? "text", text: msg.body ?? "",
      ts: msg.timestamp ? msg.timestamp * 1000 : null, ...(answer ? {} : { answer: false }) };
    let res;
    try {
      // a quiet chat's message is handed in once, without retries (no load from a flood)
      res = answer ? await this.withRetry(() => this.api.message(body)) : await this.api.message(body);
    } catch (e) {
      this.serverError(e, "message");
      return;                                                     // left unread: staff see it in WhatsApp
    }
    if (res?.duplicate) { this.log.info(`رسالة من ${mask(chat)} عولجت من قبل — لا رد جديد.`, `A message from ${mask(chat)} was already handled — no new reply.`); return; }
    // a chat kept quiet is never typed into, whatever comes back
    const replies = answer && Array.isArray(res?.replies) ? res.replies.filter((x) => typeof x === "string" && x.trim()) : [];
    if (!replies.length) {
      if (res?.silent) this.log.info(`رسالة من ${mask(chat)} سُجّلت للموظفين دون رد آلي (${SILENT_AR[res.silent] ?? res.silent}).`, `Message from ${mask(chat)} left for staff (${res.silent}).`);
      return;
    }
    let typed = 0, why = null;
    for (const text of replies) {
      const r = await this.type(chat, text, { bot: true });
      if (!r.ok) { why = r.reason; break; }
      if (++typed === 1) await this.safe(() => this.wa.markSeen(chat));     // read only once the guest really got an answer
    }
    if (typed < replies.length) {
      this.log.error(`لم يُرسل رد المساعد كاملًا إلى ${mask(chat)} (${why}) — المحادثة متروكة للموظف.`, `The assistant's reply to ${mask(chat)} was not fully sent (${why}) — left to staff.`);
      if (res?.turn) await this.safe(() => this.api.undelivered({ turn: res.turn, reason: typed ? "partly_sent" : why === "limit" ? "limit" : "send_failed" }));
    }
  }

  /**
   * Types one message like a person — one message at a time on this computer — and sends it.
   * { ok: true, id } or { ok: false, reason: "limit" | "send_failed" }. `bot`: the assistant's reply (per-chat limit).
   */
  type(chatId, text, { bot = false } = {}) {
    const run = async () => {
      if (bot && !this.botSlot(chatId)) return { ok: false, reason: "limit" };
      await this.globalSlot();
      await this.safe(() => this.wa.typing(chatId));
      await this.sleep(this.typingDelay(text));
      const key = chatId + "\u0000" + text;
      this.pendingOwn.set(key, (this.pendingOwn.get(key) ?? 0) + 1);
      try {
        const sent = await this.wa.sendText(chatId, text);
        if (!sent?.id) throw new Error("WhatsApp did not confirm the message");
        this.remember(sent.id);
        this.sentAt.push(this.now());
        if (bot) { const per = this.sentPerChat.get(chatId) ?? []; per.push(this.now()); this.sentPerChat.set(chatId, per); }
        this.sendFailures = 0;
        return { ok: true, id: sent.id };
      } catch (e) {
        this.unpend(key);
        this.log.error(`تعذّر إرسال رسالة إلى ${mask(chatId)}: ${short(e)}`, `Could not send to ${mask(chatId)}: ${short(e)}`);
        this.sendTrouble();
        return { ok: false, reason: "send_failed" };
      } finally {
        await this.safe(() => this.wa.clearTyping(chatId));
      }
    };
    const next = this.typingTail.then(run, run);
    this.typingTail = next.then(() => {}, () => {});
    return next;
  }

  typingDelay(text) {
    const base = 1200 + 35 * String(text).length;
    const jitter = 0.85 + this.random() * 0.3;
    return Math.round(Math.min(7000, base) * jitter);
  }

  /** the assistant's share in one chat; reaching it (a loop with another bot) keeps the chat quiet for a while */
  botSlot(chatId) {
    const per = (this.sentPerChat.get(chatId) ?? []).filter((x) => x > this.now() - 60_000);
    this.sentPerChat.set(chatId, per);
    if (per.length < this.limits.perChatPerMinute) return true;
    this.quiet(chatId, "limit");
    return false;
  }

  /** waits for room under the per-minute limit of the whole computer (messages are typed one at a time) */
  async globalSlot() {
    for (;;) {
      this.sentAt = this.sentAt.filter((x) => x > this.now() - 60_000);
      if (this.sentAt.length < this.limits.globalPerMinute) return;
      await this.sleep(Math.max(500, this.sentAt[0] + 60_000 - this.now()));
    }
  }

  quiet(chatId, why) {
    this.quietUntil.set(chatId, this.now() + this.limits.floodPauseMs);
    this.quietCount.set(chatId, 0);
    const mins = Math.round(this.limits.floodPauseMs / 60000);
    this.log.warn(why === "limit"
      ? `تجاوزت محادثة ${mask(chatId)} حد الردود في الدقيقة؛ لا ردود آلية فيها ${mins} دقيقة (رسائلها تصل للوارد).`
      : `محادثة ${mask(chatId)} أرسلت رسائل كثيرة بسرعة؛ لا ردود آلية فيها ${mins} دقيقة (رسائلها تصل للوارد).`,
    why === "limit" ? `Chat ${mask(chatId)} reached the replies-per-minute limit; no automatic replies for ${mins} min (its messages still reach the inbox).`
      : `Chat ${mask(chatId)} is flooding; no automatic replies for ${mins} min (its messages still reach the inbox).`);
  }
  isQuiet(chatId) { return (this.quietUntil.get(chatId) ?? 0) > this.now(); }
  takeQuietSlot(chatId) {
    const n = this.quietCount.get(chatId) ?? 0;
    if (n >= this.limits.quietRecordMax) return false;
    this.quietCount.set(chatId, n + 1);
    return true;
  }

  /** a failed send; several in a row usually mean WhatsApp Web itself is stuck → it is reopened */
  sendTrouble() {
    if (++this.sendFailures < this.limits.sendFailuresBeforeReopen) return;
    this.sendFailures = 0;
    this.log.error("تعذّر الإرسال عدة مرات متتالية — يُعاد فتح واتساب ويب.", "Several sends failed in a row — reopening WhatsApp Web.");
    this.onTrouble?.("send_failed");
  }

  // ---------------------------------------------------------------- what staff type in WhatsApp itself
  /** whatsapp-web.js "message_create" with fromMe: the program's own message, or a receptionist's */
  async onOwnMessage(msg) {
    if (!msg?.fromMe || !msg.id || !PERSON_CHAT.test(msg.chatId ?? "") || !TYPE_MAP[msg.type]) return;
    if (this.isOwn(msg)) return;
    await this.sleep(1500);                                          // the send may still be returning its id
    if (this.isOwn(msg)) return;
    if (this.keyRejected || this.stopped || this.blocked) return;    // never a personal phone's messages
    const phone = await this.phoneOf(msg.chatId);
    try {
      await this.withRetry(() => this.api.human({ id: msg.id, chat: msg.chatId, phone, linked: this.me.phone, type: TYPE_MAP[msg.type], text: msg.body ?? "" }));
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
    if (this.blocked || this.catching || this.stopped) return 0;
    this.catching = true;
    try {
      let chats = [];
      try { chats = await this.wa.unreadChats(this.limits.catchUpPerChat); } catch (e) { this.log.warn(`تعذّر قراءة المحادثات غير المقروءة: ${short(e)}`, `Could not read unread chats: ${short(e)}`); return 0; }
      const work = [];
      for (const c of chats) {
        const waiting = (c.messages ?? []).filter((m) => this.answerable(m)).sort((a, b) => (a.timestamp ?? 0) - (b.timestamp ?? 0));
        if (waiting.length) work.push(waiting);
      }
      if (!work.length) return 0;
      this.log.info(`محادثات كانت بانتظار الرد عند التشغيل: ${work.length}`, `Answering ${work.length} chat(s) that were waiting.`);
      for (const waiting of work) {                                  // one chat after another, like a person going down the list
        if (this.blocked || this.stopped) break;
        await this.onIncoming(waiting.length === 1 ? waiting[0] : combine(waiting));
      }
      return work.length;
    } finally { this.catching = false; }
  }

  // ---------------------------------------------------------------- heartbeat + staff replies from the inbox
  async pollOnce() {
    const working = this.status === "connected" && !this.blocked;
    this.beatSoon = false;
    const res = await this.api.poll({ status: this.blocked ? "disconnected" : this.status, phone: this.me.phone, name: this.me.name, version: this.version,
      detail: this.blocked ?? this.detail, wait: working ? this.limits.pollWaitS : 0 });
    this.keyRejected = false;
    if (res?.display_phone && digits(res.display_phone) !== digits(this.expected)) {
      this.expected = digits(res.display_phone);
      if (this.checkLink() === "unblocked" && this.status === "connected") this.catchUp();
    }
    if (res?.enabled !== this.server.enabled || res?.auto_reply !== this.server.auto_reply) {
      this.server = { enabled: res?.enabled ?? null, auto_reply: res?.auto_reply ?? null };
      this.log.info(`إعدادات الفرع: واتساب ${res?.enabled ? "مفعّل" : "غير مفعّل"} · الرد الآلي ${res?.auto_reply ? "يعمل" : "متوقف"}`, `Branch settings: WhatsApp ${res?.enabled ? "on" : "off"} · auto-reply ${res?.auto_reply ? "on" : "off"}`);
    }
    if (this.pendingAcks.size) await this.flushAcks();
    const items = Array.isArray(res?.outbox) ? res.outbox : [];
    await Promise.all(items.map((it) => this.enqueue(it.chat_id, () => this.typeStaffReply(it))));
    return items.length;
  }

  async typeStaffReply(it) {
    if (this.blocked) { await this.ack(it.id, false, null, this.blocked); return; }   // never typed from a phone that is not the branch's
    if (!PERSON_CHAT.test(it.chat_id ?? "") || !it.text) { await this.ack(it.id, false, null, "bad_item"); return; }
    const r = await this.type(it.chat_id, it.text);
    await this.ack(it.id, r.ok, r.ok ? r.id : null, r.ok ? null : r.reason);
    if (r.ok) this.log.info(`رد من الوارد أُرسل إلى ${mask(it.chat_id)}.`, `Inbox reply sent to ${mask(it.chat_id)}.`);
  }

  async ack(id, ok, waId, error) {
    try { await this.withRetry(() => this.api.ack({ id, ok, wa_id: waId, error })); }
    catch (e) {
      this.serverError(e, "ack");
      // the message WAS typed (or not): that must still reach the server, or the inbox would offer to send it again
      if (e?.status !== 401 && e?.status !== 400) this.pendingAcks.set(id, { ok, waId, error, at: this.now() });
    }
  }

  async flushAcks() {
    for (const [id, a] of [...this.pendingAcks]) {
      if (this.now() - a.at > this.limits.ackKeepMs) { this.pendingAcks.delete(id); continue; }
      try { await this.api.ack({ id, ok: a.ok, wa_id: a.waId, error: a.error }); this.pendingAcks.delete(id); }
      catch (e) { if (e?.status === 400) this.pendingAcks.delete(id); else break; }   // still unreachable: the next poll tries again
    }
  }

  /** runs until stop(): long polls while working, a heartbeat every 15 s otherwise, backs off on errors */
  async runPollLoop() {
    let backoff = 5000;
    while (!this.stopped) {
      try {
        await this.pollOnce();
        backoff = 5000;
        if (this.status !== "connected" || this.blocked) await this.idle(15_000);
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
        if (e?.status === 401 || e?.status === 400 || e?.status === 409 || i >= 2) throw e;
        await this.sleep(e?.status === 429 ? 30_000 : wait); wait *= 3;              // the branch's per-minute limit: wait it out
      }
    }
  }

  serverError(e, what) {
    if (e?.status === 401) {
      if (!this.keyRejected) this.log.error("مفتاح الربط مرفوض: أُنشئ مفتاح جديد أو تغيّرت طريقة الربط. نزّل ملف bridge-config.json الجديد من صفحة «واتساب الفروع» وضعه في مجلد البرنامج ثم أعد تشغيله.", "The branch key was refused (a new key was made, or the branch no longer uses this computer). Put the new bridge-config.json in this folder and restart.");
      this.keyRejected = true;
      return;
    }
    if (e?.status === 409 && String(e?.message) === "wrong_number") { this.blockWrongNumber(); return; }
    this.log.warn(`تعذّر الاتصال بالخادم (${what}): ${short(e)}`, `Server unreachable (${what}): ${short(e)}`);
  }

  async safe(fn) { try { return await fn(); } catch { return undefined; } }
}

export const STATUS_AR = { starting: "بدء التشغيل", qr: "بانتظار مسح رمز QR", connected: "متصل", disconnected: "غير مربوط", stopped: "متوقف" };
export const STATUS_EN = { starting: "starting", qr: "waiting for the QR code to be scanned", connected: "connected", disconnected: "not linked", stopped: "stopped" };
const SILENT_AR = { human: "موظف يتابع المحادثة", auto_reply_off: "الرد الآلي متوقف", disabled: "واتساب الفرع غير مفعّل", too_old: "رسالة قديمة", ignored: "نوع غير مدعوم", paused: "محادثة بلا ردود آلية مؤقتًا" };

/** numbers never reach the log in full */
export const mask = (s) => String(s ?? "").replace(/\d{5,}/g, (d) => "••••" + d.slice(-4));
const short = (e) => mask(String(e?.message ?? e)).slice(0, 200);
