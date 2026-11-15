/**
 * The guest journey on WhatsApp (0070, W3–W4) — the flow against fakes (CX20–CX25, DR20–DR21), then the reception
 * computer's server code end to end against the demo store at 10:30 on a day of departure (JM20, DR22): the server's
 * 10 AM options, the guest's numbered answers, «غادرت وسلّمت المفتاح», the reception's check-out and the receipt of the
 * deposit's return — only once the return is recorded.
 */
import { describe, it, expect, beforeAll, afterEach, vi } from "vitest";
import { runWaFlow, WA_TEXTS, CO, type WaBooking, type WaFlowPorts, type WaThread, type WaCheckout, type WaCheckoutChoice } from "../../supabase/functions/_shared/wa_flow";
import { asksForNumber } from "../../supabase/functions/_shared/wa_text";
import { BTN, type WaInbound } from "../../supabase/functions/_shared/whatsapp";

const FROM = "966501110003";
const BASE = "https://hotel.example/app";
const offer = (over: Partial<WaCheckout> = {}): WaCheckout => ({
  open: true, check_out: "2026-11-15", room_number: "201", free_until: "13:00",
  night: { available: true, price_halalas: 40000 }, hours: { max: 3, price_halalas: 500, until_limit: "16:00", next_guest: true },
  hold_minutes: 30, choice: null, late_checkout_until: null, instructions: "ضع البطاقة في الصندوق عند الباب.", departed_at: null, guide_checkout: true,
  deposit_halalas: 30000, refund_hours: 3, balance_due: 0, request: null, ...over,
});
const b = (ref: string, status = "checked_in"): WaBooking => ({ ref, internal_ref: "R-" + ref, status, check_in: "2026-11-12", check_out: "2026-11-15", nights: 3, category_name: "شقة" });

interface World {
  threads: Array<WaThread & { closed: boolean }>;
  sent: Array<Record<string, any>>; // eslint-disable-line @typescript-eslint/no-explicit-any
  saved: Array<{ sender: string; content: string }>;
  chosen: Array<{ tok: string; choice: WaCheckoutChoice; hours: number | null }>;
  departed: number;
  offer: WaCheckout | null;
  refuse: string | null;
}
function world(o: WaCheckout | null, opts: { bound?: boolean; bookings?: WaBooking[] } = {}): World & { ports: WaFlowPorts } {
  const w: World = { threads: opts.bound === false ? [] : [{ id: "T1", guest_token: "GT1", closed: false }], sent: [], saved: [], chosen: [], departed: 0, offer: o, refuse: null };
  let n = 1;
  const bookings = opts.bookings ?? [b("BK-1")];
  const ports: WaFlowPorts = {
    appBaseUrl: BASE,
    findThread: async () => w.threads.find((t) => !t.closed) ?? null,
    newThread: async () => { const t = { id: "T" + ++n, guest_token: null, closed: false }; w.threads.push(t); return t; },
    closeThread: async (id) => { w.threads.find((t) => t.id === id)!.closed = true; },
    touch: async () => {},
    save: async (_t, sender, content) => { w.saved.push({ sender, content }); },
    bookings: async () => ({ token: "PS", list: bookings }),
    openBooking: async (_t, ref) => "GT-" + ref,
    bindThread: async (id, gt) => { w.threads.find((t) => t.id === id)!.guest_token = gt; },
    ask: async () => ({ reply: "أهلًا", actions: [] }),
    send: async (p) => { w.sent.push(p); },
    checkoutOffer: async () => w.offer,
    chooseCheckout: async (tok, choice, hours) => {
      w.chosen.push({ tok, choice, hours });
      if (w.refuse) return { error: w.refuse };
      const o = w.offer!;
      if (choice === "on_time") w.offer = { ...o, choice: "on_time" };
      else if (choice === "cancel") w.offer = { ...o, request: null };
      else w.offer = { ...o, request: { id: "Q1", kind: choice === "night" ? "night" : "hours", hours, late_until: hours ? `${13 + hours}:00` : null, amount_halalas: choice === "night" ? 40000 : 500 * (hours ?? 0), status: "held", hold_until: "2026-11-15T08:00:00.000Z" } };
      return { offer: w.offer };
    },
    departed: async () => { w.departed++; return { already: w.departed > 1 }; },
  };
  return Object.assign(w, { ports });
}
const tap = (replyId: string, title = ""): WaInbound => ({ phoneNumberId: "web", from: FROM, id: "m" + Math.random(), type: "interactive", text: title, replyId });
const text = (t: string): WaInbound => ({ phoneNumberId: "web", from: FROM, id: "m" + Math.random(), type: "text", text: t });
const bodyOf = (p: Record<string, any>) => p.type === "text" ? p.text.body : p.interactive.body.text; // eslint-disable-line @typescript-eslint/no-explicit-any
const buttonIds = (p: Record<string, any>) => p.interactive?.action?.buttons?.map((x: any) => x.reply.id) ?? []; // eslint-disable-line @typescript-eslint/no-explicit-any
const rowIds = (p: Record<string, any>) => p.interactive?.action?.sections?.[0]?.rows?.map((r: any) => r.id) ?? []; // eslint-disable-line @typescript-eslint/no-explicit-any

describe("the day of departure on WhatsApp (W3–W4, the flow)", () => {
  it("CX20 «سأخرج في الموعد»: the choice is recorded, the instructions come before «غادرت وسلّمت المفتاح», the guide's link is not kept in the log", async () => {
    const w = world(offer());
    await runWaFlow(tap(CO.ON_TIME, "سأخرج في الموعد (12–1)"), w.ports);
    expect(w.chosen).toEqual([{ tok: "GT1", choice: "on_time", hours: null }]);
    const body = bodyOf(w.sent[0]);
    expect(body).toContain("قبل 13:00");
    expect(body.indexOf("ضع البطاقة في الصندوق")).toBeLessThan(body.indexOf("غادرت وسلّمت المفتاح"));
    expect(body).toContain(`${BASE}/booking/status/GT1`);
    expect(buttonIds(w.sent[0])).toEqual([CO.LEFT, BTN.HUMAN]);
    const stored = w.saved.filter((s) => s.sender === "assistant").map((s) => s.content).join("\n");
    expect(stored).not.toContain("GT1");
    expect(stored).toContain("/booking/status/…");
  });

  it("CX21 «ساعات بعد 13:00»: one row per hour up to the limit, each with its end and its price; the question is numbered (no «كم»)", async () => {
    const w = world(offer());
    await runWaFlow(tap(CO.HOURS), w.ports);
    const p = w.sent[0];
    expect(rowIds(p)).toEqual([CO.HOUR + 1, CO.HOUR + 2, CO.HOUR + 3]);
    const rows = p.interactive.action.sections[0].rows;
    expect(rows[0].title).toBe("ساعة واحدة — حتى 14:00");
    expect(rows[1].title).toBe("ساعتان — حتى 15:00");
    expect(rows[2]).toMatchObject({ title: "3 ساعات — حتى 16:00", description: "15.00 ر.س" });
    expect(bodyOf(p)).toContain("الحد 16:00");
    expect(asksForNumber(bodyOf(p))).toBe(false);
    expect(w.chosen).toEqual([]);
  });

  it("CX22 two hours chosen: held while the guest pays at reception, with its amount and its time, and «إلغاء الطلب»", async () => {
    const w = world(offer());
    await runWaFlow(tap(CO.HOUR + 2), w.ports);
    expect(w.chosen).toEqual([{ tok: "GT1", choice: "hours", hours: 2 }]);
    const body = bodyOf(w.sent[0]);
    expect(body).toMatch(/حجزنا لك خروجًا متأخرًا ساعتان حتى 15:00 بمبلغ 10\.00 ر\.س حتى الساعة \d{2}:\d{2}/);
    expect(body).toContain("لدى الاستقبال");
    expect(buttonIds(w.sent[0])).toEqual([CO.CANCEL, BTN.HUMAN]);
  });

  it("CX23 a night refused (the unit is booked tonight): the reason first, then the options without the night", async () => {
    const w = world(offer({ night: { available: false, price_halalas: 40000 } }));
    w.refuse = "VALIDATION: night_unavailable";
    await runWaFlow(tap(CO.NIGHT), w.ports);
    const p = w.sent[0];
    expect(bodyOf(p)).toMatch(/^لا تتاح ليلة إضافية/);
    expect(rowIds(p)).toEqual([CO.ON_TIME, CO.HOURS, CO.LEFT]);
  });

  it("CX24 «خروج» typed in a new thread: the only stay in the house is bound and its options shown", async () => {
    const w = world(offer(), { bound: false });
    await runWaFlow(text("خروج"), w.ports);
    expect(w.threads[0].guest_token).toBe("GT-R-BK-1");
    expect(rowIds(w.sent[0])).toEqual([CO.ON_TIME, CO.NIGHT, CO.HOURS, CO.LEFT]);
    expect(bodyOf(w.sent[0])).toContain("من غرفة 201");
  });

  it("CX25 a guest not in the house asking «تمديد» is told the options are for guests in their unit; nothing is chosen", async () => {
    const w = world(offer(), { bound: false, bookings: [b("BK-2", "confirmed")] });
    await runWaFlow(text("تمديد"), w.ports);
    expect(bodyOf(w.sent[0])).toBe(WA_TEXTS.checkoutNeedsStay);
    expect(buttonIds(w.sent[0])).toEqual([BTN.BOOKINGS, BTN.HUMAN]);
    expect(w.chosen).toEqual([]);
  });

  it("DR20 «غادرت وسلّمت المفتاح»: the reception is told to check the unit, and the deposit's return is promised within its hours", async () => {
    const w = world(offer({ choice: "on_time" }));
    await runWaFlow(tap(CO.LEFT), w.ports);
    expect(w.departed).toBe(1);
    const body = bodyOf(w.sent[0]);
    expect(body).toContain("يفحص الوحدة ثم يؤكد خروجك");
    expect(body).toContain("يُرد تأمينك (300.00 ر.س) خلال 3 ساعات من تأكيد الخروج");
    await runWaFlow(tap(CO.LEFT), w.ports);
    expect(bodyOf(w.sent[1])).toMatch(/^أبلغتنا بمغادرتك من قبل/);
  });

  it("DR21 a held request cancelled by the guest: the stay is as before and the options come back", async () => {
    const w = world(offer({ request: { id: "Q1", kind: "night", hours: null, late_until: null, amount_halalas: 40000, status: "held", hold_until: "2026-11-15T08:00:00.000Z" } }));
    await runWaFlow(tap(CO.CANCEL), w.ports);
    expect(w.chosen).toEqual([{ tok: "GT1", choice: "cancel", hours: null }]);
    expect(bodyOf(w.sent[0])).toMatch(/^ألغينا الطلب\. موعد خروجك اليوم قبل 13:00/);
    expect(rowIds(w.sent[0])).toContain(CO.ON_TIME);
  });
});

// ---------------------------------------------------------------------------------------------------------------
// The reception computer's server code against the demo store, at 10:30 Riyadh time on a day of departure
// ---------------------------------------------------------------------------------------------------------------
type Demo = typeof import("../../src/demo/client");
type Sim = typeof import("../../src/demo/whatsappSim");
let demo: Demo; let sim: Sim;
const memStorage = () => {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, String(v)), removeItem: (k: string) => void m.delete(k), clear: () => m.clear(), key: () => null, length: 0 };
};
const LEAVER = "966501110005";   // the seed's guest of unit U-2, leaving today

describe("the journey end to end on the reception computer (demo store)", () => {
  beforeAll(async () => {
    (globalThis as any).window = globalThis; // eslint-disable-line @typescript-eslint/no-explicit-any
    (globalThis as any).localStorage = memStorage(); // eslint-disable-line @typescript-eslint/no-explicit-any
    (globalThis as any).sessionStorage = memStorage(); // eslint-disable-line @typescript-eslint/no-explicit-any
    (globalThis as any).location = { href: "https://demo.test/index.html#/" }; // eslint-disable-line @typescript-eslint/no-explicit-any
    demo = await import("../../src/demo/client");
    sim = await import("../../src/demo/whatsappSim");
  });
  afterEach(() => { vi.useRealTimers(); });

  it("JM20 at 10:30 the guests leaving today get their options once; «1» chooses on time, the next «1» says they left; the reception sees it to check", async () => {
    vi.useFakeTimers({ toFake: ["Date"], now: new Date("2026-11-15T07:30:00.000Z") });   // 10:30 in Riyadh
    demo.resetDemo();
    const staff = demo.createDemoClient();
    await staff.auth.signInWithPassword({ email: "owner@demo.sa", password: "demo" });
    const rpc = async <T,>(fn: string, args: Record<string, unknown>) => { const { data, error } = await staff.rpc(fn, args); if (error) throw new Error(error.message); return data as T; };
    const channels = await rpc<Array<{ branch_id: string; mode: string }>>("fn_admin_whatsapp_channels", {});
    const BRANCH = channels.find((x) => x.mode === "web_bridge" && demo.demoBridgeKey(x.branch_id))!.branch_id;

    const first = await sim.simPollStaff(BRANCH, "966500000100");
    const options = first.filter((it) => it.chat_id === LEAVER + "@c.us");
    expect(options).toHaveLength(1);
    expect(options[0].text).toMatch(/^صباح الخير\. موعد خروجك اليوم من غرفة U-2 بين 12 و1 ظهرًا\. ماذا تفضّل؟/);
    expect(options[0].text).toMatch(/1️⃣ سأخرج في الموعد \(12–1\)/);
    expect(options[0].text).toContain("التحدث مع موظف");
    expect(options[0].text).toMatch(/أرسل رقم الخيار\.$/);
    // once per stay: a later pick does not send it again
    expect((await sim.simPollStaff(BRANCH, "966500000100")).filter((it) => it.chat_id === LEAVER + "@c.us")).toEqual([]);

    const a = await sim.simSend(BRANCH, LEAVER, "1");
    expect(a.replies.join("\n")).toContain("تم. موعد خروجك اليوم قبل 13:00.");
    expect(a.replies.join("\n")).toMatch(/1️⃣ غادرت وسلّمت المفتاح/);
    const b2 = await sim.simSend(BRANCH, LEAVER, "1");
    expect(b2.replies.join("\n")).toContain("يفحص الوحدة ثم يؤكد خروجك");

    const board = await rpc<{ awaiting_check: Array<{ room_number: string; via: string }>; alerts: Array<{ event: string }> }>("fn_staff_journey", { p_branch: BRANCH });
    expect(board.awaiting_check.map((x) => [x.room_number, x.via])).toEqual([["U-2", "whatsapp"]]);
    expect(board.alerts.some((x) => x.event === "guest_departed")).toBe(true);
  });

  it("DR22 the reception checks the unit and checks the guest out: the confirmation goes out with the deposit's hours; the receipt only after the return is recorded", async () => {
    vi.useFakeTimers({ toFake: ["Date"], now: new Date("2026-11-15T08:00:00.000Z") });   // 11:00 in Riyadh
    demo.resetDemo();
    const staff = demo.createDemoClient();
    await staff.auth.signInWithPassword({ email: "owner@demo.sa", password: "demo" });
    const rpc = async <T,>(fn: string, args: Record<string, unknown>) => { const { data, error } = await staff.rpc(fn, args); if (error) throw new Error(error.message); return data as T; };
    const channels = await rpc<Array<{ branch_id: string; mode: string }>>("fn_admin_whatsapp_channels", {});
    const BRANCH = channels.find((x) => x.mode === "web_bridge" && demo.demoBridgeKey(x.branch_id))!.branch_id;
    const { data: rooms } = await staff.from("rooms").select("id, room_number").eq("room_number", "U-2");
    const { data: stays } = await staff.from("reservations").select("id, status, room_id").eq("room_id", (rooms as Array<{ id: string }>)[0].id).eq("status", "checked_in");
    const res = (stays as Array<{ id: string }>)[0].id;
    await sim.simPollStaff(BRANCH, "966500000100");   // the morning's options go out first

    await rpc("fn_staff_record_inspection", { p: { reservation_id: res, result: "ok" } });
    const out = await rpc<{ ok: boolean; deposit_to_settle_halalas: number }>("fn_staff_check_out", { p: { reservation_id: res } });
    expect(out.ok).toBe(true);
    const told = (await sim.simPollStaff(BRANCH, "966500000100")).filter((it) => it.chat_id === LEAVER + "@c.us").map((it) => it.text);
    expect(told).toHaveLength(1);
    expect(told[0]).toMatch(/^تم تأكيد خروجك من غرفة U-2\. شكرًا لإقامتك معنا\./);
    expect(told[0]).toContain("خلال 3 ساعات: تحويلًا إلى حسابك أو نقدًا من الاستقبال");
    expect(told.join("\n")).not.toContain("رُد إليك تأمينك");

    await rpc("fn_refund", { p: { reservation_id: res, kind: "deposit_refund", amount_halalas: out.deposit_to_settle_halalas, method: "cash", reason: "رد التأمين", idempotency_key: "dr22-refund" } });
    const receipt = (await sim.simPollStaff(BRANCH, "966500000100")).filter((it) => it.chat_id === LEAVER + "@c.us").map((it) => it.text);
    expect(receipt).toHaveLength(1);
    expect(receipt[0]).toMatch(new RegExp(`^رُد إليك تأمينك ${(out.deposit_to_settle_halalas / 100).toFixed(2)} ر\\.س نقدًا\\. رقم السند `));
    // a second return attempt with a card is refused (by transfer or in cash only)
    await expect(rpc("fn_refund", { p: { reservation_id: res, kind: "deposit_refund", amount_halalas: 100, method: "pos", reason: "x", idempotency_key: "dr22-pos" } })).rejects.toThrow(/deposit_method|deposit/);
  });
});
