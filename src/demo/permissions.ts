/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * Demo parity for migration 0043 (decision 71): the permissions matrix the owner approved, editable from the owner's
 * account. The same rules, argument names, errors and return shapes as the SQL:
 *  - role_permissions holds only the cells the owner changed (organisation-wide); every other cell reads the approved
 *    default from PERMISSION_CATALOG (the copy of fn_permission_catalog());
 *  - can(code) answers for the person making the request, at that request (fn_can): nobody signed in → no; the owner →
 *    every operation of the catalogue; the locked row («تعديل مصفوفة الصلاحيات») → the owner only; otherwise the stored
 *    cell, else the approved default;
 *  - capFull / requireCap / requireCapFull / requireAnyCap / seesMoney / requireMoney mirror fn_cap_full,
 *    fn_require_cap, fn_require_cap_full, fn_require_any_cap, fn_sees_money and fn_require_money (same messages);
 *  - fn_my_permissions, fn_permissions_matrix, fn_admin_set_permissions, fn_admin_reset_permissions: the editor, with a
 *    reason and one audit row (category security) listing every cell before and after.
 */
import { nowISO, type Row } from "./data";
import { PERMISSION_CATALOG, EDITABLE_ROLES, MONEY_PERMISSIONS, permissionRow } from "../lib/permissionCatalog";

export interface PermissionsCtx {
  T: (t: string) => Row[];
  me: () => Row | null;
  staffId: () => string | null;
  audit: (branch: string | null, action: string, entity: string, entityId: string | null, details: Row) => void;
  emit: (table: string) => void;
  /** all or nothing, as the transaction: a refusal half-way leaves the store as it was */
  atomically: <V>(fn: () => V) => V;
}

export interface Permissions {
  can: (code: string) => boolean;
  capFull: (code: string) => boolean;
  requireCap: (code: string) => void;
  requireCapFull: (code: string) => void;
  requireAnyCap: (codes: string[]) => void;
  seesMoney: () => boolean;
  requireMoney: () => void;
}

const ALL_ROLES = ["owner", "manager", "supervisor", "finance", "housekeeping"];

export function makePermissions(c: Pick<PermissionsCtx, "T" | "me">): Permissions {
  const { T, me } = c;
  /** the stored cell of the organisation for (role, code), or undefined when the owner never changed it */
  const stored = (org: string, role: string, code: string) => T("role_permissions").find((x) => x.organization_id === org && x.role === role && x.capability === code);
  const can = (code: string): boolean => {
    const m = me(); if (!m) return false;
    const row = permissionRow(code);
    if (m.role === "owner") return !!row;
    if (!row) return false;
    if (row.locked) return false;
    const cell = stored(m.organization_id, m.role, code);
    return cell ? !!cell.allowed : row.defaultRoles.includes(m.role);
  };
  const capFull = (code: string): boolean => {
    if (!can(code)) return false;
    const m = me()!; if (m.role === "owner") return true;
    const row = permissionRow(code)!; return row.fullRoles == null || row.fullRoles.includes(m.role);
  };
  const requireCap = (code: string) => {
    if (!permissionRow(code)) throw new Error(`UNKNOWN_PERMISSION: ${code}`);
    if (!can(code)) throw new Error(`FORBIDDEN: ${code}`);
  };
  const requireCapFull = (code: string) => { requireCap(code); if (!capFull(code)) throw new Error(`FORBIDDEN: ${code} (limited)`); };
  const requireAnyCap = (codes: string[]) => { if (!codes.some((x) => can(x))) throw new Error(`FORBIDDEN: ${codes.join(" / ")}`); };
  const seesMoney = () => me()?.role === "owner" || MONEY_PERMISSIONS.some((x) => can(x));
  const requireMoney = () => { if (!seesMoney()) throw new Error("FORBIDDEN: money"); };
  return { can, capFull, requireCap, requireCapFull, requireAnyCap, seesMoney, requireMoney };
}

export function permissionRpcs(c: PermissionsCtx, p: Permissions): Record<string, (a: any) => any> {
  const { T, me, staffId, audit, emit, atomically } = c;
  const { can, capFull, requireCap, seesMoney } = p;
  const org = () => me()?.organization_id ?? null;
  const cellOf = (o: string, code: string, role: string) => T("role_permissions").find((x) => x.organization_id === o && x.capability === code && x.role === role);
  const isDefault = (code: string, role: string) => !!permissionRow(code)?.defaultRoles.includes(role as any);
  /** the cell as the matrix reads it: the stored value, else the approved default */
  const current = (o: string, code: string, role: string) => { const x = cellOf(o, code, role); return x ? !!x.allowed : isDefault(code, role); };
  const write = (o: string, code: string, role: string, allowed: boolean) => {
    const x = cellOf(o, code, role); const at = nowISO(), by = staffId();
    if (x) Object.assign(x, { allowed, updated_at: at, updated_by: by });
    else T("role_permissions").push({ organization_id: o, capability: code, role, allowed, updated_at: at, updated_by: by });
  };
  const changedCells = (o: string) => T("role_permissions").filter((x) => x.organization_id === o && permissionRow(x.capability) && !!x.allowed !== isDefault(x.capability, x.role));
  /** `x->>'k'`: the text of a json value (null when missing) */
  const textOf = (v: unknown): string | null => (v == null ? null : typeof v === "string" ? v : JSON.stringify(v));

  return {
    // what the person may do — the screens show and hide by it (the server decides anyway)
    fn_my_permissions: () => {
      const m = me(); if (!m) return { role: null, allowed: [], full: [], sees_money: false };
      const sorted = [...PERMISSION_CATALOG].sort((a, b) => a.sort - b.sort);
      return { role: m.role, allowed: sorted.filter((r) => can(r.code)).map((r) => r.code), full: sorted.filter((r) => capFull(r.code)).map((r) => r.code), sees_money: seesMoney() };
    },
    // the matrix as the owner edits it: every row, every role, its current value, the approved default
    fn_permissions_matrix: () => {
      requireCap("admin.permissions"); const o = org()!;
      const rows = [...PERMISSION_CATALOG].sort((a, b) => a.sort - b.sort).map((r) => ({
        code: r.code, label: r.label, area: r.area, locked: r.locked, limit_note: r.limitNote, full_roles: r.fullRoles ? [...r.fullRoles] : null,
        cells: Object.fromEntries(ALL_ROLES.map((role) => [role, {
          allowed: role === "owner" ? true : r.locked ? false : current(o, r.code, role),
          default: r.defaultRoles.includes(role as any),
          limited: role !== "owner" && r.fullRoles != null && !r.fullRoles.includes(role as any),
        }])),
      }));
      const last = T("audit_events").filter((e) => e.organization_id === o && ["permissions.updated", "permissions.reset"].includes(e.action))
        .sort((a, b) => (a.created_at < b.created_at ? 1 : a.created_at > b.created_at ? -1 : 0))[0];
      return {
        roles: [...ALL_ROLES], editable_roles: [...EDITABLE_ROLES], rows, changed: changedCells(o).length,
        last_change: last ? { at: last.created_at, by: T("staff_profiles").find((s) => s.id === last.actor_id)?.full_name ?? null, reason: textOf(last.details?.reason) } : null,
      };
    },
    // the owner ticks or unticks cells, with a reason; one audit row with every cell before and after
    fn_admin_set_permissions: ({ p }) => atomically(() => {
      requireCap("admin.permissions"); const o = org()!; const q: Row = p ?? {};
      const reason = String(textOf(q.reason) ?? "").trim() || null; if (!reason) throw new Error("VALIDATION: reason");
      if (!Array.isArray(q.changes)) throw new Error("VALIDATION: changes");
      const changes: Row[] = [];
      for (const ch of q.changes as any[]) {
        const obj = ch && typeof ch === "object" && !Array.isArray(ch) ? ch : {};
        const code = textOf(obj.code); const row = code == null ? undefined : permissionRow(code);
        if (!row) throw new Error(`UNKNOWN_PERMISSION: ${code ?? "<NULL>"}`);
        if (row.locked) throw new Error(`PERMISSION_LOCKED: ${row.code}`);
        const role = textOf(obj.role) ?? ""; if (!(EDITABLE_ROLES as readonly string[]).includes(role)) throw new Error("VALIDATION: role");
        if (typeof obj.allowed !== "boolean") throw new Error("VALIDATION: allowed");
        const before = current(o, row.code, role);
        if (before !== obj.allowed) { write(o, row.code, role, obj.allowed); changes.push({ code: row.code, label: row.label, role, before, after: obj.allowed }); }
      }
      if (!changes.length) return { ok: true, unchanged: true };
      emit("role_permissions");
      audit(null, "permissions.updated", "role_permissions", null, { changes, reason });
      return { ok: true, changed: changes.length };
    }),
    // back to the approved matrix, with a reason; the audit row lists every cell that changed back
    fn_admin_reset_permissions: ({ p_reason }) => {
      requireCap("admin.permissions"); const o = org()!;
      const reason = String(textOf(p_reason) ?? "").trim(); if (!reason) throw new Error("VALIDATION: reason");
      const back = changedCells(o);
      const changes = back.map((x) => ({ code: x.capability, label: permissionRow(x.capability)!.label, role: x.role, before: !!x.allowed, after: isDefault(x.capability, x.role) }));
      if (!changes.length) return { ok: true, unchanged: true };
      for (const x of back) write(o, x.capability, x.role, isDefault(x.capability, x.role));
      emit("role_permissions");
      audit(null, "permissions.reset", "role_permissions", null, { changes, reason });
      return { ok: true, changed: changes.length };
    },
  };
}
