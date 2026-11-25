import { describe, it, expect } from "vitest";
import { staySummaryHtml, printableDocument } from "../../src/lib/printTemplates";
import type { StaySummary } from "../../src/lib/api";

const base = { language: "ar", text: "نص", hash: "abc123",
  branch: { id: "b", name: "فرع بريدة", name_ar: "فرع بريدة", name_en: null, city: "بريدة", address: "حي الصفراء", phone: "0500000000", country_code: "SA", commercial_register: "1010000000", logo_version: null },
  reservation: { id: "r", internal_ref: "R-TEST0001", external_ref: "123456", source: "Booking.com", guest_name: "<b>x</b>", category: "غرفة", room_number: "B11", check_in: "2026-11-25", check_out: "2026-11-30", check_in_time: "16:00", check_out_time: "12:00", nights: 5 },
  money: { rent: 37500, discounts: 0, extras: 0, tax: 0, total: 37500, paid: 37500, balance: 0, deposit_required: 5000, deposit_held: 5000 },
  policies: [{ title: "التدخين", content: "ممنوع\nغرامة 50" }] } as unknown as StaySummary;

describe("stay summary template", () => {
  it("is a stay summary, not a tax invoice, and escapes guest text", () => {
    const h = staySummaryHtml(base, null);
    expect(h).toContain("ملخص الإقامة");
    expect(h).toContain("ليس فاتورة ضريبية");
    expect(h).not.toContain("<b>x</b>");
    expect(h).toContain("375.00");
    expect(h).toContain("abc123");
  });
  it("wraps in a document with the shared stylesheet and a mobile breakpoint", () => {
    const d = printableDocument(staySummaryHtml(base, null), "R", "ar");
    expect(d).toContain("max-width:560px");
    expect(d).toContain("@page");
  });
});
