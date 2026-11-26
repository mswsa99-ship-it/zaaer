import { describe, it, expect } from "vitest";
import { mergeReviews } from "../../src/lib/journeyMerge";
import type { StaffReviews } from "../../src/lib/api";

const mk = (marks: number[], count = marks.length, avg?: number): StaffReviews => ({
  aspects: [{ key: "staff", label: "x" }], alert_below: 6, invited: marks.length,
  summary: { count, below: 0, overall: avg ?? marks.reduce((a, n) => a + n, 0) / (marks.length || 1), staff: avg ?? 0 },
  reviews: marks.map((n, i) => ({ id: `r${i}${n}`, overall: n, staff: n })),
} as unknown as StaffReviews);

describe("mergeReviews", () => {
  it("MRG1 exact: averages the raw rows, not the rounded branch averages", () => {
    const a = mk([9, 8, 8], 3, 8.3), b = mk([5], 1, 5);       // plain mean of branch averages would be 6.65
    const r = mergeReviews([a, b]);
    expect(r.exact).toBe(true);
    expect(r.merged!.summary.overall).toBe(7.5);              // (9+8+8+5)/4 = 7.5
  });
  it("MRG2 count-vs-row mismatch is flagged approximate and weighted by count", () => {
    const a = mk([9, 8], 3, 8.7), b = mk([5], 1, 5);          // branch a says 3 reviews but returned 2 rows
    const r = mergeReviews([a, b]);
    expect(r.exact).toBe(false);
    expect(r.merged!.summary.overall).toBe(7.8);              // (8.7*3 + 5*1)/4 = 7.775 -> 7.8
  });
  it("MRG3 nothing to merge", () => { expect(mergeReviews([]).merged).toBeNull(); });
});
