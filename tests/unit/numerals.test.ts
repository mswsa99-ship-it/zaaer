import { describe, expect, it } from "vitest";
import { formatCurrency, formatDateTime } from "../../src/lib/utils";
import { buildVoucherPrint } from "../../src/lib/printDocs";

const ARABIC_INDIC = /[٠-٩۰-۹]/;

/** The owner's decision of 30 Oct 2026 (design system U2): Latin digits 0–9 and the Gregorian calendar everywhere. */
describe("NU01 amounts, dates and prints use Latin digits and the Gregorian calendar", () => {
  it("an amount is 1,250.50 with the riyal sign, never in Arabic-Indic digits", () => {
    const s = formatCurrency(1250.5);
    expect(s).toContain("1,250.50");
    expect(s).not.toMatch(ARABIC_INDIC);
  });

  it("a date and time is Gregorian (2026), in Latin digits", () => {
    const s = formatDateTime("2026-10-30T10:15:00Z");
    expect(s).toContain("2026");
    expect(s).not.toMatch(ARABIC_INDIC);
  });

  it("a printed voucher carries no Arabic-Indic digit", () => {
    const html = buildVoucherPrint({ number: "RCP-2026-000009", kindLabel: "سند قبض", amount_halalas: 125050, methodLabel: "شبكة", reference: null, note: null, occurred_at: "2026-10-30T10:15:00Z", status: "approved" },
      { property: "فايف اورز", branch: "عنيزة", reservationRef: "R-26A0001" }, "a4");
    expect(html).not.toMatch(ARABIC_INDIC);
    expect(html).toContain("1,250.50");
  });
});
