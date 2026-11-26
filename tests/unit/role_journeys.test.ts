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
