/**
 * Decision 71 — pages that serve operations of the permissions matrix follow the matrix (src/lib/nav.ts `cap`).
 * NV01: with the approved matrix every such page opens for exactly the roles it opened for before; NV02: a changed
 * cell moves the page and its link for that role, and the owner is never locked out; NV03: every code named exists.
 */
import { describe, it, expect } from "vitest";
import { PAGES, pageAllowed, adminNav, staffNav, type Allows } from "../../src/lib/nav";
import { defaultPermissions } from "../../src/lib/permissionCatalog";
import { PERMISSION_CATALOG } from "../../src/lib/permissionCatalog";

const ROLES = ["owner", "manager", "supervisor", "finance", "housekeeping"] as const;
const allowsOf = (role: string, extra: string[] = [], minus: string[] = []): Allows => {
  const d = defaultPermissions(role);
  const allowed = new Set([...d.allowed, ...extra].filter((c) => !minus.includes(c)));
  const full = new Set([...d.full, ...extra].filter((c) => !minus.includes(c)));
  return { can: (c) => allowed.has(c), canFull: (c) => full.has(c) };
};

describe("navigation follows the permissions matrix", () => {
  it("NV01 with the approved matrix every page that names operations opens for exactly its listed roles", () => {
    const capped = PAGES.filter((p) => p.cap);
    expect(capped.length).toBeGreaterThan(15);
    for (const p of capped) {
      const byMatrix = ROLES.filter((r) => pageAllowed(p, r, allowsOf(r)));
      expect(byMatrix, p.path).toEqual(ROLES.filter((r) => (p.roles as readonly string[]).includes(r)));
    }
  });

  it("NV02 a changed cell moves the page and its link; the owner keeps every page", () => {
    const sup = allowsOf("supervisor", [], ["res.create"]);
    expect(pageAllowed(PAGES.find((p) => p.path === "/staff/reservations/new")!, "supervisor", sup)).toBe(false);
    const fin = allowsOf("finance", ["definitions"]);
    expect(adminNav("finance", fin).flatMap((g) => g.items.map((i) => i.path))).toContain("/admin/rooms");
    const hk = allowsOf("housekeeping", [], ["keybox.code"]);
    expect(staffNav("housekeeping", hk).map((p) => p.path)).not.toContain("/staff/codes");
    const ownerNothing: Allows = { can: () => false, canFull: () => false };
    for (const p of PAGES) expect(pageAllowed(p, "owner", ownerNothing), p.path).toBe((p.roles as readonly string[]).includes("owner"));
    const mgr = allowsOf("manager", ["security", "staff.manage"]);
    expect(pageAllowed(PAGES.find((p) => p.path === "/admin/roles")!, "manager", mgr)).toBe(false);   // the matrix stays the owner's
  });

  it("NV03 every operation a page names is in the matrix", () => {
    const codes = new Set(PERMISSION_CATALOG.map((r) => r.code));
    for (const p of PAGES) for (const c of p.cap ?? []) expect(codes.has(c), `${p.path}: ${c}`).toBe(true);
  });
});
