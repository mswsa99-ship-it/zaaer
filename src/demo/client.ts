/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * In-browser demo backend. Implements the slice of the Supabase client the UI uses
 * (query builder with embeds, RPCs, auth, realtime, edge functions) over an in-memory
 * store persisted to localStorage. The RPCs mirror the SQL functions' rules (branch scope,
 * roles, ledger-derived money, allocation overlap, idempotency) so the walkthrough behaves
 * like the real system. Nothing here talks to a server.
 */
import { seed, uid, todayISO, addDays, nowISO, ORG, STAFF, type Row, type Store } from "./data";
import { scriptedReply } from "../../supabase/functions/_shared/guardrails";
import { buildBriefing, fallbackOpsReply } from "../../supabase/functions/_shared/ops";
import { seedKnowledge, knowledgeRpcs } from "./knowledge";

const KEY = "zaaer_demo_store_v4";
/** seed() + the modules that add their own tables (keeps data.ts free of import cycles) */
function fullSeed(): Store { const s = seed(); s.knowledge_entries ??= []; s.unanswered_questions ??= []; seedKnowledge((t) => (s[t] ??= []), STAFF.supervisor.id); return s; }
const SESSION_KEY = "zaaer_demo_session";

// ---------------------------------------------------------------------------
// store
// ---------------------------------------------------------------------------
let S: Store = load();
function load(): Store {
  try { const raw = localStorage.getItem(KEY); if (raw) { const parsed = JSON.parse(raw); if (parsed && parsed.__today === todayISO()) { delete parsed.__today; return parsed; } } } catch { /* ignore */ }
  return fullSeed();
}
let saveTimer: number | null = null;
function persist() {
  if (saveTimer) return;
  saveTimer = window.setTimeout(() => { saveTimer = null; try { localStorage.setItem(KEY, JSON.stringify({ ...S, __today: todayISO() })); } catch { /* ignore */ } }, 150);
}
export function resetDemo() { try { localStorage.removeItem(KEY); } catch { /* ignore */ } S = fullSeed(); emitAll(); persist(); }
const T = (t: string): Row[] => { if (!S[t]) S[t] = []; return S[t]; };
const byId = (t: string, id: string | null | undefined) => (id ? T(t).find((r) => r.id === id) : undefined);

// ---------------------------------------------------------------------------
// realtime (in-memory)
// ---------------------------------------------------------------------------
type Listener = { table: string; cb: () => void };
const listeners = new Set<Listener>();
let emitTimer: number | null = null; const dirty = new Set<string>();
function emit(table: string) {
  dirty.add(table); persist();
  if (emitTimer) return;
  emitTimer = window.setTimeout(() => { emitTimer = null; const tables = [...dirty]; dirty.clear(); for (const l of listeners) if (tables.includes(l.table)) { try { l.cb(); } catch { /* ignore */ } } }, 60);
}
function emitAll() { for (const t of Object.keys(S)) dirty.add(t); emit("rooms"); }

// ---------------------------------------------------------------------------
// auth
// ---------------------------------------------------------------------------
type Session = { user: { id: string; email: string }; access_token: string } | null;
let session: Session = (() => { try { return JSON.parse(sessionStorage.getItem(SESSION_KEY) ?? "null"); } catch { return null; } })();
const authListeners = new Set<(e: string, s: Session) => void>();
function setSession(s: Session) { session = s; try { if (s) sessionStorage.setItem(SESSION_KEY, JSON.stringify(s)); else sessionStorage.removeItem(SESSION_KEY); } catch { /* ignore */ } for (const l of authListeners) l(s ? "SIGNED_IN" : "SIGNED_OUT", s); }
const DEMO_ACCOUNTS = Object.values(STAFF);

// ---------------------------------------------------------------------------
// current staff context (mirrors fn_staff_id / fn_user_branch_ids / fn_require_*)
// ---------------------------------------------------------------------------
function me(): Row | null { if (!session) return null; return T("staff_profiles").find((s) => s.auth_user_id === session!.user.id && s.is_active) ?? null; }
function myBranches(): string[] { const m = me(); if (!m) return []; if (m.role === "owner") return T("branches").filter((b) => b.organization_id === m.organization_id).map((b) => b.id); return T("branch_memberships").filter((x) => x.staff_id === m.id).map((x) => x.branch_id); }
function hasRole(...roles: string[]) { const m = me(); return !!m && roles.includes(m.role); }
function requireRole(...roles: string[]) { if (!hasRole(...roles)) throw new Error(`FORBIDDEN: requires one of {${roles.join(",")}}`); }
function requireBranch(b: string | null | undefined) { if (!b || !myBranches().includes(b)) throw new Error("FORBIDDEN: branch not permitted"); }
function staffId() { return me()?.id ?? null; }
function branchToday(_b?: string) { return todayISO(); }
function audit(branch: string | null, action: string, entity: string, entityId: string, details: Row) {
  T("audit_events").unshift({ id: uid(), organization_id: ORG, branch_id: branch, actor_id: staffId(), action, entity_type: entity, entity_id: entityId, details, created_at: nowISO() });
  emit("audit_events");
}
// 0009 (A06): updates of definitions, stays, prices and task completion must carry the version the user saw
const checkVersion = (cur: number, exp?: number | null) => { if (exp == null) throw new Error("VERSION_REQUIRED: expected version must be supplied"); if (cur !== exp) throw new Error("VERSION_CONFLICT: record changed by another user"); };
const checkVersionLenient = (cur: number, exp?: number | null) => { if (exp != null && cur !== exp) throw new Error("VERSION_CONFLICT: record changed by another user"); };
const nonEmpty = (v: unknown, code: string) => { if (!v || !String(v).trim()) throw new Error(`VALIDATION: ${code}`); };

// ---------------------------------------------------------------------------
// query builder
// ---------------------------------------------------------------------------
const FK: Record<string, Record<string, string>> = {
  rooms: { room_categories: "category_id", blocks: "block_id", floors: "floor_id", branches: "branch_id" },
  reservations: { booking_sources: "source_id", rooms: "room_id", room_categories: "room_category_id", branches: "branch_id" },
  housekeeping_tasks: { rooms: "room_id", facilities: "facility_id", staff_profiles: "assignee_id", task_types: "task_type_id" },
  keyboxes: { rooms: "room_id" }, financial_vouchers: { reservations: "reservation_id", staff_profiles: "created_by" },
  maintenance_tickets: { rooms: "room_id" }, release_rules: { room_categories: "category_id" }, inventory_periods: { room_categories: "category_id" },
  facilities: { blocks: "block_id", floors: "floor_id" }, floors: { blocks: "block_id" }, reservation_allocations: { rooms: "room_id", reservations: "reservation_id" },
  conversation_messages: { conversations: "conversation_id" }, human_handoff_tickets: { reservations: "reservation_id" },
};
const FK_HINT: Record<string, string> = { housekeeping_tasks_assignee_id_fkey: "assignee_id", financial_vouchers_created_by_fkey: "created_by", reservations_room_id_fkey: "room_id" };

interface Embed { alias: string; table: string; cols: string; hint?: string }
function parseSelect(sel: string): { cols: string[]; embeds: Embed[] } {
  const cols: string[] = []; const embeds: Embed[] = []; let depth = 0; let cur = "";
  const flush = () => { const t = cur.trim(); cur = ""; if (!t) return; const m = t.match(/^(?:([\w]+):)?([\w]+)(?:!([\w]+))?\((.*)\)$/s); if (m) embeds.push({ alias: m[1] ?? m[2], table: m[2], hint: m[3], cols: m[4] }); else cols.push(t); };
  for (const ch of sel) { if (ch === "(") depth++; if (ch === ")") depth--; if (ch === "," && depth === 0) { flush(); continue; } cur += ch; }
  flush();
  return { cols, embeds };
}
function project(table: string, row: Row, sel: string): Row {
  const { cols, embeds } = parseSelect(sel);
  const out: Row = {};
  if (cols.includes("*") || cols.length === 0) Object.assign(out, row); else for (const c of cols) out[c] = row[c];
  for (const e of embeds) {
    const col = (e.hint && FK_HINT[e.hint]) || FK[table]?.[e.table];
    if (!col) { out[e.alias] = null; continue; }
    const target = byId(e.table, row[col]);
    out[e.alias] = target ? project(e.table, target, e.cols) : null;
  }
  return out;
}
type Filter = (r: Row) => boolean;
const MONEY_ROLES = ["owner", "manager", "supervisor", "finance"];
const BRANCH_TABLES = new Set(["rooms", "reservations", "housekeeping_tasks", "facilities", "blocks", "floors", "task_types", "service_definitions", "room_categories", "maintenance_tickets", "property_policies", "inventory_periods", "release_rules", "released_slots", "keyboxes", "financial_vouchers", "reservation_charges", "invoices", "reservation_allocations", "human_handoff_tickets", "notifications"]);
/** Mirrors the row-level security of the real schema closely enough for the walkthrough. */
function visible(table: string, r: Row): boolean {
  const m = me(); const branches = myBranches();
  if (table === "branches") return !m || branches.includes(r.id);
  if (table === "property_policies" && !m) return !!r.is_public;
  if (table === "booking_sources" || table === "organizations" || table === "system_settings") return true;
  if (!m) return false;
  if (["financial_vouchers", "reservation_charges", "invoices", "reservation_guests"].includes(table) && !MONEY_ROLES.includes(m.role)) return false;
  if (["keyboxes", "code_rotation_events", "audit_events", "access_delivery_events"].includes(table) && !["owner", "manager", "supervisor"].includes(m.role)) return false;
  if (["ai_settings", "ai_usage_daily", "ai_tool_executions", "ai_guardrail_events", "integration_events"].includes(table) && !["owner", "manager"].includes(m.role)) return false;
  if (table === "knowledge_entries" || table === "unanswered_questions") return r.organization_id === m.organization_id && (r.branch_id == null || branches.includes(r.branch_id));
  if (table === "reservation_guests") { const res = byId("reservations", r.reservation_id); return !!res && branches.includes(res.branch_id); }
  if (table === "conversations") return r.branch_id == null || branches.includes(r.branch_id);
  if (table === "conversation_messages") { const c = byId("conversations", r.conversation_id); return !!c && (c.branch_id == null || branches.includes(c.branch_id)); }
  if (["ai_ops_conversations", "ai_action_proposals"].includes(table)) return r.staff_id === m.id;
  if (table === "ai_ops_messages") return byId("ai_ops_conversations", r.conversation_id)?.staff_id === m.id;
  if (BRANCH_TABLES.has(table)) return r.branch_id == null || branches.includes(r.branch_id);
  return true;
}
class QB implements PromiseLike<any> {
  private filters: Filter[] = []; private mode: "select" | "insert" | "update" | "delete" | "upsert" = "select"; private sel = "*"; private payload: any = null;
  private orders: Array<{ col: string; asc: boolean; nullsFirst?: boolean }> = []; private lim: number | null = null; private off = 0; private countMode = false; private head = false; private one: "maybe" | "one" | null = null;
  constructor(private table: string) {}
  select(sel = "*", opts?: { count?: string; head?: boolean }) { if (this.mode === "select") this.sel = sel; else this.sel = sel; this.countMode = !!opts?.count; this.head = !!opts?.head; return this; }
  insert(p: any) { this.mode = "insert"; this.payload = p; return this; }
  upsert(p: any) { this.mode = "upsert"; this.payload = p; return this; }
  update(p: any) { this.mode = "update"; this.payload = p; return this; }
  delete() { this.mode = "delete"; return this; }
  eq(c: string, v: any) { this.filters.push((r) => r[c] === v || (v != null && String(r[c]) === String(v))); return this; }
  neq(c: string, v: any) { this.filters.push((r) => r[c] !== v); return this; }
  in(c: string, vs: any[]) { this.filters.push((r) => vs.includes(r[c])); return this; }
  is(c: string, v: any) { this.filters.push((r) => (v === null ? r[c] == null : r[c] === v)); return this; }
  not(c: string, op: string, v: any) { this.filters.push((r) => !(op === "is" ? (v === null ? r[c] == null : r[c] === v) : r[c] === v)); return this; }
  gte(c: string, v: any) { this.filters.push((r) => r[c] != null && r[c] >= v); return this; }
  lte(c: string, v: any) { this.filters.push((r) => r[c] != null && r[c] <= v); return this; }
  gt(c: string, v: any) { this.filters.push((r) => r[c] != null && r[c] > v); return this; }
  lt(c: string, v: any) { this.filters.push((r) => r[c] != null && r[c] < v); return this; }
  like(c: string, v: string) { const re = new RegExp("^" + v.replace(/%/g, ".*") + "$"); this.filters.push((r) => re.test(String(r[c] ?? ""))); return this; }
  ilike(c: string, v: string) { const re = new RegExp("^" + v.replace(/%/g, ".*") + "$", "i"); this.filters.push((r) => re.test(String(r[c] ?? ""))); return this; }
  or(expr: string) {
    const parts = expr.split(",").map((p) => { const [col, op, ...rest] = p.split("."); const val = rest.join("."); return { col, op, val }; });
    this.filters.push((r) => parts.some(({ col, op, val }) => (op === "is" ? (val === "null" ? r[col] == null : r[col] === (val === "true")) : op === "eq" ? String(r[col]) === val : false)));
    return this;
  }
  order(c: string, o?: { ascending?: boolean; nullsFirst?: boolean }) { this.orders.push({ col: c, asc: o?.ascending !== false, nullsFirst: o?.nullsFirst }); return this; }
  limit(n: number) { this.lim = n; return this; }
  range(a: number, b: number) { this.off = a; this.lim = b - a + 1; return this; }
  maybeSingle() { this.one = "maybe"; return this; }
  single() { this.one = "one"; return this; }
  private run(): { data: any; error: any; count: number | null } {
    try {
      const rows = T(this.table);
      const match = (r: Row) => this.filters.every((f) => f(r));
      if (this.mode === "insert" || this.mode === "upsert") {
        const list: Row[] = (Array.isArray(this.payload) ? this.payload : [this.payload]).map((p: Row) => ({ id: uid(), created_at: nowISO(), ...p }));
        for (const p of list) { const i = this.mode === "upsert" ? rows.findIndex((r) => r.id === p.id || (this.table === "ai_usage_daily" && r.organization_id === p.organization_id && r.day === p.day)) : -1; if (i >= 0) rows[i] = { ...rows[i], ...p }; else rows.push(p); }
        emit(this.table);
        const data = list.map((r: Row) => project(this.table, r, this.sel));
        return { data: this.one ? data[0] : data, error: null, count: null };
      }
      if (this.mode === "update") { const hit = rows.filter(match); for (const r of hit) Object.assign(r, this.payload); emit(this.table); return { data: hit.map((r) => project(this.table, r, this.sel)), error: null, count: null }; }
      if (this.mode === "delete") { const keep = rows.filter((r) => !match(r)); S[this.table] = keep; emit(this.table); return { data: [], error: null, count: null }; }
      let out = rows.filter(match).filter((r) => visible(this.table, r));   // RLS emulation (read side)
      for (const o of [...this.orders].reverse()) out = [...out].sort((a, b) => { const x = a[o.col], y = b[o.col]; if (x == null && y == null) return 0; if (x == null) return o.nullsFirst ? -1 : 1; if (y == null) return o.nullsFirst ? 1 : -1; return (x < y ? -1 : x > y ? 1 : 0) * (o.asc ? 1 : -1); });
      const count = out.length;
      if (this.off) out = out.slice(this.off);
      if (this.lim != null) out = out.slice(0, this.lim);
      if (this.head) return { data: null, error: null, count };
      const data = out.map((r) => project(this.table, r, this.sel));
      if (this.one === "maybe") return { data: data[0] ?? null, error: null, count };
      if (this.one === "one") return data.length === 1 ? { data: data[0], error: null, count } : { data: null, error: { message: "PGRST116: expected one row" }, count };
      return { data, error: null, count: this.countMode ? count : null };
    } catch (e) { return { data: null, error: { message: (e as Error).message }, count: null }; }
  }
  then<R1 = any, R2 = never>(onf?: ((v: any) => R1 | PromiseLike<R1>) | null, onr?: ((e: any) => R2 | PromiseLike<R2>) | null): Promise<R1 | R2> { return Promise.resolve(this.run()).then(onf ?? undefined, onr ?? undefined); }
}

// ---------------------------------------------------------------------------
// money
// ---------------------------------------------------------------------------
function financeOf(resId: string) {
  const c = T("reservation_charges").filter((x) => x.reservation_id === resId);
  const v = T("financial_vouchers").filter((x) => x.reservation_id === resId && x.status === "approved");
  const sum = (arr: Row[], f: (r: Row) => boolean) => arr.filter(f).reduce((a, r) => a + Number(r.total_halalas ?? r.amount_halalas), 0);
  const rent = sum(c, (x) => x.kind === "rent"), addons = sum(c, (x) => x.kind === "addon"), discounts = sum(c, (x) => x.kind === "discount"), penalties = sum(c, (x) => x.kind === "penalty"), adjustments = sum(c, (x) => x.kind === "adjustment"), tax = sum(c, (x) => x.kind === "tax");
  const total = rent + addons + discounts + penalties + adjustments + tax;
  const received = sum(v, (x) => x.kind === "receipt"), refunded = sum(v, (x) => x.kind === "refund"), deposit_received = sum(v, (x) => x.kind === "deposit"), deposit_refunded = sum(v, (x) => x.kind === "deposit_refund"), deposit_applied = sum(v, (x) => x.kind === "deposit_apply");
  const net = received - refunded + deposit_applied;
  return { rent, addons, discounts, penalties, adjustments, tax, total, received, refunded, deposit_applied, net_collected: net, balance_due: Math.max(total - net, 0), credit: Math.max(net - total, 0), deposit_received, deposit_refunded, deposit_balance: deposit_received - deposit_refunded - deposit_applied, payment_status: net === 0 ? "pending" : net < total ? "partially_paid" : "paid" };
}
function recompute(resId: string) {
  const r = byId("reservations", resId); if (!r) return null; const f = financeOf(resId);
  Object.assign(r, { total_halalas: f.total, rent_amount_halalas: f.rent, discount_halalas: -f.discounts, addons_halalas: f.addons + f.penalties + f.adjustments, taxes_halalas: f.tax, paid_halalas: f.net_collected, refunded_halalas: f.refunded, balance_due_halalas: f.balance_due, deposit_balance_halalas: f.deposit_balance, payment_status: f.payment_status, updated_at: nowISO() });
  emit("reservations"); return f;
}
function applyTax(branchId: string, amount: number, taxable: boolean) { const b = byId("branches", branchId)!; if (!taxable || !b.tax_rate_bp) return { net: amount, tax: 0 }; if (b.prices_include_tax) { const tax = amount - Math.round((amount * 10000) / (10000 + b.tax_rate_bp)); return { net: amount - tax, tax }; } return { net: amount, tax: Math.round((amount * b.tax_rate_bp) / 10000) }; }
function addCharge(resId: string, kind: string, description: string, qty: number, unit: number, taxable: boolean, reason: string | null, serviceId: string | null = null) {
  const r = byId("reservations", resId)!; let gross = Math.round(qty * unit); if (kind === "discount") gross = -Math.abs(gross);
  const { net, tax } = applyTax(r.branch_id, gross, taxable);
  const id = uid();
  T("reservation_charges").push({ id, organization_id: ORG, branch_id: r.branch_id, reservation_id: resId, kind, description, quantity: qty, unit_price_halalas: unit, total_halalas: net, taxable, service_definition_id: serviceId, invoice_id: null, reason, created_by: staffId(), created_at: nowISO() });
  if (tax) T("reservation_charges").push({ id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: resId, kind: "tax", description: "ضريبة القيمة المضافة — " + description, quantity: 1, unit_price_halalas: tax, total_halalas: tax, taxable: false, service_definition_id: null, invoice_id: null, reason, created_by: staffId(), created_at: nowISO() });
  emit("reservation_charges"); return id;
}
let docSeq = 500;
const nextNumber = (prefix: string) => `${prefix}-2026-${String(++docSeq).padStart(6, "0")}`;

// ---------------------------------------------------------------------------
// rooms / allocations
// ---------------------------------------------------------------------------
function overlaps(a1: string, a2: string, b1: string, b2: string) { return a1 < b2 && b1 < a2; }
function roomAvailable(roomId: string, from: string, to: string, exclude?: string | null) {
  const room = byId("rooms", roomId); if (!room || !myBranches().includes(room.branch_id)) return false;
  return !T("reservation_allocations").some((a) => a.room_id === roomId && a.status === "active" && overlaps(a.from_date, a.to_date, from, to) && (!exclude || a.reservation_id !== exclude));
}
function recomputeRoomReady(roomId: string): string {
  const rm = byId("rooms", roomId)!;
  if (!rm.is_active || rm.archived_at) { rm.status = "out_of_service"; emit("rooms"); return rm.status; }
  if (["occupied", "reserved", "blocked"].includes(rm.status)) return rm.status;
  const maint = T("maintenance_tickets").some((m) => m.room_id === roomId && m.status !== "resolved");
  const kb = T("keyboxes").find((k) => k.room_id === roomId);
  rm.status = maint ? "maintenance" : rm.cleanliness !== "clean" ? "cleaning" : !kb || kb.code_status !== "active" || !kb.field_tested ? "cleaning" : "ready";
  emit("rooms"); return rm.status;
}
function allocate(resId: string, roomId: string, from: string, to: string, reason: string) {
  const r = byId("reservations", resId)!; const rm = byId("rooms", roomId);
  if (!rm || rm.branch_id !== r.branch_id) throw new Error("ROOM_NOT_FOUND");
  if (!rm.is_active || rm.archived_at || ["blocked", "out_of_service", "maintenance"].includes(rm.status)) throw new Error("ROOM_NOT_AVAILABLE");
  if (r.room_category_id && rm.category_id !== r.room_category_id) throw new Error("ROOM_CATEGORY_MISMATCH");
  if (T("reservation_allocations").some((a) => a.room_id === roomId && a.status === "active" && overlaps(a.from_date, a.to_date, from, to))) throw new Error(`ALLOCATION_CONFLICT: room ${rm.room_number} is allocated during part of ${from}–${to}`);
  const id = uid();
  T("reservation_allocations").push({ id, reservation_id: resId, room_id: roomId, branch_id: r.branch_id, from_date: from, to_date: to, status: "active", reason, created_by: staffId(), created_at: nowISO(), closed_at: null });
  r.room_id = roomId; r.updated_at = nowISO();
  if (["available", "ready", "cleaning"].includes(rm.status) && ["confirmed", "pending_verification"].includes(r.status) && from <= branchToday()) rm.status = "reserved"; else recomputeRoomReady(roomId);
  emit("reservation_allocations"); emit("rooms"); emit("reservations"); return id;
}
function releaseAllocations(resId: string, mode: "cancel" | "close") {
  for (const a of T("reservation_allocations").filter((x) => x.reservation_id === resId && x.status === "active")) {
    a.status = mode === "cancel" ? "cancelled" : "closed"; a.closed_at = nowISO();
    if (a.from_date <= branchToday() && branchToday() < a.to_date) { const rm = byId("rooms", a.room_id)!; if (rm.status === "reserved") rm.status = "available"; if (mode === "cancel") recomputeRoomReady(a.room_id); }
  }
  emit("reservation_allocations"); emit("rooms");
}
function roomCleaningType(branchId: string) { let t = T("task_types").find((x) => x.branch_id === branchId && x.code === "room_cleaning"); if (!t) { t = { id: uid(), organization_id: ORG, branch_id: branchId, code: "room_cleaning", name: "تنظيف الوحدة وتعقيمها", description: null, is_active: true, archived_at: null, version: 1, created_at: nowISO(), updated_at: nowISO() }; T("task_types").push(t); emit("task_types"); } return t; }
function createCleaningTask(branchId: string, roomId: string, resId: string | null, desc: string, priority = "high") {
  const t = roomCleaningType(branchId); const rm = byId("rooms", roomId)!; rm.cleanliness = "dirty"; rm.status = "cleaning"; rm.updated_at = nowISO();
  const existing = T("housekeeping_tasks").find((h) => h.room_id === roomId && h.reservation_id === resId && ["pending", "in_progress"].includes(h.status));
  if (!existing) T("housekeeping_tasks").push({ id: uid(), organization_id: ORG, branch_id: branchId, room_id: roomId, facility_id: null, task_type_id: t.id, task_type_name_snapshot: t.name, reservation_id: resId, priority, status: "pending", assignee_id: null, scheduled_start: nowISO(), scheduled_end: null, started_at: null, completed_at: null, completed_by: null, cancelled_at: null, cancel_reason: null, description: desc, result_note: null, images: [], version: 1, created_by: staffId(), created_at: nowISO(), updated_at: nowISO() });
  const kb = T("keyboxes").find((k) => k.room_id === roomId); if (kb) { kb.code_status = "needs_change"; kb.field_tested = false; }
  emit("housekeeping_tasks"); emit("rooms"); emit("keyboxes");
}
const guestName = (resId: string) => T("reservation_guests").find((g) => g.reservation_id === resId && g.is_primary)?.full_name ?? null;
const roomNo = (roomId: string | null) => (roomId ? byId("rooms", roomId)?.room_number ?? null : null);

// ---------------------------------------------------------------------------
// RPC implementations
// ---------------------------------------------------------------------------
const rpcs: Record<string, (a: any) => any> = {
  fn_staff_id: () => staffId(),
  fn_user_branch_ids: () => myBranches(),
  fn_claim_staff_profile: () => ({ ok: true, claimed: true }),
  fn_staff_invite: ({ p_email, p_full_name, p_role, p_branch_ids }) => { requireRole("owner"); const id = uid(); T("staff_profiles").push({ id, auth_user_id: null, organization_id: ORG, full_name: p_full_name, email: p_email, phone: null, role: p_role, is_active: true, created_at: nowISO() }); for (const b of p_branch_ids ?? []) T("branch_memberships").push({ id: uid(), staff_id: id, branch_id: b }); emit("staff_profiles"); return { ok: true, staff_id: id }; },
  fn_admin_update_ai_settings: ({ p }) => { requireRole("owner"); Object.assign(T("ai_settings")[0], p, { updated_at: nowISO() }); emit("ai_settings"); return { ok: true }; },
  fn_definition_dependencies: ({ p_entity, p_id }) => { requireRole("owner", "manager"); return deps(p_entity, p_id); },

  // ---- definitions ----
  fn_admin_upsert_branch: ({ p }) => { requireRole("owner", "manager"); nonEmpty(p.name_ar, "name_ar"); if (p.timezone) { try { new Intl.DateTimeFormat("en", { timeZone: p.timezone }); } catch { throw new Error("VALIDATION: timezone"); } }
    if (!p.id) { requireRole("owner"); const b = { id: uid(), organization_id: ORG, name_ar: p.name_ar, name_en: p.name_en ?? null, city: p.city ?? null, address: p.address ?? null, map_url: null, phone: p.phone ?? null, email: p.email ?? null, check_in_time: p.check_in_time ?? "16:00", check_out_time: p.check_out_time ?? "12:00", logo_url: null, is_active: true, timezone: p.timezone ?? "Asia/Riyadh", tax_rate_bp: p.tax_rate_bp ?? 1500, prices_include_tax: !!p.prices_include_tax, default_deposit_halalas: p.default_deposit_halalas ?? 0, tax_number: p.tax_number ?? null, commercial_register: p.commercial_register ?? null, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: nowISO(), updated_at: nowISO() }; T("branches").push(b); roomCleaningType(b.id); emit("branches"); audit(b.id, "branch.created", "branch", b.id, { after: b }); return { ok: true, id: b.id, version: 1 }; }
    const b = byId("branches", p.id); if (!b) throw new Error("NOT_FOUND"); requireBranch(b.id); checkVersionLenient(b.version, p.version); const before = { ...b };
    for (const k of ["name_ar", "name_en", "city", "address", "phone", "email", "check_in_time", "check_out_time", "timezone", "tax_rate_bp", "prices_include_tax", "default_deposit_halalas", "tax_number", "commercial_register", "is_active"]) if (p[k] !== undefined) b[k] = p[k];
    b.version++; b.updated_at = nowISO(); emit("branches"); audit(b.id, "branch.updated", "branch", b.id, { before, after: b }); return { ok: true, id: b.id, version: b.version }; },
  fn_admin_upsert_block: ({ p }) => upsertDef("blocks", "block", p, ["name", "description", "sort_order", "is_active"], (x) => nonEmpty(x.name, "name"), ["name"]),
  fn_admin_upsert_floor: ({ p }) => { if (!p.id) { const blk = byId("blocks", p.block_id); if (!blk) throw new Error("NOT_FOUND: block"); p.branch_id = blk.branch_id; } return upsertDef("floors", "floor", p, ["name", "sort_order", "is_active", "block_id"], (x) => nonEmpty(x.name, "name"), ["name"], "block_id"); },
  fn_admin_upsert_room_category: ({ p }) => upsertDef("room_categories", "room_category", p, ["name_ar", "name_en", "description", "base_capacity", "max_capacity", "base_price_halalas", "amenities", "is_public", "is_active", "sort_order"], (x) => { nonEmpty(x.name_ar, "name_ar"); if (x.base_price_halalas < 0) throw new Error("VALIDATION: amount"); if (x.max_capacity < x.base_capacity) throw new Error("VALIDATION: capacity"); }, ["name_ar"]),
  fn_admin_upsert_room: ({ p }) => { requireRole("owner", "manager"); const rows = T("rooms"); let r = p.id ? byId("rooms", p.id) : null; if (p.id && !r) throw new Error("NOT_FOUND");
    const branch = r ? r.branch_id : p.branch_id; requireBranch(branch); const cat = p.category_id ?? r?.category_id; const blk = p.block_id === undefined ? r?.block_id ?? null : p.block_id; const flr = p.floor_id === undefined ? r?.floor_id ?? null : p.floor_id;
    if (!cat || byId("room_categories", cat)?.branch_id !== branch) throw new Error("BRANCH_MISMATCH: category"); if (blk && byId("blocks", blk)?.branch_id !== branch) throw new Error("BRANCH_MISMATCH: block"); if (flr && (byId("floors", flr)?.branch_id !== branch || (blk && byId("floors", flr)?.block_id !== blk))) throw new Error("BRANCH_MISMATCH: floor");
    if (!r) { nonEmpty(p.room_number, "room_number"); if (rows.some((x) => x.branch_id === branch && x.room_number === p.room_number.trim())) throw new Error("DUPLICATE_ROOM_NUMBER"); r = { id: uid(), branch_id: branch, organization_id: ORG, category_id: cat, block_id: blk, floor_id: flr, room_number: p.room_number.trim(), floor: 1, status: "available", cleanliness: "clean", is_active: p.is_active ?? true, notes: p.notes ?? null, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: nowISO(), updated_at: nowISO() }; rows.push(r); emit("rooms"); audit(branch, "room.created", "room", r.id, { after: r }); return { ok: true, id: r.id, version: 1 }; }
    checkVersion(r.version, p.version); const before = { ...r };
    if (p.is_active === false && r.is_active && T("reservation_allocations").some((a) => a.room_id === r!.id && a.status === "active" && a.to_date > branchToday() && ["confirmed", "checked_in", "pending_verification"].includes(byId("reservations", a.reservation_id)?.status))) throw new Error("HAS_FUTURE_COMMITMENTS");
    if (p.room_number && p.room_number.trim() !== r.room_number && rows.some((x) => x.id !== r!.id && x.branch_id === branch && x.room_number === p.room_number.trim())) throw new Error("DUPLICATE_ROOM_NUMBER");
    Object.assign(r, { room_number: p.room_number?.trim() || r.room_number, category_id: cat, block_id: blk, floor_id: flr, notes: p.notes ?? r.notes, is_active: p.is_active ?? r.is_active, version: r.version + 1, updated_at: nowISO() });
    if (!r.is_active) r.status = "out_of_service"; else if (r.status === "out_of_service") r.status = "available";
    emit("rooms"); audit(branch, "room.updated", "room", r.id, { before, after: r }); return { ok: true, id: r.id, version: r.version }; },
  fn_admin_upsert_facility: ({ p }) => upsertDef("facilities", "facility", p, ["name", "description", "block_id", "floor_id", "images", "is_active"], (x) => nonEmpty(x.name, "name"), ["name"]),
  fn_admin_upsert_task_type: ({ p }) => upsertDef("task_types", "task_type", p, ["name", "description", "is_active"], (x) => nonEmpty(x.name, "name"), ["name"]),
  fn_admin_upsert_service: ({ p }) => upsertDef("service_definitions", "service", p, ["name_ar", "name_en", "description", "billing_unit", "price_halalas", "is_free", "taxable", "task_type_id", "is_active"], (x) => { nonEmpty(x.name_ar, "name_ar"); if (x.price_halalas < 0) throw new Error("VALIDATION: amount"); }, ["name_ar"]),
  fn_admin_archive_definition: ({ p_entity, p_id, p_reason, p_archive }) => { requireRole("owner", "manager"); const table = TABLE_OF[p_entity]; const row = byId(table, p_id); if (!row) throw new Error("NOT_FOUND"); requireBranch(p_entity === "branch" ? row.id : row.branch_id);
    if (p_archive !== false) { nonEmpty(p_reason, "reason"); const open = openCommitments(p_entity, p_id); if (open > 0) throw new Error(`HAS_OPEN_COMMITMENTS: ${open}`); Object.assign(row, { archived_at: nowISO(), archived_by: staffId(), archive_reason: p_reason, is_active: false, version: row.version + 1 }); if (p_entity === "room") row.status = "out_of_service"; }
    else { Object.assign(row, { archived_at: null, archived_by: null, archive_reason: null, is_active: true, version: row.version + 1 }); if (p_entity === "room" && row.status === "out_of_service") row.status = "available"; }
    emit(table); audit(p_entity === "branch" ? row.id : row.branch_id, p_entity + (p_archive !== false ? ".archived" : ".restored"), p_entity, p_id, { reason: p_reason }); return { ok: true }; },
  fn_admin_delete_definition: ({ p_entity, p_id }) => { requireRole("owner", "manager"); const table = TABLE_OF[p_entity]; const row = byId(table, p_id); if (!row) throw new Error("NOT_FOUND"); const d = deps(p_entity, p_id); if (Object.values(d).some((n) => n > 0)) return { ok: false, error: "HAS_DEPENDENCIES", dependencies: d }; if (p_entity === "task_type" && row.code) return { ok: false, error: "SYSTEM_DEFINITION" }; audit(p_entity === "branch" ? row.id : row.branch_id, p_entity + ".deleted", p_entity, p_id, { before: row }); S[table] = T(table).filter((x) => x.id !== p_id); emit(table); return { ok: true }; },

  // ---- reservations ----
  fn_staff_quote: ({ p_branch, p_category, p_check_in, p_check_out, p_nightly_override, p_discount_halalas }) => quote(p_branch, p_category, p_check_in, p_check_out, p_nightly_override, p_discount_halalas ?? 0),
  fn_available_rooms: ({ p_branch, p_from, p_to, p_category, p_exclude_reservation }) => T("rooms").filter((r) => r.branch_id === p_branch && myBranches().includes(p_branch) && r.is_active && !r.archived_at && !["blocked", "out_of_service", "maintenance"].includes(r.status) && (!p_category || r.category_id === p_category) && roomAvailable(r.id, p_from, p_to, p_exclude_reservation)).map((r) => ({ room_id: r.id, room_number: r.room_number, category_id: r.category_id, category_name: byId("room_categories", r.category_id)?.name_ar, status: r.status, cleanliness: r.cleanliness, block_name: byId("blocks", r.block_id)?.name ?? null, floor_name: byId("floors", r.floor_id)?.name ?? null })).sort((a, b) => a.room_number.localeCompare(b.room_number, "en", { numeric: true })),
  fn_room_available: ({ p_room, p_from, p_to, p_exclude_reservation }) => roomAvailable(p_room, p_from, p_to, p_exclude_reservation),
  // multi-unit booking (0011): one reservation per unit sharing group_ref, all-or-nothing
  fn_staff_create_reservation: ({ p }) => {
    requireRole("owner", "manager", "supervisor");
    const units: any[] | null = Array.isArray(p.units) && p.units.length > 0 ? p.units : null;
    if (!units) return createReservationUnit(p, null);
    if (units.length > 20) throw new Error("VALIDATION: too many units");
    const g = units.length > 1 ? "G-" + Math.random().toString(16).slice(2, 10).toUpperCase() : null;
    const tables = ["reservations", "reservation_guests", "reservation_charges", "reservation_allocations", "rooms", "audit_events", "guest_profiles"];
    const snapshot = Object.fromEntries(tables.map((t) => [t, JSON.parse(JSON.stringify(T(t)))]));
    try {
      const { units: _u, ...base } = p; void _u;
      const results = units.map((u) => createReservationUnit({ ...base, ...u }, g));
      return { ...results[0], ids: results.map((x) => x.id), internal_refs: results.map((x) => x.internal_ref), group_ref: g, units: units.length };
    } catch (e) { for (const t of tables) S[t] = snapshot[t]; emitAll(); throw e; }
  },
  fn_reservation_group: ({ p_reservation }) => { const r = byId("reservations", p_reservation); if (!r || !r.group_ref || !myBranches().includes(r.branch_id)) return []; return T("reservations").filter((x) => x.group_ref === r.group_ref).map((x) => ({ id: x.id, internal_ref: x.internal_ref, status: x.status, room_number: roomNo(x.room_id), category_name: byId("room_categories", x.room_category_id)?.name_ar ?? null, check_in: x.check_in, check_out: x.check_out, adults: x.adults, companions: x.companions })).sort((a, b) => a.internal_ref.localeCompare(b.internal_ref)); },
};
function createReservationUnit(p: any, groupRef: string | null) { requireRole("owner", "manager", "supervisor"); requireBranch(p.branch_id); if (!p.check_in || !p.check_out || p.check_out <= p.check_in) throw new Error("VALIDATION: dates"); nonEmpty(p.guest_name, "guest_name");
    const details: any[] = Array.isArray(p.companions_details) ? p.companions_details : []; for (const d of details) if (!String(d?.full_name ?? "").trim()) throw new Error("VALIDATION: companion_name");
    const timeOk = (t: any) => t == null || t === "" || /^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$/.test(String(t)); if (!timeOk(p.arrival_time) || !timeOk(p.departure_time)) throw new Error("VALIDATION: times");
    const br = byId("branches", p.branch_id); const arrival = p.arrival_time ? String(p.arrival_time).slice(0, 5) + ":00" : br?.check_in_time ?? "16:00:00"; const departure = p.departure_time ? String(p.departure_time).slice(0, 5) + ":00" : br?.check_out_time ?? "12:00:00";
    const src = byId("booking_sources", p.source_id); if (!src || !src.is_active) throw new Error("VALIDATION: source"); if (src.external_reference_required && !p.external_ref) throw new Error("VALIDATION: external_ref_required");
    const cat = byId("room_categories", p.category_id); if (!cat || cat.branch_id !== p.branch_id) throw new Error("BRANCH_MISMATCH: category"); const adults = p.adults ?? 1, comp = Math.max(p.companions ?? 0, details.length); if (adults < 1 || comp < 0) throw new Error("VALIDATION: guests"); if (adults + comp > cat.max_capacity) throw new Error("CAPACITY_EXCEEDED");
    if ((p.discount_halalas ?? 0) > 0) requireRole("owner", "manager"); if (p.nightly_rate_halalas != null && p.nightly_rate_halalas < cat.base_price_halalas && !hasRole("owner", "manager")) throw new Error("FORBIDDEN: rate below base price requires manager");
    if (p.external_ref && T("reservations").some((r) => r.source_id === src.id && r.external_ref === p.external_ref)) throw new Error("DUPLICATE_EXTERNAL_REF");
    const q = quote(p.branch_id, p.category_id, p.check_in, p.check_out, p.nightly_rate_halalas ?? null, p.discount_halalas ?? 0);
    const id = uid(); const ref = "R-" + Math.random().toString(16).slice(2, 10).toUpperCase();
    const r: Row = { id, organization_id: ORG, branch_id: p.branch_id, internal_ref: ref, external_ref: p.external_ref ?? null, source_id: src.id, status: p.confirm === false ? "pending_verification" : "confirmed", booking_type: p.booking_type ?? "individual", company_name: p.company_name ?? null, visit_purpose: p.visit_purpose ?? null, check_in: p.check_in, check_out: p.check_out, adults, companions: comp, room_category_id: cat.id, room_id: null, rent_amount_halalas: 0, discount_halalas: 0, addons_halalas: 0, taxes_halalas: 0, total_halalas: 0, paid_halalas: 0, payment_status: "pending", identity_status: "not_started", government_registration: false, access_status: "locked", keybox_delivered: false, checkin_approved_by: null, checkin_approved_at: null, actual_check_in: null, actual_check_out: null, notes: p.notes ?? null, created_at: nowISO(), created_by: staffId(), security_hold: false, security_hold_reason: null, gov_registration_ref: null, updated_at: nowISO(), version: 1, rate_type: "daily", nightly_rate_halalas: q.nightly_rate, cancelled_at: null, cancel_reason: null, cancel_source: null, no_show_at: null, deposit_balance_halalas: 0, refunded_halalas: 0, balance_due_halalas: 0, expected_arrival_time: arrival, expected_departure_time: departure, group_ref: groupRef };
    T("reservations").push(r); T("reservation_guests").push({ id: uid(), reservation_id: id, guest_profile_id: null, is_primary: true, full_name: p.guest_name, identity_type: null, identity_number_last4: null, nationality: p.nationality ?? null, birth_date: null, phone: p.guest_phone ?? null, relationship: null, verification_status: "not_started", data_submitted: false, created_at: nowISO() });
    for (const d of details) T("reservation_guests").push({ id: uid(), reservation_id: id, guest_profile_id: null, is_primary: false, full_name: String(d.full_name).trim(), identity_type: null, identity_number_last4: null, nationality: d.nationality?.trim() || null, birth_date: null, phone: d.phone?.trim() || null, relationship: d.relationship?.trim() || null, verification_status: "not_started", data_submitted: false, created_at: nowISO() });
    addCharge(id, "rent", `إيجار ${q.nights} ليلة × ${(q.nightly_rate / 100).toFixed(2)} ر.س`, q.nights, q.nightly_rate, true, null); if ((p.discount_halalas ?? 0) > 0) addCharge(id, "discount", p.discount_reason || "خصم", 1, p.discount_halalas, true, p.discount_reason ?? null);
    if (p.room_id) { if (!roomAvailable(p.room_id, p.check_in, p.check_out)) throw new Error("ROOM_NOT_AVAILABLE"); allocate(id, p.room_id, p.check_in, p.check_out, "create"); }
    recompute(id); audit(p.branch_id, "reservation.created", "reservation", id, { after: { internal_ref: ref, check_in: p.check_in, check_out: p.check_out, quote: q, arrival_time: arrival, departure_time: departure, companions: comp, group_ref: groupRef } }); emit("reservation_guests"); return { ok: true, id, internal_ref: ref, quote: q, group_ref: groupRef }; }
const rpcsMore: Record<string, (a: any) => any> = {
  fn_staff_amend_stay: ({ p_reservation, p_new_check_out, p_pricing_mode, p_reason, p_expected_version }) => { requireRole("owner", "manager", "supervisor"); nonEmpty(p_reason, "reason"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); checkVersion(r.version, p_expected_version);
    if (!["confirmed", "checked_in", "pending_verification"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID"); if (p_new_check_out <= r.check_in) throw new Error("VALIDATION: dates"); if (r.status === "checked_in" && p_new_check_out <= branchToday() && p_new_check_out < r.check_out) throw new Error("VALIDATION: checkout_in_past");
    const delta = Math.round((Date.parse(p_new_check_out) - Date.parse(r.check_out)) / 86400000); if (delta === 0) return { ok: true, unchanged: true };
    const cat = byId("room_categories", r.room_category_id)!; const rate = p_pricing_mode === "keep_rate" ? r.nightly_rate_halalas : cat.base_price_halalas; const before = { check_out: r.check_out, total_halalas: r.total_halalas };
    const a = T("reservation_allocations").filter((x) => x.reservation_id === r.id && x.status === "active").sort((x, y) => (x.to_date < y.to_date ? 1 : -1))[0];
    if (a) { if (a.to_date !== r.check_out) throw new Error("ALLOCATION_MISMATCH"); if (p_new_check_out <= a.from_date) throw new Error("VALIDATION: dates"); if (T("reservation_allocations").some((o) => o.id !== a.id && o.room_id === a.room_id && o.status === "active" && overlaps(o.from_date, o.to_date, a.from_date, p_new_check_out))) throw new Error("ALLOCATION_CONFLICT: room is allocated during the added period"); a.to_date = p_new_check_out; emit("reservation_allocations"); }
    if (delta > 0) addCharge(r.id, "rent", `تمديد ${delta} ليلة × ${(rate / 100).toFixed(2)} ر.س`, delta, rate, true, p_reason); else addCharge(r.id, "adjustment", `تقصير الإقامة ${-delta} ليلة`, 1, -(-delta * r.nightly_rate_halalas), true, p_reason);
    r.check_out = p_new_check_out; if (p_pricing_mode === "reprice") r.nightly_rate_halalas = rate; r.version++; const f = recompute(r.id)!; audit(r.branch_id, "reservation.departure_changed", "reservation", r.id, { before, after: { check_out: p_new_check_out, total_halalas: r.total_halalas, delta_nights: delta }, reason: p_reason }); return { ok: true, delta_nights: delta, finance: f }; },
  fn_staff_switch_room: ({ p_reservation, p_room, p_effective, p_reason, p_expected_version }) => { requireRole("owner", "manager", "supervisor"); nonEmpty(p_reason, "reason"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); checkVersion(r.version, p_expected_version);
    if (!["confirmed", "checked_in", "pending_verification"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID"); const today = branchToday(); const eff = p_effective ?? (today > r.check_in ? today : r.check_in); if (eff < r.check_in || eff >= r.check_out) throw new Error("VALIDATION: effective_date"); if (r.status === "checked_in" && eff > today) throw new Error("VALIDATION: effective_date");
    const rm = byId("rooms", p_room); if (!rm || rm.branch_id !== r.branch_id) throw new Error("ROOM_NOT_FOUND"); if (r.room_id === p_room) throw new Error("SAME_ROOM"); if (r.status === "checked_in" && rm.cleanliness !== "clean") throw new Error("ROOM_NOT_CLEAN"); if (r.adults + r.companions > byId("room_categories", rm.category_id)!.max_capacity) throw new Error("CAPACITY_EXCEEDED");
    const old = T("reservation_allocations").find((a) => a.reservation_id === r.id && a.status === "active" && a.from_date <= eff && eff < a.to_date); let oldRoom: string | null = null;
    if (old) { oldRoom = old.room_id; if (old.from_date === eff) { old.status = "cancelled"; old.closed_at = nowISO(); } else { old.to_date = eff; if (r.status === "checked_in") { old.status = "closed"; old.closed_at = nowISO(); } } if (r.status === "checked_in") createCleaningTask(r.branch_id, oldRoom!, r.id, "تبديل وحدة"); else { const orm = byId("rooms", oldRoom!)!; if (orm.status === "reserved") orm.status = "available"; } }
    if (r.room_category_id !== rm.category_id) r.room_category_id = rm.category_id;
    allocate(r.id, p_room, eff, r.check_out, "switch: " + p_reason); if (r.status === "checked_in") { rm.status = "occupied"; const kb = T("keyboxes").find((k) => k.room_id === p_room); if (kb) kb.last_reservation_id = r.id; }
    r.version++; r.updated_at = nowISO(); emit("rooms"); emit("reservations"); audit(r.branch_id, "reservation.room_switched", "reservation", r.id, { before: { room_id: oldRoom }, after: { room_id: p_room, effective: eff }, reason: p_reason }); return { ok: true, from_room: oldRoom, to_room: p_room, effective: eff, entry_code_review_required: r.status === "checked_in" }; },
  fn_staff_adjust_price: ({ p_reservation, p_kind, p_amount_halalas, p_description, p_reason, p_expected_version }) => { if (["discount", "adjustment"].includes(p_kind)) requireRole("owner", "manager"); else requireRole("owner", "manager", "supervisor"); nonEmpty(p_reason, "reason"); if (!p_amount_halalas || (p_kind !== "adjustment" && p_amount_halalas < 0)) throw new Error("VALIDATION: amount"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); checkVersion(r.version, p_expected_version); if (["cancelled", "rejected", "closed", "no_show"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID"); const before = { total_halalas: r.total_halalas }; addCharge(r.id, p_kind, p_description || p_kind, 1, p_amount_halalas, true, p_reason); r.version++; const f = recompute(r.id)!; audit(r.branch_id, "reservation.total_changed", "reservation", r.id, { before, after: { total_halalas: r.total_halalas, kind: p_kind, amount_halalas: p_amount_halalas }, reason: p_reason }); return { ok: true, finance: f }; },
  fn_staff_add_service: ({ p_reservation, p_service, p_quantity, p_note }) => { requireRole("owner", "manager", "supervisor"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); if (["cancelled", "rejected", "closed", "no_show"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID"); const s = byId("service_definitions", p_service); if (!s || s.branch_id !== r.branch_id || s.archived_at || !s.is_active) throw new Error("SERVICE_NOT_AVAILABLE"); const nights = Math.round((Date.parse(r.check_out) - Date.parse(r.check_in)) / 86400000); const qty = s.billing_unit === "night" ? nights : s.billing_unit === "person" ? r.adults + r.companions : s.billing_unit === "quantity" ? p_quantity ?? 1 : 1; addCharge(r.id, "addon", s.name_ar + (p_note ? " — " + p_note : ""), qty, s.is_free ? 0 : s.price_halalas, s.taxable, null, s.id); r.version++; const f = recompute(r.id)!; audit(r.branch_id, "reservation.service_added", "reservation", r.id, { after: { service_id: s.id, name: s.name_ar, quantity: qty } }); return { ok: true, finance: f }; },
  fn_staff_cancel_reservation: ({ p_reservation, p_reason, p_source }) => { requireRole("owner", "manager", "supervisor"); nonEmpty(p_reason, "reason"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); if (["cancelled", "rejected", "no_show"].includes(r.status)) return { ok: true, duplicate: true, status: r.status }; if (["checked_in", "checked_out", "closed"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID"); releaseAllocations(r.id, "cancel"); Object.assign(r, { status: "cancelled", cancelled_at: nowISO(), cancel_reason: p_reason, cancel_source: p_source ?? "staff", access_status: "locked", version: r.version + 1, updated_at: nowISO() }); emit("reservations"); const f = financeOf(r.id); audit(r.branch_id, "reservation.cancelled", "reservation", r.id, { before: { status: "confirmed" }, after: { status: "cancelled" }, reason: p_reason }); return { ok: true, duplicate: false, status: "cancelled", refund_required_separately: f.net_collected > 0 || f.deposit_balance > 0 }; },
  fn_staff_no_show: ({ p_reservation, p_reason }) => { requireRole("owner", "manager", "supervisor"); nonEmpty(p_reason, "reason"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); if (!["confirmed", "pending_verification"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID"); if (r.check_in > branchToday()) throw new Error("VALIDATION: arrival_not_due"); releaseAllocations(r.id, "cancel"); Object.assign(r, { status: "no_show", no_show_at: nowISO(), cancel_reason: p_reason, access_status: "locked", version: r.version + 1 }); emit("reservations"); audit(r.branch_id, "reservation.no_show", "reservation", r.id, { reason: p_reason }); return { ok: true }; },
  fn_reservation_finance: ({ p_reservation }) => { const r = byId("reservations", p_reservation); if (!r || !myBranches().includes(r.branch_id) || !hasRole("owner", "manager", "supervisor", "finance")) return null; return financeOf(p_reservation); },
  fn_reservation_detail: ({ p_reservation }) => { const r = byId("reservations", p_reservation); if (!r || !myBranches().includes(r.branch_id)) return null; const money = hasRole("owner", "manager", "supervisor", "finance");
    const reservation = { ...r }; delete reservation.notes; if (!money) for (const k of ["total_halalas", "paid_halalas", "rent_amount_halalas", "discount_halalas", "addons_halalas", "taxes_halalas", "balance_due_halalas", "deposit_balance_halalas", "refunded_halalas", "nightly_rate_halalas", "payment_status"]) delete reservation[k];
    const src = byId("booking_sources", r.source_id); const room = byId("rooms", r.room_id);
    return { reservation, notes: r.notes, source: src ? { name: src.name, code: src.code, kind: src.kind } : null, category: byId("room_categories", r.room_category_id)?.name_ar ?? null, room: room ? { id: room.id, room_number: room.room_number, status: room.status, cleanliness: room.cleanliness } : null,
      guests: money ? T("reservation_guests").filter((g) => g.reservation_id === r.id).map((g) => ({ id: g.id, is_primary: g.is_primary, full_name: g.full_name, identity_type: g.identity_type, identity_number_last4: g.identity_number_last4, nationality: g.nationality, phone: hasRole("owner", "manager", "supervisor") ? g.phone : null, verification_status: g.verification_status, data_submitted: g.data_submitted })) : null,
      allocations: T("reservation_allocations").filter((a) => a.reservation_id === r.id).map((a) => ({ id: a.id, room_number: roomNo(a.room_id), from_date: a.from_date, to_date: a.to_date, status: a.status, reason: a.reason, created_at: a.created_at })).sort((a, b) => (a.from_date < b.from_date ? -1 : 1)),
      charges: money ? T("reservation_charges").filter((c) => c.reservation_id === r.id) : null, vouchers: money ? T("financial_vouchers").filter((v) => v.reservation_id === r.id).map((v) => { const x = { ...v }; delete x.content_hash; return x; }) : null,
      invoices: money ? T("invoices").filter((i) => i.reservation_id === r.id).map((i) => ({ id: i.id, number: i.number, status: i.status, total_halalas: i.total_halalas, issued_at: i.issued_at, period_from: i.period_from, period_to: i.period_to })) : null,
      finance: money ? financeOf(r.id) : null, history: hasRole("owner", "manager", "supervisor") ? T("audit_events").filter((e) => e.entity_id === r.id).slice(0, 50).map((e) => ({ action: e.action, at: e.created_at, actor: byId("staff_profiles", e.actor_id)?.full_name ?? null, details: e.details })) : null }; },
  fn_reservation_list: ({ p_branch, p_filters, p_limit, p_offset }) => { if (!myBranches().includes(p_branch)) return { total: 0, rows: [] }; const f = p_filters ?? {}; const q = (f.q ?? "").toLowerCase();
    let rows = T("reservations").filter((r) => r.branch_id === p_branch && (!f.status || String(f.status).split(",").includes(r.status)) && (f.open_only !== true && f.open_only !== "true" || ["pending_verification", "confirmed", "checked_in"].includes(r.status)) && (!f.check_in_from || r.check_in >= f.check_in_from) && (!f.check_in_to || r.check_in <= f.check_in_to) && (!f.source_id || r.source_id === f.source_id) && (f.has_balance !== true && f.has_balance !== "true" || r.balance_due_halalas > 0) && (!q || r.internal_ref.toLowerCase().includes(q) || (r.external_ref ?? "").toLowerCase().includes(q) || T("reservation_guests").some((g) => g.reservation_id === r.id && ((g.full_name ?? "").toLowerCase().includes(q) || (g.phone ?? "").includes(q)))));
    rows = rows.sort((a, b) => (a.check_in === b.check_in ? (a.created_at < b.created_at ? 1 : -1) : a.check_in < b.check_in ? 1 : -1));
    const page = rows.slice(p_offset ?? 0, (p_offset ?? 0) + (p_limit ?? 50));
    return { total: rows.length, rows: page.map((r) => ({ id: r.id, internal_ref: r.internal_ref, external_ref: r.external_ref, status: r.status, check_in: r.check_in, check_out: r.check_out, nights: Math.round((Date.parse(r.check_out) - Date.parse(r.check_in)) / 86400000), guest_name: guestName(r.id), room_number: roomNo(r.room_id), source_name: byId("booking_sources", r.source_id)?.name ?? null, category_name: byId("room_categories", r.room_category_id)?.name_ar ?? null, total_halalas: r.total_halalas, paid_halalas: r.paid_halalas, balance_due_halalas: r.balance_due_halalas, deposit_balance_halalas: r.deposit_balance_halalas, payment_status: r.payment_status, identity_status: r.identity_status, access_status: r.access_status, created_at: r.created_at })) }; },

  // ---- money ----
  fn_create_voucher: ({ p }) => { if (!["receipt", "deposit"].includes(p.kind)) throw new Error("VALIDATION: kind"); requireRole("owner", "manager", "supervisor", "finance"); if (!p.amount_halalas || p.amount_halalas <= 0) throw new Error("VALIDATION: amount"); nonEmpty(p.idempotency_key, "idempotency_key"); if (!p.method) throw new Error("VALIDATION: method"); const r = byId("reservations", p.reservation_id); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id);
    const hash = [r.id, p.kind, p.amount_halalas, p.method, p.reference ?? ""].join("|"); const ex = T("financial_vouchers").find((v) => v.idempotency_key === p.idempotency_key); if (ex) { if (ex.content_hash !== hash) throw new Error("IDEMPOTENCY_CONFLICT: same key, different content"); if (ex.status === "cancelled") throw new Error("IDEMPOTENCY_CANCELLED"); return { ok: true, duplicate: true, voucher_id: ex.id, number: ex.number, finance: financeOf(r.id) }; }
    const v = { id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: r.id, number: nextNumber(p.kind === "receipt" ? "RCP" : "DEP"), kind: p.kind, amount_halalas: p.amount_halalas, method: p.method, status: "approved", reference: p.reference ?? null, note: p.note ?? null, reason: p.reason ?? null, original_voucher_id: null, payment_transaction_id: null, idempotency_key: p.idempotency_key, content_hash: hash, occurred_at: nowISO(), created_by: staffId(), created_at: nowISO(), cancelled_by: null, cancelled_at: null, cancel_reason: null };
    T("financial_vouchers").push(v); emit("financial_vouchers"); const f = recompute(r.id)!; audit(r.branch_id, "voucher." + p.kind + "_created", "voucher", v.id, { after: { number: v.number, amount_halalas: v.amount_halalas, method: v.method, reservation_id: r.id } }); return { ok: true, duplicate: false, voucher_id: v.id, number: v.number, finance: f }; },
  fn_refund: ({ p }) => { if (!["refund", "deposit_refund", "deposit_apply"].includes(p.kind)) throw new Error("VALIDATION: kind"); requireRole("owner", "manager", "finance"); if (!p.amount_halalas || p.amount_halalas <= 0) throw new Error("VALIDATION: amount"); nonEmpty(p.reason, "reason"); nonEmpty(p.idempotency_key, "idempotency_key"); const r = byId("reservations", p.reservation_id); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id);
    const hash = [r.id, p.kind, p.amount_halalas, p.method ?? "", p.reference ?? ""].join("|"); const ex = T("financial_vouchers").find((v) => v.idempotency_key === p.idempotency_key); if (ex) { if (ex.content_hash !== hash) throw new Error("IDEMPOTENCY_CONFLICT"); if (ex.status === "cancelled") throw new Error("IDEMPOTENCY_CANCELLED"); return { ok: true, duplicate: true, voucher_id: ex.id, number: ex.number, finance: financeOf(r.id) }; }
    const f0 = financeOf(r.id); const available = p.kind === "refund" ? f0.received - f0.refunded : f0.deposit_balance; if (p.amount_halalas > available) throw new Error(`REFUND_EXCEEDS_AVAILABLE: available ${available} halalas`); if (p.kind === "deposit_apply" && p.amount_halalas > f0.balance_due) throw new Error("REFUND_EXCEEDS_AVAILABLE: nothing due");
    const v = { id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: r.id, number: nextNumber(p.kind === "refund" ? "RFD" : p.kind === "deposit_refund" ? "DRF" : "DAP"), kind: p.kind, amount_halalas: p.amount_halalas, method: p.method ?? "cash", status: "approved", reference: p.reference ?? null, note: p.note ?? null, reason: p.reason, original_voucher_id: p.original_voucher_id ?? null, payment_transaction_id: null, idempotency_key: p.idempotency_key, content_hash: hash, occurred_at: nowISO(), created_by: staffId(), created_at: nowISO(), cancelled_by: null, cancelled_at: null, cancel_reason: null };
    T("financial_vouchers").push(v); emit("financial_vouchers"); const f = recompute(r.id)!; audit(r.branch_id, "voucher." + p.kind + "_created", "voucher", v.id, { after: { number: v.number, amount_halalas: v.amount_halalas, available_before: available }, reason: p.reason }); return { ok: true, duplicate: false, voucher_id: v.id, number: v.number, finance: f }; },
  fn_cancel_voucher: ({ p_voucher, p_reason }) => { requireRole("owner", "manager"); nonEmpty(p_reason, "reason"); const v = byId("financial_vouchers", p_voucher); if (!v) throw new Error("NOT_FOUND"); requireBranch(v.branch_id); if (v.status !== "approved") throw new Error("VOUCHER_STATUS_INVALID"); v.status = "cancelled"; const f = financeOf(v.reservation_id); if (f.deposit_balance < 0 || f.received - f.refunded < 0) { v.status = "approved"; throw new Error("CANCEL_WOULD_GO_NEGATIVE"); } Object.assign(v, { cancelled_at: nowISO(), cancelled_by: staffId(), cancel_reason: p_reason }); emit("financial_vouchers"); recompute(v.reservation_id); audit(v.branch_id, "voucher.cancelled", "voucher", v.id, { before: { status: "approved" }, after: { status: "cancelled", number: v.number }, reason: p_reason }); return { ok: true, finance: f, provider_refund_note: "إلغاء السند محلي؛ لا يعني أن مزود الدفع ردّ المبلغ." }; },
  fn_staff_confirm_payment: ({ p_reservation, p_method, p_amount_halalas, p_reference, p_idempotency_key }) => { requireRole("owner", "manager", "supervisor", "finance"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); if (p_amount_halalas <= 0) throw new Error("VALIDATION: amount"); nonEmpty(p_reference, "reference_required"); const res = rpcs.fn_create_voucher({ p: { reservation_id: r.id, kind: "receipt", amount_halalas: p_amount_halalas, method: p_method, reference: p_reference, idempotency_key: p_idempotency_key } }); audit(r.branch_id, "confirm_payment", "reservation", r.id, { method: p_method, amount_halalas: p_amount_halalas, reference: p_reference }); return { ok: true, duplicate: res.duplicate, payment_status: r.payment_status, paid_halalas: r.paid_halalas, voucher: res.number }; },
  fn_create_invoice: ({ p_reservation, p_from, p_to }) => { requireRole("owner", "manager", "supervisor", "finance"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); const lines = T("reservation_charges").filter((c) => c.reservation_id === r.id && !c.invoice_id); if (!lines.length) throw new Error("NOTHING_TO_INVOICE"); const b = byId("branches", r.branch_id)!; const id = uid(); const sub = lines.filter((c) => c.kind !== "tax").reduce((a, c) => a + c.total_halalas, 0), tax = lines.filter((c) => c.kind === "tax").reduce((a, c) => a + c.total_halalas, 0);
    const inv = { id, organization_id: ORG, branch_id: r.branch_id, reservation_id: r.id, number: nextNumber("INV"), period_from: p_from ?? r.check_in, period_to: p_to ?? r.check_out, status: "issued", snapshot: { property: { name: b.name_ar, tax_number: b.tax_number }, guest: { name: guestName(r.id) }, lines: lines.map((c) => ({ ...c })) }, subtotal_halalas: sub, tax_halalas: tax, total_halalas: sub + tax, issued_by: staffId(), issued_at: nowISO(), cancelled_by: null, cancelled_at: null, cancel_reason: null }; T("invoices").push(inv); for (const c of lines) c.invoice_id = id; emit("invoices"); emit("reservation_charges"); audit(r.branch_id, "invoice.issued", "invoice", id, { after: { number: inv.number, total_halalas: inv.total_halalas } }); return { ok: true, id, number: inv.number, total_halalas: inv.total_halalas }; },
  fn_cancel_invoice: ({ p_invoice, p_reason }) => { requireRole("owner", "manager"); nonEmpty(p_reason, "reason"); const inv = byId("invoices", p_invoice); if (!inv) throw new Error("NOT_FOUND"); if (inv.status !== "issued") throw new Error("INVOICE_STATUS_INVALID"); Object.assign(inv, { status: "cancelled", cancelled_at: nowISO(), cancelled_by: staffId(), cancel_reason: p_reason }); for (const c of T("reservation_charges")) if (c.invoice_id === inv.id) c.invoice_id = null; emit("invoices"); emit("reservation_charges"); return { ok: true }; },

  // ---- housekeeping ----
  fn_hk_create_task: ({ p }) => { requireRole("owner", "manager", "supervisor", "housekeeping"); if (!!p.room_id === !!p.facility_id) throw new Error("VALIDATION: one_target"); const target = p.room_id ? byId("rooms", p.room_id) : byId("facilities", p.facility_id); if (!target || target.archived_at) throw new Error("NOT_FOUND: target"); requireBranch(target.branch_id); const tt = byId("task_types", p.task_type_id); if (!tt || tt.branch_id !== target.branch_id || tt.archived_at) throw new Error("BRANCH_MISMATCH: task_type"); if (p.reservation_id && byId("reservations", p.reservation_id)?.branch_id !== target.branch_id) throw new Error("BRANCH_MISMATCH: reservation"); if (p.assignee_id && !staffInBranch(p.assignee_id, target.branch_id)) throw new Error("ASSIGNEE_NOT_IN_BRANCH");
    const t = { id: uid(), organization_id: ORG, branch_id: target.branch_id, room_id: p.room_id ?? null, facility_id: p.facility_id ?? null, task_type_id: tt.id, task_type_name_snapshot: tt.name, reservation_id: p.reservation_id ?? null, priority: p.priority ?? "medium", status: "pending", assignee_id: p.assignee_id ?? null, scheduled_start: p.scheduled_start ?? nowISO(), scheduled_end: p.scheduled_end ?? null, started_at: null, completed_at: null, completed_by: null, cancelled_at: null, cancel_reason: null, description: p.description ?? null, result_note: null, images: [], version: 1, created_by: staffId(), created_at: nowISO(), updated_at: nowISO() }; T("housekeeping_tasks").push(t);
    if (p.room_id && tt.code === "room_cleaning") { const rm = byId("rooms", p.room_id)!; if (rm.cleanliness === "clean") rm.cleanliness = "dirty"; recomputeRoomReady(p.room_id); } emit("housekeeping_tasks"); audit(target.branch_id, "task.created", "housekeeping_task", t.id, { after: t }); return { ok: true, id: t.id }; },
  fn_hk_start_task: ({ p_task }) => { requireRole("owner", "manager", "supervisor", "housekeeping"); const t = byId("housekeeping_tasks", p_task); if (!t) throw new Error("TASK_NOT_FOUND"); requireBranch(t.branch_id); if (t.status !== "pending") throw new Error("TASK_STATUS_INVALID"); if (hasRole("housekeeping") && t.assignee_id && t.assignee_id !== staffId()) throw new Error("FORBIDDEN: not assignee"); Object.assign(t, { status: "in_progress", started_at: nowISO(), assignee_id: t.assignee_id ?? staffId(), version: t.version + 1 }); if (t.room_id && byId("task_types", t.task_type_id)?.code === "room_cleaning") { byId("rooms", t.room_id)!.cleanliness = "in_progress"; emit("rooms"); } emit("housekeeping_tasks"); return { ok: true }; },
  fn_hk_complete_task: ({ p_task, p_note, p_expected_version }) => { requireRole("owner", "manager", "supervisor", "housekeeping"); const t = byId("housekeeping_tasks", p_task); if (!t) throw new Error("TASK_NOT_FOUND"); requireBranch(t.branch_id); checkVersion(t.version, p_expected_version); if (!["pending", "in_progress"].includes(t.status)) throw new Error("TASK_STATUS_INVALID"); if (hasRole("housekeeping") && t.assignee_id && t.assignee_id !== staffId()) throw new Error("FORBIDDEN: not assignee"); Object.assign(t, { status: "completed", completed_at: nowISO(), completed_by: staffId(), assignee_id: t.assignee_id ?? staffId(), result_note: p_note ?? null, version: t.version + 1 }); let st: string | undefined; if (t.room_id) { if (byId("task_types", t.task_type_id)?.code === "room_cleaning") byId("rooms", t.room_id)!.cleanliness = "clean"; st = recomputeRoomReady(t.room_id); } emit("housekeeping_tasks"); audit(t.branch_id, "task.completed", "housekeeping_task", t.id, { after: { room_status: st, note: p_note } }); return { ok: true, room_status: st }; },
  fn_hk_cancel_task: ({ p_task, p_reason }) => { requireRole("owner", "manager", "supervisor"); nonEmpty(p_reason, "reason"); const t = byId("housekeeping_tasks", p_task); if (!t) throw new Error("TASK_NOT_FOUND"); if (!["pending", "in_progress"].includes(t.status)) throw new Error("TASK_STATUS_INVALID"); Object.assign(t, { status: "cancelled", cancelled_at: nowISO(), cancel_reason: p_reason, version: t.version + 1 }); if (t.room_id && byId("task_types", t.task_type_id)?.code === "room_cleaning") { const rm = byId("rooms", t.room_id)!; if (rm.cleanliness === "in_progress") rm.cleanliness = "dirty"; recomputeRoomReady(t.room_id); } emit("housekeeping_tasks"); return { ok: true }; },
  fn_hk_assign_task: ({ p_task, p_assignee }) => { requireRole("owner", "manager", "supervisor"); const t = byId("housekeeping_tasks", p_task); if (!t) throw new Error("TASK_NOT_FOUND"); if (p_assignee && !staffInBranch(p_assignee, t.branch_id)) throw new Error("ASSIGNEE_NOT_IN_BRANCH"); t.assignee_id = p_assignee; t.version++; emit("housekeeping_tasks"); return { ok: true }; },
  fn_hk_set_cleanliness: ({ p_room, p_state, p_reason }) => { requireRole("owner", "manager", "supervisor", "housekeeping"); const rm = byId("rooms", p_room); if (!rm) throw new Error("ROOM_NOT_FOUND"); requireBranch(rm.branch_id); if (p_state === "clean" && T("housekeeping_tasks").some((h) => h.room_id === p_room && ["pending", "in_progress"].includes(h.status) && byId("task_types", h.task_type_id)?.code === "room_cleaning")) throw new Error("OPEN_CLEANING_TASK"); const before = rm.cleanliness; rm.cleanliness = p_state; recomputeRoomReady(p_room); audit(rm.branch_id, "room.cleanliness_changed", "room", p_room, { before: { cleanliness: before }, after: { cleanliness: p_state }, reason: p_reason }); return { ok: true, room_status: rm.status }; },
  fn_staff_complete_cleaning: ({ p_task }) => rpcs.fn_hk_complete_task({ p_task }),
  fn_staff_rotate_keybox_code: ({ p_room, p_new_code, p_field_tested }) => { requireRole("owner", "manager", "supervisor"); if (!/^\d{4,8}$/.test(p_new_code)) throw new Error("VALIDATION: code_must_be_4_to_8_digits"); const kb = T("keyboxes").find((k) => k.room_id === p_room); if (!kb) throw new Error("ROOM_NOT_FOUND"); T("code_rotation_events").unshift({ id: uid(), room_id: p_room, from_version: kb.code_version, to_version: kb.code_version + 1, field_tested: !!p_field_tested, created_at: nowISO() }); Object.assign(kb, { code_version: kb.code_version + 1, code_status: "active", field_tested: !!p_field_tested, last_changed_at: nowISO(), last_changed_by: staffId() }); emit("keyboxes"); emit("code_rotation_events"); const st = recomputeRoomReady(p_room); return { ok: true, room_status: st, code_version: kb.code_version }; },
  fn_staff_mark_keybox_tested: ({ p_room }) => { requireRole("owner", "manager", "supervisor"); const kb = T("keyboxes").find((k) => k.room_id === p_room); if (!kb) throw new Error("ROOM_NOT_FOUND"); kb.field_tested = true; emit("keyboxes"); return { ok: true, room_status: recomputeRoomReady(p_room) }; },
  fn_staff_create_maintenance: ({ p_room, p_title, p_description }) => { requireRole("owner", "manager", "supervisor", "housekeeping"); nonEmpty(p_title, "title"); const rm = byId("rooms", p_room); if (!rm) throw new Error("ROOM_NOT_FOUND"); const id = uid(); T("maintenance_tickets").unshift({ id, room_id: p_room, branch_id: rm.branch_id, title: p_title, description: p_description ?? null, status: "open", created_by: staffId(), created_at: nowISO() }); if (!["occupied"].includes(rm.status)) rm.status = "maintenance"; emit("maintenance_tickets"); emit("rooms"); return { ok: true, ticket_id: id }; },
  fn_staff_resolve_maintenance: ({ p_ticket }) => { requireRole("owner", "manager", "supervisor"); const t = byId("maintenance_tickets", p_ticket); if (!t) throw new Error("TICKET_NOT_FOUND"); t.status = "resolved"; emit("maintenance_tickets"); const rm = byId("rooms", t.room_id)!; if (rm.status === "maintenance") rm.status = "available"; return { ok: true, room_status: recomputeRoomReady(t.room_id) }; },
  fn_staff_resolve_ticket: ({ p_ticket }) => { requireRole("owner", "manager", "supervisor"); const t = byId("human_handoff_tickets", p_ticket); if (!t) throw new Error("TICKET_NOT_FOUND"); Object.assign(t, { status: "resolved", resolved_by: staffId(), resolved_at: nowISO() }); emit("human_handoff_tickets"); return { ok: true }; },
  fn_staff_release_next_slot: ({ p_category }) => { requireRole("owner", "manager"); const slot = T("released_slots").find((x) => x.category_id === p_category && x.date === todayISO()); if (slot) slot.released_count++; else T("released_slots").push({ id: uid(), branch_id: byId("room_categories", p_category)?.branch_id, category_id: p_category, date: todayISO(), released_count: 1, updated_at: nowISO() }); emit("released_slots"); return (slot?.released_count ?? 1); },

  // ---- gate flow ----
  fn_evaluate_access: ({ p_reservation }) => [evaluate(p_reservation)],
  fn_staff_approve_identity: ({ p_guest_id, p_approve, p_reason }) => { requireRole("owner", "manager", "supervisor"); const g = byId("reservation_guests", p_guest_id); if (!g) throw new Error("GUEST_NOT_FOUND"); if (!p_approve) nonEmpty(p_reason, "reason"); g.verification_status = p_approve ? "verified" : "rejected"; const r = byId("reservations", g.reservation_id)!; const all = T("reservation_guests").filter((x) => x.reservation_id === r.id); r.identity_status = all.every((x) => x.verification_status === "verified") ? "verified" : all.some((x) => x.verification_status === "rejected") ? "rejected" : "pending_supervisor"; emit("reservation_guests"); emit("reservations"); audit(r.branch_id, p_approve ? "approve_identity" : "reject_identity", "reservation", r.id, { guest_id: g.id, reason: p_reason }); return { ok: true, identity_status: r.identity_status }; },
  fn_staff_confirm_gov_registration: ({ p_reservation, p_reference }) => { requireRole("owner", "manager", "supervisor"); const r = byId("reservations", p_reservation)!; if (r.identity_status !== "verified") throw new Error("IDENTITY_NOT_VERIFIED"); nonEmpty(p_reference, "reference_required"); Object.assign(r, { government_registration: true, gov_registration_ref: p_reference, gov_registration_at: nowISO() }); emit("reservations"); audit(r.branch_id, "confirm_gov_registration", "reservation", r.id, { reference: p_reference }); return { ok: true }; },
  fn_staff_assign_room: ({ p_reservation, p_room }) => { requireRole("owner", "manager", "supervisor"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); if (!["confirmed", "pending_verification"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID"); if (T("reservation_allocations").some((a) => a.reservation_id === r.id && a.status === "active")) throw new Error("ALREADY_ALLOCATED"); if (!roomAvailable(p_room, r.check_in, r.check_out)) throw new Error("ROOM_NOT_AVAILABLE"); allocate(r.id, p_room, r.check_in, r.check_out, "assign"); r.version++; audit(r.branch_id, "assign_room", "reservation", r.id, { room_id: p_room }); return { ok: true }; },
  fn_staff_approve_checkin: ({ p_reservation }) => { requireRole("owner", "manager", "supervisor"); const r = byId("reservations", p_reservation)!; const ev = evaluate(r.id, true); if (!ev.allowed) return { ok: false, reasons: ev.reasons }; Object.assign(r, { access_status: "approved", checkin_approved_by: staffId(), checkin_approved_at: nowISO() }); emit("reservations"); audit(r.branch_id, "approve_checkin", "reservation", r.id, {}); return { ok: true }; },
  fn_staff_deliver_access_code: ({ p_reservation, p_channel }) => { requireRole("owner", "manager", "supervisor"); const r = byId("reservations", p_reservation)!; const ev = evaluate(r.id); if (!ev.allowed) return { ok: false, reasons: ev.reasons }; Object.assign(r, { access_status: "delivered", keybox_delivered: true, status: "checked_in", actual_check_in: r.actual_check_in ?? nowISO(), version: r.version + 1 }); const rm = byId("rooms", r.room_id)!; rm.status = "occupied"; const kb = T("keyboxes").find((k) => k.room_id === r.room_id); if (kb) { kb.last_reservation_id = r.id; kb.last_delivered_at = nowISO(); } if (!T("reservation_allocations").some((a) => a.reservation_id === r.id && a.status === "active")) T("reservation_allocations").push({ id: uid(), reservation_id: r.id, room_id: r.room_id, branch_id: r.branch_id, from_date: r.check_in, to_date: r.check_out, status: "active", reason: "auto:checkin", created_by: staffId(), created_at: nowISO(), closed_at: null }); T("access_delivery_events").push({ id: uid(), reservation_id: r.id, keybox_id: kb?.id ?? null, channel: p_channel, delivered_by: staffId(), acknowledged: false, created_at: nowISO() }); emit("reservations"); emit("rooms"); emit("keyboxes"); audit(r.branch_id, "deliver_access_code", "reservation", r.id, { channel: p_channel }); return { ok: true, code: p_channel === "supervisor" ? "4" + String(Math.floor(1000 + Math.random() * 8999)) : undefined, released_count: null }; },
  fn_staff_mark_delivery_failed: ({ p_reservation, p_reason }) => { requireRole("owner", "manager", "supervisor"); nonEmpty(p_reason, "reason"); const r = byId("reservations", p_reservation)!; r.access_status = "approved"; emit("reservations"); audit(r.branch_id, "mark_delivery_failed", "reservation", r.id, { reason: p_reason }); return { ok: true }; },
  fn_staff_checkout: ({ p_reservation, p_override_reason }) => { requireRole("owner", "manager", "supervisor"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); if (r.status === "checked_out") return { ok: true, duplicate: true }; if (r.status !== "checked_in") throw new Error("NOT_CHECKED_IN"); const f = recompute(r.id)!; if (f.balance_due > 0 && (!p_override_reason?.trim() || !hasRole("owner", "manager"))) return { ok: false, reasons: [`يوجد مبلغ متبقٍ ${(f.balance_due / 100).toFixed(2)} ر.س — يلزم السداد أو تجاوز بصلاحية مدير مع سبب`] }; Object.assign(r, { status: "checked_out", actual_check_out: nowISO(), version: r.version + 1 }); releaseAllocations(r.id, "close"); if (r.room_id) createCleaningTask(r.branch_id, r.room_id, r.id, "تنظيف بعد المغادرة"); emit("reservations"); audit(r.branch_id, "checkout", "reservation", r.id, { remaining_halalas: f.balance_due, override_reason: p_override_reason ?? null, deposit_balance_halalas: f.deposit_balance }); return { ok: true, deposit_to_settle_halalas: f.deposit_balance }; },

  // ---- operations ----
  fn_ops_units_board: ({ p_branch }) => { if (!myBranches().includes(p_branch)) return []; const today = branchToday(); return T("rooms").filter((r) => r.branch_id === p_branch && !r.archived_at).map((r) => { const cur = T("reservation_allocations").filter((a) => a.room_id === r.id && a.status === "active" && a.from_date <= today).map((a) => ({ a, r: byId("reservations", a.reservation_id)! })).filter((x) => x.r && ["confirmed", "checked_in", "pending_verification"].includes(x.r.status) && (today < x.a.to_date || x.r.status === "checked_in")).map((x) => x.r).sort((a) => (a.status === "checked_in" ? -1 : 1))[0]; const next = T("reservation_allocations").filter((a) => a.room_id === r.id && a.status === "active" && a.from_date > today && ["confirmed", "pending_verification"].includes(byId("reservations", a.reservation_id)?.status)).sort((a, b) => (a.from_date < b.from_date ? -1 : 1))[0]; const kb = T("keyboxes").find((k) => k.room_id === r.id);
    return { room_id: r.id, room_number: r.room_number, category: byId("room_categories", r.category_id)?.name_ar, block: byId("blocks", r.block_id)?.name ?? null, floor: byId("floors", r.floor_id)?.name ?? null, is_active: r.is_active, status: r.status, cleanliness: r.cleanliness, open_tasks: T("housekeeping_tasks").filter((h) => h.room_id === r.id && ["pending", "in_progress"].includes(h.status)).length, open_maintenance: T("maintenance_tickets").filter((m) => m.room_id === r.id && m.status !== "resolved").length, keybox_ready: !!kb && kb.code_status === "active" && kb.field_tested, current: cur ? { reservation_id: cur.id, internal_ref: cur.internal_ref, status: cur.status, check_in: cur.check_in, check_out: cur.check_out, guest: guestName(cur.id) ?? "—", balance_due: cur.balance_due_halalas } : null, next: next ? { internal_ref: byId("reservations", next.reservation_id)!.internal_ref, check_in: next.from_date } : null }; }).sort((a, b) => a.room_number.localeCompare(b.room_number, "en", { numeric: true })); },
  fn_ops_daily_summary: ({ p_branch, p_date }) => summary(p_branch, p_date ?? branchToday()),
  // Ledger-based finance KPIs for reports (A05): revenue = vouchers, never reservation totals; deposits never count as revenue.
  fn_reports_finance: ({ p_branch, p_from, p_to }) => {
    requireRole("owner", "manager", "finance"); requireBranch(p_branch);
    const from = p_from ?? addDays(branchToday(), -29), to = p_to ?? branchToday();
    const inPeriod = (iso: string) => { const d = String(iso).slice(0, 10); return d >= from && d <= to; };
    const vouchers = T("financial_vouchers").filter((v) => v.branch_id === p_branch && v.status === "approved" && inPeriod(v.occurred_at));
    const sumV = (kind: string) => vouchers.filter((v) => v.kind === kind).reduce((a, v) => a + v.amount_halalas, 0);
    const receipts = sumV("receipt"), refunds = sumV("refund"), deposits_received = sumV("deposit"), deposits_refunded = sumV("deposit_refund"), deposits_applied = sumV("deposit_apply");
    const net_collected = receipts - refunds + deposits_applied;
    const stays = T("reservations").filter((r) => r.branch_id === p_branch && r.check_in <= to && r.check_out > from && !["cancelled", "rejected", "no_show"].includes(r.status));
    const charges = T("reservation_charges").filter((c) => c.branch_id === p_branch && stays.some((r) => r.id === c.reservation_id));
    const sumC = (kind: string) => charges.filter((c) => c.kind === kind).reduce((a, c) => a + c.total_halalas, 0);
    const rent = sumC("rent"), addons = sumC("addon") + sumC("penalty") + sumC("adjustment"), discounts = sumC("discount"), tax = sumC("tax");
    const total_charged = rent + addons + discounts + tax;
    const allRes = T("reservations").filter((r) => r.branch_id === p_branch && r.check_in <= to && r.check_out > from);
    const by_method = Object.values(vouchers.filter((v) => v.kind === "receipt").reduce((acc: Record<string, { method: string; amount_halalas: number }>, v) => { (acc[v.method] ??= { method: v.method, amount_halalas: 0 }).amount_halalas += v.amount_halalas; return acc; }, {}));
    const days: Record<string, { day: string; receipts: number; refunds: number }> = {};
    for (const v of vouchers) { const d = String(v.occurred_at).slice(0, 10); const row = (days[d] ??= { day: d, receipts: 0, refunds: 0 }); if (v.kind === "receipt" || v.kind === "deposit_apply") row.receipts += v.amount_halalas; if (v.kind === "refund") row.refunds += v.amount_halalas; }
    const by_source = Object.values(allRes.reduce((acc: Record<string, { source: string; count: number; total_halalas: number }>, r) => { const s = byId("booking_sources", r.source_id)?.name ?? "—"; (acc[s] ??= { source: s, count: 0, total_halalas: 0 }); acc[s].count++; acc[s].total_halalas += r.total_halalas ?? 0; return acc; }, {}));
    const nights = stays.reduce((a, r) => a + Math.max(0, (new Date(r.check_out + "T00:00:00Z").getTime() - new Date(r.check_in + "T00:00:00Z").getTime()) / 86400000), 0);
    const openDeposits = T("reservations").filter((r) => r.branch_id === p_branch).reduce((a, r) => a + Math.max(0, r.deposit_balance_halalas ?? 0), 0);
    return {
      period: { from, to },
      ledger: { receipts, refunds, net_collected, deposits_received, deposits_refunded, deposits_applied, deposit_balance_open: openDeposits },
      charges: { total_charged, rent, addons, discounts, tax },
      collection_rate_pct: total_charged > 0 ? Math.round((net_collected / total_charged) * 1000) / 10 : null,
      by_method, by_day: Object.values(days).sort((a, b) => a.day.localeCompare(b.day)),
      reservations: { count: allRes.length, nights, cancelled: allRes.filter((r) => r.status === "cancelled").length, no_show: allRes.filter((r) => r.status === "no_show").length, by_source },
      definitions: {
        revenue: "صافي التحصيل = سندات قبض الإقامة − الاستردادات + التأمين المستخدم لتغطية رسوم، بتاريخ السند. التأمين المقبوض ليس إيرادًا.",
        collection_rate: "نسبة التحصيل = صافي التحصيل ÷ إجمالي الرسوم (إيجار + إضافات − خصومات + ضريبة) للإقامات المتقاطعة مع الفترة.",
      },
    };
  },
  fn_ai_ops_context: ({ p_branch, p_date }) => { const ctx = opsContext(p_branch, p_date ?? branchToday()); if (!ctx || hasRole(...MONEY_ROLES)) return ctx; const strip = (rows: Row[]) => rows.map((e) => { const x = { ...e }; delete x.balance_due; delete x.deposit_balance; delete x.payment_status; return x; }); const c: any = { ...ctx, summary: { ...ctx.summary, finance: undefined }, arrivals: strip(ctx.arrivals), departures: strip(ctx.departures), overstays: strip(ctx.overstays) }; delete c.in_house_with_balance; delete c.checked_out_with_deposit; return c; },
  fn_ai_ops_find_reservation: ({ p_branch, p_query }) => findRes(p_branch, p_query),
  fn_ai_ops_propose: ({ p_conversation, p_action, p_args, p_summary }) => { const c = byId("ai_ops_conversations", p_conversation); if (!c) throw new Error("NOT_FOUND: conversation"); const id = uid(); const args = { ...(p_args ?? {}) }; if (["amend_stay", "switch_room", "complete_task"].includes(p_action) && args.expected_version == null) { const tgt = p_action === "complete_task" ? byId("housekeeping_tasks", args.task_id) : byId("reservations", args.reservation_id); if (tgt && tgt.branch_id === c.branch_id) args.expected_version = tgt.version; } T("ai_action_proposals").push({ id, organization_id: ORG, branch_id: c.branch_id, conversation_id: c.id, staff_id: staffId(), action: p_action, args, summary: p_summary, status: "proposed", result: null, error: null, created_at: nowISO(), expires_at: new Date(Date.now() + 30 * 60000).toISOString(), decided_at: null, decided_by: null }); return { ok: true, proposal_id: id, requires_confirmation: true }; },
  fn_ai_ops_execute_proposal: ({ p_id }) => { const p = byId("ai_action_proposals", p_id); if (!p || p.staff_id !== staffId()) throw new Error("FORBIDDEN: not your proposal"); if (p.status !== "proposed") throw new Error("PROPOSAL_STATUS_INVALID"); const a = p.args ?? {}; const key = "ai:" + p.id;
    const snapshot = JSON.stringify(S);
    try { let res: any; switch (p.action) {
      case "create_task": res = rpcs.fn_hk_create_task({ p: { ...a, description: (a.description ?? "") + " (اقتراح المساعد)" } }); break;
      case "complete_task": res = rpcs.fn_hk_complete_task({ p_task: a.task_id, p_note: a.note, p_expected_version: a.expected_version }); break;
      case "assign_task": res = rpcs.fn_hk_assign_task({ p_task: a.task_id, p_assignee: a.assignee_id }); break;
      case "set_cleanliness": res = rpcs.fn_hk_set_cleanliness({ p_room: a.room_id, p_state: a.state, p_reason: a.reason ?? "اقتراح المساعد" }); break;
      case "amend_stay": res = rpcs.fn_staff_amend_stay({ p_reservation: a.reservation_id, p_new_check_out: a.new_check_out, p_pricing_mode: a.pricing_mode ?? "keep_rate", p_reason: a.reason ?? p.summary, p_expected_version: a.expected_version }); break;
      case "switch_room": res = rpcs.fn_staff_switch_room({ p_reservation: a.reservation_id, p_room: a.room_id, p_effective: a.effective ?? null, p_reason: a.reason ?? p.summary, p_expected_version: a.expected_version }); break;
      case "cancel_reservation": res = rpcs.fn_staff_cancel_reservation({ p_reservation: a.reservation_id, p_reason: a.reason ?? p.summary, p_source: "staff" }); break;
      case "no_show": res = rpcs.fn_staff_no_show({ p_reservation: a.reservation_id, p_reason: a.reason ?? p.summary }); break;
      case "create_receipt": case "create_deposit": res = rpcs.fn_create_voucher({ p: { reservation_id: a.reservation_id, kind: p.action === "create_receipt" ? "receipt" : "deposit", amount_halalas: a.amount_halalas, method: a.method, reference: a.reference, note: "اقتراح المساعد", idempotency_key: key } }); break;
      case "add_service": res = rpcs.fn_staff_add_service({ p_reservation: a.reservation_id, p_service: a.service_id, p_quantity: a.quantity ?? 1 }); break;
      case "create_invoice": res = rpcs.fn_create_invoice({ p_reservation: a.reservation_id }); break;
      default: throw new Error("VALIDATION: action"); }
      Object.assign(p, { status: "executed", result: res, decided_at: nowISO(), decided_by: staffId() }); audit(p.branch_id, "ai_proposal.executed", "ai_action_proposal", p.id, { after: { action: p.action, summary: p.summary } }); return { ok: true, result: res };
    } catch (e) { S = JSON.parse(snapshot); const p2 = byId("ai_action_proposals", p_id)!; Object.assign(p2, { status: "failed", error: (e as Error).message, decided_at: nowISO(), decided_by: staffId() }); emitAll(); return { ok: false, error: (e as Error).message }; } },
  fn_ai_ops_reject_proposal: ({ p_id, p_reason }) => { const p = byId("ai_action_proposals", p_id); if (!p || p.staff_id !== staffId() || p.status !== "proposed") throw new Error("NOT_FOUND"); Object.assign(p, { status: "rejected", error: p_reason ?? null, decided_at: nowISO(), decided_by: staffId() }); return { ok: true }; },

  // ---- guest ----
  fn_get_public_availability: ({ p_branch, p_date }) => T("room_categories").filter((c) => c.branch_id === p_branch && c.is_public && c.is_active && !c.archived_at).map((c) => { const rooms = T("rooms").filter((r) => r.category_id === c.id && r.is_active && !r.archived_at); const free = rooms.filter((r) => roomAvailablePublic(r.id, p_date, addDays(p_date, 1))).length; return { category_id: c.id, category_name: c.name_ar, base_price_halalas: c.base_price_halalas, base_capacity: c.base_capacity, max_capacity: c.max_capacity, available_to_show: Math.min(free, 2), total_available: free }; }),
  fn_guest_lookup: ({ p_external_ref, p_phone_last4 }) => { const r = T("reservations").find((x) => (x.external_ref ?? "").toLowerCase() === String(p_external_ref).toLowerCase() || x.internal_ref.toLowerCase() === String(p_external_ref).toLowerCase()); if (!r) { T("human_handoff_tickets").unshift({ id: uid(), organization_id: ORG, branch_id: null, conversation_id: null, reservation_id: null, kind: "unmatched_reservation", external_ref: p_external_ref, source_name: null, details: "رقم حجز غير مطابق", status: "open", resolved_by: null, resolved_at: null, created_at: nowISO() }); emit("human_handoff_tickets"); return { status: "unmatched" }; } const g = T("reservation_guests").find((x) => x.reservation_id === r.id && x.is_primary); if (!g?.phone || !g.phone.endsWith(p_phone_last4)) return { status: "mismatch" }; const token = "DEMO" + Math.random().toString(16).slice(2, 14).toUpperCase(); T("registration_sessions").push({ id: uid(), reservation_id: r.id, token, expires_at: new Date(Date.now() + 86400000).toISOString(), used_at: null, created_at: nowISO() }); return { status: "ok", token }; },
  // phone-first lookup (0020). The demo has no WhatsApp: guest-otp answers channel_unavailable, so the page asks for a booking number
  fn_guest_phone_verify: () => ({ status: "expired" }),
  fn_guest_phone_verify_ref: ({ p_phone, p_ref }) => { const ph = normPhone(p_phone); if (!ph) return { status: "invalid" }; const ids = phoneReservationIds(ph); const ok = T("reservations").some((r) => ids.includes(r.id) && [r.external_ref, r.internal_ref].some((x) => String(x ?? "").toUpperCase() === String(p_ref ?? "").trim().toUpperCase())); if (!ok) return { status: "mismatch" }; const token = "PH" + Math.random().toString(16).slice(2, 14).toUpperCase(); phoneSessions.set(token, ph); return { status: "ok", token }; },
  fn_guest_phone_reservations: ({ p_token }) => { const ph = phoneSessions.get(p_token); if (!ph) throw new Error("TOKEN_INVALID"); const ids = phoneReservationIds(ph); return { phone_last4: ph.slice(-4), reservations: T("reservations").filter((r) => ids.includes(r.id)).sort((a, b) => (a.check_in < b.check_in ? -1 : 1)).map((r) => ({ ref: r.external_ref ?? r.internal_ref, internal_ref: r.internal_ref, status: r.status, check_in: r.check_in, check_out: r.check_out, nights: Math.round((Date.parse(r.check_out) - Date.parse(r.check_in)) / 86400000), branch_name: byId("branches", r.branch_id)?.name_ar ?? null, category_name: byId("room_categories", r.room_category_id)?.name_ar ?? null, payment_status: r.payment_status, access_status: r.access_status, identity_status: r.identity_status })) }; },
  fn_guest_phone_open: ({ p_token, p_internal_ref }) => { const ph = phoneSessions.get(p_token); if (!ph) throw new Error("TOKEN_INVALID"); const r = T("reservations").find((x) => x.internal_ref === p_internal_ref && phoneReservationIds(ph).includes(x.id)); if (!r) throw new Error("NOT_FOUND"); const token = "DEMO" + Math.random().toString(16).slice(2, 14).toUpperCase(); T("registration_sessions").push({ id: uid(), reservation_id: r.id, token, expires_at: new Date(Date.now() + 86400000).toISOString(), used_at: null, created_at: nowISO() }); return { status: "ok", token }; },
  fn_guest_session: ({ p_token }) => { const s = T("registration_sessions").find((x) => x.token === p_token); if (!s) throw new Error("TOKEN_INVALID"); const r = byId("reservations", s.reservation_id)!; const ev = evaluate(r.id); return { reservation: { id: r.id, internal_ref: r.internal_ref, external_ref: r.external_ref, status: r.status, check_in: r.check_in, check_out: r.check_out, adults: r.adults, companions: r.companions, payment_status: r.payment_status, identity_status: r.identity_status, government_registration: r.government_registration, access_status: r.access_status, total_halalas: r.total_halalas, paid_halalas: r.paid_halalas, branch_name: byId("branches", r.branch_id)?.name_ar ?? null, room_number: roomNo(r.room_id), category_name: byId("room_categories", r.room_category_id)?.name_ar ?? null }, guests: T("reservation_guests").filter((g) => g.reservation_id === r.id).map((g) => ({ id: g.id, is_primary: g.is_primary, full_name: g.full_name, identity_type: g.identity_type, identity_number_last4: g.identity_number_last4, nationality: g.nationality, birth_date: g.birth_date, relationship: g.relationship, verification_status: g.verification_status, data_submitted: g.data_submitted })), access: { allowed: ev.allowed, reasons: ev.reasons }, expires_at: s.expires_at }; },
  fn_guest_submit: ({ p_token, p_guest_id, p_payload }) => { const s = T("registration_sessions").find((x) => x.token === p_token); if (!s) throw new Error("TOKEN_INVALID"); const r = byId("reservations", s.reservation_id)!; const p = p_payload ?? {}; if (!p.full_name || p.full_name.trim().split(/\s+/).length < 3) throw new Error("VALIDATION: full_name_three_parts"); if (!/^[12]\d{9}$/.test(String(p.identity_number ?? "")) && ["national_id", "iqama"].includes(p.identity_type)) throw new Error("VALIDATION: identity_number_format"); if (String(p.consent) !== "true") throw new Error("VALIDATION: consent_required"); let g = p_guest_id ? byId("reservation_guests", p_guest_id) : null; if (!g) { const n = T("reservation_guests").filter((x) => x.reservation_id === r.id).length; if (n >= r.adults + r.companions) throw new Error("GUEST_LIMIT_REACHED"); g = { id: uid(), reservation_id: r.id, guest_profile_id: null, is_primary: n === 0, full_name: "", identity_type: null, identity_number_last4: null, nationality: null, birth_date: null, phone: null, relationship: null, verification_status: "not_started", data_submitted: false, created_at: nowISO() }; T("reservation_guests").push(g); } if (g.verification_status === "verified") throw new Error("GUEST_ALREADY_VERIFIED"); Object.assign(g, { full_name: p.full_name, identity_type: p.identity_type, identity_number_last4: String(p.identity_number ?? "").slice(-4), nationality: p.nationality, birth_date: p.birth_date, relationship: p.relationship ?? null, phone: p.phone ?? g.phone, verification_status: "data_submitted", data_submitted: true }); const all = T("reservation_guests").filter((x) => x.reservation_id === r.id); r.identity_status = all.length >= r.adults + r.companions && all.every((x) => x.data_submitted) ? "pending_supervisor" : "data_submitted"; emit("reservation_guests"); emit("reservations"); return { ok: true, guest_id: g.id }; },
  fn_guest_submit_checkin: ({ p_token }) => { const s = T("registration_sessions").find((x) => x.token === p_token); if (!s) throw new Error("TOKEN_INVALID"); const r = byId("reservations", s.reservation_id)!; if (r.access_status === "locked") r.access_status = "eligibility_review"; emit("reservations"); return { ok: true, access_status: r.access_status }; },
  fn_guest_access_code: ({ p_token }) => { const s = T("registration_sessions").find((x) => x.token === p_token); if (!s) throw new Error("TOKEN_INVALID"); const r = byId("reservations", s.reservation_id)!; const ev = evaluate(r.id); if (!ev.allowed || !["delivered", "acknowledged"].includes(r.access_status)) return { allowed: false, reasons: ev.allowed ? ["لم يُسلَّم الرمز بعد"] : ev.reasons }; return { allowed: true, code: "4" + String(1000 + (r.internal_ref.charCodeAt(2) * 7) % 8999), room_number: roomNo(r.room_id) }; },
  ...knowledgeRpcs({ T, byId, me, myBranches, hasRole, requireRole, requireBranch, checkVersion, audit, emit, staffId }),

  // ---- WhatsApp per branch (0021): settings only — the demo sends nothing ----
  fn_admin_whatsapp_channels: () => { requireRole("owner"); return T("branches").filter((b) => !b.archived_at).map((b) => { const c = T("branch_whatsapp_channels").find((x) => x.branch_id === b.id); return { branch_id: b.id, branch_name: b.name_ar, branch_phone: b.phone, enabled: !!c?.enabled, display_phone: c?.display_phone ?? null, phone_number_id: c?.phone_number_id ?? null, waba_id: c?.waba_id ?? null, has_token: !!c?.has_token, token_last4: c?.token_last4 ?? null, has_app_secret: !!c?.has_app_secret, verify_token: c?.verify_token ?? null, otp_template: c?.otp_template ?? null, template_lang: c?.template_lang ?? "ar", status: c?.status ?? "not_configured", last_error: c?.last_error ?? null, last_checked_at: c?.last_checked_at ?? null, verified_name: c?.verified_name ?? null, updated_at: c?.updated_at ?? null }; }); },
  fn_admin_whatsapp_save: ({ p_branch, p }) => { requireRole("owner"); if (!byId("branches", p_branch)) throw new Error("NOT_FOUND: branch");
    let c = T("branch_whatsapp_channels").find((x) => x.branch_id === p_branch); if (!c) { c = { branch_id: p_branch, organization_id: ORG, enabled: false, display_phone: null, phone_number_id: null, waba_id: null, has_token: false, token_last4: null, has_app_secret: false, verify_token: "demo-" + uid().replace(/-/g, ""), otp_template: null, template_lang: "ar", status: "not_configured", last_error: null, last_checked_at: null, verified_name: null, created_at: nowISO() }; T("branch_whatsapp_channels").push(c); }
    const changed: string[] = [];
    if ("display_phone" in p) { const v = String(p.display_phone ?? "").trim() ? normPhone(p.display_phone) : null; if (String(p.display_phone ?? "").trim() && !v) throw new Error("VALIDATION: display_phone"); if (v !== c.display_phone) { c.display_phone = v; changed.push("display_phone"); } }
    if ("phone_number_id" in p) { const v = String(p.phone_number_id ?? "").trim() || null; if (v && !/^\d{5,30}$/.test(v)) throw new Error("VALIDATION: phone_number_id"); if (v && T("branch_whatsapp_channels").some((x) => x.phone_number_id === v && x.branch_id !== p_branch)) throw new Error("VALIDATION: phone_number_id already used by another branch"); if (v !== c.phone_number_id) { c.phone_number_id = v; changed.push("phone_number_id"); } }
    if ("waba_id" in p) c.waba_id = String(p.waba_id ?? "").trim() || null;
    if ("otp_template" in p) c.otp_template = String(p.otp_template ?? "").trim().toLowerCase() || null;
    if ("template_lang" in p) c.template_lang = String(p.template_lang ?? "").trim() || "ar";
    const tok = String(p.access_token ?? "").trim(); if (tok) { if (tok.length < 20 || /\s/.test(tok)) throw new Error("VALIDATION: access_token"); c.has_token = true; c.token_last4 = tok.slice(-4); changed.push("access_token"); }
    const sec = String(p.app_secret ?? "").trim(); if (sec) { if (sec.length < 16 || /\s/.test(sec)) throw new Error("VALIDATION: app_secret"); c.has_app_secret = true; changed.push("app_secret"); }
    if (p.regenerate_verify_token) { c.verify_token = "demo-" + uid().replace(/-/g, ""); changed.push("verify_token"); }
    const complete = !!(c.display_phone && c.phone_number_id && c.has_token && c.has_app_secret);
    if (changed.some((k) => ["display_phone", "phone_number_id", "access_token", "app_secret"].includes(k))) { c.status = "configured"; c.last_error = null; c.verified_name = null; }
    if (!complete) c.status = "not_configured"; else if (c.status === "not_configured") c.status = "configured";
    if ("enabled" in p) { if (p.enabled && !complete) throw new Error("VALIDATION: channel_incomplete"); c.enabled = !!p.enabled; changed.push("enabled"); }
    if (!complete) c.enabled = false;
    c.updated_at = nowISO(); emit("branch_whatsapp_channels"); audit(p_branch, "whatsapp_channel_updated", "branch", p_branch, { changed, enabled: c.enabled, status: c.status });
    return { ok: true, status: c.status, enabled: c.enabled, changed }; },
  fn_public_whatsapp: ({ p_branch }) => { const b = byId("branches", p_branch); if (!b || !b.is_active || b.archived_at) return null; const c = T("branch_whatsapp_channels").find((x) => x.branch_id === p_branch); const active = !!c?.enabled && ["configured", "active"].includes(c.status); return { active, wa_phone: active ? c!.display_phone : null, branch_name: b.name_ar, branch_phone: b.phone }; },

  // ---- data purge (0022): the same kinds, period and three confirmations; the demo resets with the seed ----
  fn_admin_purge_preview: ({ p_branch, p_from, p_to, p_categories }) => { requireRole("owner"); const cats = purgeValidate(p_branch, p_from, p_to, p_categories); const snapshot = JSON.stringify(S); const counts = purgeRun(p_branch, p_from, p_to, cats); S = JSON.parse(snapshot); const token = "PURGE" + uid().replace(/-/g, ""); purgeRequests.set(token, { branch: p_branch ?? null, from: p_from, to: p_to, cats, staff: staffId(), expires: Date.now() + 15 * 60_000, used: false }); return { request_id: uid(), token, counts, categories: cats, phrase: "احذف نهائيا", expires_in_minutes: 15 }; },
  fn_admin_purge_execute: ({ p_token, p_phrase }) => { requireRole("owner"); const q = purgeRequests.get(p_token); if (!q || q.used || q.expires < Date.now()) throw new Error("VALIDATION: preview_expired"); if (q.staff !== staffId()) throw new Error("FORBIDDEN: only the owner who previewed can confirm"); if (String(p_phrase ?? "").replace(/[\u064B-\u0652]/g, "").trim() !== "احذف نهائيا") throw new Error("VALIDATION: confirmation_phrase"); if (Date.now() - lastSignInAt > 10 * 60_000) throw new Error("REAUTH_REQUIRED: sign in again to confirm"); const counts = purgeRun(q.branch, q.from, q.to, q.cats); q.used = true; emitAll(); audit(q.branch, "data_purge_executed", "organization", ORG, { from: q.from, to: q.to, categories: q.cats, counts }); purgeHistory.unshift({ id: uid(), branch_name: q.branch ? byId("branches", q.branch)?.name_ar ?? null : null, from: q.from, to: q.to, categories: q.cats, counts, executed_at: nowISO(), by: me()?.full_name ?? null }); return { ok: true, counts }; },
  fn_admin_purge_history: () => { requireRole("owner"); return purgeHistory; },
};
Object.assign(rpcs, rpcsMore);

// ---- data purge (demo): same rules as fn_purge_run in 0022 ----
const purgeRequests = new Map<string, { branch: string | null; from: string; to: string; cats: string[]; staff: string | null; expires: number; used: boolean }>();
const purgeHistory: Row[] = [];
let lastSignInAt = Date.now();
const PURGE_KINDS = ["conversations", "reservations", "finance", "guests", "operations", "logs", "audit"];
function purgeValidate(branch: string | null, from: string, to: string, cats: string[]): string[] {
  if (!from || !to || from > to) throw new Error("VALIDATION: period");
  if (to > branchToday()) throw new Error("VALIDATION: period_after_today");
  if (branch && !byId("branches", branch)) throw new Error("NOT_FOUND: branch");
  const c = [...new Set(cats ?? [])].sort(); if (!c.length) throw new Error("VALIDATION: choose_category"); if (c.some((x) => !PURGE_KINDS.includes(x))) throw new Error("VALIDATION: unknown_category");
  return c;
}
function purgeRun(branch: string | null, from: string, to: string, cats: string[]): Record<string, number> {
  const inBranch = (b: string | null | undefined) => (branch ? b === branch : true);
  const day = (iso: unknown) => String(iso ?? "").slice(0, 10);
  const inRange = (iso: unknown) => day(iso) >= from && day(iso) <= to;
  const has = (k: string) => cats.includes(k);
  const c: Record<string, number> = {};
  const drop = (table: string, pred: (r: Row) => boolean) => { const before = T(table).length; S[table] = T(table).filter((r) => !pred(r)); return before - T(table).length; };
  const finished = (r: Row) => ["checked_out", "closed", "cancelled", "rejected", "no_show"].includes(r.status) || (["draft", "pending_verification", "confirmed"].includes(r.status) && r.check_out < branchToday());
  let res = T("reservations").filter((r) => inBranch(r.branch_id) && r.check_in >= from && r.check_in <= to && finished(r)).map((r) => r.id);
  const money = (id: string) => T("financial_vouchers").some((v) => v.reservation_id === id) || T("invoices").some((v) => v.reservation_id === id) || T("reservation_charges").some((v) => v.reservation_id === id);
  if (has("reservations")) {
    const skipped = has("finance") ? [] : res.filter(money); c.reservations_skipped_with_money = skipped.length; res = res.filter((id) => !skipped.includes(id));
    c.reservations_kept_active_or_with_money = T("reservations").filter((r) => inBranch(r.branch_id) && r.check_in >= from && r.check_in <= to && !res.includes(r.id)).length;
  }
  if (has("conversations")) {
    const conv = T("conversations").filter((x) => inBranch(x.branch_id) && inRange(x.created_at)).map((x) => x.id);
    c.conversation_messages = drop("conversation_messages", (m) => conv.includes(m.conversation_id));
    c.handoff_tickets = drop("human_handoff_tickets", (t) => inBranch(t.branch_id) && inRange(t.created_at));
    c.conversations = drop("conversations", (x) => conv.includes(x.id));
    c.staff_assistant_chats = drop("ai_ops_conversations", (x) => inBranch(x.branch_id) && inRange(x.created_at));
    c.unanswered_questions = drop("unanswered_questions", (x) => inBranch(x.branch_id) && inRange(x.last_asked_at));
  }
  if (has("operations")) {
    c.housekeeping_tasks = drop("housekeeping_tasks", (x) => inBranch(x.branch_id) && inRange(x.created_at) && ["completed", "cancelled"].includes(x.status));
    c.maintenance_tickets = drop("maintenance_tickets", (x) => inBranch(x.branch_id) && inRange(x.created_at) && x.status === "resolved");
    c.released_slots = drop("released_slots", (x) => inBranch(x.branch_id) && x.date >= from && x.date <= to && x.date < branchToday());
  }
  if (has("finance")) {
    const ok = (rid: string | null) => !rid || res.includes(rid);
    c.vouchers = drop("financial_vouchers", (v) => inBranch(v.branch_id) && ok(v.reservation_id) && (inRange(v.occurred_at ?? v.created_at) || (has("reservations") && res.includes(v.reservation_id))));
    c.payments = drop("payment_transactions", (p) => res.includes(p.reservation_id) && (inRange(p.created_at) || has("reservations")));
    c.invoices = drop("invoices", (i) => inBranch(i.branch_id) && ok(i.reservation_id) && (inRange(i.issued_at) || (has("reservations") && res.includes(i.reservation_id))));
  }
  if (has("reservations")) {
    for (const t of ["reservation_guests", "reservation_charges", "reservation_allocations", "registration_sessions", "access_release_requests", "access_delivery_events", "payment_transactions"]) drop(t, (x) => res.includes(x.reservation_id));
    c.reservations = drop("reservations", (r) => res.includes(r.id));
  }
  if (has("guests")) c.guest_profiles = drop("guest_profiles", (g) => !T("reservation_guests").some((x) => x.guest_profile_id === g.id) && (!branch && inRange(g.created_at)));
  if (has("logs")) { c.notifications = drop("notifications", (n) => inBranch(n.branch_id) && inRange(n.created_at)); if (!branch) c.integration_events = drop("integration_events", (e) => inRange(e.created_at)); }
  if (has("audit")) c.audit_events = drop("audit_events", (a) => inBranch(a.branch_id) && inRange(a.created_at));
  return c;
}

const TABLE_OF: Record<string, string> = { branch: "branches", block: "blocks", floor: "floors", room_category: "room_categories", room: "rooms", facility: "facilities", task_type: "task_types", service: "service_definitions" };
function upsertDef(table: string, entity: string, p: Row, fields: string[], validate: (x: Row) => void, uniqueOn: string[], scopeCol = "branch_id") {
  requireRole("owner", "manager"); validate(p); const rows = T(table);
  if (!p.id) { requireBranch(p.branch_id); const scopeVal = scopeCol === "block_id" ? p.block_id : p.branch_id; for (const u of uniqueOn) if (rows.some((x) => x[scopeCol] === scopeVal && String(x[u]).trim() === String(p[u]).trim())) throw new Error("DUPLICATE_NAME"); const r: Row = { id: uid(), organization_id: ORG, branch_id: p.branch_id, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, sort_order: 0, created_by: staffId(), created_at: nowISO(), updated_at: nowISO() }; for (const f of fields) if (p[f] !== undefined) r[f] = p[f]; if (table === "service_definitions") Object.assign(r, { billing_unit: r.billing_unit ?? "once", price_halalas: r.price_halalas ?? 0, is_free: !!r.is_free, taxable: r.taxable ?? true, task_type_id: r.task_type_id ?? null }); if (table === "room_categories") Object.assign(r, { base_capacity: r.base_capacity ?? 2, max_capacity: r.max_capacity ?? 4, base_price_halalas: r.base_price_halalas ?? 0, amenities: r.amenities ?? [], is_public: r.is_public ?? true, images: [] }); if (table === "facilities") r.images = r.images ?? []; rows.push(r); emit(table); audit(r.branch_id, entity + ".created", entity, r.id, { after: r }); return { ok: true, id: r.id, version: 1 }; }
  const r = byId(table, p.id); if (!r) throw new Error("NOT_FOUND"); requireBranch(r.branch_id); checkVersion(r.version, p.version); const before = { ...r }; const scopeVal = r[scopeCol];
  for (const u of uniqueOn) if (p[u] !== undefined && rows.some((x) => x.id !== r.id && x[scopeCol] === scopeVal && String(x[u]).trim() === String(p[u]).trim())) throw new Error("DUPLICATE_NAME");
  for (const f of fields) if (p[f] !== undefined) r[f] = p[f]; r.version++; r.updated_at = nowISO(); emit(table); audit(r.branch_id, entity + ".updated", entity, r.id, { before, after: r }); return { ok: true, id: r.id, version: r.version };
}
function deps(entity: string, id: string): Record<string, number> {
  const n = (t: string, f: (r: Row) => boolean) => T(t).filter(f).length;
  switch (entity) {
    case "branch": return { rooms: n("rooms", (r) => r.branch_id === id), room_categories: n("room_categories", (r) => r.branch_id === id), reservations: n("reservations", (r) => r.branch_id === id), staff: n("branch_memberships", (r) => r.branch_id === id), blocks: n("blocks", (r) => r.branch_id === id), facilities: n("facilities", (r) => r.branch_id === id), vouchers: n("financial_vouchers", (r) => r.branch_id === id) };
    case "block": return { floors: n("floors", (r) => r.block_id === id), rooms: n("rooms", (r) => r.block_id === id), facilities: n("facilities", (r) => r.block_id === id) };
    case "floor": return { rooms: n("rooms", (r) => r.floor_id === id), facilities: n("facilities", (r) => r.floor_id === id) };
    case "room_category": return { rooms: n("rooms", (r) => r.category_id === id), reservations: n("reservations", (r) => r.room_category_id === id) };
    case "room": return { reservations: n("reservations", (r) => r.room_id === id), allocations: n("reservation_allocations", (r) => r.room_id === id), tasks: n("housekeeping_tasks", (r) => r.room_id === id), keyboxes: n("keyboxes", (r) => r.room_id === id) };
    case "facility": return { tasks: n("housekeeping_tasks", (r) => r.facility_id === id) };
    case "task_type": return { tasks: n("housekeeping_tasks", (r) => r.task_type_id === id), services: n("service_definitions", (r) => r.task_type_id === id) };
    case "service": return { charges: n("reservation_charges", (r) => r.service_definition_id === id) };
    default: throw new Error("VALIDATION: entity");
  }
}
function openCommitments(entity: string, id: string) {
  const today = branchToday();
  if (entity === "room") return T("reservation_allocations").filter((a) => a.room_id === id && a.status === "active" && a.to_date > today && ["confirmed", "checked_in", "pending_verification"].includes(byId("reservations", a.reservation_id)?.status)).length;
  if (entity === "facility") return T("housekeeping_tasks").filter((h) => h.facility_id === id && ["pending", "in_progress"].includes(h.status)).length;
  if (entity === "task_type") return T("housekeeping_tasks").filter((h) => h.task_type_id === id && ["pending", "in_progress"].includes(h.status)).length;
  if (entity === "block") return T("rooms").filter((r) => r.block_id === id && !r.archived_at).length;
  if (entity === "floor") return T("rooms").filter((r) => r.floor_id === id && !r.archived_at).length;
  if (entity === "room_category") return T("rooms").filter((r) => r.category_id === id && !r.archived_at).length;
  if (entity === "branch") { if (T("branches").filter((b) => !b.archived_at && b.is_active).length <= 1) throw new Error("LAST_ACTIVE_BRANCH"); return T("reservations").filter((r) => r.branch_id === id && ["confirmed", "checked_in", "pending_verification"].includes(r.status) && r.check_out > today).length; }
  return 0;
}
function staffInBranch(sid: string, branch: string) { const s = byId("staff_profiles", sid); return !!s && s.is_active && (s.role === "owner" || T("branch_memberships").some((m) => m.staff_id === sid && m.branch_id === branch)); }
function quote(branch: string, category: string, ci: string, co: string, override: number | null, discount: number) {
  requireBranch(branch); if (co <= ci) throw new Error("VALIDATION: dates"); const cat = byId("room_categories", category); if (!cat || cat.branch_id !== branch) throw new Error("BRANCH_MISMATCH: category");
  const nights = Math.round((Date.parse(co) - Date.parse(ci)) / 86400000); const rate = override ?? cat.base_price_halalas; if (rate < 0 || discount < 0) throw new Error("VALIDATION: amount");
  const rent = applyTax(branch, rate * nights, true); const disc = applyTax(branch, -discount, true); const b = byId("branches", branch)!;
  return { nights, nightly_rate: rate, rent: rent.net, discount: disc.net, tax: rent.tax + disc.tax, total: rent.net + disc.net + rent.tax + disc.tax, tax_rate_bp: b.tax_rate_bp, prices_include_tax: b.prices_include_tax };
}
function roomAvailablePublic(roomId: string, from: string, to: string) { const rm = byId("rooms", roomId)!; if (["blocked", "out_of_service", "maintenance"].includes(rm.status)) return false; return !T("reservation_allocations").some((a) => a.room_id === roomId && a.status === "active" && overlaps(a.from_date, a.to_date, from, to)); }
function evaluate(resId: string, skipSupervisor = false) {
  const r = byId("reservations", resId)!; const reasons: string[] = []; const today = branchToday();
  if (!["confirmed", "checked_in"].includes(r.status)) reasons.push("الحجز غير مؤكد");
  if (r.security_hold) reasons.push("يوجد حظر أمني");
  if (today < r.check_in || today >= r.check_out) reasons.push("التاريخ الحالي خارج فترة الإقامة");
  const guests = T("reservation_guests").filter((g) => g.reservation_id === r.id); if (guests.length < r.adults + r.companions) reasons.push("عدد النزلاء المسجلين أقل من المطلوب");
  if (r.identity_status !== "verified") reasons.push("لم تكتمل مطابقة الهوية");
  if (r.payment_status !== "paid") reasons.push("لم يتم استيفاء السداد المطلوب");
  if (!r.government_registration) reasons.push("لم يتم تأكيد التسجيل النظامي");
  if (!r.room_id) reasons.push("لم يتم تخصيص غرفة"); else { const rm = byId("rooms", r.room_id)!; if (!["ready", "reserved", "occupied"].includes(rm.status) || (rm.status === "occupied" && r.status !== "checked_in")) reasons.push("الغرفة غير جاهزة"); const kb = T("keyboxes").find((k) => k.room_id === r.room_id); if (!kb) reasons.push("لا يوجد صندوق مفتاح للغرفة"); else if (kb.code_status !== "active") reasons.push("رمز الصندوق يحتاج إلى تغيير"); else if (!kb.field_tested) reasons.push("لم يتم اختبار رمز الصندوق ميدانيًا"); }
  if (!skipSupervisor && !["approved", "delivery_pending", "delivered", "acknowledged"].includes(r.access_status)) reasons.push("لم يعتمد المشرف الدخول النهائي");
  return { allowed: reasons.length === 0, reasons };
}
function summary(branch: string, date: string) {
  if (!myBranches().includes(branch)) return null; const rooms = T("rooms").filter((r) => r.branch_id === branch && !r.archived_at); const res = T("reservations").filter((r) => r.branch_id === branch); const hk = T("housekeeping_tasks").filter((h) => h.branch_id === branch); const v = T("financial_vouchers").filter((x) => x.branch_id === branch && x.status === "approved");
  const active = rooms.filter((r) => r.is_active).length, occupied = rooms.filter((r) => r.status === "occupied").length;
  return { date, units: { active, occupied, reserved: rooms.filter((r) => r.status === "reserved").length, ready: rooms.filter((r) => r.status === "ready").length, dirty: rooms.filter((r) => r.is_active && r.cleanliness !== "clean").length, maintenance: rooms.filter((r) => r.status === "maintenance").length, out_of_service: rooms.filter((r) => r.status === "out_of_service" || !r.is_active).length },
    occupancy_pct: active ? Math.round((1000 * occupied) / active) / 10 : 0,
    arrivals: { expected: res.filter((r) => r.check_in === date && ["confirmed", "pending_verification"].includes(r.status)).length, arrived: res.filter((r) => r.check_in === date && r.status === "checked_in").length, pending_identity: res.filter((r) => r.check_in <= date && r.check_out > date && ["confirmed", "pending_verification"].includes(r.status) && r.identity_status !== "verified").length, unpaid: res.filter((r) => r.check_in === date && ["confirmed", "pending_verification"].includes(r.status) && r.balance_due_halalas > 0).length, overdue: res.filter((r) => r.check_in < date && ["confirmed", "pending_verification"].includes(r.status)).length },
    departures: { expected: res.filter((r) => r.check_out === date && r.status === "checked_in").length, done: res.filter((r) => r.check_out === date && r.status === "checked_out").length, overstay: res.filter((r) => r.check_out < date && r.status === "checked_in").length, with_balance: res.filter((r) => r.check_out === date && r.status === "checked_in" && r.balance_due_halalas > 0).length },
    housekeeping: { open: hk.filter((h) => h.status === "pending").length, in_progress: hk.filter((h) => h.status === "in_progress").length, completed_today: hk.filter((h) => h.status === "completed" && (h.completed_at ?? "").slice(0, 10) === date).length, unassigned: hk.filter((h) => h.status === "pending" && !h.assignee_id).length },
    finance: { received_today: v.filter((x) => x.kind === "receipt" && x.occurred_at.slice(0, 10) === date).reduce((a, x) => a + x.amount_halalas, 0), refunded_today: v.filter((x) => x.kind === "refund" && x.occurred_at.slice(0, 10) === date).reduce((a, x) => a + x.amount_halalas, 0), deposits_held: res.filter((r) => ["confirmed", "checked_in", "checked_out"].includes(r.status)).reduce((a, r) => a + r.deposit_balance_halalas, 0), outstanding_in_house: res.filter((r) => r.status === "checked_in").reduce((a, r) => a + r.balance_due_halalas, 0), deposit_to_settle_after_checkout: res.filter((r) => r.status === "checked_out" && r.deposit_balance_halalas > 0).reduce((a, r) => a + r.deposit_balance_halalas, 0) },
    tickets_open: T("human_handoff_tickets").filter((t) => t.branch_id === branch && t.status === "open").length, generated_at: nowISO() };
}
function opsContext(branch: string, date: string) {
  if (!myBranches().includes(branch)) return null; const res = T("reservations").filter((r) => r.branch_id === branch); const b = byId("branches", branch)!;
  const rs = (r: Row) => ({ reservation_id: r.id, ref: r.internal_ref, guest: guestName(r.id), status: r.status, room: roomNo(r.room_id), category: byId("room_categories", r.room_category_id)?.name_ar, nights: Math.round((Date.parse(r.check_out) - Date.parse(r.check_in)) / 86400000), identity_status: r.identity_status, payment_status: r.payment_status, balance_due: r.balance_due_halalas, deposit_balance: r.deposit_balance_halalas, access_status: r.access_status, check_in: r.check_in, check_out: r.check_out, days_late: Math.round((Date.parse(date) - Date.parse(r.check_in)) / 86400000), days_over: Math.round((Date.parse(date) - Date.parse(r.check_out)) / 86400000), checked_out_at: r.actual_check_out, source: byId("booking_sources", r.source_id)?.name });
  return { branch: { id: b.id, name: b.name_ar, check_in_time: b.check_in_time, check_out_time: b.check_out_time }, summary: summary(branch, date),
    arrivals: res.filter((r) => r.check_in === date && ["confirmed", "pending_verification", "checked_in"].includes(r.status)).map(rs), overdue_arrivals: res.filter((r) => r.check_in < date && ["confirmed", "pending_verification"].includes(r.status)).map(rs),
    departures: res.filter((r) => r.check_out === date && r.status === "checked_in").map(rs), overstays: res.filter((r) => r.check_out < date && r.status === "checked_in").map(rs),
    in_house_with_balance: res.filter((r) => r.status === "checked_in" && r.balance_due_halalas > 0).map(rs), checked_out_with_deposit: res.filter((r) => r.status === "checked_out" && r.deposit_balance_halalas > 0).map(rs),
    units_needing_attention: T("rooms").filter((r) => r.branch_id === branch && r.is_active && !r.archived_at && (r.cleanliness !== "clean" || ["cleaning", "maintenance"].includes(r.status))).map((r) => { const kb = T("keyboxes").find((k) => k.room_id === r.id); const next = T("reservation_allocations").filter((a) => a.room_id === r.id && a.status === "active" && a.from_date >= date && ["confirmed", "pending_verification"].includes(byId("reservations", a.reservation_id)?.status)).map((a) => a.from_date).sort()[0] ?? null; return { room_id: r.id, room: r.room_number, status: r.status, cleanliness: r.cleanliness, open_tasks: T("housekeeping_tasks").filter((h) => h.room_id === r.id && ["pending", "in_progress"].includes(h.status)).length, keybox_ready: !!kb && kb.code_status === "active" && kb.field_tested, next_arrival: next }; }),
    open_tasks: T("housekeeping_tasks").filter((h) => h.branch_id === branch && ["pending", "in_progress"].includes(h.status)).map((h) => ({ task_id: h.id, target: roomNo(h.room_id) ?? byId("facilities", h.facility_id)?.name, type: h.task_type_name_snapshot, priority: h.priority, status: h.status, assignee: byId("staff_profiles", h.assignee_id)?.full_name ?? null, since: h.created_at })),
    open_tickets: T("human_handoff_tickets").filter((t) => t.branch_id === branch && t.status === "open").map((t) => ({ ticket_id: t.id, kind: t.kind, created_at: t.created_at })),
    staff_on_branch: T("staff_profiles").filter((s) => s.is_active && staffInBranch(s.id, branch)).map((s) => ({ staff_id: s.id, name: s.full_name, role: s.role })), generated_at: nowISO() };
}
function findRes(branch: string, q: string) { const ql = q.toLowerCase(); return T("reservations").filter((r) => r.branch_id === branch && (r.internal_ref.toLowerCase().includes(ql) || (r.external_ref ?? "").toLowerCase().includes(ql) || (guestName(r.id) ?? "").toLowerCase().includes(ql) || roomNo(r.room_id) === q)).slice(0, 8).map((r) => ({ reservation_id: r.id, ref: r.internal_ref, external_ref: r.external_ref, guest: guestName(r.id), status: r.status, check_in: r.check_in, check_out: r.check_out, room: roomNo(r.room_id), category_id: r.room_category_id, balance_due: r.balance_due_halalas, deposit_balance: r.deposit_balance_halalas, payment_status: r.payment_status, identity_status: r.identity_status, version: r.version })); }

// ---------------------------------------------------------------------------
// edge functions (deterministic in the demo — no provider)
// ---------------------------------------------------------------------------
function opsChat(body: any) {
  const branch = body.branch_id; const m = me(); if (!m) return { error: { message: "forbidden" } }; const ctx = rpcs.fn_ai_ops_context({ p_branch: branch }); if (!ctx) return { error: { message: "forbidden" } };
  let conv = body.conversation_id ? byId("ai_ops_conversations", body.conversation_id) : null; if (!conv) { conv = { id: uid(), organization_id: ORG, branch_id: branch, staff_id: m.id, title: String(body.message).slice(0, 60), created_at: nowISO(), last_message_at: nowISO() }; T("ai_ops_conversations").push(conv); }
  const message = String(body.message ?? ""); T("ai_ops_messages").push({ id: uid(), conversation_id: conv.id, sender: "staff", content: message, meta: null, created_at: nowISO() });
  const proposals: Array<{ id: string; action: string; summary: string; args: Row }> = []; let reply: string | null = null;
  // light intent parsing so the confirmation flow can be demonstrated without a model
  const roomMatch = message.match(/(?:وحدة|غرفة|room)\s*([A-Za-z]?-?\d{1,4})/i); const room = roomMatch ? T("rooms").find((r) => r.branch_id === branch && r.room_number.replace("-", "").toLowerCase() === roomMatch[1].replace("-", "").toLowerCase()) : null;
  const refMatch = message.match(/R-[0-9A-Z]{6,10}/i); const res = refMatch ? T("reservations").find((r) => r.internal_ref.toLowerCase() === refMatch[0].toLowerCase()) : null;
  if (room && /(مهمة|تنظيف|نظف)/.test(message)) { const p = rpcs.fn_ai_ops_propose({ p_conversation: conv.id, p_action: "create_task", p_args: { room_id: room.id, task_type_id: roomCleaningType(branch).id, priority: /عاجل|مرتفع/.test(message) ? "high" : "medium", description: "بناءً على طلب في المحادثة" }, p_summary: `إنشاء مهمة تنظيف للوحدة ${room.room_number}. الأثر: تصبح الوحدة «متسخة» حتى إتمام المهمة؛ لا يتغير إشغالها.` }); proposals.push({ id: p.proposal_id, action: "create_task", summary: `إنشاء مهمة تنظيف للوحدة ${room.room_number}`, args: {} }); reply = `جهّزت اقتراحًا بإنشاء مهمة تنظيف للوحدة ${room.room_number} (حالتها الآن: ${room.cleanliness === "clean" ? "نظيفة" : "تحتاج تنظيفًا"}). أكّد من البطاقة ليُنفذ بصلاحيتك.`; }
  else if (res && /(مدد|تمديد|extend)/.test(message)) { const n = Number((message.match(/(\d+)\s*(ليلة|ليالي|night)/) ?? [])[1] ?? 1); const newOut = addDays(res.check_out, n); const p = rpcs.fn_ai_ops_propose({ p_conversation: conv.id, p_action: "amend_stay", p_args: { reservation_id: res.id, new_check_out: newOut, pricing_mode: "keep_rate", reason: "طلب في المحادثة" }, p_summary: `تمديد الحجز ${res.internal_ref} ${n} ليلة حتى ${newOut} بسعر الليلة المتفق عليه. الأثر: يُفحص تعارض الوحدة أولًا ثم يُضاف بند إيجار ويُعاد حساب الإجمالي.` }); proposals.push({ id: p.proposal_id, action: "amend_stay", summary: `تمديد ${res.internal_ref} ${n} ليلة حتى ${newOut}`, args: {} }); reply = `الحجز ${res.internal_ref} (${guestName(res.id)}) مغادرته الحالية ${res.check_out} والمتبقي عليه ${(res.balance_due_halalas / 100).toFixed(2)} ر.س. أعددت اقتراح تمديد ${n} ليلة؛ التعارض مع حجز آخر على الوحدة يُفحص عند التنفيذ.`; }
  else if (res) { const f = financeOf(res.id); reply = `${res.internal_ref} — ${guestName(res.id)} — ${res.status === "checked_in" ? "مقيم" : res.status} — وحدة ${roomNo(res.room_id) ?? "غير مخصصة"} — ${res.check_in} → ${res.check_out}\nالإجمالي ${(f.total / 100).toFixed(2)} ر.س، المحصل ${(f.net_collected / 100).toFixed(2)}، المتبقي ${(f.balance_due / 100).toFixed(2)}، رصيد التأمين ${(f.deposit_balance / 100).toFixed(2)} ر.س.`; }
  else reply = fallbackOpsReply(message, ctx);
  T("ai_ops_messages").push({ id: uid(), conversation_id: conv.id, sender: "assistant", content: reply, meta: { mode: "deterministic" }, created_at: nowISO() }); conv.last_message_at = nowISO(); persist();
  return { data: { conversation_id: conv.id, reply, proposals, mode: "deterministic", ai_status: "demo" } };
}

// ---- phone-first lookup helpers (mirror fn_normalize_phone / fn_phone_reservation_ids) ----
const phoneSessions = new Map<string, string>();
function normPhone(p: unknown): string | null {
  let d = String(p ?? "").replace(/[٠-٩]/g, (x) => String("٠١٢٣٤٥٦٧٨٩".indexOf(x))).replace(/\D/g, "");
  if (d.startsWith("00")) d = d.slice(2);
  if (/^05\d{8}$/.test(d)) return "966" + d.slice(1);
  if (/^5\d{8}$/.test(d)) return "966" + d;
  if (/^9665\d{8}$/.test(d)) return d;
  if (d.startsWith("966")) return null;
  return d.length >= 8 && d.length <= 15 ? d : null;
}
function phoneReservationIds(ph: string): string[] {
  return T("reservations").filter((r) => r.status !== "rejected" && T("reservation_guests").some((g) => g.reservation_id === r.id && g.is_primary && normPhone(g.phone) === ph)).map((r) => r.id);
}
function invoke(name: string, opts: any) {
  const body = opts?.body ?? {};
  if (name === "guest-otp") return { data: { status: "channel_unavailable" }, error: null };
  // WhatsApp (demo): the connection test answers from the demo row; a supervisor's reply is stored but nothing is sent
  if (name === "whatsapp-send") {
    if (body.mode === "check") { if (!hasRole("owner")) return { data: null, error: { message: "forbidden" } }; const ch = T("branch_whatsapp_channels").find((x) => x.branch_id === body.branch_id); if (!ch || ch.status === "not_configured") return { data: { ok: false, error: "channel_incomplete" }, error: null }; Object.assign(ch, { last_checked_at: nowISO() }); return { data: { ok: false, error: "وضع العرض التجريبي — لا اتصال حقيقي بـ Meta" }, error: null }; }
    const conv = byId("conversations", body.conversation_id); if (!conv) return { data: null, error: { message: "forbidden" } };
    T("conversation_messages").push({ id: uid(), conversation_id: conv.id, sender: "supervisor", content: String(body.text ?? ""), meta: { channel: "whatsapp", delivery: "failed", error: "demo" }, created_at: nowISO() }); emit("conversation_messages");
    return { data: { ok: true, delivered: false, error: "channel_unavailable" }, error: null };
  }
  if (name === "ai-health") return { data: { configured: false, ok: false, model: null, error: "وضع العرض التجريبي — لا مزود متصل" }, error: null };
  if (name === "ai-ops") { if (body.mode === "briefing") { const ctx = rpcs.fn_ai_ops_context({ p_branch: body.branch_id, p_date: body.date ?? null }); if (!ctx) return { data: null, error: { message: "forbidden" } }; const b = buildBriefing(ctx); return { data: { ...b, insights: null, mode: "deterministic", ai_status: "demo", generated_at: ctx.generated_at, date: ctx.summary?.date }, error: null }; } const r = opsChat(body); return r.error ? { data: null, error: r.error } : { data: r.data, error: null }; }
  if (name === "ai-reception") { const branch = body.branch_id ?? T("branches")[0]?.id; let conv = body.conversation_id ? byId("conversations", body.conversation_id) : null; if (!conv) { conv = { id: uid(), reservation_id: null, channel: "screen", status: "active", branch_id: branch, guest_token: body.guest_token ?? null, client_fingerprint: body.client_fingerprint ?? null, created_at: nowISO(), last_message_at: nowISO(), handed_off_at: null, handoff_reason: null }; T("conversations").unshift(conv); } const msg = String(body.message ?? ""); T("conversation_messages").push({ id: uid(), conversation_id: conv.id, sender: "guest", content: msg, meta: { mode: "scripted" }, created_at: nowISO() }); const bb = byId("branches", branch); const knowledge = { branchName: bb?.name_ar, checkInTime: bb?.check_in_time, checkOutTime: bb?.check_out_time, address: bb?.address, phone: bb?.phone, policies: T("property_policies").filter((x) => x.branch_id === branch && x.is_public).map((x) => ({ topic: x.topic, title: x.title, content: x.content_ar })), entries: rpcs.fn_public_knowledge({ p_branch: branch }) };
    const note = (r: { intent: string; knowledgeId?: string }) => { if (r.knowledgeId) rpcs.fn_knowledge_usage_bump({ p_entry: r.knowledgeId }); if (r.intent === "unknown") rpcs.fn_record_unanswered({ p_branch: branch, p_question: msg, p_conversation: conv!.id }); };
    if (conv.status === "handed_off") { const r0 = scriptedReply(msg, "منازل الراحة", undefined, knowledge); note(r0); const informative = ["policy", "knowledge", "existing_booking", "availability", "access_code"].includes(r0.intent); const reply = informative ? r0.text + "\n\nمحادثتك ما زالت محوّلة إلى مشرف الاستقبال وسيرد عليك هنا عند توفره." : "تم تحويل محادثتك إلى مشرف الاستقبال وسيرد عليك هنا قريبًا. أثناء الانتظار يمكنك سؤالي عن مواعيد الوصول والمغادرة أو الإنترنت أو المواقف أو الموقع، أو بدء محادثة جديدة."; T("conversation_messages").push({ id: uid(), conversation_id: conv.id, sender: "assistant", content: reply, meta: { mode: "scripted", reason: "handed_off" }, created_at: nowISO() }); emit("conversation_messages"); return { data: { conversation_id: conv.id, reply, intent: r0.intent, actions: [...(informative ? r0.actions.filter((a) => !a.value) : []), { label: "محادثة جديدة", route: "/reception?new=1" }], mode: "scripted", verified: !!body.guest_token, handed_off: true }, error: null }; }
    const r = scriptedReply(msg, "منازل الراحة", undefined, knowledge); note(r); if (/(موظف|مشرف|بشري|human|staff)/.test(msg)) { Object.assign(conv, { status: "handed_off", handed_off_at: nowISO(), handoff_reason: "طلب صريح من النزيل" }); T("human_handoff_tickets").unshift({ id: uid(), organization_id: ORG, branch_id: branch, conversation_id: conv.id, reservation_id: null, kind: "guest_request", external_ref: null, source_name: null, details: "طلب صريح من النزيل", status: "open", resolved_by: null, resolved_at: null, created_at: nowISO() }); emit("human_handoff_tickets"); } T("conversation_messages").push({ id: uid(), conversation_id: conv.id, sender: "assistant", content: r.text, meta: { mode: "scripted" }, created_at: nowISO() }); conv.last_message_at = nowISO(); emit("conversations"); emit("conversation_messages"); return { data: { conversation_id: conv.id, reply: r.text, actions: r.actions, intent: r.intent, mode: "scripted", verified: !!body.guest_token, handed_off: conv.status === "handed_off", ai_status: "demo" }, error: null }; }
  return { data: null, error: { message: "unknown function" } };
}

// ---------------------------------------------------------------------------
// client
// ---------------------------------------------------------------------------
export function createDemoClient() {
  return {
    from: (table: string) => new QB(table),
    rpc: async (fn: string, args: any = {}) => { const impl = rpcs[fn]; if (!impl) return { data: null, error: { message: `FN_NOT_IMPLEMENTED_IN_DEMO: ${fn}` } }; try { return { data: impl(args) ?? null, error: null }; } catch (e) { return { data: null, error: { message: (e as Error).message, code: "P0001" } }; } },
    auth: {
      getSession: async () => ({ data: { session }, error: null }),
      onAuthStateChange: (cb: (e: string, s: Session) => void) => { authListeners.add(cb); return { data: { subscription: { unsubscribe: () => authListeners.delete(cb) } } }; },
      signInWithPassword: async ({ email }: { email: string; password: string }) => { lastSignInAt = Date.now(); const acc = DEMO_ACCOUNTS.find((a) => a.email.toLowerCase() === String(email).trim().toLowerCase()) ?? DEMO_ACCOUNTS[0]; setSession({ user: { id: acc.auth, email: acc.email }, access_token: "demo" }); return { data: { session }, error: null }; },
      signUp: async ({ email }: { email: string; password: string }) => { const acc = DEMO_ACCOUNTS[0]; setSession({ user: { id: acc.auth, email }, access_token: "demo" }); return { data: { session }, error: null }; },
      signOut: async () => { setSession(null); return { error: null }; },
    },
    channel: (_name: string) => { const mine: Listener[] = []; const ch = { on: (_e: string, f: { table: string }, cb: () => void) => { const l = { table: f.table, cb }; mine.push(l); listeners.add(l); return ch; }, subscribe: () => ch, unsubscribe: () => { for (const l of mine) listeners.delete(l); }, _mine: mine }; return ch; },
    removeChannel: async (ch: { _mine?: Listener[] }) => { for (const l of ch?._mine ?? []) listeners.delete(l); return "ok"; },
    functions: { invoke: async (name: string, opts?: any) => invoke(name, opts) },
  };
}
export const DEMO_LOGINS = DEMO_ACCOUNTS.map((a) => ({ email: a.email, name: a.name, role: a.role }));
