/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * Demo parity for migration 0040 (phase 6: the lists, the calendar, the log, the ledger, the reports' filter options,
 * the staff editor, forced sign-out and «استعمال القدرات»). The same rules, argument names and return shapes as the SQL
 * functions, so the screens behave against the demo as against the server:
 *  - fn_reservation_list (decision 14, 10.1): every filter of the reference, the columns a column picker needs, an exact
 *    total, pages clamped to 1..1000; money, bans and ratings only for the roles that have them;
 *  - fn_reservation_calendar (10.2): units × days, at most 62 days, the allocations clipped to the window;
 *  - fn_audit_list (10.3): readable Arabic names (the one dictionary of src/lib/auditLabels.ts), filters, pages; security
 *    rows for the owner only, the details column for the owner and the manager, branch scoping for the others;
 *  - fn_voucher_list (10.4): filters, pages and totals over the whole filtered set, never over the page;
 *  - staff_saved_views: a person's own views, one default per screen, at most 20 live, archived never erased;
 *  - fn_report_filter_options and fn_branch_staff (decision 36): what the filters of a branch offer;
 *  - the staff editor, activation and «تسجيل خروج إجباري» (decisions 34, 35): a reason, before and after in the log, the
 *    phone masked, no one changes their own role or branches, the last owner stays, memberships retired not erased;
 *  - fn_reports_capability_usage (decision 55): from the audit log alone, «غير محسوم» where the log cannot tell.
 */
import { uid, nowISO, addDays, ORG, type Row } from "./data";
import { auditActionLabel, auditEntityLabel } from "../lib/auditLabels";
import { CAPABILITY_CATALOG } from "../lib/capabilityCatalog";
import type { Permissions } from "./permissions";

export interface Phase6Ctx extends Permissions {
  T: (t: string) => Row[];
  byId: (t: string, id: string | null | undefined) => Row | undefined;
  me: () => Row | null;
  myBranches: () => string[];
  hasRole: (...roles: string[]) => boolean;
  requireRole: (...roles: string[]) => void;
  requireBranch: (b: string | null | undefined) => void;
  staffId: () => string | null;
  staffName: (id: string | null | undefined) => string | null;
  audit: (branch: string | null, action: string, entity: string, entityId: string, details: Row) => void;
  emit: (table: string) => void;
  branchToday: (b?: string) => string;
  roomNo: (roomId: string | null) => string | null;
  guestName: (resId: string) => string | null;
  /** fn_is_member: an active owner of the organisation, or an active member whose membership is not retired */
  isMember: (staffId: string, branch: string) => boolean;
  banMatches: (resId: string) => Row[];
}

const STAFF_ROLES = ["owner", "manager", "supervisor", "finance", "housekeeping"];
const OPEN_STATUSES = ["pending_verification", "confirmed", "checked_in"];
const SCREENS = ["reservations", "vouchers", "audit"];
const USAGE_NOTE = "القياس من سجل الإجراءات وحده. «غير محسوم»: قدرة لا يسجّل السجل كل مساراتها، أو نافذة لا يغطيها السجل. لا يُحذف شيء آليًا بقلة الاستعمال (القرار 53).";

/** `x ilike '%q%'` */
const ilike = (v: unknown, q: string) => String(v ?? "").toLowerCase().includes(q.toLowerCase());
/** the branch's calendar day of a moment (`at time zone tz`) */
const dayIn = (iso: string, tz: string) => { try { return new Date(iso).toLocaleDateString("en-CA", { timeZone: tz }); } catch { return new Date(iso).toLocaleDateString("en-CA", { timeZone: "Asia/Riyadh" }); } };
const daysBetween = (a: string, b: string) => Math.round((Date.parse(b + "T00:00:00Z") - Date.parse(a + "T00:00:00Z")) / 86400000);
const clamp = (n: number, lo: number, hi: number) => Math.min(Math.max(n, lo), hi);
/** `(x)::int` with a default for a missing value */
const intArg = (v: unknown, dflt: number) => { if (v == null || v === "") return dflt; const n = Number(v); return Number.isFinite(n) ? Math.trunc(n) : dflt; };
/** `(x)::boolean`: true for the spellings Postgres accepts */
const boolArg = (v: unknown) => v === true || ["true", "t", "1", "yes", "on"].includes(String(v ?? "").toLowerCase());
const cmp = (a: any, b: any) => (a < b ? -1 : a > b ? 1 : 0);
const desc = (a: any, b: any) => cmp(b, a);
const text = (a: unknown, b: unknown) => String(a ?? "").localeCompare(String(b ?? ""));
const ms = (iso: unknown) => Date.parse(String(iso ?? "")) || 0;
const maskPhone = (p: unknown) => (p == null ? null : "••••" + String(p).slice(-4));
const sameSet = (a: string[], b: string[]) => a.length === new Set(a).size && b.length === new Set(b).size && a.length === b.length && a.every((x) => b.includes(x));
/** `details->>'reason'` */
const reasonOf = (details: unknown): string | null => { const v = details && typeof details === "object" ? (details as Row).reason : null; return v == null ? null : typeof v === "string" ? v : JSON.stringify(v); };

export function phase6Rpcs(c: Phase6Ctx): Record<string, (a: any) => any> {
  const { T, byId, me, myBranches, hasRole, requireBranch, staffId, staffName, audit, emit, branchToday, roomNo, guestName, isMember, banMatches, can, capFull, requireCap, requireMoney, seesMoney } = c;
  /** `coalesce(j->>'k', '')`: the text of a filter, '' when missing or null */
  const arg = (j: Row, k: string) => (j[k] == null ? "" : String(j[k]));
  const branchTz = (b: string | null | undefined) => (b ? byId("branches", b)?.timezone || "Asia/Riyadh" : "Asia/Riyadh");
  const primaryRating = (resId: string): number | null => { const pg = T("reservation_guests").find((g) => g.reservation_id === resId && g.is_primary); return pg?.guest_profile_id ? byId("guest_profiles", pg.guest_profile_id)?.rating ?? null : null; };
  const orgStaff = () => T("staff_profiles").filter((s) => s.organization_id === ORG);
  const liveBranches = (sid: string) => T("branch_memberships").filter((m) => m.staff_id === sid && !m.removed_at).sort((a, b) => cmp(ms(a.created_at), ms(b.created_at)) || cmp(a.id, b.id)).map((m) => m.branch_id as string);
  /** fn_audit_entity_ref: a short reference for the entity of an event */
  const entityRef = (type: string | null | undefined, id: string | null | undefined): string | null => {
    if (!id) return null;
    switch (type) {
      case "reservation": return byId("reservations", id)?.internal_ref ?? null;
      case "room": return byId("rooms", id)?.room_number ?? null;
      case "staff_profile": return byId("staff_profiles", id)?.full_name ?? null;
      case "financial_voucher": case "voucher": return byId("financial_vouchers", id)?.number ?? null;
      case "invoice": return byId("invoices", id)?.number ?? null;
      case "housekeeping_task": { const h = byId("housekeeping_tasks", id); if (!h || h.task_type_name_snapshot == null) return null; const rn = roomNo(h.room_id); return String(h.task_type_name_snapshot) + (rn ? " · " + rn : ""); }
      case "branch": return byId("branches", id)?.name_ar ?? null;
      case "room_category": return byId("room_categories", id)?.name_ar ?? null;
      case "facility": return byId("facilities", id)?.name ?? null;
      case "task_type": return byId("task_types", id)?.name ?? null;
      case "service_definition": return byId("service_definitions", id)?.name_ar ?? null;
      case "cash_account": return byId("cash_accounts", id)?.name ?? null;
      case "booking_source": return byId("booking_sources", id)?.name ?? null;
      case "block": return byId("blocks", id)?.name ?? null;
      case "floor": return byId("floors", id)?.name ?? null;
      case "knowledge_entry": { const k = byId("knowledge_entries", id); return k?.question == null ? null : String(k.question).slice(0, 60); }
      case "reservation_guest": { const g = byId("reservation_guests", id); return g ? byId("reservations", g.reservation_id)?.internal_ref ?? null : null; }
      default: return null;
    }
  };
  /** the staff member of the organisation an admin function targets */
  const orgStaffRow = (id: unknown) => { const sp = byId("staff_profiles", id ? String(id) : null); if (!sp || sp.organization_id !== ORG) throw new Error("NOT_FOUND: staff"); return sp; };
  const requireReason = (reason: unknown) => { const r = String(reason ?? "").trim(); if (!r) throw new Error("VALIDATION: reason"); return r; };

  return {
    // ---- the reservations list (decision 14, 10.1; X09b) ----
    fn_reservation_list: ({ p_branch, p_filters, p_limit, p_offset }) => {
      if (!p_branch || !myBranches().includes(p_branch)) return { total: 0, rows: [] };
      const f: Row = p_filters ?? {}; const tz = branchTz(p_branch); const money = seesMoney(); const a = (k: string) => arg(f, k);
      const statuses = a("status") ? a("status").split(",") : null; const q = a("q"); const pc = a("platform_collects"); const guests = T("reservation_guests");
      const base = T("reservations").filter((r) => r.branch_id === p_branch
        && (!statuses || statuses.includes(String(r.status)))
        && (a("open_only") !== "true" || OPEN_STATUSES.includes(r.status))
        && (!a("check_in_from") || r.check_in >= a("check_in_from")) && (!a("check_in_to") || r.check_in <= a("check_in_to"))
        && (!a("check_out_from") || r.check_out >= a("check_out_from")) && (!a("check_out_to") || r.check_out <= a("check_out_to"))
        && (!a("created_from") || dayIn(r.created_at, tz) >= a("created_from")) && (!a("created_to") || dayIn(r.created_at, tz) <= a("created_to"))
        && (!a("stay_on") || (r.check_in <= a("stay_on") && r.check_out > a("stay_on")))
        && (!a("source_id") || r.source_id === a("source_id")) && (!a("category_id") || r.room_category_id === a("category_id")) && (!a("room_id") || r.room_id === a("room_id"))
        && (!a("room_number") || byId("rooms", r.room_id)?.room_number === a("room_number"))
        && (!a("booking_type") || r.booking_type === a("booking_type"))
        && (!a("company") || ilike(r.company_name, a("company")))
        && (!a("price_basis") || r.price_basis === a("price_basis"))
        && (!a("payment_status") || String(r.payment_status) === a("payment_status")) && (!a("identity_status") || String(r.identity_status) === a("identity_status")) && (!a("access_status") || String(r.access_status) === a("access_status"))
        && (!a("group_ref") || r.group_ref === a("group_ref"))
        && (a("has_discount") !== "true" || Number(r.discount_halalas) > 0)
        && (!pc || r.platform_collects === boolArg(pc))
        && (a("has_balance") !== "true" || (money && Number(r.balance_due_halalas) > 0))
        && (!q || ilike(r.internal_ref, q) || ilike(r.external_ref, q) || ilike(r.cancel_reference, q) || ilike(r.company_name, q)
            || guests.some((g) => g.reservation_id === r.id && (ilike(g.full_name, q) || String(g.phone ?? "").includes(q)))));
      const sort = a("sort");
      const ordered = [...base].sort((x, y) => (sort === "check_in_asc" ? cmp(x.check_in, y.check_in) : sort === "check_out" ? desc(x.check_out, y.check_out) : sort === "created" ? desc(ms(x.created_at), ms(y.created_at)) : sort === "ref" ? cmp(x.internal_ref, y.internal_ref) : 0)
        || desc(x.check_in, y.check_in) || desc(ms(x.created_at), ms(y.created_at)));
      const lim = clamp(intArg(p_limit, 50), 1, 1000), off = intArg(p_offset, 0);
      const rows = ordered.filter((_, i) => i + 1 > off && i + 1 <= off + lim).map((r) => ({
        id: r.id, internal_ref: r.internal_ref, external_ref: r.external_ref ?? null, status: r.status, check_in: r.check_in, check_out: r.check_out, nights: daysBetween(r.check_in, r.check_out),
        guest_name: guestName(r.id), room_number: roomNo(r.room_id), source_name: byId("booking_sources", r.source_id)?.name ?? null, category_name: byId("room_categories", r.room_category_id)?.name_ar ?? null,
        booking_type: r.booking_type ?? null, company_name: r.company_name ?? null, price_basis: r.price_basis ?? null, adults: r.adults, companions: r.companions,
        platform_booked_on: r.platform_booked_on ?? null, platform_collects: r.platform_collects ?? null, created_by_name: staffName(r.created_by),
        actual_check_in: r.actual_check_in ?? null, actual_check_out: r.actual_check_out ?? null, cancelled_at: r.cancelled_at ?? null, cancel_reference: r.cancel_reference ?? null,
        total_halalas: money ? r.total_halalas : null, paid_halalas: money ? r.paid_halalas : null, discount_halalas: money ? r.discount_halalas : null, nightly_rate_halalas: money ? r.nightly_rate_halalas : null,
        balance_due_halalas: money ? r.balance_due_halalas : null, deposit_balance_halalas: money ? r.deposit_balance_halalas : null,
        payment_status: r.payment_status, identity_status: r.identity_status, access_status: r.access_status, created_at: r.created_at, group_ref: r.group_ref ?? null, hold: !!r.security_hold,
        ban: money ? banMatches(r.id).length > 0 : null,
        rating: hasRole("owner", "manager", "supervisor") ? primaryRating(r.id) : null }));
      return { total: base.length, rows };
    },

    // ---- «تقويم الحجوزات» (decision 14, 10.2): the units of a branch against the days of a window ----
    fn_reservation_calendar: ({ p_branch, p_from, p_to }) => {
      if (!p_branch || !myBranches().includes(p_branch)) throw new Error("FORBIDDEN: branch not permitted");
      if (!p_from || !p_to || p_to < p_from || daysBetween(p_from, p_to) > 62) throw new Error("VALIDATION: range");
      const money = seesMoney(); const end = addDays(p_to, 1);
      const floorOrder = (r: Row) => (r.floor_id ? byId("floors", r.floor_id)?.sort_order ?? null : null);
      const units = T("rooms").filter((r) => r.branch_id === p_branch && !r.archived_at)
        .sort((x, y) => { const fx = floorOrder(x), fy = floorOrder(y); if (fx == null && fy != null) return 1; if (fy == null && fx != null) return -1; return cmp(fx, fy) || cmp(x.room_number, y.room_number); })
        .map((r) => ({ room_id: r.id, room_number: r.room_number, category_id: r.category_id ?? null, category: byId("room_categories", r.category_id)?.name_ar ?? null, floor_id: r.floor_id ?? null, floor: byId("floors", r.floor_id)?.name ?? null, block: byId("blocks", r.block_id)?.name ?? null, status: r.status, cleanliness: r.cleanliness, is_active: !!r.is_active }));
      const segments = T("reservation_allocations").filter((al) => al.branch_id === p_branch && ["active", "closed"].includes(al.status) && al.from_date <= p_to && al.to_date > p_from)
        .map((al) => ({ al, r: byId("reservations", al.reservation_id) })).filter((x): x is { al: Row; r: Row } => !!x.r && !["cancelled", "rejected", "no_show"].includes(x.r.status))
        .sort((x, y) => cmp(x.al.room_id, y.al.room_id) || cmp(x.al.from_date, y.al.from_date))
        .map(({ al, r }) => ({ room_id: al.room_id, reservation_id: r.id, internal_ref: r.internal_ref, status: r.status, from_date: al.from_date > p_from ? al.from_date : p_from, to_date: al.to_date < end ? al.to_date : end,
          starts_before: al.from_date < p_from, ends_after: al.to_date > end, guest: guestName(r.id), source: byId("booking_sources", r.source_id)?.name ?? null, group_ref: r.group_ref ?? null,
          payment_status: money ? r.payment_status : null, balance_due_halalas: money ? r.balance_due_halalas : null }));
      return { from: p_from, to: p_to, today: branchToday(p_branch), units, segments };
    },

    // ---- the log (decision 14, 10.3; X09c): readable names, filters, pages; the same rows for the export ----
    fn_audit_list: ({ p }) => {
      requireCap("audit.log"); const q: Row = p ?? {}; const a = (k: string) => arg(q, k); const isOwner = hasRole("owner"), isMgmt = capFull("audit.log");
      const vBranch = a("branch_id") || null; if (vBranch) requireBranch(vBranch);
      const tz = vBranch ? branchTz(vBranch) : T("branches").filter((b) => b.organization_id === ORG).sort((x, y) => cmp(ms(x.created_at), ms(y.created_at)))[0]?.timezone || "Asia/Riyadh";
      const from = a("from") || null, to = a("to") || null; if (from && to && to < from) throw new Error("VALIDATION: period");
      const actor = a("actor_id") || null, action = a("action") || null, prefix = boolArg(q.action_prefix), entity = a("entity_type") || null, entityId = a("entity_id") || null, corr = a("correlation_id") || null;
      const cat = a("category") || null, result = a("result") || null, source = a("source") || null, search = a("q").trim() || null;
      const lim = clamp(intArg(q.limit, 50), 1, 500), off = Math.max(intArg(q.offset, 0), 0); const mine = myBranches();
      const all = T("audit_events").filter((e) => e.organization_id === ORG
        && ((e.category ?? "business") !== "security" || can("security"))
        && (isOwner || e.branch_id == null || mine.includes(e.branch_id))
        && (!vBranch || e.branch_id === vBranch)
        && (!from || dayIn(e.created_at, tz) >= from) && (!to || dayIn(e.created_at, tz) <= to)
        && (!actor || e.actor_id === actor)
        && (!action || (prefix ? String(e.action).startsWith(action) : e.action === action))
        && (!entity || e.entity_type === entity) && (!entityId || e.entity_id === entityId) && (!corr || e.correlation_id === corr)
        && (!cat || (e.category ?? "business") === cat) && (!result || (e.result ?? "success") === result) && (!source || e.source === source)
        && (!search || ilike(e.action, search) || ilike(e.entity_type, search) || e.correlation_id === search || ilike(auditActionLabel(String(e.action)), search) || String(e.entity_id ?? "") === search))
        .sort((x, y) => desc(ms(x.created_at), ms(y.created_at)) || desc(String(x.id), String(y.id)));
      const rows = all.slice(off, off + lim).map((e) => ({
        id: e.id, created_at: e.created_at, action: e.action, action_label: auditActionLabel(String(e.action)), entity_type: e.entity_type ?? null, entity_label: auditEntityLabel(e.entity_type), entity_id: e.entity_id ?? null, entity_ref: entityRef(e.entity_type, e.entity_id),
        actor_id: e.actor_id ?? null, actor_name: e.actor_id != null ? staffName(e.actor_id) : e.actor_type === "guest" ? "ضيف" : e.actor_type === "user" ? "مستخدم" : "النظام",
        actor_type: e.actor_type ?? null, source: e.source ?? null, result: e.result ?? "success", category: e.category ?? "business", correlation_id: e.correlation_id ?? null,
        branch_id: e.branch_id ?? null, branch_name: e.branch_id ? byId("branches", e.branch_id)?.name_ar ?? null : null, reason: reasonOf(e.details), details: isMgmt ? e.details ?? null : null }));
      return { total: all.length, rows, limit: lim, offset: off, tz };
    },

    // ---- the ledger (decision 14, 10.4; X09a): filters, pages, and totals over the whole filtered set ----
    fn_voucher_list: ({ p }) => {
      requireMoney(); const q: Row = p ?? {}; const a = (k: string) => arg(q, k);
      const vBranch = a("branch_id") || null; if (!vBranch) throw new Error("VALIDATION: branch_id"); requireBranch(vBranch); const tz = branchTz(vBranch);
      const from = a("from") || null, to = a("to") || null; if (from && to && to < from) throw new Error("VALIDATION: period");
      const kind = a("kind") || null, method = a("method") || null, account = a("account_id") || null, status = a("status") || "approved"; const accNone = account === "none", acc = account && !accNone ? account : null;
      const staff = a("staff_id") || null, res = a("reservation_id") || null, search = a("q").trim() || null;
      if (!["approved", "cancelled", "all"].includes(status)) throw new Error("VALIDATION: status");
      const lim = clamp(intArg(q.limit, 100), 1, 1000), off = Math.max(intArg(q.offset, 0), 0);
      const x = T("financial_vouchers").filter((v) => v.branch_id === vBranch
        && (!from || dayIn(v.occurred_at, tz) >= from) && (!to || dayIn(v.occurred_at, tz) <= to)
        && (!kind || v.kind === kind) && (!method || String(v.method) === method)
        && (!account || (accNone && v.account_id == null) || v.account_id === acc)
        && (status === "all" || v.status === status)
        && (!staff || v.created_by === staff) && (!res || v.reservation_id === res)
        && (!search || ilike(v.number, search) || ilike(v.reference, search) || (v.reservation_id != null && ilike(byId("reservations", v.reservation_id)?.internal_ref, search))))
        .sort((v, w) => desc(ms(v.occurred_at), ms(w.occurred_at)) || desc(String(v.number), String(w.number)));
      const rows = x.slice(off, off + lim).map((v) => ({
        id: v.id, number: v.number, kind: v.kind, amount_halalas: v.amount_halalas, method: v.method, status: v.status, reference: v.reference ?? null, reason: v.reason ?? null, note: v.note ?? null, occurred_at: v.occurred_at,
        cancel_reason: v.cancel_reason ?? null, cancelled_at: v.cancelled_at ?? null, created_by: v.created_by ?? null, creator_name: staffName(v.created_by),
        account_id: v.account_id ?? null, account_name: v.account_id ? byId("cash_accounts", v.account_id)?.name ?? null : null, payout_id: v.payout_id ?? null,
        original_voucher_id: v.original_voucher_id ?? null, original_number: v.original_voucher_id ? byId("financial_vouchers", v.original_voucher_id)?.number ?? null : null,
        reservation: v.reservation_id != null ? { id: v.reservation_id, internal_ref: byId("reservations", v.reservation_id)?.internal_ref ?? null } : null }));
      const ok = x.filter((v) => v.status === "approved"); const sum = (kinds: string[]) => ok.filter((v) => kinds.includes(v.kind)).reduce((s, v) => s + Number(v.amount_halalas), 0);
      const byMethod = new Map<string, number>(); for (const v of ok) if (v.kind === "receipt") byMethod.set(String(v.method), (byMethod.get(String(v.method)) ?? 0) + Number(v.amount_halalas));
      const byAccount = new Map<string, { account_id: string; account_name: string | null; in_halalas: number; out_halalas: number }>();
      for (const v of ok) { if (v.account_id == null) continue; const row = byAccount.get(v.account_id) ?? { account_id: v.account_id, account_name: byId("cash_accounts", v.account_id)?.name ?? null, in_halalas: 0, out_halalas: 0 }; if (v.kind === "receipt" || v.kind === "deposit") row.in_halalas += Number(v.amount_halalas); if (v.kind === "refund" || v.kind === "deposit_refund") row.out_halalas += Number(v.amount_halalas); byAccount.set(v.account_id, row); }
      const totals = { receipts: sum(["receipt"]), refunds: sum(["refund"]), deposits: sum(["deposit"]), deposit_refunds: sum(["deposit_refund"]), deposit_applied: sum(["deposit_apply"]), approved: ok.length, cancelled: x.filter((v) => v.status === "cancelled").length,
        by_method: [...byMethod].map(([m, amount_halalas]) => ({ method: m, amount_halalas })).sort((v, w) => w.amount_halalas - v.amount_halalas), by_account: [...byAccount.values()].sort((v, w) => w.in_halalas - v.in_halalas) };
      return { total: x.length, rows, totals, limit: lim, offset: off, tz };
    },

    // ---- saved views (decision 14): a person's own filters and columns for a list, own rows only ----
    fn_saved_views_list: ({ p_screen }) => { const mine = staffId(); if (!mine) return []; return T("staff_saved_views").filter((v) => v.staff_id === mine && v.screen === p_screen && !v.archived_at).sort((x, y) => Number(!!y.is_default) - Number(!!x.is_default) || text(x.name, y.name)).map((v) => ({ id: v.id, name: v.name, filters: v.filters, columns: v.columns ?? null, is_default: !!v.is_default, updated_at: v.updated_at })); },
    fn_saved_view_save: ({ p }) => {
      const mine = staffId(); if (!mine) throw new Error("FORBIDDEN"); const q: Row = p ?? {}; const name = String(q.name ?? "").trim(); const screen = q.screen;
      if (!name || name.length > 60) throw new Error("VALIDATION: name"); if (!SCREENS.includes(String(screen))) throw new Error("VALIDATION: screen");
      let v: Row;
      if (q.id != null) {
        const cur = T("staff_saved_views").find((x) => x.id === q.id && x.staff_id === mine && !x.archived_at); if (!cur) throw new Error("NOT_FOUND: view");
        Object.assign(cur, { name, filters: q.filters !== undefined ? q.filters : cur.filters, columns: q.columns !== undefined ? q.columns : cur.columns, is_default: q.is_default == null ? cur.is_default : boolArg(q.is_default), updated_at: nowISO() }); v = cur;
      } else {
        if (T("staff_saved_views").filter((x) => x.staff_id === mine && x.screen === screen && !x.archived_at).length >= 20) throw new Error("LIMIT: saved_views");
        v = { id: uid(), organization_id: ORG, staff_id: mine, screen, name, filters: q.filters ?? {}, columns: q.columns ?? null, is_default: q.is_default == null ? false : boolArg(q.is_default), archived_at: null, created_at: nowISO(), updated_at: nowISO() }; T("staff_saved_views").push(v);
      }
      if (v.is_default) for (const o of T("staff_saved_views")) if (o.staff_id === mine && o.screen === v.screen && o.id !== v.id && o.is_default) o.is_default = false;
      emit("staff_saved_views"); return { ok: true, id: v.id };
    },
    fn_saved_view_remove: ({ p_id }) => { const v = T("staff_saved_views").find((x) => x.id === p_id && x.staff_id === staffId() && !x.archived_at); if (!v) throw new Error("NOT_FOUND: view"); Object.assign(v, { archived_at: nowISO(), is_default: false, updated_at: nowISO() }); emit("staff_saved_views"); return { ok: true }; },

    // ---- the filter options a report screen offers (decision 36) and the live members of a branch ----
    fn_report_filter_options: ({ p_branch }) => {
      if (!p_branch || !myBranches().includes(p_branch)) return {};
      const staff = orgStaff().filter((s) => s.role === "owner" || T("branch_memberships").some((m) => m.staff_id === s.id && m.branch_id === p_branch) || T("financial_vouchers").some((v) => v.branch_id === p_branch && v.created_by === s.id) || T("reservations").some((r) => r.branch_id === p_branch && r.created_by === s.id))
        .sort((x, y) => Number(!!y.is_active) - Number(!!x.is_active) || text(x.full_name, y.full_name)).map((s) => ({ id: s.id, name: s.full_name, role: s.role, is_active: !!s.is_active }));
      const accounts = T("cash_accounts").filter((x) => x.branch_id === p_branch).sort((x, y) => text(x.kind, y.kind) || text(x.name, y.name)).map((x) => ({ id: x.id, name: x.name, kind: x.kind, is_active: !!x.is_active }));
      const sources = T("booking_sources").filter((b) => b.organization_id === ORG && !b.archived_at).sort((x, y) => text(x.name, y.name)).map((b) => ({ id: b.id, name: b.name, kind: b.kind, is_active: !!b.is_active }));
      const categories = T("room_categories").filter((x) => x.branch_id === p_branch && !x.archived_at).sort((x, y) => cmp(x.sort_order ?? 0, y.sort_order ?? 0) || text(x.name_ar, y.name_ar)).map((x) => ({ id: x.id, name: x.name_ar }));
      const floors = T("floors").filter((x) => x.branch_id === p_branch && !x.archived_at).sort((x, y) => cmp(x.sort_order ?? 0, y.sort_order ?? 0) || text(x.name, y.name)).map((x) => ({ id: x.id, name: x.name, block: byId("blocks", x.block_id)?.name ?? null }));
      return { staff, accounts, sources, categories, floors };
    },
    fn_branch_staff: ({ p_branch }) => { if (!p_branch || !myBranches().includes(p_branch)) return []; return T("staff_profiles").filter((s) => s.is_active && isMember(s.id, p_branch)).map((s) => ({ id: s.id, full_name: s.full_name, role: s.role })).sort((x, y) => text(x.full_name, y.full_name)); },

    // ---- staff: the list, the editor, activation and «تسجيل خروج إجباري» (decisions 34, 35) ----
    fn_admin_staff_list: () => {
      if (!(can("staff.manage") || can("staff.force_logout"))) return []; const owner = can("staff.manage"); const mine = staffId();
      return orgStaff().sort((x, y) => Number(!!y.is_active) - Number(!!x.is_active) || text(x.full_name, y.full_name)).map((s) => ({
        id: s.id, full_name: s.full_name, email: s.email, phone: owner ? s.phone ?? null : null, role: s.role, is_active: !!s.is_active, linked: s.auth_user_id != null, created_at: s.created_at,
        sessions_ended_at: s.sessions_ended_at ?? null, updated_at: s.updated_at ?? null, branch_ids: liveBranches(s.id), is_me: s.id === mine }));
    },
    // «تعديل موظف»: the owner, with a reason; name, phone, role and branches. Never the email, never oneself's role or
    // branches, never the last owner's role. One audit row with before and after (the phone masked).
    fn_admin_update_staff: ({ p }) => {
      requireCap("staff.manage"); const q: Row = p ?? {}; const mine = staffId(); const reason = requireReason(q.reason); const has = (k: string) => q[k] !== undefined;
      const sp = orgStaffRow(q.staff_id);
      // decision 44 (0043): no one but the owner edits an owner or makes someone an owner
      if ((sp.role === "owner" || (q.role == null ? "" : String(q.role)) === "owner") && !hasRole("owner")) throw new Error("FORBIDDEN: only the owner changes an owner");
      if (has("email") && (q.email == null ? null : String(q.email).trim().toLowerCase()) !== (sp.email ?? null)) throw new Error("EMAIL_NOT_EDITABLE");
      const vName: string | null = has("full_name") ? String(q.full_name ?? "").trim() || null : sp.full_name; if (!vName) throw new Error("VALIDATION: full_name");
      const vPhone: string | null = has("phone") ? String(q.phone ?? "").replace(/[^0-9+]/g, "") || null : sp.phone ?? null;
      const vRole: string = has("role") ? String(q.role) : sp.role; if (!STAFF_ROLES.includes(vRole)) throw new Error("INVALID_ROLE");
      const beforeB = liveBranches(sp.id);
      const vBranches: string[] = has("branch_ids") ? [...new Set<string>((Array.isArray(q.branch_ids) ? q.branch_ids : []).map(String))] : beforeB;
      if (sp.id === mine && (vRole !== sp.role || !sameSet(vBranches, beforeB))) throw new Error("SELF_ROLE_OR_BRANCHES");
      if (sp.role === "owner" && vRole !== "owner" && !orgStaff().some((s) => s.role === "owner" && s.is_active && s.id !== sp.id)) throw new Error("LAST_OWNER: cannot remove or demote the last active owner");
      for (const b of vBranches) requireBranch(b);
      const changed: string[] = [];
      if (vName !== sp.full_name) changed.push("full_name"); if (vPhone !== (sp.phone ?? null)) changed.push("phone"); if (vRole !== sp.role) changed.push("role"); if (!sameSet(vBranches, beforeB)) changed.push("branches");
      if (!changed.length) return { ok: true, unchanged: true };
      const before = { full_name: sp.full_name, phone: maskPhone(sp.phone), role: sp.role, branch_ids: beforeB };
      Object.assign(sp, { full_name: vName, phone: vPhone, role: vRole, updated_at: nowISO() });
      // memberships: retire what is gone, re-open or add what is new (effective from the person's next operation)
      for (const m of T("branch_memberships")) if (m.staff_id === sp.id && !m.removed_at && !vBranches.includes(m.branch_id)) { m.removed_at = nowISO(); m.removed_by = mine; }
      for (const b of vBranches) { const m = T("branch_memberships").find((x) => x.staff_id === sp.id && x.branch_id === b); if (m) { m.removed_at = null; m.removed_by = null; } else T("branch_memberships").push({ id: uid(), staff_id: sp.id, branch_id: b, created_at: nowISO(), removed_at: null, removed_by: null }); }
      const after = { full_name: vName, phone: maskPhone(vPhone), role: vRole, branch_ids: liveBranches(sp.id) };
      emit("staff_profiles"); emit("branch_memberships");
      audit(null, changed.includes("role") ? "staff.role_changed" : "staff.updated", "staff_profile", sp.id, { changed, before, after, reason });
      return { ok: true, changed };
    },
    // activation (owner): a reason, never oneself; deactivation ends every session (decision 34)
    fn_admin_set_staff_active: ({ p_staff, p_active, p_reason }) => {
      requireCap("staff.manage"); const reason = requireReason(p_reason); const sp = orgStaffRow(p_staff); if (sp.id === staffId()) throw new Error("SELF_NOT_ALLOWED");
      if (sp.role === "owner" && !hasRole("owner")) throw new Error("FORBIDDEN: only the owner changes an owner");   // decision 44 (0043)
      const active = p_active == null ? !!sp.is_active : !!p_active; if (!!sp.is_active === active) return { ok: true, unchanged: true };
      const before = { role: sp.role, is_active: !!sp.is_active };
      Object.assign(sp, { is_active: active, updated_at: nowISO(), sessions_ended_at: active ? sp.sessions_ended_at ?? null : nowISO() });
      const n = !active && sp.auth_user_id ? 1 : 0;
      emit("staff_profiles"); audit(null, active ? "staff.activated" : "staff.deactivated", "staff_profile", sp.id, { before, after: { role: sp.role, is_active: active }, reason });
      return { ok: true, is_active: active, sessions_ended: n };
    },
    // «تسجيل خروج إجباري» (decision 34): owner or manager, with a reason; the manager never signs out an owner or another
    // manager; never oneself. Every session ends now (the token in hand is refused on its next request); the account stays active.
    fn_admin_force_logout: ({ p_staff, p_reason }) => {
      requireCap("staff.force_logout"); const reason = requireReason(p_reason); const m = me()!; const sp = orgStaffRow(p_staff);
      if (sp.id === m.id) throw new Error("SELF_NOT_ALLOWED");
      if (!capFull("staff.force_logout") && ["owner", "manager"].includes(sp.role)) throw new Error("FORBIDDEN: a manager signs out neither an owner nor a manager");
      const n = sp.auth_user_id ? 1 : 0; sp.sessions_ended_at = nowISO(); emit("staff_profiles");
      audit(null, "staff.signed_out", "staff_profile", sp.id, { reason, sessions_ended: n, role: sp.role, linked: sp.auth_user_id != null });
      return { ok: true, sessions_ended: n };
    },

    // ---- «استعمال القدرات» (decision 55; control G26, test D04): from the audit log alone ----
    fn_reports_capability_usage: ({ p }) => {
      requireCap("reports.identities_usage"); const q: Row = p ?? {}; const weeks = clamp(intArg(q.weeks, 4), 1, 26); const now = Date.now(); const winStart = now - weeks * 7 * 86400000; const weekStart = now - 7 * 86400000;
      const yearBefore = new Date(winStart); yearBefore.setUTCFullYear(yearBefore.getUTCFullYear() - 1);
      const org = T("audit_events").filter((e) => e.organization_id === ORG);
      const horizon = org.reduce<number | null>((h, e) => { const t = ms(e.created_at); return h == null || t < h ? t : h; }, null);
      const purgeInWindow = org.some((e) => e.action === "data_purge_executed" && ms(e.created_at) >= winStart && (Array.isArray(e.details?.categories) ? e.details.categories.includes("audit") : !!e.details?.categories && typeof e.details.categories === "object" && "audit" in e.details.categories));
      const ev = org.filter((e) => ms(e.created_at) >= yearBefore.getTime()).map((e) => ({ action: String(e.action), at: ms(e.created_at), result: String(e.result ?? "success"),
        who: e.actor_type === "system" || ["system", "scheduler"].includes(String(e.source)) ? "automation" : e.source === "ops_assistant" ? "assistant" : e.actor_type === "guest" ? "guest" : "human" }));
      const catalogued = new Set(CAPABILITY_CATALOG.flatMap((r) => [...r.actions]));
      const rows = CAPABILITY_CATALOG.map((r) => {
        const ok = ev.filter((e) => r.actions.includes(e.action) && e.result === "success"); const win = ok.filter((e) => e.at >= winStart);
        const windowCount = win.length; const last = ok.reduce<number | null>((m, e) => (m == null || e.at > m ? e.at : m), null);
        return { code: r.code, label: r.label, area: r.area, core: r.core, coverage: r.coverage,
          last_success_at: last == null ? null : new Date(last).toISOString(), week_count: ok.filter((e) => e.at >= weekStart).length, window_count: windowCount,
          by: { human: win.filter((e) => e.who === "human").length, assistant: win.filter((e) => e.who === "assistant").length, automation: win.filter((e) => e.who === "automation").length, guest: win.filter((e) => e.who === "guest").length },
          rejected: ev.filter((e) => r.actions.includes(e.action) && e.result === "rejected" && e.at >= winStart).length,
          status: r.coverage === "none" ? "unmeasured" : windowCount > 0 ? "used" : r.coverage === "partial" || horizon == null || horizon > winStart || purgeInWindow ? "undetermined" : "idle" };
      }).sort((x, y) => text(x.area, y.area) || Number(y.core) - Number(x.core) || text(x.label, y.label));
      const other = new Map<string, { action: string; label: string; window_count: number; last_at: number }>();
      for (const e of ev) { if (e.at < winStart || e.result !== "success" || catalogued.has(e.action)) continue; const o = other.get(e.action) ?? { action: e.action, label: auditActionLabel(e.action), window_count: 0, last_at: 0 }; o.window_count++; o.last_at = Math.max(o.last_at, e.at); other.set(e.action, o); }
      return { weeks, window_start: new Date(winStart).toISOString(), generated_at: new Date(now).toISOString(), log_since: horizon == null ? null : new Date(horizon).toISOString(),
        log_covers_window: horizon != null && horizon <= winStart && !purgeInWindow, rows,
        other_actions: [...other.values()].sort((x, y) => y.window_count - x.window_count).map((o) => ({ ...o, last_at: new Date(o.last_at).toISOString() })), note: USAGE_NOTE };
    },
  };
}
