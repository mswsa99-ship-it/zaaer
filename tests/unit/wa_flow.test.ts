/**
 * The guest's WhatsApp conversation (_shared/wa_flow.ts) — WF01–WF15. The same code runs in whatsapp-webhook (database
 * + Cloud API) and in the demo's WhatsApp simulator; here it runs against fakes, so every branch of the flow is pinned.
 */
import { describe, it, expect } from "vitest";
import { runWaFlow, WA_TEXTS, type WaBooking, type WaFlowPorts, type WaThread } from "../../supabase/functions/_shared/wa_flow";
import { BTN, type WaInbound } from "../../supabase/functions/_shared/whatsapp";

const FROM = "966501110006";
const BASE = "https://hotel.example/app";
const b = (ref: string, status = "confirmed", extra: Partial<WaBooking> = {}): WaBooking =>
  ({ ref, internal_ref: "R-" + ref, status, check_in: "2026-10-24", check_out: "2026-10-27", nights: 3, category_name: "استوديو", ...extra });

interface World {
  bookings: WaBooking[];
  threads: Array<WaThread & { closed: boolean }>;
  saved: Array<{ thread: string; sender: string; content: string; meta: Record<string, unknown> }>;
  sent: Array<Record<string, any>>; // eslint-disable-line @typescript-eslint/no-explicit-any
  asked: Array<{ thread: WaThread; message: string }>;
  answer: { reply: string; actions: Array<{ label: string; route?: string; value?: string }> } | null;
  base: string;
}

function world(bookings: WaBooking[] = [], over: Partial<World> = {}): World & { ports: WaFlowPorts } {
  const w: World = { bookings, threads: [], saved: [], sent: [], asked: [], answer: { reply: "أهلًا بك", actions: [] }, base: BASE, ...over };
  let n = 0;
  const ports: WaFlowPorts = {
    get appBaseUrl() { return w.base; },
    findThread: async () => w.threads.find((t) => !t.closed) ?? null,
    newThread: async () => { const t = { id: "T" + ++n, guest_token: null, closed: false }; w.threads.push(t); return t; },
    closeThread: async (id) => { w.threads.find((t) => t.id === id)!.closed = true; },
    touch: async () => {},
    save: async (thread, sender, content, meta) => { w.saved.push({ thread, sender, content, meta }); },
    bookings: async () => ({ token: "PS", list: w.bookings }),
    openBooking: async (token, ref) => (token === "PS" && w.bookings.some((x) => x.internal_ref === ref) ? "GT-" + ref : null),
    bindThread: async (id, gt) => { w.threads.find((t) => t.id === id)!.guest_token = gt; },
    ask: async (thread, message) => { w.asked.push({ thread: { ...thread }, message }); return w.answer; },
    send: async (payload) => { w.sent.push(payload); },
  };
  return Object.assign(w, { ports });
}
const text = (t: string): WaInbound => ({ phoneNumberId: "1", from: FROM, id: "m" + Math.random(), type: "text", text: t });
const tap = (replyId: string, title = ""): WaInbound => ({ phoneNumberId: "1", from: FROM, id: "m" + Math.random(), type: "interactive", text: title, replyId });
const bodyOf = (p: Record<string, any>) => p.type === "text" ? p.text.body : p.interactive.body.text; // eslint-disable-line @typescript-eslint/no-explicit-any
const buttonIds = (p: Record<string, any>) => p.interactive?.action?.buttons?.map((x: any) => x.reply.id) ?? []; // eslint-disable-line @typescript-eslint/no-explicit-any

describe("WhatsApp conversation flow", () => {
  it("WF01 «حجوزاتي» with one booking: opens it, binds the thread, sends the secure links with «وصلت» and «موظف»", async () => {
    const w = world([b("BK-1")]);
    await runWaFlow(text("حجوزاتي"), w.ports);
    expect(w.threads[0].guest_token).toBe("GT-R-BK-1");
    expect(w.sent).toHaveLength(1);
    const msg = w.sent[0];
    expect(bodyOf(msg)).toContain("حجزك BK-1 — استوديو");
    expect(bodyOf(msg)).toContain(`${BASE}/booking/status/GT-R-BK-1`);
    expect(bodyOf(msg)).toContain(`${BASE}/booking/registration/GT-R-BK-1`);
    expect(buttonIds(msg)).toEqual(["SAY:" + WA_TEXTS.arrived, BTN.HUMAN]);
    // the stored copy keeps no token of the secure pages
    const stored = w.saved.filter((s) => s.sender === "assistant").map((s) => s.content).join("\n");
    expect(stored).not.toContain("GT-R-BK-1");
    expect(stored).toContain("/booking/status/…");
  });

  it("WF02 two bookings: a list to choose from; choosing one opens it and offers «حجوزاتي» to switch", async () => {
    const w = world([b("BK-1"), b("BK-2", "checked_in", { category_name: "شقة غرفتين", branch_name: "فرع جدة" })]);
    await runWaFlow(tap(BTN.BOOKINGS, "حجوزاتي"), w.ports);
    const list = w.sent[0].interactive;
    expect(list.type).toBe("list");
    expect(list.body.text).toMatch(/لديك حجزان/);
    expect(list.action.sections[0].rows.map((r: { id: string }) => r.id)).toEqual(["OPEN:R-BK-1", "OPEN:R-BK-2"]);
    expect(list.action.sections[0].rows[1].description).toContain("فرع جدة");

    await runWaFlow(tap("OPEN:R-BK-2", "شقة غرفتين"), w.ports);
    expect(w.threads[0].guest_token).toBe("GT-R-BK-2");
    expect(bodyOf(w.sent[1])).toContain("حجزك BK-2 — شقة غرفتين");
    expect(buttonIds(w.sent[1])).toContain(BTN.BOOKINGS);
  });

  it("WF03 no bookings on the number: says so (last 4 digits only) and offers «احجز الآن» and «موظف»", async () => {
    const w = world([]);
    await runWaFlow(text("حجوزاتي"), w.ports);
    expect(bodyOf(w.sent[0])).toContain("المنتهي بـ 0006");
    expect(bodyOf(w.sent[0])).not.toContain(FROM);
    expect(buttonIds(w.sent[0])).toEqual([BTN.BOOK, BTN.HUMAN]);
  });

  it("WF04 the first message of a guest with exactly one current stay binds the thread silently, then the assistant answers about it", async () => {
    const w = world([b("BK-OLD", "checked_out"), b("BK-1", "confirmed")]);
    await runWaFlow(text("متى أقدر أدخل؟"), w.ports);
    expect(w.asked).toHaveLength(1);
    expect(w.asked[0].thread.guest_token).toBe("GT-R-BK-1");
    expect(w.asked[0].message).toBe("متى أقدر أدخل؟");
    expect(w.sent).toHaveLength(1);                         // only the assistant's answer, no booking card
    expect(bodyOf(w.sent[0])).toBe("أهلًا بك");
  });

  it("WF05 two current stays are not guessed: the assistant answers unbound", async () => {
    const w = world([b("BK-1"), b("BK-2")]);
    await runWaFlow(text("مرحبا"), w.ports);
    expect(w.asked[0].thread.guest_token).toBeNull();
  });

  it("WF06 a photo or voice note is not read: the guest is told to use the secure link, nothing reaches the assistant", async () => {
    const w = world([b("BK-1")]);
    await runWaFlow({ ...text(""), type: "image" }, w.ports);
    expect(w.asked).toHaveLength(0);
    expect(bodyOf(w.sent[0])).toBe(WA_TEXTS.textOnly);
    expect(w.saved[0]).toMatchObject({ sender: "guest", content: "[image]" });
  });

  it("WF07 «التحدث مع موظف» and «SAY:» buttons reach the assistant as the guest's words", async () => {
    const w = world([]);
    await runWaFlow(tap(BTN.HUMAN, "التحدث مع موظف"), w.ports);
    await runWaFlow(tap("SAY:" + WA_TEXTS.arrived, "وصلت"), w.ports);
    expect(w.asked.map((a) => a.message)).toEqual([WA_TEXTS.human, WA_TEXTS.arrived]);
  });

  it("WF08 «محادثة جديدة» closes the thread and starts another one", async () => {
    const w = world([]);
    await runWaFlow(text("مرحبا"), w.ports);
    await runWaFlow(tap(BTN.NEW, "محادثة جديدة"), w.ports);
    expect(w.threads.map((t) => t.closed)).toEqual([true, false]);
    expect(w.asked[1]).toMatchObject({ thread: { id: "T2" }, message: "مرحبا" });
  });

  it("WF09 the assistant unreachable: an honest apology with a «موظف» button, recorded with the reason", async () => {
    const w = world([], { answer: null });
    await runWaFlow(text("سؤال"), w.ports);
    expect(bodyOf(w.sent[0])).toBe(WA_TEXTS.unreachable);
    expect(buttonIds(w.sent[0])).toEqual([BTN.HUMAN]);
    expect(w.saved.find((s) => s.meta.reason === "assistant_unreachable")).toBeTruthy();
  });

  it("WF10 the assistant's actions become WhatsApp buttons and links", async () => {
    const w = world([], { answer: { reply: "تفضل", actions: [{ label: "حجوزاتي", route: "/booking/lookup" }, { label: "احجز الآن", route: "/booking/new" }] } });
    await runWaFlow(text("أبغى أحجز"), w.ports);
    expect(buttonIds(w.sent[0])).toEqual([BTN.BOOKINGS]);
    expect(bodyOf(w.sent[0])).toContain(`${BASE}/booking/new`);
  });

  it("WF11 a booking that is not on this number cannot be opened from a forged list reply", async () => {
    const w = world([b("BK-1")]);
    await runWaFlow(tap("OPEN:R-SOMEONE-ELSE", "x"), w.ports);
    expect(bodyOf(w.sent[0])).toBe(WA_TEXTS.openFailed);
    expect(w.threads[0].guest_token).toBeNull();
  });

  it("WF12 without the website address no links are sent (and nothing breaks)", async () => {
    const w = world([b("BK-1")], { base: "" });
    await runWaFlow(text("حجوزاتي"), w.ports);
    expect(bodyOf(w.sent[0])).not.toMatch(/https?:|\/booking\//);
    await runWaFlow(tap(BTN.BOOK, "احجز الآن"), w.ports);
    expect(bodyOf(w.sent[1])).toBe("الحجز الجديد متاح عبر منصات الحجز المعتمدة.");
  });

  it("WF14 a chat whose number is hidden (privacy id on the reception computer) gets no digits and no guess", async () => {
    const w = world([]);
    await runWaFlow({ ...text("حجوزاتي"), from: "lid:204587116371" }, w.ports);
    expect(bodyOf(w.sent[0])).toBe("لم أجد حجوزات مرتبطة بهذه المحادثة. إن كان لديك حجز فاطلب موظف الاستقبال، أو احجز الآن.");
    expect(bodyOf(w.sent[0])).not.toMatch(/\d{4}/);
  });

  it("WF13 what the guest types is stored PII-redacted (a phone or ID number never lands in the log in clear)", async () => {
    const w2 = world([b("BK-1")]);
    await runWaFlow({ ...tap("OPEN:R-BK-1"), text: "رقمي 0551234567 وهويتي 1012345678" }, w2.ports);
    const guest = w2.saved.find((s) => s.sender === "guest")!.content;
    expect(guest).not.toContain("0551234567");
    expect(guest).not.toContain("1012345678");
    expect(guest).toContain("4567");
  });

  it("WF15 an album (one message per photo) gets the «text only» notice once; every photo is still recorded", async () => {
    const w = world();
    // what the assistant said in the thread lately, as the database port reports it
    w.ports.recentBot = async (thread) => w.saved.filter((s) => s.thread === thread && s.sender === "assistant").map((s) => s.content);
    const photo = (): WaInbound => ({ phoneNumberId: "1", from: FROM, id: "p" + Math.random(), type: "image", text: "" });
    for (let i = 0; i < 4; i++) await runWaFlow(photo(), w.ports);
    expect(w.sent).toHaveLength(1);
    expect(bodyOf(w.sent[0])).toBe(WA_TEXTS.textOnly);
    expect(w.saved.filter((s) => s.sender === "guest").map((s) => s.content)).toEqual(["[image]", "[image]", "[image]", "[image]"]);
    // without that port (an older caller) every photo still gets its notice, as before
    const old = world();
    for (let i = 0; i < 2; i++) await runWaFlow(photo(), old.ports);
    expect(old.sent).toHaveLength(2);
  });
});
