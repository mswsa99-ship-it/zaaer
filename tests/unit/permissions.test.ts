/**
 * Decision 71 — the permissions matrix lives twice: fn_permission_catalog() in migration 0043 (the server decides by it)
 * and src/lib/permissionCatalog.ts (the matrix screen and the demo show it). PC01 keeps them identical; PC02 checks the
 * shape the owner approved; PC03 the money list matches fn_sees_money().
 */
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { PERMISSION_CATALOG, MONEY_PERMISSIONS, EDITABLE_ROLES } from "../../src/lib/permissionCatalog";

const m43 = readFileSync(join(__dirname, "..", "..", "supabase/migrations/20261029020000_0043_permissions_matrix.sql"), "utf8");
const body = (fn: string) => { const s = m43.indexOf(`create or replace function ${fn}(`); return m43.slice(s, m43.indexOf("$$;", s)); };
const roles = (x: string | undefined) => (x === undefined ? null : x.split(",").filter(Boolean));

describe("the permissions matrix — one catalogue in two places", () => {
  it("PC01 the TypeScript catalogue is fn_permission_catalog() of 0043, row for row", () => {
    const sql = [...body("fn_permission_catalog").matchAll(/\('([a-z_.]+)', '([^']+)', '([^']+)', (\d+), '\{([a-z,]*)\}'(?:::role_code\[\])?, (?:null|'\{([a-z,]*)\}'(?:::role_code\[\])?), (?:null|'([^']*)'), (true|false)\)/g)]
      .map((m) => ({ code: m[1], label: m[2], area: m[3], sort: Number(m[4]), defaultRoles: roles(m[5]), fullRoles: roles(m[6]), limitNote: m[7] ?? null, locked: m[8] === "true" }));
    expect(PERMISSION_CATALOG.map((r) => ({ ...r, defaultRoles: [...r.defaultRoles], fullRoles: r.fullRoles ? [...r.fullRoles] : null }))).toEqual(sql);
  });

  it("PC02 the approved shape: 55 operations, unique codes, the owner in every row, only the matrix itself locked, conditions only where full roles narrow it", () => {
    expect(PERMISSION_CATALOG.length).toBe(55);
    expect(new Set(PERMISSION_CATALOG.map((r) => r.code)).size).toBe(55);
    for (const r of PERMISSION_CATALOG) expect(r.defaultRoles, r.code).toContain("owner");
    expect(PERMISSION_CATALOG.filter((r) => r.locked).map((r) => r.code)).toEqual(["admin.permissions"]);
    for (const r of PERMISSION_CATALOG) expect(Boolean(r.limitNote), r.code).toBe(r.fullRoles !== null);
    expect(EDITABLE_ROLES).toEqual(["manager", "supervisor", "finance", "housekeeping"]);
  });

  it("PC03 the money operations are the ones fn_sees_money() asks", () => {
    const asked = [...body("fn_sees_money").matchAll(/fn_can\('([a-z_.]+)'\)/g)].map((m) => m[1]);
    expect([...MONEY_PERMISSIONS].sort()).toEqual(asked.sort());
  });
});
