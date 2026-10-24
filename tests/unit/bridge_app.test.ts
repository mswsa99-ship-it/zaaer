/**
 * The program on the reception computer (bridge/src) — BA01–BA30, with WhatsApp and the server faked:
 * what it answers, how it types, what it leaves to staff, how it tells its own messages from a receptionist's,
 * the limits that keep the number safe, staff replies from the inbox, the branch's own number only, and the
 * settings file and browser it finds.
 */
import { describe, it, expect } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
// @ts-expect-error — plain JavaScript modules of the Windows program
import { Bridge, mask, combine } from "../../bridge/src/core.mjs";
// @ts-expect-error — plain JavaScript module
import { findConfig, validateConfig } from "../../bridge/src/config.mjs";
// @ts-expect-error — plain JavaScript module
import { findBrowser, browserCandidates } from "../../bridge/src/browser.mjs";
// @ts-expect-error — plain JavaScript module
import { createApi } from "../../bridge/src/api.mjs";
// @ts-expect-error — plain JavaScript module
import { createLogger } from "../../bridge/src/log.mjs";
// @ts-expect-error — plain JavaScript module
import { toMsg, waAdapter } from "../../bridge/src/wa.mjs";

type Any = any; // eslint-disable-line @typescript-eslint/no-explicit-any
const GUEST = "966501110006@c.us";
const KEY = "zb_" + "a1".repeat(32);

const BRANCH_PHONE = "966500000100";

function harness(o: { reply?: (b: Any) => Any; poll?: (b: Any) => Any; unread?: Any[]; lidPhone?: string | null; sendFails?: boolean | (() => boolean); sendNoId?: boolean;
  failMessage?: Any; failAck?: () => Any; branchPhone?: string | null; me?: string | null } = {}) {
  let t = Date.parse("2026-10-24T10:00:00Z");
  const now = () => t;
  const sleeps: number[] = [];
  const sleep = async (ms: number) => { sleeps.push(ms); t += ms; };
  const lines: Array<[string, string, string?]> = [];
  const log = { info: (a: string, e?: string) => lines.push(["info", a, e]), warn: (a: string, e?: string) => lines.push(["warn", a, e]), error: (a: string, e?: string) => lines.push(["error", a, e]) };
  const sent: Array<{ chatId: string; text: string; id: string; at: number }> = []; const seen: string[] = []; const typing: string[] = [];
  const events: string[] = [];
  let seq = 0; let typingNow = 0; let maxTyping = 0;
  const wa = {
    sendText: async (chatId: string, text: string) => {
      const fails = typeof o.sendFails === "function" ? o.sendFails() : o.sendFails;
      if (fails) throw new Error("not on WhatsApp");
      if (o.sendNoId) return { id: null };
      const id = `true_${chatId}_OUT${++seq}`; sent.push({ chatId, text, id, at: t }); events.push("send:" + chatId); return { id };
    },
    markSeen: async (c: string) => { seen.push(c); events.push("seen:" + c); },
    typing: async (c: string) => { typing.push(c); typingNow++; maxTyping = Math.max(maxTyping, typingNow); },
    clearTyping: async () => { typingNow = Math.max(0, typingNow - 1); },
    resolvePhone: async () => o.lidPhone ?? null, unreadChats: async () => o.unread ?? [],
  };
  const calls: Array<[string, Any]> = [];
  const api = {
    message: async (b: Any) => { calls.push(["message", b]); if (o.failMessage) throw o.failMessage; return o.reply ? o.reply(b) : { ok: true, replies: ["أهلًا بك"] }; },
    human: async (b: Any) => { calls.push(["human", b]); return { ok: true }; },
    poll: async (b: Any) => { calls.push(["poll", b]); return o.poll ? o.poll(b) : { ok: true, enabled: true, auto_reply: true, display_phone: BRANCH_PHONE, outbox: [] }; },
    ack: async (b: Any) => { calls.push(["ack", b]); const f = o.failAck?.(); if (f) throw f; return { ok: true }; },
    undelivered: async (b: Any) => { calls.push(["undelivered", b]); return { ok: true }; },
  };
  const core = new Bridge({ api, log, now, sleep, random: () => 0.5, version: "test", branchPhone: o.branchPhone === undefined ? BRANCH_PHONE : o.branchPhone });
  core.attach(wa);
  if (o.me !== null) core.setMe({ phone: o.me ?? BRANCH_PHONE, name: "الاستقبال" });
  const msg = (over: Any = {}) => ({ id: `false_${GUEST}_${++seq}`, chatId: GUEST, fromMe: false, type: "chat", body: "مرحبا", timestamp: Math.floor(t / 1000), name: "ضيف", ...over });
  return { core, calls, sent, seen, typing, lines, sleeps, events, msg, advance: (ms: number) => { t += ms; }, now, maxTyping: () => maxTyping,
    of: (kind: string) => calls.filter((c) => c[0] === kind).map((c) => c[1]) };
}

describe("reception computer program (bridge/src/core.mjs)", () => {
  it("BA01 answers a guest: hands the message to the server, then reads, types and sends each reply in order", async () => {
    const h = harness({ reply: () => ({ ok: true, replies: ["الأول", "الثاني"] }) });
    await h.core.onIncoming(h.msg({ body: "حجوزاتي" }));
    expect(h.calls[0]).toEqual(["message", expect.objectContaining({ chat: GUEST, phone: "966501110006", type: "text", text: "حجوزاتي", name: "ضيف" })]);
    expect(h.seen).toEqual([GUEST]);
    expect(h.typing).toEqual([GUEST, GUEST]);
    expect(h.sent.map((s) => s.text)).toEqual(["الأول", "الثاني"]);
    expect(h.sleeps.every((ms) => ms >= 1000 && ms <= 8050)).toBe(true);          // a person's typing pace
  });

  it("BA02 groups, status, channels, broadcasts, system notices, its own messages and old messages are never handed in", async () => {
    const h = harness();
    for (const m of [
      h.msg({ chatId: "120363025246125486@g.us" }), h.msg({ chatId: "status@broadcast" }), h.msg({ chatId: "120363041234567890@newsletter" }),
      h.msg({ broadcast: true }), h.msg({ type: "e2e_notification" }), h.msg({ type: "revoked" }), h.msg({ type: "call_log" }), h.msg({ type: "reaction" }),
      h.msg({ fromMe: true }), h.msg({ timestamp: Math.floor((Date.parse("2026-10-24T10:00:00Z") - 13 * 3600_000) / 1000) }),
    ]) await h.core.onIncoming(m);
    expect(h.calls).toEqual([]);
    expect(h.sent).toEqual([]);
  });

  it("BA03 a silent answer leaves the chat unread for staff (no read mark, nothing typed)", async () => {
    const h = harness({ reply: () => ({ ok: true, replies: [], silent: "human" }) });
    await h.core.onIncoming(h.msg());
    expect(h.calls).toHaveLength(1);
    expect(h.seen).toEqual([]);
    expect(h.sent).toEqual([]);
  });

  it("BA04 its own replies are recognised; what a receptionist types in WhatsApp is reported once as a staff reply", async () => {
    const h = harness();
    await h.core.onIncoming(h.msg());
    const own = h.sent[0];
    await h.core.onOwnMessage({ id: own.id, chatId: GUEST, fromMe: true, type: "chat", body: own.text });
    await h.core.onOwnMessage({ id: "true_" + GUEST + "_STAFF1", chatId: GUEST, fromMe: true, type: "chat", body: "معك أحمد من الاستقبال" });
    await h.core.onOwnMessage({ id: "true_120363@g.us_X", chatId: "120363025246125486@g.us", fromMe: true, type: "chat", body: "group" });
    const human = h.calls.filter((c) => c[0] === "human");
    expect(human).toEqual([["human", expect.objectContaining({ chat: GUEST, phone: "966501110006", text: "معك أحمد من الاستقبال", type: "text" })]]);
  });

  it("BA05 the program's message seen before the send returns (same text in the same chat) is not mistaken for staff", async () => {
    const h = harness();
    const text = "أهلًا بك";
    // WhatsApp Web may announce the program's message before sendMessage resolves
    (h.core as Any).pendingOwn.set(GUEST + "\u0000" + text, 1);
    await h.core.onOwnMessage({ id: "true_x_EARLY", chatId: GUEST, fromMe: true, type: "chat", body: text });
    expect(h.calls.filter((c) => c[0] === "human")).toEqual([]);
  });

  it("BA06 messages of one chat are handled one after another, in order", async () => {
    const order: string[] = [];
    let release: () => void = () => {};
    const gate = new Promise<void>((r) => { release = r; });
    const h = harness({ reply: async (b: Any) => { order.push("start:" + b.text); if (b.text === "1") await gate; order.push("end:" + b.text); return { ok: true, replies: ["رد " + b.text] }; } });
    const a = h.core.onIncoming(h.msg({ body: "1" }));
    const b = h.core.onIncoming(h.msg({ body: "2" }));
    await new Promise((r) => setTimeout(r, 5));
    expect(order).toEqual(["start:1"]);
    release();
    await Promise.all([a, b]);
    expect(order).toEqual(["start:1", "end:1", "start:2", "end:2"]);
    expect(h.sent.map((s) => s.text)).toEqual(["رد 1", "رد 2"]);
  });

  it("BA07 a chat that loops (another bot) is kept quiet for a while: nothing more is typed, its messages still reach the inbox", async () => {
    // the fake server answers even "record only" messages: the program must not type into a quiet chat anyway
    const h = harness({ reply: () => ({ ok: true, replies: ["أهلًا بك"], turn: { thread: "T1", after: null } }) });
    for (let i = 0; i < 15; i++) await h.core.onIncoming(h.msg({ body: "x" + i }));
    // 6 assistant replies a minute per chat; the 7th answer is not typed (the inbox is told) and the chat goes quiet
    expect(h.sent.length).toBe(6);
    expect(h.of("undelivered")).toEqual([{ turn: { thread: "T1", after: null }, reason: "limit" }]);
    const msgs = h.of("message");
    expect(msgs).toHaveLength(15);                                            // every message reaches the inbox …
    expect(msgs.slice(0, 7).every((b: Any) => b.answer === undefined)).toBe(true);
    expect(msgs.slice(7).every((b: Any) => b.answer === false)).toBe(true);    // … the quiet ones as "record only"
    expect(h.lines.some(([lvl]) => lvl === "warn")).toBe(true);
    h.advance(16 * 60_000);
    await h.core.onIncoming(h.msg({ body: "بعد" }));
    expect(h.sent.length).toBe(7);
  });

  it("BA08 no more than 20 messages a minute in all: the 21st waits for the minute to pass", async () => {
    const h = harness();
    const chats = Array.from({ length: 21 }, (_, i) => `9665011100${String(i).padStart(2, "0")}@c.us`);
    for (const c of chats) await h.core.onIncoming(h.msg({ chatId: c, id: "id-" + c }));
    expect(h.sent).toHaveLength(21);
    expect(h.sleeps.some((ms) => ms >= 500 && ms <= 60_000 && ms > 8050)).toBe(true);   // a limiter wait, not a typing pause
  });

  it("BA09 staff replies from the inbox are typed and confirmed; a failed send is reported, not retried", async () => {
    const h = harness({ poll: () => ({ ok: true, enabled: true, auto_reply: true, outbox: [{ id: "OB1", chat_id: GUEST, text: "الغرفة جاهزة" }] }) });
    h.core.setStatus("connected");
    await h.core.pollOnce();
    expect(h.calls.find((c) => c[0] === "poll")![1]).toMatchObject({ status: "connected", wait: 25, version: "test" });
    expect(h.sent.map((s) => s.text)).toEqual(["الغرفة جاهزة"]);
    expect(h.calls.find((c) => c[0] === "ack")![1]).toMatchObject({ id: "OB1", ok: true, wa_id: expect.stringContaining("OUT") });
    // the program's own staff message is not reported back as a receptionist typing
    await h.core.onOwnMessage({ id: h.sent[0].id, chatId: GUEST, fromMe: true, type: "chat", body: "الغرفة جاهزة" });
    expect(h.calls.filter((c) => c[0] === "human")).toEqual([]);

    const f = harness({ sendFails: true, poll: () => ({ ok: true, outbox: [{ id: "OB2", chat_id: GUEST, text: "x" }] }) });
    f.core.setStatus("connected");
    await f.core.pollOnce();
    expect(f.calls.filter((c) => c[0] === "ack")).toEqual([["ack", expect.objectContaining({ id: "OB2", ok: false, error: "send_failed" })]]);
  });

  it("BA10 at start, recent unread messages waiting in WhatsApp are answered (at most 5 per chat)", async () => {
    const t0 = Math.floor(Date.parse("2026-10-24T10:00:00Z") / 1000);
    const h = harness({ unread: [
      { chatId: GUEST, messages: [{ id: "u1", chatId: GUEST, fromMe: false, type: "chat", body: "هل الغرفة جاهزة؟", timestamp: t0 - 600 }] },
      { chatId: "966501110007@c.us", messages: [{ id: "u2", chatId: "966501110007@c.us", fromMe: false, type: "chat", body: "قديمة", timestamp: t0 - 20 * 3600 }] },
    ] });
    const n = await h.core.catchUp();
    expect(n).toBe(1);
    expect(h.calls.map((c) => c[1].text)).toEqual(["هل الغرفة جاهزة؟"]);
  });

  it("BA11 a privacy id (…@lid) uses the number WhatsApp gives, or none — never a guess", async () => {
    const a = harness({ lidPhone: "966501110006" });
    await a.core.onIncoming(a.msg({ chatId: "204587116371@lid" }));
    expect(a.calls[0][1]).toMatchObject({ chat: "204587116371@lid", phone: "966501110006" });
    const b = harness({ lidPhone: null });
    await b.core.onIncoming(b.msg({ chatId: "204587116371@lid" }));
    expect(b.calls[0][1].phone).toBeNull();
  });

  it("BA12 a refused key stops answering and says what to do; the chat stays unread for staff", async () => {
    const h = harness({ failMessage: Object.assign(new Error("bad_key"), { status: 401 }) });
    await h.core.onIncoming(h.msg());
    expect(h.core.keyRejected).toBe(true);
    expect(h.sent).toEqual([]);
    expect(h.lines.some(([lvl, ar]) => lvl === "error" && ar.includes("bridge-config.json"))).toBe(true);
    await h.core.onIncoming(h.msg({ body: "ثانية" }));
    expect(h.calls).toHaveLength(1);                     // nothing more is handed in until a new key works
  });

  it("BA13 a server hiccup is retried (3 tries), then the message is left for staff", async () => {
    let n = 0;
    const h = harness({ reply: () => { n++; if (n < 3) throw Object.assign(new Error("timeout"), { status: 0 }); return { ok: true, replies: ["تم"] }; } });
    await h.core.onIncoming(h.msg());
    expect(n).toBe(3);
    expect(h.sent.map((s) => s.text)).toEqual(["تم"]);
  });

  it("BA14 numbers never reach the log in full", () => {
    expect(mask("chat 966501110006@c.us and 204587116371@lid")).toBe("chat ••••0006@c.us and ••••6371@lid");
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "wa-log-"));
    const out = { log: () => {}, warn: () => {}, error: () => {} };
    const log = createLogger(dir, { out, now: () => new Date("2026-10-24T10:00:00Z") });
    log.info("رسالة من 966501110006", "Message from 966501110006");
    const text = fs.readFileSync(path.join(dir, "bridge-2026-10-24.log"), "utf8");
    expect(text).toContain("••••0006");
    expect(text).not.toContain("966501110006");
  });

  it("BA19 a phone other than the branch's is linked: nothing is answered, reported or typed from it, and the owner's page is told", async () => {
    const h = harness({ me: "966555000111", poll: () => ({ ok: true, enabled: true, auto_reply: true, display_phone: BRANCH_PHONE, outbox: [{ id: "OB9", chat_id: GUEST, text: "رد" }] }) });
    expect(h.core.blocked).toBe("wrong_number");
    expect(h.lines.some(([lvl, ar]) => lvl === "error" && ar.includes("ليس رقم الفرع"))).toBe(true);
    await h.core.onIncoming(h.msg());
    await h.core.onOwnMessage({ id: "true_x_PERSONAL", chatId: GUEST, fromMe: true, type: "chat", body: "رسالة شخصية" });
    expect(await h.core.catchUp()).toBe(0);
    h.core.setStatus("connected");
    await h.core.pollOnce();
    expect(h.of("message")).toEqual([]);
    expect(h.of("human")).toEqual([]);
    expect(h.sent).toEqual([]);
    expect(h.of("poll")[0]).toMatchObject({ status: "disconnected", detail: "wrong_number", phone: "966555000111", wait: 0 });
    expect(h.of("ack")).toEqual([expect.objectContaining({ id: "OB9", ok: false, error: "wrong_number" })]);
  });

  it("BA20 the number on the owner's page decides: once it matches the linked phone, answering resumes; the server's refusal blocks too", async () => {
    let display = BRANCH_PHONE;
    const h = harness({ me: "966555000111", poll: () => ({ ok: true, enabled: true, auto_reply: true, display_phone: display, outbox: [] }) });
    h.core.setStatus("connected");
    display = "966555000111";                                                   // the owner corrects the branch number
    await h.core.pollOnce();
    expect(h.core.blocked).toBeNull();
    await h.core.onIncoming(h.msg());
    expect(h.of("message")[0]).toMatchObject({ linked: "966555000111" });
    expect(h.sent).toHaveLength(1);

    const s = harness({ branchPhone: null, failMessage: Object.assign(new Error("wrong_number"), { status: 409 }) });
    await s.core.onIncoming(s.msg());
    expect(s.core.blocked).toBe("wrong_number");
    expect(s.of("message")).toHaveLength(1);                                   // refused at once, not retried
    await s.core.onIncoming(s.msg({ body: "ثانية" }));
    expect(s.of("message")).toHaveLength(1);
  });

  it("BA21 messages from many chats at once are typed one at a time, never more than 20 in any minute", async () => {
    const h = harness();
    const chats = Array.from({ length: 30 }, (_, i) => `9665011101${String(i).padStart(2, "0")}@c.us`);
    await Promise.all(chats.map((c) => h.core.onIncoming(h.msg({ chatId: c, id: "id-" + c }))));
    expect(h.sent).toHaveLength(30);
    expect(h.maxTyping()).toBe(1);
    for (const s of h.sent) expect(h.sent.filter((x) => x.at > s.at - 60_000 && x.at <= s.at).length).toBeLessThanOrEqual(20);
  });

  it("BA22 at start, the waiting messages of a chat are answered once, together; chats are taken one after another", async () => {
    const t0 = Math.floor(Date.parse("2026-10-24T10:00:00Z") / 1000);
    const other = "966501110007@c.us";
    const h = harness({ unread: [
      { chatId: GUEST, messages: [
        { id: "u1", chatId: GUEST, fromMe: false, type: "chat", body: "السلام عليكم", timestamp: t0 - 900 },
        { id: "u2", chatId: GUEST, fromMe: false, type: "image", body: "", timestamp: t0 - 800 },
        { id: "u3", chatId: GUEST, fromMe: false, type: "chat", body: "متى الدخول؟", timestamp: t0 - 700 }] },
      { chatId: other, messages: [{ id: "u4", chatId: other, fromMe: false, type: "chat", body: "مرحبا", timestamp: t0 - 600 }] },
    ] });
    expect(await h.core.catchUp()).toBe(2);
    expect(h.of("message")).toEqual([
      expect.objectContaining({ id: "u3", chat: GUEST, type: "text", text: "السلام عليكم\n[image]\nمتى الدخول؟" }),
      expect.objectContaining({ id: "u4", chat: other, text: "مرحبا" }),
    ]);
    expect(h.sent.map((s) => s.chatId)).toEqual([GUEST, other]);
    expect(combine([{ id: "a", type: "image", body: "" }, { id: "b", type: "ptt", body: "" }])).toMatchObject({ id: "b", type: "ptt", body: "[image]\n[voice]" });
  });

  it("BA23 a chat is marked read only after the answer went out; a failed send leaves it unread, tells the inbox, and repeated failures reopen WhatsApp", async () => {
    const ok = harness();
    await ok.core.onIncoming(ok.msg());
    expect(ok.events).toEqual(["send:" + GUEST, "seen:" + GUEST]);

    const troubles: string[] = [];
    const h = harness({ sendFails: true, reply: () => ({ ok: true, replies: ["أهلًا"], turn: { thread: "T2", after: "2026-10-24T09:00:00Z" } }) });
    h.core.onTrouble = (why: string) => troubles.push(why);
    for (const c of ["966501110021@c.us", "966501110022@c.us", "966501110023@c.us"]) await h.core.onIncoming(h.msg({ chatId: c, id: "f-" + c }));
    expect(h.seen).toEqual([]);
    expect(h.of("undelivered")).toHaveLength(3);
    expect(h.of("undelivered")[0]).toEqual({ turn: { thread: "T2", after: "2026-10-24T09:00:00Z" }, reason: "send_failed" });
    expect(troubles).toEqual(["send_failed"]);
  });

  it("BA24 a send WhatsApp did not confirm is not counted as sent (a staff reply is reported failed, not marked sent)", async () => {
    const h = harness({ sendNoId: true, poll: () => ({ ok: true, enabled: true, auto_reply: true, display_phone: BRANCH_PHONE, outbox: [{ id: "OB3", chat_id: GUEST, text: "تفضل" }] }) });
    h.core.setStatus("connected");
    await h.core.pollOnce();
    expect(h.of("ack")).toEqual([expect.objectContaining({ id: "OB3", ok: false, error: "send_failed" })]);
  });

  it("BA25 a confirmation the server did not get is kept and sent with a later poll (the reply is never typed twice)", async () => {
    let down = true; let first = true;
    const h = harness({ failAck: () => (down ? Object.assign(new Error("network"), { status: 0 }) : null),
      poll: () => { const r = { ok: true, enabled: true, auto_reply: true, display_phone: BRANCH_PHONE, outbox: first ? [{ id: "OB4", chat_id: GUEST, text: "الغرفة جاهزة" }] : [] }; first = false; return r; } });
    h.core.setStatus("connected");
    await h.core.pollOnce();
    expect(h.sent).toHaveLength(1);
    expect(h.of("ack")).toHaveLength(3);                                       // three tries, then kept
    down = false;
    await h.core.pollOnce();
    expect(h.of("ack")).toHaveLength(4);
    expect(h.of("ack")[3]).toMatchObject({ id: "OB4", ok: true, wa_id: expect.stringContaining("OUT") });
    await h.core.pollOnce();
    expect(h.of("ack")).toHaveLength(4);                                       // confirmed once, then forgotten
    expect(h.sent).toHaveLength(1);
  });

  it("BA26 a quiet chat: at most 10 of its messages reach the inbox per quiet spell; staff replies to it are still typed", async () => {
    const h = harness({ reply: (b: Any) => (b.answer === false ? { ok: true, replies: [], silent: "paused" } : { ok: true, replies: ["أهلًا"] }),
      poll: () => ({ ok: true, enabled: true, auto_reply: true, display_phone: BRANCH_PHONE, outbox: [{ id: "OB5", chat_id: GUEST, text: "معك الاستقبال" }] }) });
    for (let i = 0; i < 30; i++) await h.core.onIncoming(h.msg({ body: "spam" + i }));
    expect(h.of("message").filter((b: Any) => b.answer === false)).toHaveLength(10);
    h.core.setStatus("connected");
    await h.core.pollOnce();
    expect(h.of("ack")).toEqual([expect.objectContaining({ id: "OB5", ok: true })]);
    expect(h.sent.at(-1)!.text).toBe("معك الاستقبال");
  });

  it("BA27 a message the server already handled is not answered again, and the log says so", async () => {
    const h = harness({ reply: () => ({ ok: true, replies: [], duplicate: true }) });
    await h.core.onIncoming(h.msg());
    expect(h.sent).toEqual([]);
    expect(h.lines.some(([lvl, ar]) => lvl === "info" && ar.includes("عولجت من قبل"))).toBe(true);
  });

  it("BA28 the branch's per-minute limit on the server (429) is waited out, not hammered", async () => {
    let n = 0;
    const h = harness({ reply: () => { if (++n === 1) throw Object.assign(new Error("rate_limited"), { status: 429 }); return { ok: true, replies: ["تم"] }; } });
    await h.core.onIncoming(h.msg());
    expect(h.sleeps).toContain(30_000);
    expect(h.sent.map((s) => s.text)).toEqual(["تم"]);
  });

  it("BA29 WhatsApp side: a chat marked unread by hand, groups and channels are left alone at start; an unconfirmed send has no id", async () => {
    const mk = (id: string, unreadCount: number, isGroup = false, n = 3) => ({ id: { _serialized: id }, isGroup, unreadCount,
      fetchMessages: async ({ limit }: Any) => Array.from({ length: n }, (_, i) => ({ id: { _serialized: `${id}_${i}` }, from: id, fromMe: false, type: "chat", body: "m" + i, timestamp: 1 })).slice(-limit) });
    const client = {
      getChats: async () => [mk("966501110031@c.us", 2), mk("966501110032@c.us", -1), mk("120363025246125486@g.us", 4, true), mk("120363041234567890@newsletter", 1), mk("966501110033@c.us", 0)],
      sendMessage: async () => undefined,
    };
    const wa = waAdapter(client);
    const list = await wa.unreadChats(5);
    expect(list.map((c: Any) => c.chatId)).toEqual(["966501110031@c.us"]);
    expect(list[0].messages.map((m: Any) => m.body)).toEqual(["m1", "m2"]);
    expect(await wa.sendText("966501110031@c.us", "x")).toEqual({ id: null });
  });
});

describe("reception computer program — settings, browser, server client", () => {
  it("BA15 bridge-config.json: read from the program's folder, or the newest valid one copied in from Downloads", () => {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), "wa-home-"));
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "wa-root-"));
    fs.mkdirSync(path.join(home, "Downloads"));
    const good = { server: "https://abc.supabase.co/functions/v1/wa-bridge", key: KEY, branch: "فرع الرياض", branch_phone: "966500000100" };
    expect(findConfig(root, { home })).toBeNull();
    fs.writeFileSync(path.join(home, "Downloads", "bridge-config (1).json"), JSON.stringify({ ...good, key: "zb_bad" }));
    fs.writeFileSync(path.join(home, "Downloads", "bridge-config.json"), JSON.stringify(good));
    const f = findConfig(root, { home });
    expect(f.config).toMatchObject({ server: good.server, key: KEY, branch_phone: "966500000100", headless: false });
    expect(fs.existsSync(path.join(root, "bridge-config.json"))).toBe(true);
    expect(() => validateConfig({ ...good, server: "http://abc.supabase.co/functions/v1/wa-bridge" })).toThrow(/https/);
    expect(() => validateConfig({ ...good, server: "https://evil.example/other" })).toThrow();
    expect(() => validateConfig({ ...good, key: "zb_123" })).toThrow(/key/);
  });

  it("BA16 the browser is the computer's own Chrome or Edge (configured path first)", () => {
    const env = { PROGRAMFILES: "C:\\Program Files", "PROGRAMFILES(X86)": "C:\\Program Files (x86)", LOCALAPPDATA: "C:\\Users\\r\\AppData\\Local" };
    const list = browserCandidates(env, "win32");
    expect(list[0]).toBe("C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe");
    expect(list).toContain("C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe");
    const edgeOnly = (p: string) => p.endsWith("msedge.exe");
    expect(findBrowser(null, { env, platform: "win32", exists: edgeOnly })).toBe("C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe");
    expect(findBrowser("D:\\Chrome\\chrome.exe", { env, platform: "win32", exists: () => true })).toBe("D:\\Chrome\\chrome.exe");
    expect(findBrowser(null, { env, platform: "win32", exists: () => false })).toBeNull();
  });

  it("BA17 the server client sends the key in a header and turns refusals into errors with their status", async () => {
    const seen: Any[] = [];
    const fetchImpl = async (url: string, init: Any) => { seen.push({ url, init }); return new Response(JSON.stringify({ error: "bad_key" }), { status: 401 }); };
    const api = createApi({ server: "https://abc.supabase.co/functions/v1/wa-bridge", key: KEY }, { fetchImpl });
    await expect(api.message({ id: "1" })).rejects.toMatchObject({ status: 401, message: "bad_key" });
    expect(seen[0].init.headers["x-bridge-key"]).toBe(KEY);
    expect(JSON.parse(seen[0].init.body)).toMatchObject({ action: "message", id: "1" });
  });

  it("BA18 whatsapp-web.js messages are read the same way for guests and for the program's own sends", () => {
    expect(toMsg({ id: { _serialized: "false_1@c.us_A" }, from: "1@c.us", to: "me@c.us", fromMe: false, type: "chat", body: "hi", timestamp: 5, _data: { notifyName: "N" } }))
      .toMatchObject({ id: "false_1@c.us_A", chatId: "1@c.us", fromMe: false, name: "N", timestamp: 5 });
    expect(toMsg({ id: { _serialized: "true_1@c.us_B" }, from: "me@c.us", to: "1@c.us", fromMe: true, type: "chat", body: "x" }).chatId).toBe("1@c.us");
  });
});
