// Batch 3: role journeys. The phone bar and the menu order follow the role's work; what a role may open is unchanged.
import { describe, it, expect } from "vitest";
import { ALL_STAFF, PAGES, canOpen, groupedMenu, bottomTabPrefs, orderTopForRole } from "../../src/lib/nav";
import { pickTabs } from "../../src/components/BottomTabs";

// the openable page set per role at base 33b9422 (counts) — a reorder must never change it
const OPENABLE = { owner: 65, manager: 56, supervisor: 32, finance: 24, housekeeping: 12 } as const;
describe("role journeys (batch 3)", () => {
  for (const role of ALL_STAFF) {
    it(`${role}: openable page set is unchanged (${OPENABLE[role]})`, () => {
      expect(PAGES.filter((p) => canOpen(role, p.path.replace(":id", "x"))).length).toBe(OPENABLE[role]);
    });
    it(`${role}: reordering loses no menu entry`, () => {
      const top = groupedMenu(role).top;
      expect(orderTopForRole(role, top).map((t) => t.path).sort()).toEqual(top.map((t) => t.path).sort());
    });
  }
  it("owner order is untouched", () => {
    const top = groupedMenu("owner").top;
    expect(orderTopForRole("owner", top)).toEqual(top);
  });
  it("housekeeping leads with Room Service and its bar starts with its own page", () => {
    const top = orderTopForRole("housekeeping", groupedMenu("housekeeping").top);
    expect(top[0].label).toBe("خدمة الغرف");
    const items = top.map((p) => ({ to: p.path, label: p.label, icon: p.icon }));
    expect(pickTabs(items, bottomTabPrefs("housekeeping"))[0].to).toBe("/staff/housekeeping");
  });
  it("finance leads with its centre and its bar starts with payments", () => {
    const top = orderTopForRole("finance", groupedMenu("finance").top);
    expect(top[0].label).toBe("المالية");
    const items = top.map((p) => ({ to: p.path, label: p.label, icon: p.icon }));
    expect(pickTabs(items, bottomTabPrefs("finance"))[0].to).toBe("/staff/payments");
  });
  it("every preferred page of a role is a page that role can open", () => {
    for (const role of ALL_STAFF) for (const p of bottomTabPrefs(role)) if (canOpen(role, p)) expect(canOpen(role, p)).toBe(true);
  });
});

import { adminNav, type Allows } from "../../src/lib/nav";
describe("duplicate admin reservations link", () => {
  const paths = (role: string, allows?: Allows) => groupedMenu(role, allows).adminGroups.flatMap((g) => g.items.map((i) => i.path));
  for (const role of ["owner", "manager", "supervisor", "finance"] as const) {
    it(`${role}: the admin copy is not listed twice, the staff entry is, and the route still opens`, () => {
      expect(paths(role)).not.toContain("/admin/reservations");
      expect(groupedMenu(role).top.some((t) => t.path === "/staff/reservations")).toBe(true);
      expect(canOpen(role, "/admin/reservations")).toBe(true);
      // only that link (and the property tabs, which moved into their own centre) left the admin list
      expect(adminNav(role).flatMap((g) => g.items).length - 1 - hubTabs("property", role).length).toBe(paths(role).length);
    });
  }
  it("a person whose staff entry is not listed keeps the admin link (individual mode, admin page only)", () => {
    const allows: Allows = { can: () => false, canFull: () => false, pageAccess: { mode: "individual", pages: { "/admin/reservations": { view: true } } } as never };
    expect(adminNav("manager", allows).flatMap((g) => g.items.map((i) => i.path))).toContain("/admin/reservations");
    expect(paths("manager", allows)).toContain("/admin/reservations");
  });
});

import { hubTabs, pageAllowed } from "../../src/lib/nav";
describe("property data centre (three existing pages as tabs)", () => {
  const OLD = ["/admin/branches", "/admin/policies", "/admin/knowledge"];
  const oldListed = (role: string, allows?: Allows) => adminNav(role, allows).flatMap((g) => g.items.map((i) => i.path)).filter((p) => OLD.includes(p)).sort();
  const modes: Array<[string, Allows | undefined]> = [
    ["no matrix", undefined],
    ["all caps", { can: () => true, canFull: () => true }],
    ["no caps", { can: () => false, canFull: () => false }],
    ["knowledge only", { can: (c) => c === "knowledge", canFull: () => false }],
    ["branch.settings only", { can: (c) => c === "branch.settings", canFull: () => false }],
    ["individual: policies view only", { can: () => false, canFull: () => false, pageAccess: { mode: "individual", pages: { "/admin/policies": { view: true } } } as never }],
  ];
  for (const role of ALL_STAFF) for (const [name, allows] of modes) {
    it(`${role}, ${name}: tabs are exactly the pages listed before, each openable, none new`, () => {
      const tabs = hubTabs("property", role, allows).map((t) => t.path).sort();
      expect(tabs).toEqual(oldListed(role, allows));
      for (const t of tabs) expect(pageAllowed(PAGES.find((p) => p.path === t)!, role, allows)).toBe(true);
      const g = groupedMenu(role, allows);
      const entry = g.top.find((t) => t.label === "بيانات المنشأة");
      expect(!!entry).toBe(tabs.length > 0);
      // no property page is listed a second time in the admin groups
      for (const p of OLD) expect(g.adminGroups.flatMap((x) => x.items.map((i) => i.path))).not.toContain(p);
      // the entry leads to the first tab the person may open
      if (entry) expect(entry.path).toBe(hubTabs("property", role, allows)[0].path);
    });
  }
});
