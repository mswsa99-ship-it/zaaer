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
  it("the owner's menu is 6 items: Review sits inside Finance, Codes and Reports inside Room Service", () => {
    expect(staffMenu("owner").map((m) => m.label)).toEqual(["لوحة الوحدات", "لوحة العمليات", "النزيل", "الحجوزات", "المالية", "خدمة الغرف"]);
  });
  it("every page tagged with a centre is listed in that centre's tab order", () => {
    for (const hub of ["guest", "finance", "service"] as const) {
      const tagged = PAGES.filter((p) => p.hub === hub).map((p) => p.path).sort();
      expect(hubTabs(hub, "owner").map((p) => p.path).sort()).toEqual(tagged);
    }
  });

  // the grouping is navigation only: what each role may open is exactly what it could open before (nothing widens, nothing is lost)
  const WAS = {
    owner: { review: ["/staff/day-close", "/staff/platforms"], service: ["/staff/housekeeping", "/staff/codes", "/staff/tickets"] },
    manager: { review: ["/staff/day-close", "/staff/platforms"], service: ["/staff/housekeeping", "/staff/codes", "/staff/tickets"] },
    supervisor: { review: ["/staff/day-close", "/staff/platforms"], service: ["/staff/housekeeping", "/staff/codes", "/staff/tickets"] },
    finance: { review: ["/staff/day-close"], service: ["/staff/housekeeping", "/staff/tickets"] },
    housekeeping: { review: [], service: ["/staff/housekeeping", "/staff/codes", "/staff/tickets"] },
  } as const;
  for (const role of ALL_STAFF) {
    it(`${role}: Review tabs and Room Service tabs are the same pages as before, inside Finance and Room Service`, () => {
      const finance = hubTabs("finance", role).map((p) => p.path);
      const service = hubTabs("service", role).map((p) => p.path);
      expect(finance.filter((p) => p === "/staff/day-close" || p === "/staff/platforms")).toEqual([...WAS[role].review]);
      expect(service).toEqual([...WAS[role].service]);
      // the finance entry of a role with no payments tab leads to a page it may open (the first tab it has)
      const menu = staffMenu(role).find((m) => m.label === "المالية");
      if (menu) expect(menu.members).toContain(menu.path);
    });
  }
  it("/admin/review is the owner-only last tab of the finance centre; no other role sees it in any centre (26 Nov 13:10 merge ask, permissions unchanged)", () => {
    const owner = hubTabs("finance", "owner").map((p) => p.path);
    expect(owner[owner.length - 1]).toBe("/admin/review");
    for (const hub of ["guest", "finance", "service"] as const) for (const role of ALL_STAFF.filter((r) => r !== "owner")) expect(hubTabs(hub, role).map((p) => p.path)).not.toContain("/admin/review");
    for (const hub of ["guest", "service"] as const) expect(hubTabs(hub, "owner").map((p) => p.path)).not.toContain("/admin/review");
  });
});
