import { expect, it } from "vitest";
import { groupedMenu, unifiedMenu, topLevelCount, pageAllowed } from "../../src/lib/nav";
import { defaultPermissions } from "../../src/lib/permissionCatalog";

const ROLES = ["owner", "manager", "supervisor", "finance", "housekeeping"];
function allowsFor(role: string) {
  const permissions = defaultPermissions(role);
  return { can: (c: string) => permissions.allowed.has(c), canFull: (c: string) => permissions.full.has(c) };
}
it.each(ROLES)("NV91 grouping keeps every page of the flat menu reachable and adds none (%s)", (role) => {
  const allows = allowsFor(role);
  const flat = unifiedMenu(role, allows).map((p) => p.path).sort();
  const g = groupedMenu(role, allows);
  const grouped = [...g.top.map((p) => p.path), ...g.adminGroups.flatMap((x) => x.items.map((p) => p.path))].sort();
  expect(grouped).toEqual(flat);
});
it.each(ROLES)("NV92 at most 12 top-level entries (%s)", (role) => {
  expect(topLevelCount(groupedMenu(role, allowsFor(role)))).toBeLessThanOrEqual(12);
});
it.each(ROLES)("NV93 every grouped page is one the role may open (%s)", (role) => {
  const allows = allowsFor(role);
  const g = groupedMenu(role, allows);
  for (const p of [...g.top, ...g.adminGroups.flatMap((x) => x.items)]) expect(pageAllowed(p, role, allows)).toBe(true);
});
it("NV94 the owner reaches the sensitive pages through the groups (purge is listed, not run)", () => {
  const g = groupedMenu("owner");
  const paths = g.adminGroups.flatMap((x) => x.items.map((p) => p.path));
  for (const p of ["/admin/data-purge", "/admin/backups", "/admin/roles", "/admin/audit-logs"]) expect(paths).toContain(p);
});
it("NV95 a role with no admin pages gets no «الإدارة» entry", () => {
  expect(groupedMenu("housekeeping", allowsFor("housekeeping")).adminGroups).toEqual([]);
});
