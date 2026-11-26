/** F5: the briefing context always reaches the model as valid JSON within the limit, and the model is told when it is partial. */
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fitOpsContext, opsContextNote } from "../../supabase/functions/_shared/ops";

const item = (i: number) => ({ id: i, text: "بند تشغيلي رقم " + i + " ".repeat(40) });
const deepFreeze = <T,>(o: T): T => { if (o && typeof o === "object") { Object.values(o as object).forEach(deepFreeze); Object.freeze(o); } return o; };

describe("fitOpsContext", () => {
  it("leaves a small context byte-identical", () => {
    const c = { summary: { date: "2026-11-27" }, items: [item(1)] };
    const r = fitOpsContext(c, 12000);
    expect(r.text).toBe(JSON.stringify(c)); expect(r.mode).toBe("full"); expect(r.omitted).toEqual({}); expect(opsContextNote(r)).toBe("");
  });
  it("drops whole items from the largest list, keeps valid JSON within the limit, records the count", () => {
    const c = { summary: { date: "2026-11-27", n: 5 }, arrivals: Array.from({ length: 200 }, (_, i) => item(i)), tasks: Array.from({ length: 5 }, (_, i) => item(i)) };
    const r = fitOpsContext(c, 4000);
    const parsed = JSON.parse(r.text);
    expect(r.text.length).toBeLessThanOrEqual(4000);
    expect(r.mode).toBe("trimmed");
    expect(parsed.summary).toEqual(c.summary);
    expect(parsed.tasks).toHaveLength(5);
    expect(parsed.arrivals.length + parsed._omitted.arrivals).toBe(200);
    expect(r.omitted.arrivals).toBe(parsed._omitted.arrivals);
    expect(parsed.arrivals[0]).toEqual(c.arrivals[0]);
    expect(parsed.arrivals.every((x: { id: number; text: string }) => typeof x.id === "number" && x.text)).toBe(true);
    expect(opsContextNote(r)).toContain("_omitted");
  });
  it("trims nested lists and lists inside lists, counting by path", () => {
    const nested = { a: { rows: Array.from({ length: 300 }, (_, i) => item(i)) } };
    const p1 = JSON.parse(fitOpsContext(nested, 3000).text);
    expect(p1.a.rows.length + p1._omitted["a.rows"]).toBe(300);
    const inList = { groups: Array.from({ length: 6 }, (_, g) => ({ g, rows: Array.from({ length: 60 }, (_, i) => item(i)) })) };
    const r = fitOpsContext(inList, 5000);
    expect(r.text.length).toBeLessThanOrEqual(5000);
    expect(() => JSON.parse(r.text)).not.toThrow();
  });
  it("never mutates its input", () => {
    const c = deepFreeze({ summary: { n: 1 }, rows: Array.from({ length: 300 }, (_, i) => item(i)) });
    const before = JSON.stringify(c);
    expect(() => fitOpsContext(c, 3000)).not.toThrow();
    expect(JSON.stringify(c)).toBe(before);
  });
  it("a huge scalar falls back to a valid envelope that keeps what fits and names what was dropped", () => {
    const c = { summary: { date: "2026-11-27" }, notes: "x".repeat(30000), flag: true };
    const r = fitOpsContext(c, 2000);
    const p = JSON.parse(r.text);
    expect(r.mode).toBe("envelope"); expect(r.text.length).toBeLessThanOrEqual(2000);
    expect(p._context_cut).toBe(true); expect(p._dropped_keys).toEqual(["notes"]); expect(p.summary).toEqual(c.summary); expect(p.flag).toBe(true);
    expect(opsContextNote(r)).toContain("_dropped_keys");
  });
  it("a root array, a primitive and an object with no list all give valid JSON within the limit", () => {
    for (const v of [Array.from({ length: 400 }, (_, i) => item(i)), "y".repeat(5000), { only: "z".repeat(5000) }]) {
      const r = fitOpsContext(v, 1500);
      expect(r.text.length).toBeLessThanOrEqual(1500);
      expect(() => JSON.parse(r.text)).not.toThrow();
      expect(r.mode).not.toBe("full");
    }
  });
  it("empty lists are fine and are not reported as omitted", () => {
    const r = fitOpsContext({ a: [], b: { c: [] }, big: "q".repeat(9000) }, 1000);
    expect(() => JSON.parse(r.text)).not.toThrow();
    expect(r.omitted).toEqual({});
  });
  it("a very large payload is trimmed in bounded time", () => {
    const c = { summary: { n: 1 }, rows: Array.from({ length: 20000 }, (_, i) => item(i)) };
    const t0 = Date.now(); const r = fitOpsContext(c, 12000); const ms = Date.now() - t0;
    expect(r.text.length).toBeLessThanOrEqual(12000); expect(() => JSON.parse(r.text)).not.toThrow();
    expect(ms).toBeLessThan(1500);
  });
});

describe("call site", () => {
  const src = readFileSync("supabase/functions/ai-ops/index.ts", "utf8");
  it("sends the fitted context with the note, and no raw character cut remains", () => {
    expect(src).toContain("ctxFit.text + opsContextNote(ctxFit)");
    expect(src).not.toMatch(/JSON\.stringify\(ctxData\)\.slice\(/);
    expect(src).toContain("ctxFit.mode !== \"full\"");   // the trim is logged, not hidden
  });
});
