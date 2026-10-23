/**
 * The reception computer's server code end to end — SIM01–SIM10. The demo's WhatsApp simulator runs
 * supabase/functions/_shared/wa_bridge.ts (the wa-bridge function's logic) against the in-browser demo store, so these
 * tests drive the same queries and RPCs the deployed function makes, from a guest's first message to a staff reply
 * typed back by the program.
 */
import { describe, it, expect, beforeAll, beforeEach } from "vitest";

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
});
