import { describe, it, expect } from "vitest";
import { mergeDailySummary, mergeFollowups } from "../../src/lib/allBranches";

const s = (active: number, occupied: number, all?: number) => ({ date: "d", occupancy_pct: 0, occupancy_all_pct: 0, units: { active, all, occupied, ready: 1 }, tickets_open: 1 });
describe("owner all-branches operations centre", () => {
  it("adds counts and recomputes occupancy from the sums, never averaging", () => {
    const m = mergeDailySummary([s(10, 5, 10), s(30, 3, 30)])!;
    expect(m.units.active).toBe(40); expect(m.units.occupied).toBe(8); expect(m.tickets_open).toBe(2);
    expect(m.occupancy_pct).toBe(20);   // 8/40, not (50+10)/2
  });
  it("ignores a branch that returned nothing and gives null when none did", () => {
    expect(mergeDailySummary([null, s(10, 5, 10)])!.units.active).toBe(10);
    expect(mergeDailySummary([null, null])).toBeNull();
  });
  it("joins follow-up lists", () => {
    const f = (n: number) => ({ generated_at: "x", overdue: Array(n).fill(1), departed_open: [], late_departures: [2] });
    const m = mergeFollowups([f(1), f(2), null])!;
    expect(m.overdue.length).toBe(3); expect(m.late_departures.length).toBe(2);
  });
});
