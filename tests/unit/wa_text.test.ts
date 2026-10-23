/**
 * Plain-text WhatsApp for the reception computer (_shared/wa_text.ts) — WT01–WT11: the flow's messages become text
 * with numbered options, and the guest's answer (number or words) maps back to the option a tap would have sent.
 */
import { describe, it, expect } from "vitest";
import { asksForNumber, choiceNumber, pickOption, renderPayloads, WA_CHOOSE_HINT, type WaMenu } from "../../supabase/functions/_shared/wa_text";
import { buttonsPayload, ctaUrlPayload, listPayload, otpTemplatePayload, textPayload, BTN } from "../../supabase/functions/_shared/whatsapp";
import { runWaFlow, WA_TEXTS, type WaFlowPorts } from "../../supabase/functions/_shared/wa_flow";

const TO = "966501110006";
const menuOf = (options: WaMenu["options"], at = new Date().toISOString()): WaMenu => ({ at, options });

describe("WhatsApp as plain text (reception computer)", () => {
  it("WT01 buttons become numbered lines with the hint; the options keep their ids", () => {
    const r = renderPayloads([buttonsPayload(TO, "حجزك BK-1", [{ id: "SAY:" + WA_TEXTS.arrived, title: "وصلت" }, { id: BTN.HUMAN, title: "التحدث مع موظف" }])]);
    expect(r.texts).toEqual([`حجزك BK-1\n\n1️⃣ وصلت\n2️⃣ التحدث مع موظف\n\n${WA_CHOOSE_HINT}`]);
    expect(r.options).toEqual([{ n: 1, id: "SAY:" + WA_TEXTS.arrived, title: "وصلت" }, { n: 2, id: BTN.HUMAN, title: "التحدث مع موظف" }]);
  });

  it("WT02 a list keeps each row's details", () => {
    const r = renderPayloads([listPayload(TO, "لديك حجزان على هذا الرقم. اختر الحجز:", "اختر الحجز", [
      { id: "OPEN:R-1", title: "استوديو", description: "24/10 → 27/10 · مؤكد" }, { id: "OPEN:R-2", title: "شقة غرفتين", description: "1/11 → 3/11 · مؤكد · فرع جدة" }])]);
    expect(r.texts[0]).toContain("1️⃣ استوديو — 24/10 → 27/10 · مؤكد");
    expect(r.texts[0]).toContain("2️⃣ شقة غرفتين — 1/11 → 3/11 · مؤكد · فرع جدة");
    expect(r.options.map((o) => o.id)).toEqual(["OPEN:R-1", "OPEN:R-2"]);
  });

  it("WT03 a single link and plain text pass through; templates (Cloud API only) are not typed", () => {
    const r = renderPayloads([ctaUrlPayload(TO, "تفضل", "احجز الآن", "https://hotel.example/booking/new"), textPayload(TO, "  مرحبا  "), otpTemplatePayload(TO, "123456", "booking_code", "ar")]);
    expect(r.texts).toEqual(["تفضل\n\n🔗 احجز الآن: https://hotel.example/booking/new", "مرحبا"]);
    expect(r.options).toEqual([]);
  });

  it("WT04 numbers run across the messages of one turn; an option offered twice keeps its number", () => {
    const r = renderPayloads([
      buttonsPayload(TO, "أ", [{ id: BTN.BOOKINGS, title: "حجوزاتي" }, { id: BTN.HUMAN, title: "التحدث مع موظف" }]),
      buttonsPayload(TO, "ب", [{ id: BTN.HUMAN, title: "التحدث مع موظف" }, { id: BTN.NEW, title: "محادثة جديدة" }]),
    ]);
    expect(r.texts[1]).toContain("2️⃣ التحدث مع موظف\n3️⃣ محادثة جديدة");
    expect(r.options.map((o) => o.n)).toEqual([1, 2, 3]);
  });

  it("WT05 a message that asks for a number lists its options as words, and a digit there is the guest's answer", () => {
    expect(asksForNumber("كم ليلة تريد؟")).toBe(true);
    expect(asksForNumber("متى تصل إن شاء الله؟")).toBe(true);
    expect(asksForNumber("هل لديك حجز سابق أم ترغب بحجز جديد؟")).toBe(false);
    const r = renderPayloads([buttonsPayload(TO, "كم ليلة تريد؟", [{ id: BTN.HUMAN, title: "التحدث مع موظف" }])]);
    expect(r.texts[0]).toBe("كم ليلة تريد؟\n\n▫️ التحدث مع موظف");
    const menu = menuOf(r.options);
    expect(pickOption("2", menu)).toBeNull();
    expect(pickOption("1", menu)).toBeNull();
    expect(pickOption("التحدث مع موظف", menu)?.id).toBe(BTN.HUMAN);
  });

  it("WT06 the guest's number in any form picks the option; anything else is not a choice", () => {
    const menu = menuOf([{ n: 1, id: "A", title: "وصلت" }, { n: 2, id: "B", title: "التحدث مع موظف" }]);
    for (const t of ["2", "٢", "2️⃣", "رقم 2", " 2 ", "2.", "(2)"]) expect(pickOption(t, menu)?.id, t).toBe("B");
    expect(choiceNumber("🔟")).toBe(10);
    expect(pickOption("5", menu)).toBeNull();
    expect(pickOption("2 ليلة", menu)).toBeNull();
    expect(pickOption("0", menu)).toBeNull();
    expect(pickOption("", menu)).toBeNull();
  });

  it("WT07 typing the option's own words picks it (diacritics, alef and ى/ي forms aside)", () => {
    const menu = menuOf([{ n: 1, id: "A", title: "وصلت" }, { n: 2, id: "B", title: "حجوزاتي" }]);
    expect(pickOption("وصلت!", menu)?.id).toBe("A");
    expect(pickOption("حجوزاتى", menu)?.id).toBe("B");
    expect(pickOption("وَصَلْتُ", menu)?.id).toBe("A");
    expect(pickOption("وصلت الفندق", menu)).toBeNull();
  });

  it("WT08 options older than a day, or no options, are never guessed", () => {
    const old = menuOf([{ n: 1, id: "A", title: "وصلت" }], new Date(Date.now() - 25 * 3600_000).toISOString());
    expect(pickOption("1", old)).toBeNull();
    expect(pickOption("1", null)).toBeNull();
    expect(pickOption("1", { at: "garbage", options: [{ n: 1, id: "A", title: "x" }] })).toBeNull();
  });

  it("WT09 the booking card of «حجوزاتي» end to end: typed as text, and «1» means «وصلت», «2» a staff member", async () => {
    const sent: Array<Record<string, unknown>> = [];
    const ports: WaFlowPorts = {
      appBaseUrl: "https://hotel.example", findThread: async () => null, newThread: async () => ({ id: "T", guest_token: null }),
      closeThread: async () => {}, touch: async () => {}, save: async () => {},
      bookings: async () => ({ token: "PS", list: [{ ref: "BK-1", internal_ref: "R-1", status: "confirmed", check_in: "2026-10-24", check_out: "2026-10-27", nights: 3, category_name: "استوديو" }] }),
      openBooking: async () => "GT1", bindThread: async () => {}, ask: async () => null, send: async (p) => { sent.push(p); },
    };
    await runWaFlow({ phoneNumberId: "web", from: TO, id: "x", type: "text", text: "حجوزاتي" }, ports);
    const r = renderPayloads(sent);
    expect(r.texts[0]).toContain("https://hotel.example/booking/status/GT1");
    expect(r.texts[0]).toMatch(/1️⃣ وصلت\n2️⃣ التحدث مع موظف\n\nأرسل رقم الخيار\.$/);
    const menu = menuOf(r.options);
    expect(pickOption("1", menu)?.id).toBe("SAY:" + WA_TEXTS.arrived);
    expect(pickOption("٢", menu)?.id).toBe(BTN.HUMAN);
  });
});
