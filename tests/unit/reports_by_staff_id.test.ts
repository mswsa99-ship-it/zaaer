import { describe, it, expect } from "vitest";
import { mergeDiscounts, mergeLateEntries, mergeIdentities } from "../../src/lib/allBranches";

// 0150: the by-staff lines carry staff_id; two people with the same display name stay two lines, the same person in two branches is one line.
describe("by-staff merge keys use staff_id (homonyms)", () => {
  it("discounts: two same-name staff stay two lines, the same id joins across branches; lines without an id merge by name as before", () => {
    const a = { total_halalas: 3000, count: 2, rows: null, by_staff: [{ staff_id: "s1", staff: "موظف", role: "supervisor", count: 1, total_halalas: 1000 }, { staff_id: "s2", staff: "موظف", role: "supervisor", count: 1, total_halalas: 2000 }] };
    const b = { total_halalas: 500, count: 1, rows: null, by_staff: [{ staff_id: "s1", staff: "موظف", role: "supervisor", count: 1, total_halalas: 500 }] };
    const m = mergeDiscounts([a, b]);
    expect(m.by_staff).toHaveLength(2);
    expect(m.by_staff.find((r) => r.staff_id === "s1")).toMatchObject({ count: 2, total_halalas: 1500 });
    expect(m.by_staff.find((r) => r.staff_id === "s2")).toMatchObject({ count: 1, total_halalas: 2000 });
    const old = mergeDiscounts([{ ...a, by_staff: [{ staff: "ع", role: "x", count: 1, total_halalas: 1 }] }, { ...b, by_staff: [{ staff: "ع", role: "x", count: 1, total_halalas: 2 }] }]);
    expect(old.by_staff).toHaveLength(1); expect(old.by_staff[0]).toMatchObject({ count: 2, total_halalas: 3 });
  });
  it("late entries: same-name staff stay two lines, max lag kept per id", () => {
    const p = (staff_id: string, count: number, max_lag: number) => ({ platform_bookings: 1, late: count, after_arrival: 0, rows: [], by_staff: [{ staff_id, staff: "موظف", count, max_lag }] });
    const m = mergeLateEntries([p("s1", 1, 3), p("s2", 2, 5), p("s1", 1, 7)]);
    expect(m.by_staff).toHaveLength(2);
    expect(m.by_staff.find((r) => r.staff_id === "s1")).toMatchObject({ count: 2, max_lag: 7 });
  });
  it("identities: same-name staff stay two lines", () => {
    const p = (staff_id: string, office: number) => ({ count: office, rows: [], by_staff: [{ staff_id, staff: "موظف", office, guest: 0 }] });
    const m = mergeIdentities([p("s1", 1), p("s2", 2), p("s1", 3)]);
    expect(m.by_staff).toHaveLength(2);
    expect(m.by_staff.find((r) => r.staff_id === "s1")).toMatchObject({ office: 4 });
  });
});
