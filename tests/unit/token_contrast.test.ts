/**
 * Plan 3.2 — the automated token-contrast check (اختبار تباين آلي للرموز). The math is proven here on grounded
 * vectors; once the owner approves the design system (3.1) and the token file lands, its pairs are fed through
 * checkPairs and any pair below AA fails the gate. No test codes yet: the DS/DT prefix registration is reported
 * to the integrator instead of editing tests/acceptance-library.json from a work package.
 */
import { describe, it, expect } from "vitest";
import { parseColor, relativeLuminance, contrastRatio, meetsAA, checkPairs, AA_NORMAL_TEXT, AA_LARGE_TEXT } from "../../src/lib/contrast";
import { declaredPairs, knownContrastExceptions } from "../../src/lib/designTokens";

describe("contrast ratio math (WCAG 2.x)", () => {
  it("black on white is 21:1 and a color on itself is 1:1", () => {
    expect(contrastRatio("#000000", "#ffffff")).toBeCloseTo(21, 5);
    expect(contrastRatio("#ffffff", "#000000")).toBeCloseTo(21, 5);
    expect(contrastRatio("#2b7a90", "#2b7a90")).toBeCloseTo(1, 5);
  });

  it("parses #rgb, #rrggbb and rgb(), and rejects non-colors", () => {
    expect(parseColor("#fff")).toEqual({ r: 255, g: 255, b: 255 });
    expect(parseColor("#1f5f74")).toEqual({ r: 31, g: 95, b: 116 });
    expect(parseColor("rgb(31, 95, 116)")).toEqual({ r: 31, g: 95, b: 116 });
    expect(parseColor("#1f5f74cc")).toEqual({ r: 31, g: 95, b: 116 });
    expect(parseColor("not-a-color")).toBeNull();
    expect(parseColor("rgb(300, 0, 0)")).toBeNull();
    expect(parseColor("")).toBeNull();
  });

  it("relative luminance is 0 for black and 1 for white", () => {
    expect(relativeLuminance({ r: 0, g: 0, b: 0 })).toBe(0);
    expect(relativeLuminance({ r: 255, g: 255, b: 255 })).toBe(1);
  });

  it("the WCAG boundary greys: #777777 fails AA on white, #767676 passes", () => {
    // The documented boundary of criterion 1.4.3 on a white background (W3C G18 examples)
    expect(contrastRatio("#777777", "#ffffff")!).toBeLessThan(AA_NORMAL_TEXT);
    expect(contrastRatio("#767676", "#ffffff")!).toBeGreaterThanOrEqual(AA_NORMAL_TEXT);
    expect(meetsAA("#777777", "#ffffff")).toBe(false);
    expect(meetsAA("#767676", "#ffffff")).toBe(true);
  });

  it("reproduces the ratios documented in tailwind.config.js for the current palette", () => {
    // Each value is written next to its color in tailwind.config.js (U2 notes); the test recomputes it
    expect(contrastRatio("#566a8c", "#ffffff")!).toBeCloseTo(5.47, 1);   // ink-400 on white
    expect(contrastRatio("#167366", "#ffffff")!).toBeCloseTo(5.71, 1);   // accent-700 on white
    expect(contrastRatio("#8a5409", "#fbf3e8")!).toBeCloseTo(5.69, 1);   // warning-700 on warning-50
    // brand-500 on white: index.css documents 4.56:1 for the focus ring, the WCAG formula computes 4.90:1
    // (the comment understates it; the color passes AA either way — flagged to the integrator)
    expect(contrastRatio("#2b7a90", "#ffffff")!).toBeCloseTo(4.9, 1);
    expect(meetsAA("#2b7a90", "#ffffff")).toBe(true);
  });

  it("unparseable colors never pass silently", () => {
    expect(contrastRatio("red", "#ffffff")).toBeNull();
    expect(meetsAA("red", "#ffffff")).toBe(false);
  });
});

describe("approved RoomAI token pairs (plan 3.2 gate)", () => {
  const exceptions = new Set(knownContrastExceptions.map((e) => e.label));

  it("every declared text/background pair meets its AA minimum, in نهار and ليل, except the recorded exceptions", () => {
    const failing = declaredPairs
      .filter((p) => !exceptions.has(p.label))
      .map((p) => ({ ...p, ratio: contrastRatio(p.text, p.background) }))
      .filter((p) => p.ratio === null || p.ratio < p.minimum);
    expect(failing, failing.map((f) => `${f.label}: ${f.ratio?.toFixed(2)} < ${f.minimum}`).join(" | ")).toEqual([]);
  });

  it("the exceptions stay visible at their measured ratios — never claimed as AA, pending a design decision", () => {
    expect(knownContrastExceptions.length).toBe(1);
    for (const e of knownContrastExceptions) {
      const pair = declaredPairs.find((p) => p.label === e.label);
      expect(pair, `exception without its pair: ${e.label}`).toBeDefined();
      const ratio = contrastRatio(pair!.text, pair!.background)!;
      expect(ratio, `${e.label} changed — re-review the exception`).toBeCloseTo(e.ratio, 2);
      expect(ratio).toBeLessThan(e.minimum);
    }
  });
});

describe("token pair checker", () => {
  it("passes pairs at or above AA and flags the ones below, normal and large text", () => {
    const results = checkPairs([
      { label: "نص أساسي على بطاقة", text: "#18233d", background: "#ffffff" },
      { label: "نص ثانوي باهت", text: "#cdd6e4", background: "#ffffff" },
      { label: "عنوان كبير", text: "#767676", background: "#ffffff", largeText: true },
      { label: "لون غير مقروء", text: "لون", background: "#ffffff" },
    ]);
    expect(results[0].pass).toBe(true);
    expect(results[1].pass).toBe(false);
    expect(results[1].required).toBe(AA_NORMAL_TEXT);
    expect(results[2].pass).toBe(true);   // #767676 fails 4.5:1? no — and as large text it only needs 3:1 anyway
    expect(results[2].required).toBe(AA_LARGE_TEXT);
    expect(results[3].pass).toBe(false);  // unparseable token value is a failure, never a pass
    expect(results[3].ratio).toBeNull();
  });

  it("every declared pair is returned with its label, so a failure names the pair", () => {
    const results = checkPairs([
      { label: "أ", text: "#000000", background: "#ffffff" },
      { label: "ب", text: "#ffffff", background: "#ffffff" },
    ]);
    expect(results.map((r) => r.label)).toEqual(["أ", "ب"]);
    expect(results.filter((r) => !r.pass).map((r) => r.label)).toEqual(["ب"]);
  });
});
