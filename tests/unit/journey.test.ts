/**
 * The guest journey on WhatsApp (0070, W3–W4) — the flow against fakes (CX20–CX29, DR20–DR23), then the reception
 * computer's server code end to end against the demo store at 10:30 on a day of departure (JM20, DR22): the server's
 * 10 AM options, the guest's numbered answers, «غادرت وسلّمت المفتاح» only after the instructions, the reception's
 * check-out and the receipt of the deposit's return — only once the return is recorded; then the demo's own rules
 * (CX30–CX31, DR24, TD20–TD21): late hours counted from the hour being lived and never sold twice, the instructions
 * before the button, and «مسح كل بيانات التجربة» keeping a bank message of a kept movement and the guests from Zaaer.
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
  hold_minutes: 30, choice: null, late_checkout_until: null, instructions: "ضع البطاقة في الصندوق عند الباب.", departed_at: null, guide_checkout: true, on_time_open: true,
  deposit_halalas: 30000, refund_hours: 3, balance_due: 0, request: null, ...over,
});
const b = (ref: string, status = "checked_in"): WaBooking => ({ ref, internal_ref: "R-" + ref, status, check_in: "2026-11-12", check_out: "2026-11-15", nights: 3, category_name: "شقة" });

interface World {
  threads: Array<WaThread & { closed: boolean }>;
  sent: Array<Record<string, any>>; // eslint-disable-line @typescript-eslint/no-explicit-any
  saved: Array<{ sender: string; content: string }>;
  chosen: Array<{ tok: string; choice: WaCheckoutChoice; hours: number | null }>;
  departed: number;
  instructed: number;
  late: { hours: number; halalas: number } | null;
  offer: WaCheckout | null;
  refuse: string | null;
}
function world(o: WaCheckout | null, opts: { bound?: boolean; bookings?: WaBooking[] } = {}): World & { ports: WaFlowPorts } {
  const w: World = { threads: opts.bound === false ? [] : [{ id: "T1", guest_token: "GT1", closed: false }], sent: [], saved: [], chosen: [], departed: 0, instructed: 0, late: null, offer: o, refuse: null };
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
    // as the server: «غادرت وسلّمت المفتاح» only after the instructions reached the guest
    departed: async () => { if (!w.offer?.instructions_at) return { error: "VALIDATION: instructions_first" }; w.departed++; return { already: w.departed > 1, late_hours: w.late?.hours ?? 0, late_halalas: w.late?.halalas ?? 0 }; },
    instructions: async () => { w.instructed++; w.offer = w.offer ? { ...w.offer, instructions_at: w.offer.instructions_at ?? "2026-11-15T07:40:00.000Z" } : null; return w.offer; },
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
    expect(w.instructed).toBe(1);   // the server keeps the moment the instructions went out
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
    expect(rowIds(p)).toEqual([CO.ON_TIME, CO.HOURS]);
  });

  it("CX24 «خروج» typed in a new thread: the only stay in the house is bound and its options shown — without «غادرت وسلّمت المفتاح», which comes under the instructions", async () => {
    const w = world(offer(), { bound: false });
    await runWaFlow(text("خروج"), w.ports);
    expect(w.threads[0].guest_token).toBe("GT-R-BK-1");
    expect(rowIds(w.sent[0])).toEqual([CO.ON_TIME, CO.NIGHT, CO.HOURS]);
    expect(bodyOf(w.sent[0])).toContain("من غرفة 201 بين 12 و1 ظهرًا");
    expect(w.instructed).toBe(0);
  });

  it("CX25 a guest not in the house asking «تمديد» is told the options are for guests in their unit; nothing is chosen", async () => {
    const w = world(offer(), { bound: false, bookings: [b("BK-2", "confirmed")] });
    await runWaFlow(text("تمديد"), w.ports);
    expect(bodyOf(w.sent[0])).toBe(WA_TEXTS.checkoutNeedsStay);
    expect(buttonIds(w.sent[0])).toEqual([BTN.BOOKINGS, BTN.HUMAN]);
    expect(w.chosen).toEqual([]);
  });

  it("DR20 «غادرت وسلّمت المفتاح» after the instructions: the reception is told to check the unit, and the deposit's return is promised within its hours", async () => {
    const w = world(offer({ choice: "on_time", instructions_at: "2026-11-15T07:40:00.000Z" }));
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
    expect(bodyOf(w.sent[0])).toMatch(/^ألغينا الطلب\.\n\nموعد خروجك اليوم من غرفة 201 بين 12 و1 ظهرًا/);
    expect(rowIds(w.sent[0])).toContain(CO.ON_TIME);
  });

  it("DR23 «غادرت وسلّمت المفتاح» from an older list, before the instructions: nothing is reported — the instructions go out first, with the button under them; the next tap reports the departure", async () => {
    const w = world(offer());
    await runWaFlow(tap(CO.LEFT), w.ports);
    expect(w.departed).toBe(0);
    expect(w.instructed).toBe(1);
    const body = bodyOf(w.sent[0]);
    expect(body).toMatch(/^اقرأ تعليمات المغادرة أولًا:/);
    expect(body.indexOf("ضع البطاقة في الصندوق")).toBeLessThan(body.indexOf("حين تغادر اختر «غادرت وسلّمت المفتاح»"));
    expect(buttonIds(w.sent[0])).toEqual([CO.LEFT, BTN.HUMAN]);
    await runWaFlow(tap(CO.LEFT), w.ports);
    expect(w.departed).toBe(1);
    expect(bodyOf(w.sent[1])).toContain("يفحص الوحدة ثم يؤكد خروجك");
  });

  it("CX26 at 6:20 PM (the server's least is six hours): the list starts at six — until 7 PM, 30.00 — and goes to midnight", async () => {
    const w = world(offer({ hours: { max: 11, min: 6, have: 0, price_halalas: 500, until_limit: "24:00", next_guest: false } }));
    await runWaFlow(tap(CO.HOURS), w.ports);
    const p = w.sent[0];
    expect(rowIds(p)).toEqual([6, 7, 8, 9, 10, 11].map((n) => CO.HOUR + n));
    expect(p.interactive.action.sections[0].rows[0]).toMatchObject({ title: "6 ساعات — حتى 19:00", description: "30.00 ر.س" });
    expect(p.interactive.action.sections[0].rows[5]).toMatchObject({ title: "11 ساعة — حتى 24:00", description: "55.00 ر.س" });
  });

  it("CX27 two hours already bought (until 3 PM): the list offers only further, and charges only the hours more — «ساعة واحدة — حتى 16:00», 5.00", async () => {
    const w = world(offer({ late_checkout_until: "15:00", hours: { max: 3, min: 3, have: 2, price_halalas: 500, until_limit: "16:00", next_guest: true } }));
    await runWaFlow(tap(CO.HOURS), w.ports);
    const rows = w.sent[0].interactive.action.sections[0].rows;
    expect(rows.map((r: { id: string }) => r.id)).toEqual([CO.HOUR + 3]);
    expect(rows[0]).toMatchObject({ title: "ساعة واحدة — حتى 16:00", description: "5.00 ر.س" });
  });

  it("CX28 eleven possible hours (a list holds ten): the first nine and the last — midnight is always offered (no upper limit but the day's end)", async () => {
    const w = world(offer({ hours: { max: 11, min: 1, have: 0, price_halalas: 500, until_limit: "24:00", next_guest: false } }));
    await runWaFlow(tap(CO.HOURS), w.ports);
    expect(rowIds(w.sent[0])).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 11].map((n) => CO.HOUR + n));
  });

  it("CX29 the free hour's window is the branch's own (check-out 11:00, free until 12:30): «بين 11 صباحًا و12:30 ظهرًا»", async () => {
    const w = world(offer({ check_out_time: "11:00", free_until: "12:30" }));
    await runWaFlow(text("خروج"), w.ports);
    expect(bodyOf(w.sent[0])).toContain("بين 11 صباحًا و12:30 ظهرًا");
    expect(w.sent[0].interactive.action.sections[0].rows[0].description).toContain("بين 11 صباحًا و12:30 ظهرًا");
  });

  it("CX31 after the free hour (the server's on_time_open is false) the menu offers no «سأخرج في الموعد»: «سأغادر الآن» says the hours leaving now adds, and the text says the free time is over", async () => {
    const w = world(offer({ on_time_open: false, hours: { max: 11, min: 3, have: 0, late_now: 3, price_halalas: 500, until_limit: "24:00", next_guest: false } }));
    await runWaFlow(text("خروج"), w.ports);
    expect(rowIds(w.sent[0])).toEqual([CO.LEAVE, CO.NIGHT, CO.HOURS]);
    expect(w.sent[0].interactive.action.sections[0].rows[0]).toMatchObject({ title: "سأغادر الآن", description: "يُضاف خروج متأخر 3 ساعات" });
    expect(bodyOf(w.sent[0])).toMatch(/^انتهى وقت الخروج المجاني \(حتى 13:00\): كل ساعة تبدأ بعده خروج متأخر بـ 5\.00 ر\.س/);
  });

  it("DR25 «سأغادر الآن»: the instructions go out (kept by the server) with what leaving now adds, then the button", async () => {
    const w = world(offer({ on_time_open: false, hours: { max: 11, min: 3, have: 0, late_now: 3, price_halalas: 500, until_limit: "24:00", next_guest: false } }));
    await runWaFlow(tap(CO.LEAVE), w.ports);
    expect(w.instructed).toBe(1);
    const body = bodyOf(w.sent[0]);
    expect(body).toContain("إن غادرت الآن يُضاف إلى حسابك خروج متأخر 3 ساعات (15.00 ر.س).");
    expect(body.indexOf("ضع البطاقة في الصندوق")).toBeLessThan(body.indexOf("حين تغادر اختر «غادرت وسلّمت المفتاح»"));
    expect(buttonIds(w.sent[0])).toEqual([CO.LEFT, BTN.HUMAN]);
  });

  it("DR26 a guest who leaves after the free hour is told what was added as they left (the server charges it)", async () => {
    const w = world(offer({ instructions_at: "2026-11-15T12:00:00.000Z" }));
    w.late = { hours: 3, halalas: 1500 };
    await runWaFlow(tap(CO.LEFT), w.ports);
    expect(bodyOf(w.sent[0])).toContain("غادرت بعد موعد الخروج المجاني، فأُضيف إلى حسابك خروج متأخر 3 ساعات (15.00 ر.س) يُسدَّد لدى الاستقبال أو من التأمين.");
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

  /** the leaver of unit U-2 and their page's key (as the guest's own page opens it) */
  const leaver = async (staff: ReturnType<Demo["createDemoClient"]>) => {
    const { data: rooms } = await staff.from("rooms").select("id, room_number").eq("room_number", "U-2");
    const { data: stays } = await staff.from("reservations").select("id, status, room_id, internal_ref").eq("room_id", (rooms as Array<{ id: string }>)[0].id).eq("status", "checked_in");
    const st = (stays as Array<{ id: string; internal_ref: string }>)[0];
    // the guest opens their page by the booking's number and the last four digits of their phone
    const { data } = await staff.rpc("fn_guest_lookup", { p_external_ref: st.internal_ref, p_phone_last4: LEAVER.slice(-4) });
    return { res: st.id, token: (data as { token?: string } | null)?.token ?? null };
  };
  const signedIn = async () => {
    demo.resetDemo();
    const staff = demo.createDemoClient();
    await staff.auth.signInWithPassword({ email: "owner@demo.sa", password: "demo" });
    const rpc = async <T,>(fn: string, args: Record<string, unknown>) => { const { data, error } = await staff.rpc(fn, args); if (error) throw new Error(error.message); return data as T; };
    return { staff, rpc };
  };

  it("CX30 (demo) at 7 PM a guest still in the room cannot buy one hour: the least is six (13:00–19:00, a part of an hour a whole hour); six are charged; then only further hours, charged for the hours more", async () => {
    vi.useFakeTimers({ toFake: ["Date"], now: new Date("2026-11-15T16:00:00.000Z") });   // 19:00 in Riyadh
    const { staff, rpc } = await signedIn();
    const { token } = await leaver(staff);
    expect(token).toBeTruthy();
    const o = await rpc<{ hours: { min: number; max: number; have: number } }>("fn_guest_checkout", { p_token: token });
    expect(o.hours).toMatchObject({ min: 6, have: 0 });
    await expect(rpc("fn_guest_checkout_choose", { p_token: token, p_choice: "hours", p_hours: 1 })).rejects.toThrow(/late_hours/);
    const held = await rpc<{ request: { hours: number; late_until: string; amount_halalas: number }; late_checkout_until: string }>("fn_guest_checkout_choose", { p_token: token, p_choice: "hours", p_hours: 6 });
    expect(held.request).toMatchObject({ hours: 6, late_until: "19:00" });
    expect(held.late_checkout_until).toBe("19:00");
  });

  it("DR24 (demo) «غادرت وسلّمت المفتاح» before the instructions is refused; the page asks for them (the moment is kept), then it is taken", async () => {
    vi.useFakeTimers({ toFake: ["Date"], now: new Date("2026-11-15T08:00:00.000Z") });   // 11:00 in Riyadh
    const { staff, rpc } = await signedIn();
    const { token } = await leaver(staff);
    await expect(rpc("fn_guest_departure", { p_token: token, p_via: "page" })).rejects.toThrow(/instructions_first/);
    const o = await rpc<{ instructions_at: string | null }>("fn_guest_departure_instructions", { p_token: token });
    expect(o.instructions_at).toBeTruthy();
    expect((await rpc<{ already: boolean }>("fn_guest_departure", { p_token: token, p_via: "page" })).already).toBe(false);
  });

  it("DR27 (demo) at 3:20 PM leaving on time is refused (the free hour is over); the guest who says they left has three hours charged (13:00–16:00)", async () => {
    vi.useFakeTimers({ toFake: ["Date"], now: new Date("2026-11-15T12:20:00.000Z") });   // 15:20 in Riyadh
    const { staff, rpc } = await signedIn();
    const { token } = await leaver(staff);
    const o = await rpc<{ on_time_open: boolean; hours: { late_now: number } }>("fn_guest_checkout", { p_token: token });
    expect(o.on_time_open).toBe(false);
    expect(o.hours.late_now).toBe(3);
    await expect(rpc("fn_guest_checkout_choose", { p_token: token, p_choice: "on_time" })).rejects.toThrow(/free_hour_over/);
    await rpc("fn_guest_departure_instructions", { p_token: token });
    const r = await rpc<{ late_hours: number; late_halalas: number }>("fn_guest_departure", { p_token: token, p_via: "page" });
    expect(r.late_hours).toBe(3);
    expect(r.late_halalas).toBeGreaterThanOrEqual(1500);
  });

  it("TD20 (demo) «مسح كل بيانات التجربة» of one day keeps a bank message whose movement is dated the day before (it arrived after midnight): neither goes", async () => {
    vi.useFakeTimers({ toFake: ["Date"], now: new Date("2026-11-15T08:00:00.000Z") });
    const { rpc } = await signedIn();
    const svc = demo.createDemoServiceClient();
    const msg = { id: "a1111111-1111-4111-8111-111111111111", organization_id: "00000000-0000-0000-0000-000000000001", raw_body: "حوالة واردة", content_hash: "td20", status: "parsed",
      received_at: "2026-11-10T00:05:00.000Z", movement_id: "b2222222-2222-4222-8222-222222222222" };   // 10 November, 00:05 (the demo's days are the stored dates)
    const mv = { id: "b2222222-2222-4222-8222-222222222222", organization_id: "00000000-0000-0000-0000-000000000001", branch_id: null, message_id: msg.id, kind: "deposit", direction: "in",
      amount_halalas: 7000, occurred_at: "2026-11-09T23:50:00.000Z", dedupe_key: "td20", status: "pending" };   // 9 November, 23:50
    expect((await svc.from("bank_messages").insert(msg)).error).toBeNull();
    expect((await svc.from("bank_movements").insert(mv)).error).toBeNull();
    const pv = await rpc<{ token: string }>("fn_admin_purge_preview", { p_branch: null, p_from: "2026-11-10", p_to: "2026-11-10", p_categories: ["finance"] });
    expect((await rpc<{ ok: boolean }>("fn_admin_purge_execute", { p_token: pv.token, p_phrase: "احذف نهائيا" })).ok).toBe(true);
    expect(((await svc.from("bank_messages").select("id").eq("id", msg.id)).data as unknown[]).length).toBe(1);
    expect(((await svc.from("bank_movements").select("id").eq("id", mv.id)).data as unknown[]).length).toBe(1);
  });

  it("TD21 (demo) the guests imported from Zaaer stay — by their note or by the import's hour; a trial guest of the period goes", async () => {
    vi.useFakeTimers({ toFake: ["Date"], now: new Date("2026-11-15T08:00:00.000Z") });
    const { rpc } = await signedIn();
    const svc = demo.createDemoServiceClient();
    const org = "00000000-0000-0000-0000-000000000001";
    const rows = [
      { id: "c3333333-3333-4333-8333-333333333331", organization_id: org, full_name: "ضيف مستورد", phone: "0559000011", notes: "مستورد من زائر", created_at: "2026-11-12T09:00:00.000Z" },
      { id: "c3333333-3333-4333-8333-333333333332", organization_id: org, full_name: "ضيف مستورد عُدّلت ملاحظته", phone: "0559000012", notes: "يفضّل الطابق الأرضي", created_at: "2026-10-30T22:03:00.000Z" },
      { id: "c3333333-3333-4333-8333-333333333333", organization_id: org, full_name: "ضيف تجربة", phone: "0559000013", notes: "زبون تجريبي", created_at: "2026-11-12T09:00:00.000Z" },
    ];
    for (const r of rows) expect((await svc.from("guest_profiles").insert(r)).error).toBeNull();
    const pv = await rpc<{ token: string }>("fn_admin_purge_preview", { p_branch: null, p_from: "2026-10-01", p_to: "2026-11-15", p_categories: ["guests"] });
    expect((await rpc<{ ok: boolean }>("fn_admin_purge_execute", { p_token: pv.token, p_phrase: "احذف نهائيا" })).ok).toBe(true);
    const left = ((await svc.from("guest_profiles").select("id, imported_at").in("id", rows.map((r) => r.id))).data as Array<{ id: string; imported_at: string | null }>);
    expect(left.map((x) => x.id).sort()).toEqual([rows[0].id, rows[1].id]);
    expect(left.every((x) => !!x.imported_at)).toBe(true);
  });
});
