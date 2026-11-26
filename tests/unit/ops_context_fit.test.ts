/** F5: the briefing context is cut by whole items, stays valid JSON, and says what was left out. */
import { describe, it, expect } from "vitest";
import { fitOpsContext } from "../../supabase/functions/_shared/ops";

const item = (i: number) => ({ id: i, text: "بند تشغيلي رقم " + i + " ".repeat(40) });
describe("fitOpsContext", () => {
  it("leaves a small context byte-identical", () => {
    const c = { summary: { date: "2026-11-27" }, items: [item(1)] };
    const r = fitOpsContext(c, 12000);
    expect(r.text).toBe(JSON.stringify(c)); expect(r.cut).toBe(false); expect(r.omitted).toEqual({});
  });
  it("drops whole items from the longest list, keeps valid JSON, records the count", () => {
    const c = { summary: { date: "2026-11-27", n: 5 }, arrivals: Array.from({ length: 200 }, (_, i) => item(i)), tasks: Array.from({ length: 5 }, (_, i) => item(i)) };
    const r = fitOpsContext(c, 4000);
    const parsed = JSON.parse(r.text);
    expect(r.text.length).toBeLessThanOrEqual(4000);
    expect(r.cut).toBe(false);
    expect(parsed.summary).toEqual(c.summary);
    expect(parsed.tasks).toHaveLength(5);                      // the short list is untouched
    expect(parsed.arrivals.length + parsed._omitted.arrivals).toBe(200);
    expect(parsed.arrivals[0]).toEqual(c.arrivals[0]);          // the head is kept, in order
    expect(parsed.arrivals.every((x: { id: number; text: string }) => typeof x.id === "number" && x.text)).toBe(true);   // no half items
  });
  it("counts nested lists by path", () => {
    const c = { a: { rows: Array.from({ length: 300 }, (_, i) => item(i)) } };
    const parsed = JSON.parse(fitOpsContext(c, 3000).text);
    expect(parsed.a.rows.length + parsed._omitted["a.rows"]).toBe(300);
  });
  it("falls back to a character cut only when no list is left, and says so", () => {
    const r = fitOpsContext({ blob: "x".repeat(20000) }, 1000);
    expect(r.cut).toBe(true); expect(r.text.length).toBe(1000);
  });
});
