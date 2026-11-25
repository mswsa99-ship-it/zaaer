import { describe, it, expect } from "vitest";
import { PAGES } from "../../src/lib/nav";
import { ROUTE_MAP, routeMapText } from "../../supabase/functions/_shared/route_map";
import { buildOpsSystemPrompt } from "../../supabase/functions/_shared/ops";

// RM: the staff assistant's page map comes from the app's own page table, so it cannot drift, and it is guidance only.
describe("RM assistant route map", () => {
  it("RM01 matches the app's page table exactly (regenerate supabase/functions/_shared/route_map.ts from PAGES if this fails)", () => {
    const rows = PAGES.filter((p) => !p.hidden).map((p) => ({ path: p.path, label: p.label, area: p.area, roles: [...p.roles] }));
    expect(ROUTE_MAP).toEqual(rows);
  });
  it("RM02 a role is told only the pages its role may open by default", () => {
    const hk = routeMapText("housekeeping");
    for (const p of PAGES.filter((x) => !x.hidden && !x.roles.includes("housekeeping"))) expect(hk).not.toContain(`: ${p.path}\n`);
    for (const p of PAGES.filter((x) => !x.hidden && x.roles.includes("housekeeping"))) expect(hk).toContain(p.path);
    expect(routeMapText("not-a-role")).toBe("");
  });
  it("RM03 the prompt carries the map as guidance, keeps the read-only rule, and never lists a page the role lacks", () => {
    const base = { propertyName: "x", branchName: "y", staffName: "z", today: "2026-11-25" };
    const owner = buildOpsSystemPrompt({ ...base, role: "owner" });
    const hk = buildOpsSystemPrompt({ ...base, role: "housekeeping" });
    expect(owner).toContain("للإرشاد");
    expect(owner).toContain("/staff/rooms");
    expect(hk).toContain("لا تنفذ ولا تقترح تنفيذ");
    const adminOnly = PAGES.find((p) => !p.hidden && !p.roles.includes("housekeeping") && p.roles.includes("owner"))!;
    expect(hk).not.toContain(adminOnly.path + "\n");
  });
  it("RM04 the map holds no secret-like field (paths and labels only)", () => {
    for (const r of ROUTE_MAP) expect(Object.keys(r).sort()).toEqual(["area", "label", "path", "roles"]);
  });
});
