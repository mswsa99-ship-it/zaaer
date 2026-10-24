/**
 * The reception computer's server code end to end — SIM01–SIM16. The demo's WhatsApp simulator runs
 * supabase/functions/_shared/wa_bridge.ts (the wa-bridge function's logic) against the in-browser demo store, so these
 * tests drive the same queries and RPCs the deployed function makes, from a guest's first message to a staff reply
 * typed back by the program.
 */
import { describe, it, expect, beforeAll, beforeEach, vi } from "vitest";

type Demo = typeof import("../../src/demo/client");
type Sim = typeof import("../../src/demo/whatsappSim");
let demo: Demo; let sim: Sim;
let staff: ReturnType<Demo["createDemoClient"]>;
let BRANCH: string;

const memStorage = () => {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, String(v)), removeItem: (k: string) => void m.delete(k), clear: () => m.clear(), key: () => null, length: 0 };
};
async function rpc<T = any>(fn: string, args: Record<string, unknown>): Promise<T> { // eslint-disable-line @typescript-eslint/no-explicit-any
  const { data, error } = await staff.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}
const GUEST2 = "966501110010";   // the seed's guest with two current stays

beforeAll(async () => {
  (globalThis as any).window = globalThis; // eslint-disable-line @typescript-eslint/no-explicit-any
  (globalThis as any).localStorage = memStorage(); // eslint-disable-line @typescript-eslint/no-explicit-any
  (globalThis as any).sessionStorage = memStorage(); // eslint-disable-line @typescript-eslint/no-explicit-any
  (globalThis as any).location = { href: "https://demo.test/index.html#/" }; // eslint-disable-line @typescript-eslint/no-explicit-any
  demo = await import("../../src/demo/client");
  sim = await import("../../src/demo/whatsappSim");
  staff = demo.createDemoClient();
});

beforeEach(async () => {
  demo.resetDemo();
  await staff.auth.signInWithPassword({ email: "owner@demo.sa", password: "demo" });
  const list = await rpc<Array<{ branch_id: string; mode: string }>>("fn_admin_whatsapp_channels", {});
  BRANCH = list.find((x) => x.mode === "web_bridge" && demo.demoBridgeKey(x.branch_id))!.branch_id;
});

const threadOf = async (phone: string) => {
  const { data } = await demo.createDemoServiceClient().from("conversations").select("*").eq("wa_contact", phone).order("last_message_at", { ascending: false }).limit(1).maybeSingle();
  return data as Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
};
/** the wa-bridge function's handler, called as the program calls it */
const bridge = async () => {
  const { handleBridge } = await import("../../supabase/functions/_shared/wa_bridge");
  const db = demo.createDemoServiceClient();
  const env = { appBaseUrl: "", supabaseUrl: "https://demo.invalid", serviceKey: "x", fetcher: demo.demoFunctionsFetch };
  const key = demo.demoBridgeKey(BRANCH)!;
  return { handleBridge, db, env, key, call: (body: Record<string, unknown>) => handleBridge(db, key, body, env) };
};
const tick = () => new Promise((r) => setTimeout(r, 5));

describe("WhatsApp on the reception computer (server code against the demo store)", () => {
  it("SIM01 «حجوزاتي» with two stays → a numbered list; «2» opens the second with its secure links (masked in the log)", async () => {
    const a = await sim.simSend(BRANCH, GUEST2, "حجوزاتي");
    expect(a.replies).toHaveLength(1);
    expect(a.replies[0]).toMatch(/لديك حجزان/);
    expect(a.replies[0]).toMatch(/1️⃣ .+\n2️⃣ .+\n\nأرسل رقم الخيار\./);
    const b = await sim.simSend(BRANCH, GUEST2, "٢");
    expect(b.replies[0]).toMatch(/^حجزك /);
    expect(b.replies[0]).toMatch(/https:\/\/demo\.test\/index\.html#\/booking\/status\/DEMO[0-9A-F]+/);
    expect(b.replies[0]).toMatch(/1️⃣ وصلت\n2️⃣ التحدث مع موظف\n3️⃣ حجوزاتي/);
    const t = await threadOf(GUEST2);
    expect(t.channel).toBe("whatsapp");
    expect(t.wa_chat_id).toBe(GUEST2 + "@c.us");
    expect(t.guest_token).toMatch(/^DEMO/);
    const { data: msgs } = await demo.createDemoServiceClient().from("conversation_messages").select("content, sender").eq("conversation_id", t.id);
    const stored = (msgs as Array<{ content: string }>).map((m) => m.content).join("\n");
    expect(stored).toContain("/booking/status/…");
    expect(stored).not.toContain(t.guest_token);
  });

  it("SIM02 free text goes to the reception assistant and comes back as text", async () => {
    const r = await sim.simSend(BRANCH, GUEST2, "متى موعد الوصول والمغادرة؟");
    expect(r.replies.join("\n")).toMatch(/الوصول يبدأ من الساعة \d{2}:\d{2}/);
  });

  it("SIM03 a receptionist answering in WhatsApp itself silences the assistant in that chat; the guest's words reach the inbox", async () => {
    await sim.simSend(BRANCH, GUEST2, "مرحبا");
    const h = await sim.simHumanReply(BRANCH, GUEST2, "أهلًا، معك أحمد من الاستقبال");
    expect(Date.parse(h.until!)).toBeGreaterThan(Date.now() + 59 * 60_000);
    const r = await sim.simSend(BRANCH, GUEST2, "شكرًا، متى أقدر أدخل؟");
    expect(r).toEqual({ replies: [], silent: "human" });
    const t = await threadOf(GUEST2);
    const { data: msgs } = await demo.createDemoServiceClient().from("conversation_messages").select("sender, content, meta").eq("conversation_id", t.id);
    const list = msgs as Array<{ sender: string; content: string; meta: Record<string, unknown> }>;
    expect(list.some((m) => m.sender === "supervisor" && m.meta?.via === "whatsapp_app")).toBe(true);
    expect(list.some((m) => m.sender === "guest" && m.meta?.unanswered === "human" && m.content.includes("متى أقدر أدخل"))).toBe(true);
  });

  it("SIM04 «return to the assistant» in the inbox ends the pause at once", async () => {
    await sim.simSend(BRANCH, GUEST2, "مرحبا");
    await sim.simHumanReply(BRANCH, GUEST2, "تفضل");
    const t = await threadOf(GUEST2);
    await rpc("fn_conversation_take", { p_conversation: t.id, p_take: false });
    const r = await sim.simSend(BRANCH, GUEST2, "متى موعد الوصول؟");
    expect(r.silent).toBeUndefined();
    expect(r.replies.length).toBeGreaterThan(0);
  });

  it("SIM05 a staff reply from the inbox is queued, typed once by the program, and shows as sent", async () => {
    await sim.simSend(BRANCH, GUEST2, "مرحبا");
    const t = await threadOf(GUEST2);
    const { data } = await staff.functions.invoke("whatsapp-send", { body: { mode: "reply", conversation_id: t.id, text: "أهلًا بك، الغرفة جاهزة" } });
    expect(data).toMatchObject({ ok: true, queued: true, delivered: false });
    const first = await sim.simPollStaff(BRANCH, "966500000100");
    const second = await sim.simPollStaff(BRANCH, "966500000100");
    expect(first).toEqual([{ id: expect.any(String), chat_id: GUEST2 + "@c.us", text: "أهلًا بك، الغرفة جاهزة" }]);
    expect(second).toEqual([]);
    const { data: msgs } = await demo.createDemoServiceClient().from("conversation_messages").select("sender, meta").eq("conversation_id", t.id);
    expect((msgs as Array<{ sender: string; meta: Record<string, unknown> }>).find((m) => m.sender === "supervisor")?.meta?.delivery).toBe("sent");
    // the program's heartbeat shows the link as online to the owner
    const row = (await rpc<Array<Record<string, unknown>>>("fn_admin_whatsapp_channels", {})).find((x) => x.branch_id === BRANCH)!;
    expect(row).toMatchObject({ bridge_online: true, bridge_status: "connected", bridge_phone: "966500000100", status: "active" });
  });

  it("SIM06 auto-reply off: messages are recorded for staff, nothing is typed", async () => {
    await rpc("fn_admin_whatsapp_save", { p_branch: BRANCH, p: { auto_reply: false } });
    expect(await sim.simSend(BRANCH, GUEST2, "مرحبا")).toEqual({ replies: [], silent: "auto_reply_off" });
  });

  it("SIM07 a number with no stays is told so (last 4 digits only) and offered booking or a staff member", async () => {
    const r = await sim.simSend(BRANCH, "966509990000", "حجوزاتي");
    expect(r.replies[0]).toContain("المنتهي بـ 0000");
    expect(r.replies[0]).not.toContain("966509990000");
    expect(r.replies[0]).toMatch(/1️⃣ احجز الآن\n2️⃣ التحدث مع موظف/);
  });

  it("SIM08 the same WhatsApp message handed in twice is answered once; a wrong or replaced key is refused", async () => {
    const { handleBridge } = await import("../../supabase/functions/_shared/wa_bridge");
    const db = demo.createDemoServiceClient();
    const env = { appBaseUrl: "", supabaseUrl: "https://demo.invalid", serviceKey: "x", fetcher: demo.demoFunctionsFetch };
    const key = demo.demoBridgeKey(BRANCH)!;
    const body = { action: "message", id: "false_966501110010@c.us_ABC", chat: GUEST2 + "@c.us", type: "text", text: "حجوزاتي" };
    const one = await handleBridge(db, key, body, env);
    const two = await handleBridge(db, key, body, env);
    expect((one.body.replies as string[]).length).toBe(1);
    expect(two.body).toMatchObject({ duplicate: true, replies: [] });
    expect((await handleBridge(db, "zb_" + "0".repeat(64), body, env)).status).toBe(401);
    expect((await handleBridge(db, "not-a-key", body, env)).status).toBe(401);
    await rpc("fn_admin_whatsapp_save", { p_branch: BRANCH, p: { regenerate_bridge_key: true } });
    expect((await handleBridge(db, key, { ...body, id: "other" }, env)).status).toBe(401);
  });

  it("SIM09 groups and system messages are never answered", async () => {
    const { handleBridge } = await import("../../supabase/functions/_shared/wa_bridge");
    const db = demo.createDemoServiceClient();
    const env = { appBaseUrl: "", supabaseUrl: "https://demo.invalid", serviceKey: "x", fetcher: demo.demoFunctionsFetch };
    const key = demo.demoBridgeKey(BRANCH)!;
    expect((await handleBridge(db, key, { action: "message", id: "g1", chat: "120363025246125486@g.us", type: "text", text: "1" }, env)).status).toBe(400);
    expect((await handleBridge(db, key, { action: "message", id: "s1", chat: GUEST2 + "@c.us", type: "e2e_notification", text: "" }, env)).body).toMatchObject({ silent: "ignored" });
  });

  it("SIM10 a photo is not read: the guest is pointed to the secure link instead", async () => {
    const { handleBridge } = await import("../../supabase/functions/_shared/wa_bridge");
    const r = await handleBridge(demo.createDemoServiceClient(), demo.demoBridgeKey(BRANCH)!, { action: "message", id: "img1", chat: GUEST2 + "@c.us", type: "image", text: "" },
      { appBaseUrl: "", supabaseUrl: "https://demo.invalid", serviceKey: "x", fetcher: demo.demoFunctionsFetch });
    expect((r.body.replies as string[])[0]).toMatch(/^أقرأ الرسائل النصية فقط/);
  });

  it("SIM11 a phone other than the branch's is refused: nothing it hands in is recorded or answered", async () => {
    const b = await bridge();
    const count = async () => ((await b.db.from("conversations").select("id").eq("wa_contact", GUEST2)).data as unknown[]).length;
    const before = await count();
    expect(await b.call({ action: "message", id: "w1", chat: GUEST2 + "@c.us", linked: "966555000111", type: "text", text: "حجوزاتي" })).toEqual({ status: 409, body: { error: "wrong_number" } });
    expect((await b.call({ action: "human", id: "w2", chat: GUEST2 + "@c.us", linked: "966555000111", type: "text", text: "رسالة شخصية" })).status).toBe(409);
    expect(await count()).toBe(before);
    const ok = await b.call({ action: "message", id: "w3", chat: GUEST2 + "@c.us", linked: "+966 50 000 0100", type: "text", text: "حجوزاتي" });
    expect(ok.status).toBe(200);
    expect((ok.body.replies as string[])[0]).toMatch(/لديك حجزان/);
  });

  it("SIM12 a chat the program keeps quiet: the message is recorded for staff («paused»), nothing is answered", async () => {
    const b = await bridge();
    const r = await b.call({ action: "message", id: "q1", chat: GUEST2 + "@c.us", type: "text", text: "مرحبا", answer: false });
    expect(r.body).toEqual({ ok: true, replies: [], silent: "paused" });
    const t = await threadOf(GUEST2);
    const { data } = await b.db.from("conversation_messages").select("sender, meta").eq("conversation_id", t.id);
    expect(data).toEqual([expect.objectContaining({ sender: "guest", meta: expect.objectContaining({ unanswered: "paused" }) })]);
  });

  it("SIM13 an album: the «text only» notice is typed once; every photo reaches the inbox", async () => {
    const b = await bridge();
    const out: number[] = [];
    for (let i = 0; i < 3; i++) out.push(((await b.call({ action: "message", id: "al" + i, chat: GUEST2 + "@c.us", type: "image", text: "" })).body.replies as string[]).length);
    expect(out).toEqual([1, 0, 0]);
    const t = await threadOf(GUEST2);
    const { data } = await b.db.from("conversation_messages").select("sender").eq("conversation_id", t.id);
    expect((data as Array<{ sender: string }>).filter((m) => m.sender === "guest")).toHaveLength(3);
  });

  it("SIM14 handling that fails half-way can be handed in again (the message is not marked handled)", async () => {
    const b = await bridge();
    let thrown = false;
    const flaky = { from: (t: string) => b.db.from(t), rpc: (fn: string, a: Record<string, unknown>) => {
      if (fn === "fn_whatsapp_phone_session" && !thrown) { thrown = true; throw new Error("boom"); }
      return b.db.rpc(fn, a);
    } };
    const body = { action: "message", id: "fl1", chat: GUEST2 + "@c.us", type: "text", text: "حجوزاتي" };
    await expect(b.handleBridge(flaky, b.key, body, b.env)).rejects.toThrow("boom");
    const again = await b.handleBridge(flaky, b.key, body, b.env);
    expect(again.body.duplicate).toBeUndefined();
    expect((again.body.replies as string[])[0]).toMatch(/لديك حجزان/);
    expect((await b.handleBridge(flaky, b.key, body, b.env)).body).toMatchObject({ duplicate: true });   // handled now: once only
  });

  it("SIM15 replies the program could not type are marked «not delivered» in the inbox, and their options no longer stand", async () => {
    const b = await bridge();
    await b.call({ action: "message", id: "u0", chat: GUEST2 + "@c.us", type: "text", text: "مرحبا" });
    await tick();
    const r = await b.call({ action: "message", id: "u1", chat: GUEST2 + "@c.us", type: "text", text: "حجوزاتي" });
    const turn = r.body.turn as { thread: string; after: string | null };
    expect(turn.thread).toBe((await threadOf(GUEST2)).id);
    expect((await threadOf(GUEST2)).wa_menu).not.toBeNull();
    expect((await b.call({ action: "undelivered", turn, reason: "send_failed" })).body).toMatchObject({ ok: true, marked: 1 });
    const { data } = await b.db.from("conversation_messages").select("sender, meta, created_at").eq("conversation_id", turn.thread).order("created_at");
    const bot = (data as Array<{ sender: string; meta: Record<string, unknown> | null }>).filter((m) => m.sender === "assistant");
    expect(bot.at(-1)!.meta).toMatchObject({ delivery: "failed", error: "send_failed" });
    expect(bot[0].meta?.delivery).toBeUndefined();                        // the first turn's reply did go out
    expect((await threadOf(GUEST2)).wa_menu).toBeNull();
    expect((await b.call({ action: "undelivered", turn: { thread: "00000000-0000-4000-8000-000000000000", after: null } })).status).toBe(400);
  });

  it("SIM16 a confirmation that arrives after the 5-minute wait still marks the staff reply sent (0024)", async () => {
    vi.useFakeTimers({ toFake: ["Date"], now: Date.now() });
    try {
      await sim.simSend(BRANCH, GUEST2, "مرحبا");
      const t = await threadOf(GUEST2);
      await staff.functions.invoke("whatsapp-send", { body: { mode: "reply", conversation_id: t.id, text: "تفضل" } });
      const b = await bridge();
      const p = await b.call({ action: "poll", status: "connected", phone: "966500000100", wait: 0 });
      const item = (p.body.outbox as Array<{ id: string }>)[0];
      vi.setSystemTime(Date.now() + 6 * 60_000);
      await b.call({ action: "poll", status: "connected", phone: "966500000100", wait: 0 });   // the wait is over: reported failed
      const meta = async () => ((await b.db.from("conversation_messages").select("meta").eq("conversation_id", t.id).eq("sender", "supervisor").maybeSingle()).data as { meta: Record<string, unknown> }).meta;
      expect(await meta()).toMatchObject({ delivery: "failed", error: "no_ack" });
      expect((await b.call({ action: "ack", id: item.id, ok: true, wa_id: "true_LATE" })).body).toEqual({ ok: true });
      const m = await meta();
      expect(m.delivery).toBe("sent");
      expect(m.error).toBeUndefined();
    } finally { vi.useRealTimers(); }
  });
});
