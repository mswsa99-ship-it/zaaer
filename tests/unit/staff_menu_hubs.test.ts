// 6.2: the staff menu has at most 12 items for every role (9 with the three centres), and no page is lost behind the centres.
import { describe, it, expect } from "vitest";
import { staffMenu, staffNav, hubTabs, ALL_STAFF, PAGES } from "../../src/lib/nav";

describe("staff menu with centres (6.2)", () => {
  it("the old menu had 22 items for the owner (the baseline of the plan)", () => {
    expect(staffNav("owner").length).toBe(22);
  });
  for (const role of ALL_STAFF) {
    it(`${role}: at most 12 menu items and every other page is a tab of a centre`, () => {
      const menu = staffMenu(role);
      expect(menu.length).toBeLessThanOrEqual(12);
      const reachable = new Set<string>();
      for (const m of menu) { reachable.add(m.path); (m.members ?? []).forEach((x) => reachable.add(x)); }
      for (const p of staffNav(role)) expect(reachable.has(p.path), `${role} loses ${p.path}`).toBe(true);
    });
  }
  it("the owner's menu is 9 items with three centres", () => {
    expect(staffMenu("owner").map((m) => m.label)).toEqual(["لوحة الوحدات", "لوحة العمليات", "النزيل", "الحجوزات", "المالية", "المراجعة", "خدمة الغرف", "الرموز", "البلاغات"]);
  });
  it("every page tagged with a centre is listed in that centre's tab order", () => {
    for (const hub of ["guest", "finance", "review"] as const) {
      const tagged = PAGES.filter((p) => p.hub === hub).map((p) => p.path).sort();
      expect(hubTabs(hub, "owner").map((p) => p.path).sort()).toEqual(tagged);
    }
  });
});
