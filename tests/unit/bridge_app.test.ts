/**
 * The program on the reception computer (bridge/src) — BA01–BA16, with WhatsApp and the server faked:
 * what it answers, how it types, what it leaves to staff, how it tells its own messages from a receptionist's,
 * the limits that keep the number safe, staff replies from the inbox, and the settings file and browser it finds.
 */
import { describe, it, expect } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
// @ts-expect-error — plain JavaScript modules of the Windows program
import { Bridge, mask } from "../../bridge/src/core.mjs";
// @ts-expect-error — plain JavaScript module
import { findConfig, validateConfig } from "../../bridge/src/config.mjs";
// @ts-expect-error — plain JavaScript module
import { findBrowser, browserCandidates } from "../../bridge/src/browser.mjs";
// @ts-expect-error — plain JavaScript module
import { createApi } from "../../bridge/src/api.mjs";
// @ts-expect-error — plain JavaScript module
import { createLogger } from "../../bridge/src/log.mjs";
// @ts-expect-error — plain JavaScript module
import { toMsg } from "../../bridge/src/wa.mjs";

type Any = any; // eslint-disable-line @typescript-eslint/no-explicit-any
const GUEST = "966501110006@c.us";
const KEY = "zb_" + "a1".repeat(32);

function harness(o: { reply?: (b: Any) => Any; poll?: (b: Any) => Any; unread?: Any[]; lidPhone?: string | null; sendFails?: boolean; failMessage?: Any } = {}) {
  let t = Date.parse("2026-10-24T10:00:00Z");
  const now = () => t;
  const sleeps: number[] = [];
  const sleep = async (ms: number) => { sleeps.push(ms); t += ms; };
  const lines: Array<[string, string, string?]> = [];
  const log = { info: (a: string, e?: string) => lines.push(["info", a, e]), warn: (a: string, e?: string) => lines.push(["warn", a, e]), error: (a: string, e?: string) => lines.push(["error", a, e]) };
  const sent: Array<{ chatId: string; text: string; id: string }> = []; const seen: string[] = []; const typing: string[] = [];
  let seq = 0;
  const wa = {
    sendText: async (chatId: string, text: string) => { if (o.sendFails) throw new Error("not on WhatsApp"); const id = `true_${chatId}_OUT${++seq}`; sent.push({ chatId, text, id }); return { id }; },
    markSeen: async (c: string) => { seen.push(c); }, typing: async (c: string) => { typing.push(c); }, clearTyping: async () => {},
    resolvePhone: async () => o.lidPhone ?? null, unreadChats: async () => o.unread ?? [],
  };
  const calls: Array<[string, Any]> = [];
  const api = {
    message: async (b: Any) => { calls.push(["message", b]); if (o.failMessage) throw o.failMessage; return o.reply ? o.reply(b) : { ok: true, replies: ["أهلًا بك"] }; },
    human: async (b: Any) => { calls.push(["human", b]); return { ok: true }; },
    poll: async (b: Any) => { calls.push(["poll", b]); return o.poll ? o.poll(b) : { ok: true, enabled: true, auto_reply: true, outbox: [] }; },
    ack: async (b: Any) => { calls.push(["ack", b]); return { ok: true }; },
  };
  const core = new Bridge({ api, log, now, sleep, random: () => 0.5, version: "test" });
  core.attach(wa);
  const msg = (over: Any = {}) => ({ id: `false_${GUEST}_${++seq}`, chatId: GUEST, fromMe: false, type: "chat", body: "مرحبا", timestamp: Math.floor(t / 1000), name: "ضيف", ...over });
  return { core, calls, sent, seen, typing, lines, sleeps, msg, advance: (ms: number) => { t += ms; } };
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

  it("BA07 a chat that floods (another bot, a loop) is left to staff for a while", async () => {
    const h = harness();
    for (let i = 0; i < 15; i++) await h.core.onIncoming(h.msg({ body: "x" + i }));
    // 6 replies a minute per chat; the 7th message is still handed in (recorded for staff) but not answered,
    // and the chat is then left to staff
    expect(h.sent.length).toBe(6);
    expect(h.calls.length).toBe(7);
    expect(h.lines.some(([lvl]) => lvl === "warn")).toBe(true);
    h.advance(16 * 60_000);
    await h.core.onIncoming(h.msg({ body: "بعد" }));
    expect(h.calls.length).toBe(8);
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
