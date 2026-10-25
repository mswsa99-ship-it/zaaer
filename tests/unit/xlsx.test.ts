/**
 * The Excel writer and the export statement (decisions 14 and 43): a file a reader can open, whose first lines say
 * what it holds (branch, period, filters, «كل النتائج» or «هذه الصفحة»), and whose rows are exactly the ones given.
 * XL01–XL06. The zip reader here is shared with the end-to-end export tests (tests/e2e/helpers/xlsx.ts).
 */
import { describe, it, expect } from "vitest";
import { buildXlsx, crc32, columnName, sheetName, safeFileName, zipStore } from "../../src/lib/xlsx";
import { statementLines, sheetOf, exportFileName, buildPrintDocument, csvText, money, type ExportStatement } from "../../src/lib/exports";
import { readZip, sheetCells } from "../e2e/helpers/xlsx";

const statement: ExportStatement = {
  title: "الحجوزات", branch: "فرع الاختبار", period: { from: "2026-10-01", to: "2026-10-25" },
  filters: ["الحالة: مؤكد", "الوصول: 2026-10-01 → 2026-10-25"], scope: { kind: "all", count: 3 }, generatedAt: "2026-10-25 10:00", by: "المالك",
};

describe("xlsx writer", () => {
  it("XL01 the zip holds every part with a correct CRC and size, names in UTF-8, and the workbook's parts reference each other", () => {
    const bytes = buildXlsx([{ name: "ورقة", rows: [["أ", 1], ["ب", 2]] }], new Date("2026-10-25T10:00:00"));
    const z = readZip(bytes);
    expect([...z.keys()].sort()).toEqual(["[Content_Types].xml", "_rels/.rels", "xl/_rels/workbook.xml.rels", "xl/styles.xml", "xl/workbook.xml", "xl/worksheets/sheet1.xml"].sort());
    for (const [, e] of z) expect(crc32(e.data)).toBe(e.crc);
    const td = new TextDecoder();
    expect(td.decode(z.get("xl/workbook.xml")!.data)).toContain('<sheet name="ورقة" sheetId="1" r:id="rId1"/>');
    expect(td.decode(z.get("xl/_rels/workbook.xml.rels")!.data)).toContain('Target="worksheets/sheet1.xml"');
    expect(td.decode(z.get("[Content_Types].xml")!.data)).toContain('/xl/worksheets/sheet1.xml');
  });

  it("XL02 cells: text as inline strings with XML escaped, numbers as values, money with two decimals, the header row bold, the sheet right-to-left", () => {
    const bytes = buildXlsx([{ name: "s", rows: [["العنوان <&> \"x\""], [], ["العمود", "المبلغ", "عدد"], ["صف 1", money(12345), { v: 7, fmt: "int" }], [" مسافة ", 0.5, null]], headerRow: 2, widths: [30, 12, 8] }]);
    const xml = new TextDecoder().decode(readZip(bytes).get("xl/worksheets/sheet1.xml")!.data);
    expect(xml).toContain('<sheetView rightToLeft="1"');
    expect(xml).toContain("<t>العنوان &lt;&amp;&gt; &quot;x&quot;</t>");
    expect(xml).toContain('<c r="A3" t="inlineStr" s="1"><is><t>العمود</t></is></c>');
    expect(xml).toContain('<c r="B4" s="2"><v>123.45</v></c>');
    expect(xml).toContain('<c r="C4" s="3"><v>7</v></c>');
    expect(xml).toContain('<t xml:space="preserve"> مسافة </t>');
    expect(xml).toContain('<c r="B5"><v>0.5</v></c>');
    expect(xml).toContain('<col min="1" max="1" width="30" customWidth="1"/>');
    const cells = sheetCells(xml);
    expect(cells.length).toBe(5);
    expect(cells[3]).toEqual(["صف 1", "123.45", "7"]);
  });

  it("XL03 column names, sheet names and file names are made safe", () => {
    expect([0, 25, 26, 27, 701, 702].map(columnName)).toEqual(["A", "Z", "AA", "AB", "ZZ", "AAA"]);
    expect(sheetName("a:b/c?d*e[f]g")).toBe("a b c d e f g");
    expect(sheetName("x".repeat(40)).length).toBe(31);
    expect(safeFileName('الحجوزات: فرع/الرياض "كل النتائج" 2026-10-25')).toBe("الحجوزات_فرع_الرياض_كل_النتائج_2026-10-25");
    const two = readZip(buildXlsx([{ name: "same", rows: [[1]] }, { name: "same", rows: [[2]] }]));
    expect(new TextDecoder().decode(two.get("xl/workbook.xml")!.data)).toMatch(/name="same" sheetId="1".*name="same 2" sheetId="2"/);
  });

  it("XL04 the statement names the file's title, branch, period, filters, scope and time; the sheet starts with it and bolds the column header", () => {
    expect(statementLines(statement)).toEqual([
      "الحجوزات", "الفرع: فرع الاختبار", "الفترة: 2026-10-01 → 2026-10-25", "المرشحات: الحالة: مؤكد · الوصول: 2026-10-01 → 2026-10-25", "النطاق: كل النتائج (3)", "أُصدر: 2026-10-25 10:00 · بواسطة المالك",
    ]);
    expect(statementLines({ ...statement, period: null, filters: [], scope: { kind: "page", count: 25, total: 282 }, by: null }).slice(2)).toEqual(["الفترة: كل الفترات", "المرشحات: بلا مرشحات", "النطاق: هذه الصفحة فقط (25 من 282)", "أُصدر: 2026-10-25 10:00"]);
    const sheet = sheetOf(statement, { columns: ["المرجع", "الضيف"], rows: [["R-1", "أ"], ["R-2", "ب"], ["R-3", "ج"]] });
    expect(sheet.headerRow).toBe(7);
    expect(sheet.rows[7]).toEqual(["المرجع", "الضيف"]);
    expect(sheet.rows.length).toBe(6 + 1 + 1 + 3);
    expect(exportFileName(statement, "xlsx")).toBe("الحجوزات-فرع_الاختبار-2026-10-01_2026-10-25-all-3.xlsx");
    expect(exportFileName({ ...statement, scope: { kind: "page", count: 25, total: 282 }, period: null }, "csv")).toBe("الحجوزات-فرع_الاختبار-all-page-25.csv");
  });

  it("XL05 the printed document carries the same statement as a header, every row, and the scope in its footer; values are escaped", () => {
    const html = buildPrintDocument({ ...statement, scope: { kind: "page", count: 2, total: 282 } }, { columns: ["المرجع", "المبلغ"], rows: [["R-1 <b>", money(100)], ["R-2", money(250050)]] });
    expect(html).toContain('<html lang="ar" dir="rtl">');
    expect(html).toContain("<h1>الحجوزات</h1>");
    for (const line of statementLines({ ...statement, scope: { kind: "page", count: 2, total: 282 } }).slice(1)) expect(html).toContain(`<span>${line}</span>`);
    expect(html).toContain("<td>R-1 &lt;b&gt;</td><td>1.00</td>");
    expect(html).toContain("<td>R-2</td><td>2,500.50</td>");
    expect(html).toContain("هذه الصفحة فقط (2 من 282) · 2 صفًا في هذه الطباعة");
    expect(html).toContain("size: A4 landscape");
  });

  it("XL06 the CSV keeps the statement as its first lines, a BOM, and quotes every field", () => {
    const csv = csvText(statement, { columns: ["أ", "ب"], rows: [['x"y', money(5)]] });
    expect(csv.charCodeAt(0)).toBe(0xfeff);
    const lines = csv.slice(1).split("\n");
    expect(lines[0]).toBe('"الحجوزات"');
    expect(lines[4]).toBe('"النطاق: كل النتائج (3)"');
    expect(lines[6]).toBe("");
    expect(lines[7]).toBe('"أ","ب"');
    expect(lines[8]).toBe('"x""y","0.05"');
    // the zip helper itself: an empty data entry and the CRC of a known string
    expect(crc32(new TextEncoder().encode("123456789"))).toBe(0xcbf43926);
    expect(readZip(zipStore([{ name: "a.txt", data: new Uint8Array(0) }])).get("a.txt")!.data.length).toBe(0);
  });
});
