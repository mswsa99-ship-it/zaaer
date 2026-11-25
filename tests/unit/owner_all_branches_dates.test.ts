import { describe, it, expect } from "vitest";
import { tapDay, confirmPick, inPick, eachDay, monthCells, describeRange } from "../../src/lib/dateRange";
import { sumDeep, pct, mergeRows } from "../../src/lib/allBranches";
import { hourLabel, periodOf, describeTime, parseHHMM, toHHMM, wheelIndex, HOURS_24 } from "../../src/lib/timeText";

describe("day or period selection", () => {
  it("one day then confirm = that day only", () => {
    const p = tapDay({ a: null, b: null }, "2026-11-20");
    expect(confirmPick(p)).toEqual({ from: "2026-11-20", to: "2026-11-20" });
  });
  it("two days then confirm = the inclusive period, in date order", () => {
    const p = tapDay(tapDay({ a: null, b: null }, "2026-11-25"), "2026-11-20");
    expect(confirmPick(p)).toEqual({ from: "2026-11-20", to: "2026-11-25" });
    expect(inPick(p, "2026-11-20")).toBe(true); expect(inPick(p, "2026-11-25")).toBe(true); expect(inPick(p, "2026-11-26")).toBe(false);
  });
  it("a third tap starts a new selection; single mode never makes a period", () => {
    const p = tapDay(tapDay(tapDay({ a: null, b: null }, "2026-11-01"), "2026-11-05"), "2026-11-09");
    expect(confirmPick(p)).toEqual({ from: "2026-11-09", to: "2026-11-09" });
    expect(confirmPick(tapDay(tapDay({ a: null, b: null }, "2026-11-01", true), "2026-11-05", true))).toEqual({ from: "2026-11-05", to: "2026-11-05" });
  });
  it("nothing picked confirms nothing; the same day twice is that day", () => {
    expect(confirmPick({ a: null, b: null })).toBeNull();
    expect(confirmPick(tapDay(tapDay({ a: null, b: null }, "2026-11-01"), "2026-11-01"))).toEqual({ from: "2026-11-01", to: "2026-11-01" });
  });
  it("eachDay includes both ends; the display is ISO digits in a fixed order", () => {
    expect(eachDay("2026-11-29", "2026-12-02")).toEqual(["2026-11-29", "2026-11-30", "2026-12-01", "2026-12-02"]);
    expect(describeRange("2026-11-20", "2026-11-25")).toBe("2026-11-20 → 2026-11-25");
    expect(describeRange("2026-11-20", "2026-11-20")).toBe("2026-11-20");
  });
  it("month grid is Saturday-first (1 Nov 2026 is a Sunday)", () => {
    const c = monthCells(2026, 10);
    expect(c.findIndex((x) => x === "2026-11-01")).toBe(1);
    expect(c.filter(Boolean)).toHaveLength(30);
  });
});

describe("owner all-branches merge", () => {
  it("adds counts and money, recomputes percentages", () => {
    const m = sumDeep([{ units: { active: 10, occupied: 5 }, tickets_open: 1 }, { units: { active: 20, occupied: 5 }, tickets_open: 2 }]);
    expect(m).toEqual({ units: { active: 30, occupied: 10 }, tickets_open: 3 });
    expect(pct(m.units.occupied, m.units.active)).toBe(33.3);
    expect(pct(1, 0)).toBe(0);
  });
  it("merges rows by key", () => {
    const r = mergeRows([[{ k: "a", n: 1 }], [{ k: "a", n: 2 }, { k: "b", n: 4 }]], (x) => x.k, ["n"]);
    expect(r).toEqual([{ k: "a", n: 3 }, { k: "b", n: 4 }]);
  });
});

describe("time wheels", () => {
  it("24 hours read 12..11 then 12..11 and the period flips at the second 12", () => {
    expect(HOURS_24.map((h) => hourLabel(h)).join(",")).toBe("12,1,2,3,4,5,6,7,8,9,10,11,12,1,2,3,4,5,6,7,8,9,10,11");
    expect(periodOf(11)).toBe("صباحًا"); expect(periodOf(12)).toBe("مساءً"); expect(periodOf(0)).toBe("صباحًا");
  });
  it("keeps HH:MM as the stored value", () => {
    expect(describeTime("16:30")).toBe("4:30 مساءً"); expect(describeTime("00:05")).toBe("12:05 صباحًا"); expect(describeTime("")).toBe("");
    expect(parseHHMM("12:00")).toEqual({ h: 12, m: 0 }); expect(parseHHMM("")).toBeNull(); expect(parseHHMM("25:00")).toBeNull();
    expect(toHHMM(7, 5)).toBe("07:05");
  });
  it("wheel offset maps to a clamped index", () => {
    expect(wheelIndex(0, 44, 24)).toBe(0); expect(wheelIndex(44 * 13 + 10, 44, 24)).toBe(13); expect(wheelIndex(99999, 44, 24)).toBe(23); expect(wheelIndex(-5, 44, 24)).toBe(0);
  });
});

import { mergeDiscounts, mergeLateEntries, mergeIdentities } from "../../src/lib/allBranches";
describe("all-branches merges of the three owner reports", () => {
  it("discounts add up and staff rows join", () => {
    const a = { total_halalas: 1000, count: 1, by_staff: [{ staff: "س", role: "manager", count: 1, total_halalas: 1000 }], rows: [{ created_at: "2026-11-01" }] };
    const b = { total_halalas: 500, count: 2, by_staff: [{ staff: "س", role: "manager", count: 2, total_halalas: 500 }], rows: [{ created_at: "2026-11-02" }] };
    const m = mergeDiscounts([a, b]);
    expect(m.total_halalas).toBe(1500); expect(m.count).toBe(3);
    expect(m.by_staff).toHaveLength(1); expect(m.by_staff[0]).toMatchObject({ count: 3, total_halalas: 1500 });
    expect(m.rows![0]).toMatchObject({ created_at: "2026-11-02" });
  });
  it("late entries keep the largest lag", () => {
    const m = mergeLateEntries([
      { platform_bookings: 4, late: 1, after_arrival: 0, by_staff: [{ staff: "ع", count: 1, max_lag: 2 }], rows: [{ entered_on: "2026-11-01" }] },
      { platform_bookings: 6, late: 2, after_arrival: 1, by_staff: [{ staff: "ع", count: 2, max_lag: 5 }], rows: [{ entered_on: "2026-11-03" }] }]);
    expect(m).toMatchObject({ platform_bookings: 10, late: 3, after_arrival: 1 });
    expect(m.by_staff[0]).toMatchObject({ count: 3, max_lag: 5 });
  });
  it("identities add up", () => {
    const m = mergeIdentities([{ count: 2, by_staff: [{ staff: "ع", office: 1, guest: 1 }], rows: [{ a: 1 }] }, { count: 3, by_staff: [{ staff: "ع", office: 3, guest: 0 }], rows: [{ a: 2 }] }]);
    expect(m.count).toBe(5); expect(m.by_staff[0]).toMatchObject({ office: 4, guest: 1 }); expect(m.rows).toHaveLength(2);
  });
});
