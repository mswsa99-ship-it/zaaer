/**
 * خطة التصحيح 6.10 (U2 الطباعة): صفحة الطباعة مستقلة ومقسّمة إلى صفحات، وبناء مستند قائمة كبيرة
 * (5,000 صف فأكثر) لا يُجمّد التبويب — يُبنى على دفعات يفسح بينها للتبويب. أسماء وصفية بلا رموز (العقد المشترك).
 */
import { describe, it, expect } from "vitest";
import { buildPrintDocument, buildPrintDocumentAsync, type ExportStatement } from "../../src/lib/exports";

const statement: ExportStatement = {
  title: "سجل الإجراءات",
  branch: "فرع الاختبار",
  period: { from: "2026-11-01", to: "2026-11-24" },
  filters: ["النتيجة: ناجح"],
  scope: { kind: "all", count: 3 },
  generatedAt: "2026-11-24 10:00",
  by: "مختبر",
};

const small = { columns: ["المرجع", "المبلغ"], rows: [["R-1 <b>", 100], ["R-2", 250050], ["R-3", null]] as (string | number | null)[][] };

describe("الطباعة المقسّمة — صفحة مستقلة بصفحات مرقّمة", () => {
  it("النسخة غير المتزامنة تنتج المستند نفسه الذي تنتجه المتزامنة حرفيًا", async () => {
    const sync = buildPrintDocument(statement, small);
    const asyncDoc = await buildPrintDocumentAsync(statement, small);
    expect(asyncDoc).toBe(sync);
  });

  it("قائمة أكبر من صفحة تنقسم إلى أقسام صفحات، كل قسم يعيد ترويسة الأعمدة ويحمل رقم صفحته، ولا يُفقد صف", async () => {
    const rows = Array.from({ length: 85 }, (_, i) => [`R-${i + 1}`, i * 100]);
    const html = await buildPrintDocumentAsync(statement, { columns: ["المرجع", "المبلغ"], rows }, { rowsPerPage: 40 });
    // ثلاث صفحات: 40 + 40 + 5
    expect(html.match(/صفحة 1 من 3/)).toBeTruthy();
    expect(html.match(/صفحة 2 من 3/)).toBeTruthy();
    expect(html.match(/صفحة 3 من 3/)).toBeTruthy();
    // ترويسة الأعمدة مكررة في كل صفحة (3 مرات)
    expect((html.match(/<th>المرجع<\/th>/g) ?? []).length).toBe(3);
    // كل الصفوف موجودة بالترتيب
    expect((html.match(/<tr><td>R-\d+<\/td>/g) ?? []).length).toBe(85);
    expect(html.indexOf("<td>R-1</td>")).toBeLessThan(html.indexOf("<td>R-85</td>"));
    // كل قسم صفحة يُطبع في صفحة مستقلة
    expect((html.match(/break-after: page/g) ?? []).length).toBeGreaterThanOrEqual(1);
    // البيان (الفرع والفترة والمرشحات والنطاق) ما زال في رأس المستند
    expect(html).toContain("<h1>سجل الإجراءات</h1>");
    expect(html).toContain("كل النتائج (3)");
  });

  it("صفحة واحدة عندما تسعها الصفوف: قسم واحد بلا ترقيم زائد عن الحاجة", async () => {
    const html = await buildPrintDocumentAsync(statement, small, { rowsPerPage: 40 });
    expect(html.match(/صفحة 1 من 1/)).toBeTruthy();
    expect(html.match(/صفحة 2/)).toBeFalsy();
  });

  it("بناء 20,000 صف يفسح لحلقة الأحداث بين الدفعات (التبويب لا يُجمّد)", async () => {
    const rows = Array.from({ length: 20_000 }, (_, i) => [`R-${i}`, i]);
    let ticks = 0; let stopped = false;
    const ticker = (async () => { while (!stopped) { await new Promise((r) => setTimeout(r, 0)); ticks++; } })();
    const html = await buildPrintDocumentAsync(statement, { columns: ["المرجع", "المبلغ"], rows }, { rowsPerPage: 40 });
    stopped = true; await ticker;
    expect(ticks).toBeGreaterThan(3);
    expect((html.match(/<tr><td>R-\d+<\/td>/g) ?? []).length).toBe(20_000);
  });

  it("القيم تُهرَّب في كل صفحة (لا HTML من بيانات الصفوف)", async () => {
    const rows = Array.from({ length: 45 }, (_, i) => [`<img src=x onerror=alert(${i})>`, i]);
    const html = await buildPrintDocumentAsync(statement, { columns: ["أ", "ب"], rows }, { rowsPerPage: 40 });
    expect(html).not.toContain("<img src=x");
    expect(html).toContain("&lt;img src=x onerror=alert(44)&gt;");
  });
});
