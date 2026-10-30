import { describe, expect, it } from "vitest";
import { amountInWords, numberWords } from "../../src/lib/amountWords";

/** B7 (the owner's note 8): a printed voucher or invoice carries its amount in figures and in words. */
describe("PV01 the amount in words, as Saudi documents write it", () => {
  it("riyals and halalas, with the counted noun after its number", () => {
    expect(amountInWords(125025)).toBe("فقط ألف ومئتان وخمسون ريالًا وخمس وعشرون هللة لا غير");
    expect(amountInWords(100)).toBe("فقط ريال واحد لا غير");
    expect(amountInWords(200)).toBe("فقط ريالان لا غير");
    expect(amountInWords(500)).toBe("فقط خمسة ريالات لا غير");
    expect(amountInWords(1100)).toBe("فقط أحد عشر ريالًا لا غير");
    expect(amountInWords(10000)).toBe("فقط مئة ريال لا غير");
    expect(amountInWords(7500)).toBe("فقط خمسة وسبعون ريالًا لا غير");
    expect(amountInWords(50)).toBe("فقط خمسون هللة لا غير");
    expect(amountInWords(3)).toBe("فقط ثلاث هللات لا غير");
    expect(amountInWords(21)).toBe("فقط إحدى وعشرون هللة لا غير");
    expect(amountInWords(15051)).toBe("فقط مئة وخمسون ريالًا وإحدى وخمسون هللة لا غير");
    expect(amountInWords(2100)).toBe("فقط واحد وعشرون ريالًا لا غير");
    expect(amountInWords(0)).toBe("فقط صفر ريال لا غير");
    expect(amountInWords(-5000)).toBe("فقط سالب خمسون ريالًا لا غير");
  });

  it("thousands and millions agree with their count", () => {
    expect(numberWords(2000)).toBe("ألفان");
    expect(numberWords(3000)).toBe("ثلاثة آلاف");
    expect(numberWords(11500)).toBe("أحد عشر ألفًا وخمسمئة");
    expect(amountInWords(1100000)).toBe("فقط أحد عشر ألف ريال لا غير");
    expect(amountInWords(20000)).toBe("فقط مئتا ريال لا غير");
    expect(amountInWords(120000)).toBe("فقط ألف ومئتا ريال لا غير");
    expect(amountInWords(200000)).toBe("فقط ألفا ريال لا غير");
    expect(amountInWords(250000)).toBe("فقط ألفان وخمسمئة ريال لا غير");
    expect(amountInWords(20000000)).toBe("فقط مئتا ألف ريال لا غير");
    expect(amountInWords(200000000)).toBe("فقط مليونا ريال لا غير");
    expect(numberWords(2_500_000)).toBe("مليونان وخمسمئة ألف");
    expect(numberWords(18, true)).toBe("ثماني عشرة");
  });
});

describe("PV02 every voucher and invoice prints on A4 or an 80 mm receipt, its amount in figures and words", async () => {
  const { buildVoucherPrint, buildInvoicePrint } = await import("../../src/lib/printDocs");
  const ctx = { property: "فايف اورز", branch: "فرع عنيزة", reservationRef: "R-26A0001", guest: "ضيف <تجربة>", room: "B01", checkIn: "2026-11-01", checkOut: "2026-11-03" };
  const v = { number: "RCP-2026-000009", kindLabel: "سند قبض", amount_halalas: 15000, methodLabel: "شبكة", reference: null, note: null, occurred_at: "2026-11-01T10:00:00Z", status: "approved" };
  it("a voucher: the page size by format, the amount in words, the text escaped, a cancelled voucher marked", () => {
    const a4 = buildVoucherPrint(v, ctx, "a4"); const slip = buildVoucherPrint(v, ctx, "80mm");
    expect(a4).toContain("size: A4 portrait"); expect(slip).toContain("size: 80mm 297mm");
    expect(a4).toContain("فقط مئة وخمسون ريالًا لا غير");
    expect(a4).toContain("ضيف &lt;تجربة&gt;"); expect(a4).not.toContain("<تجربة>");
    expect(buildVoucherPrint({ ...v, status: "cancelled", cancel_reason: "خطأ" }, ctx, "80mm")).toContain("سند ملغى — خطأ");
  });
  it("an invoice: its lines, totals and the total in words", () => {
    const html = buildInvoicePrint({ number: "INV-2026-000003", kindLabel: "فاتورة", status: "issued", version: 1, issued_at: "2026-11-03T09:00:00Z", issued_by: "المشرف", period_from: "2026-11-01", period_to: "2026-11-03",
      bill_to: {}, lines: [{ description: "إيجار 2 ليلة × 75.00 ر.س", quantity: 2, unit_price_halalas: 7500, amount_halalas: 15000 }], subtotal_halalas: 15000, tax_halalas: 0, total_halalas: 15000 }, ctx, "a4");
    expect(html).toContain("إيجار 2 ليلة"); expect(html).toContain("فقط مئة وخمسون ريالًا لا غير"); expect(html).not.toContain("<span>الضريبة</span>");
  });
});
