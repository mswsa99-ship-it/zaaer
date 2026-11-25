/**
 * Plan 3.4 — the automated scan of staff texts (فحص آلي لنصوص الموظف). Fixture controls for the scanner; the
 * run against the real tree is the rename inventory reported with the work package, and after the rename the
 * same functions back the gate. No test codes: prefix registration is left to the integrator.
 */
import { describe, it, expect } from "vitest";
// @ts-expect-error — a plain ES module of the scripts folder, without type declarations
import { findBrandOccurrences, findTitleAssignments, classifySurface } from "../../scripts/lib/brandScan.mjs";

describe("staff brand scan (plan 3.4)", () => {
  it("finds every brand occurrence with its line, in Arabic and Latin", () => {
    const src = [
      `const a = "مساعد الاستقبال الذكي";`,
      `const b = "لا اسم هنا";`,
      `<h1>فايف اورز</h1>`,
      `const c = "مساعد الاستقبال الذكي مرة ثانية";`,
    ].join("\n");
    const found = findBrandOccurrences(src, ["مساعد الاستقبال الذكي", "فايف اورز"], "f.tsx");
    expect(found).toHaveLength(3);
    expect(found.map((f) => f.line)).toEqual([1, 3, 4]);
    expect(found[0].brand).toBe("مساعد الاستقبال الذكي");
    expect(found[1].brand).toBe("فايف اورز");
  });

  it("classifies surfaces: guest pages are the hotel's, staff and admin pages are RoomAI's, the rest is shared", () => {
    expect(classifySurface("src/pages/guest/Landing.tsx")).toBe("guest");
    expect(classifySurface("src/components/GuestJourney.tsx")).toBe("guest");
    expect(classifySurface("src/layouts/GuestLayout.tsx")).toBe("guest");
    expect(classifySurface("src/pages/staff/StaffDashboard.tsx")).toBe("staff");
    expect(classifySurface("src/pages/admin/AdminRates.tsx")).toBe("staff");
    expect(classifySurface("src/layouts/StaffLayout.tsx")).toBe("staff");
    expect(classifySurface("index.html")).toBe("shared");
    expect(classifySurface("src/lib/money.ts")).toBe("shared");
  });

  it("collects the static <title> and dynamic document.title assignments the 3.4 e2e will assert", () => {
    const html = findTitleAssignments(`<head>\n  <title>مساعد الاستقبال الذكي | فايف اورز</title>\n</head>`, "index.html");
    expect(html).toEqual([{ file: "index.html", line: 2, kind: "html", value: "مساعد الاستقبال الذكي | فايف اورز" }]);
    const dyn = findTitleAssignments(`useEffect(() => {\n  document.title = org ? \`\${title} — \${org}\` : title;\n});`, "ui.tsx");
    expect(dyn).toHaveLength(1);
    expect(dyn[0]).toMatchObject({ line: 2, kind: "dynamic" });
    expect(findTitleAssignments("const title = 'عادي';")).toEqual([]);
  });
});
