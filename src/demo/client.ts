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
import { guestRpcs, detailExtras, fingerprint, checkIdentity, validMapUrl, validHttpsUrl } from "./guests";
import { phase6Rpcs } from "./phase6";
import { checkMinAge, checkPersonName, checkPhone, latinDigits } from "../lib/validation";
import { makePermissions, permissionRpcs } from "./permissions";

const KEY = "zaaer_demo_store_v8";
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
function emit(table: string) { dirty.add(table); persist(); notifyLater(); }
function notifyLater() {
  if (emitTimer) return;
  emitTimer = window.setTimeout(() => { emitTimer = null; const tables = [...dirty]; dirty.clear(); for (const l of listeners) if (tables.includes(l.table)) { try { l.cb(); } catch { /* ignore */ } } }, 60);
}
function emitAll(save = true) { for (const t of Object.keys(S)) dirty.add(t); if (save) persist(); notifyLater(); }
// two tabs of the demo see each other's changes: a store another tab wrote is adopted here as it is (an owner's forced
// sign-out in one tab reaches the person's own tab on its next request, as fn_session_ok does on the server)
if (typeof window !== "undefined" && typeof window.addEventListener === "function") {
  window.addEventListener("storage", (e: StorageEvent) => { if (e.key === KEY) { S = load(); emitAll(false); } });
}

// ---------------------------------------------------------------------------
// auth
// ---------------------------------------------------------------------------
/** signed_in_at stands for the session id a real token carries (0040): a staff member's sessions_ended_at after it refuses it */
type Session = { user: { id: string; email: string }; access_token: string; signed_in_at?: string } | null;
let session: Session = (() => { try { return JSON.parse(sessionStorage.getItem(SESSION_KEY) ?? "null"); } catch { return null; } })();
const authListeners = new Set<(e: string, s: Session) => void>();
function setSession(s: Session) { session = s; try { if (s) sessionStorage.setItem(SESSION_KEY, JSON.stringify(s)); else sessionStorage.removeItem(SESSION_KEY); } catch { /* ignore */ } for (const l of authListeners) l(s ? "SIGNED_IN" : "SIGNED_OUT", s); }
const DEMO_ACCOUNTS = Object.values(STAFF);
/** when a new session of this account opens: now, and strictly after any end the owner set on the person's sessions (fn_end_sessions) */
function newSessionAt(authUserId: string): string { const sp = T("staff_profiles").find((s) => s.auth_user_id === authUserId); const ended = sp?.sessions_ended_at ? Date.parse(sp.sessions_ended_at) + 1 : 0; return new Date(Math.max(Date.now(), ended)).toISOString(); }

// ---------------------------------------------------------------------------
// current staff context (mirrors fn_staff_id / fn_user_branch_ids / fn_require_*)
// ---------------------------------------------------------------------------
function me(): Row | null {
  if (!session) return null;
  const s = T("staff_profiles").find((x) => x.auth_user_id === session!.user.id && x.is_active);
  // fn_session_ok (0040, decision 34): a session ended by a forced sign-out or a deactivation is refused on its next
  // request, whatever token it still holds; a session without the mark (signed in before the rule) has nothing to check
  if (!s || (s.sessions_ended_at && session.signed_in_at && Date.parse(s.sessions_ended_at) >= Date.parse(session.signed_in_at))) return null;
  return s;
}
/** fn_user_branch_ids: the owner is on every branch; the others on their live memberships (a retired one, removed_at set, no longer counts) */
function myBranches(): string[] { const m = me(); if (!m) return []; if (m.role === "owner") return T("branches").filter((b) => b.organization_id === m.organization_id).map((b) => b.id); return T("branch_memberships").filter((x) => x.staff_id === m.id && !x.removed_at).map((x) => x.branch_id); }
function hasRole(...roles: string[]) { const m = me(); return !!m && roles.includes(m.role); }
function requireRole(...roles: string[]) { if (!hasRole(...roles)) throw new Error(`FORBIDDEN: requires one of {${roles.join(",")}}`); }
/** the permissions matrix (0043, decision 71): every operation the matrix names asks it (fn_can / fn_require_cap …), the
 *  money columns follow fn_sees_money; operations the matrix does not name keep their fixed roles (hasRole / requireRole) */
const perm = makePermissions({ T: (t) => T(t), me: () => me() });
const { can, capFull, requireCap, requireCapFull, requireAnyCap, seesMoney, requireMoney } = perm;
function requireBranch(b: string | null | undefined) { if (!b || !myBranches().includes(b)) throw new Error("FORBIDDEN: branch not permitted"); }
function staffId() { return me()?.id ?? null; }
function branchToday(_b?: string) { return todayISO(); }
/** The source every audit row carries while set (the server's app.source): the operations assistant's executions (0040, decision 55). */
let auditSource: string | null = null;
function audit(branch: string | null, action: string, entity: string, entityId: string, details: Row) {
  // like the server trigger (0026): the request's trace code and source, or a per-call code when none was sent
  const trace = requestHeaders?.["x-correlation-id"], source = auditSource ?? requestHeaders?.["x-client-source"];
  T("audit_events").unshift({ id: uid(), organization_id: ORG, branch_id: branch, actor_id: staffId(), action, entity_type: entity, entity_id: entityId, details, created_at: nowISO(),
    correlation_id: trace && /^[A-Za-z0-9_-]{6,64}$/.test(trace) ? trace : "tx-" + uid().slice(0, 8),
    source: source && /^[a-z][a-z_-]{1,31}$/.test(source) ? source : staffId() ? "screen" : "system",
    actor_type: staffId() ? "staff" : "system", result: "success",
    category: /^(staff|membership|security|data_purge|permissions)/.test(action) ? "security" : "business" });
  emit("audit_events");
}

// ---------------------------------------------------------------------------
// request context and test latency
// ---------------------------------------------------------------------------
/** The headers of the RPC being run (x-correlation-id / x-client-source, as the app sends them to the server). */
let requestHeaders: Record<string, string> | null = null;

/**
 * Test hook (end-to-end tests only): `window.__demoLatency(target, detail)` returns a delay in ms for a read
 * (target = table name, detail = its filters such as "branch_id=…") or an RPC (target = "rpc:<name>", detail = its
 * arguments as JSON), so a test can replay a slow or out-of-order answer. Unset → no delay.
 */
function demoLatency(target: string, detail: string[]): number {
  const f = (globalThis as { __demoLatency?: (t: string, d: string[]) => unknown }).__demoLatency;
  if (typeof f !== "function") return 0;
  try { const n = Number(f(target, detail)); return Number.isFinite(n) && n > 0 ? Math.min(n, 10_000) : 0; } catch { return 0; }
}
/** Test hook (end-to-end tests only): `window.__demoFail(target, detail)` returns an error message to make that read
 *  (target = table) or RPC (target = "rpc:<name>") fail, so a test can show a failed load next to an empty one (U04)
 *  or a failed save (U01). Unset → nothing fails. */
function demoFailure(target: string, detail: string[]): string | null {
  const f = (globalThis as { __demoFail?: (t: string, d: string[]) => unknown }).__demoFail;
  if (typeof f !== "function") return null;
  try { const m = f(target, detail); return typeof m === "string" && m ? m : null; } catch { return null; }
}
const later = <V>(ms: number, v: V) => (ms > 0 ? new Promise<V>((r) => window.setTimeout(() => r(v), ms)) : Promise.resolve(v));

/** An RPC call like the real client's: awaitable, with setHeader(); runs once, when first awaited. */
function rpcCall(lookup: (fn: string) => ((a: any) => any) | undefined, fn: string, args: any) {
  const headers: Record<string, string> = {};
  let run: Promise<{ data: any; error: any }> | null = null;
  const exec = async () => {
    await later(demoLatency("rpc:" + fn, [JSON.stringify(args ?? {})]), null);
    const failure = demoFailure("rpc:" + fn, [JSON.stringify(args ?? {})]);
    if (failure) return { data: null, error: { message: failure, code: "P0001" } };
    const impl = lookup(fn);
    if (!impl) return { data: null, error: { message: `FN_NOT_IMPLEMENTED_IN_DEMO: ${fn}` } };
    requestHeaders = headers;
    try { return { data: impl(args) ?? null, error: null }; }
    catch (e) { return { data: null, error: { message: (e as Error).message, code: "P0001" } }; }
    finally { requestHeaders = null; }
  };
  const call = {
    setHeader(name: string, value: string) { headers[name.toLowerCase()] = value; return call; },
    then<R1 = any, R2 = never>(onf?: ((v: any) => R1 | PromiseLike<R1>) | null, onr?: ((e: any) => R2 | PromiseLike<R2>) | null): Promise<R1 | R2> {
      return (run ??= exec()).then(onf ?? undefined, onr ?? undefined);
    },
  };
  return call;
}
// 0009 (GAP06): updates of definitions, stays, prices and task completion must carry the version the user saw
const checkVersion = (cur: number, exp?: number | null) => { if (exp == null) throw new Error("VERSION_REQUIRED: expected version must be supplied"); if (cur !== exp) throw new Error("VERSION_CONFLICT: record changed by another user"); };
const checkVersionLenient = (cur: number, exp?: number | null) => { if (exp != null && cur !== exp) throw new Error("VERSION_CONFLICT: record changed by another user"); };
const nonEmpty = (v: unknown, code: string) => { if (!v || !String(v).trim()) throw new Error(`VALIDATION: ${code}`); };

// ---------------------------------------------------------------------------
// core money (0028): four methods, accounts, transaction numbers, whole halalas
// ---------------------------------------------------------------------------
const ACTIVE_METHODS = ["cash", "pos", "bank_transfer", "ota_deferred"];
/** A whole, positive number of halalas (F09). */
function parseHalalas(v: unknown): number { const s = typeof v === "number" ? (Number.isInteger(v) ? String(v) : "x") : String(v ?? ""); if (!/^[0-9]{1,15}$/.test(s) || Number(s) <= 0) throw new Error("VALIDATION: amount"); return Number(s); }
/** The transaction number of a terminal or transfer payment (decision 13). */
function checkReference(method: string, ref: unknown): string | null { const r = String(ref ?? "").trim(); if (method === "pos" || method === "bank_transfer") { if (!r) throw new Error("VALIDATION: reference_required"); if (r.length < 3 || r.length > 60) throw new Error("VALIDATION: reference"); } return r || null; }
/** Which account a voucher of this method uses: the one given (checked) or the branch's default of its kind (decision 25). */
function voucherAccount(branch: string, method: string, account: string | null | undefined): string | null {
  const want = method === "cash" ? "cash_box" : method === "pos" || method === "bank_transfer" ? "bank_account" : null;
  if (!want) { if (account) throw new Error("VALIDATION: account_not_allowed"); return null; }
  if (account) { const a = byId("cash_accounts", account); if (!a || a.branch_id !== branch) throw new Error("BRANCH_MISMATCH: account"); if (a.kind !== want) throw new Error("VALIDATION: account_kind"); if (a.archived_at || !a.is_active) throw new Error("VALIDATION: account_archived"); return a.id; }
  const d = T("cash_accounts").find((a) => a.branch_id === branch && a.kind === want && a.is_default && !a.archived_at && a.is_active);
  if (!d) throw new Error("VALIDATION: account_required"); return d.id;
}
function bootstrapAccounts(branch: string) {
  for (const [kind, name] of [["cash_box", "الصندوق الرئيسي"], ["bank_account", "الحساب البنكي الرئيسي"]] as const) {
    if (T("cash_accounts").some((a) => a.branch_id === branch && a.kind === kind)) continue;
    const a = { id: uid(), organization_id: ORG, branch_id: branch, kind, name, bank_name: null, account_last4: null, is_default: true, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_by: staffId(), created_at: nowISO(), updated_at: nowISO() };
    T("cash_accounts").push(a); audit(branch, "cash_account.created", "cash_account", a.id, { after: a, reason: "حساب أولي للفرع" });
  }
  emit("cash_accounts");
}
/** The branch-local day (Asia/Riyadh) a moment belongs to. */
const dayOf = (iso: string) => new Date(iso).toLocaleDateString("en-CA", { timeZone: "Asia/Riyadh" });
function posDayTotal(branch: string, account: string, date: string) {
  const v = T("financial_vouchers").filter((x) => x.branch_id === branch && x.account_id === account && x.method === "pos" && x.status === "approved" && x.kind !== "deposit_apply" && dayOf(x.occurred_at) === date).sort((a, b) => (a.occurred_at < b.occurred_at ? -1 : 1));
  const inn = v.filter((x) => x.kind === "receipt" || x.kind === "deposit").reduce((s, x) => s + x.amount_halalas, 0);
  const out = v.filter((x) => x.kind === "refund" || x.kind === "deposit_refund").reduce((s, x) => s + x.amount_halalas, 0);
  return { in_halalas: inn, out_halalas: out, system_total_halalas: inn - out, voucher_count: v.length, vouchers: v.map((x) => ({ id: x.id, number: x.number, kind: x.kind, amount_halalas: x.amount_halalas, reference: x.reference, occurred_at: x.occurred_at })) };
}

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
  if (table === "keyboxes") delete out.code_plain;   // like code_encrypted on the server: never readable through a query, only fn_keybox_reveal
  for (const e of embeds) {
    const col = (e.hint && FK_HINT[e.hint]) || FK[table]?.[e.table];
    if (!col) { out[e.alias] = null; continue; }
    const target = byId(e.table, row[col]);
    out[e.alias] = target ? project(e.table, target, e.cols) : null;
  }
  return out;
}
type Filter = (r: Row) => boolean;
/** Who may change a table directly (mirrors the write policies); other direct writes are not emulated.
 *  0038 revoked every direct write on the booking platforms: a source is switched through fn_admin_set_source_active (audited).
 *  0040 closed the staff tables and the saved views: name, phone, role, activation and memberships go through fn_admin_* (audited,
 *  with a reason), a saved view through fn_saved_view_save / fn_saved_view_remove.
 *  0043: the matrix's rows decide the rest — «السياسات» (property_policies), «تولّي محادثة واتساب» (a staff reply and taking
 *  a conversation); role_permissions is written only through fn_admin_set_permissions / fn_admin_reset_permissions. */
const WRITE_RULES: Record<string, () => boolean> = {
  booking_sources: () => false, staff_profiles: () => false, branch_memberships: () => false, staff_saved_views: () => false, role_permissions: () => false,
  property_policies: () => can("policies"), conversations: () => can("conversation.take"), conversation_messages: () => can("conversation.take"),
};
const BRANCH_TABLES = new Set(["rooms", "reservations", "housekeeping_tasks", "facilities", "blocks", "floors", "task_types", "service_definitions", "room_categories", "maintenance_tickets", "property_policies", "inventory_periods", "release_rules", "released_slots", "keyboxes", "financial_vouchers", "reservation_charges", "invoices", "reservation_allocations", "human_handoff_tickets", "notifications"]);
/** Mirrors the row-level security of the real schema closely enough for the walkthrough. */
function visible(table: string, r: Row): boolean {
  const m = me(); const branches = myBranches();
  if (table === "branches") return !m || branches.includes(r.id);
  if (table === "property_policies" && !m) return !!r.is_public;
  if (table === "booking_sources" || table === "organizations" || table === "system_settings") return true;
  if (!m) return false;
  if (table === "staff_saved_views") return r.staff_id === m.id;   // own rows only (0040)
  // 0043: the money tables follow fn_sees_money (any money cell of the matrix); the guests of a stay keep their fixed roles
  if (["financial_vouchers", "reservation_charges", "invoices"].includes(table) && !seesMoney()) return false;
  if (table === "reservation_guests" && !["owner", "manager", "supervisor", "finance"].includes(m.role)) return false;
  if (["keyboxes", "code_rotation_events", "access_delivery_events"].includes(table) && !["owner", "manager", "supervisor"].includes(m.role)) return false;
  if (table === "audit_events") return can("audit.log") && r.organization_id === m.organization_id && (r.category !== "security" || can("security"));
  if (table === "role_permissions") return m.role === "owner" && r.organization_id === m.organization_id;
  if (["cash_accounts", "pos_settlements"].includes(table)) return seesMoney() && branches.includes(r.branch_id);
  if (table === "platform_payouts") return can("platform.payouts") && branches.includes(r.branch_id);
  if (table === "rate_calendar") return can("rates") && branches.includes(r.branch_id);
  if (table === "reservation_nights") return seesMoney() && branches.includes(r.branch_id);
  // the stay cycle (0033): inspections for the arrival and housekeeping staff, overdue reasons for the money roles, the review list for the owner
  if (table === "checkout_inspections") return ["owner", "manager", "supervisor", "finance", "housekeeping"].includes(m.role) && branches.includes(r.branch_id);
  if (table === "stay_payment_exceptions") return seesMoney() && branches.includes(r.branch_id);
  if (table === "review_items") return can("review.list") && r.organization_id === m.organization_id;
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
  private filters: Filter[] = []; private trace: string[] = []; private mode: "select" | "insert" | "update" | "delete" | "upsert" = "select"; private sel = "*"; private payload: any = null;
  private orders: Array<{ col: string; asc: boolean; nullsFirst?: boolean }> = []; private lim: number | null = null; private off = 0; private countMode = false; private head = false; private one: "maybe" | "one" | null = null;
  /** service = the server's view (edge functions with the service role): no row-level filtering */
  constructor(private table: string, private service = false) {}
  select(sel = "*", opts?: { count?: string; head?: boolean }) { if (this.mode === "select") this.sel = sel; else this.sel = sel; this.countMode = !!opts?.count; this.head = !!opts?.head; return this; }
  insert(p: any) { this.mode = "insert"; this.payload = p; return this; }
  upsert(p: any) { this.mode = "upsert"; this.payload = p; return this; }
  update(p: any) { this.mode = "update"; this.payload = p; return this; }
  delete() { this.mode = "delete"; return this; }
  eq(c: string, v: any) { this.trace.push(`${c}=${v}`); this.filters.push((r) => r[c] === v || (v != null && String(r[c]) === String(v))); return this; }
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
    this.trace.push(`or=${expr}`);
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
      // write-side RLS for the tables the UI changes directly (0029: the booking platforms are the owner's or a manager's)
      const writers = WRITE_RULES[this.table];
      if (this.mode !== "select" && writers && !this.service && !writers()) {
        if (this.mode === "insert" || this.mode === "upsert") return { data: null, error: { message: `new row violates row-level security policy for table "${this.table}"`, code: "42501" }, count: null };
        return { data: [], error: null, count: null };   // as in Postgres: no row is visible to the change, nothing changes
      }
      const match = (r: Row) => this.filters.every((f) => f(r));
      if (this.mode === "insert" || this.mode === "upsert") {
        const list: Row[] = (Array.isArray(this.payload) ? this.payload : [this.payload]).map((p: Row) => ({ id: uid(), created_at: nowISO(), ...p }));
        // primary key of the handled-message log (0021): a second insert of the same id fails, as in Postgres
        if (this.table === "whatsapp_inbound_messages") {
          for (const p of list) { p.received_at ??= nowISO(); if (rows.some((r) => r.wa_message_id === p.wa_message_id)) return { data: null, error: { message: "duplicate key value violates unique constraint", code: "23505" }, count: null }; }
        }
        for (const p of list) { const i = this.mode === "upsert" ? rows.findIndex((r) => r.id === p.id || (this.table === "ai_usage_daily" && r.organization_id === p.organization_id && r.day === p.day)) : -1; if (i >= 0) rows[i] = { ...rows[i], ...p }; else rows.push(p); }
        emit(this.table);
        const data = list.map((r: Row) => project(this.table, r, this.sel));
        return { data: this.one ? data[0] : data, error: null, count: null };
      }
      if (this.mode === "update") { const hit = rows.filter(match); for (const r of hit) Object.assign(r, this.payload); emit(this.table); return { data: hit.map((r) => project(this.table, r, this.sel)), error: null, count: null }; }
      if (this.mode === "delete") { const keep = rows.filter((r) => !match(r)); S[this.table] = keep; emit(this.table); return { data: [], error: null, count: null }; }
      let out = rows.filter(match).filter((r) => this.service || visible(this.table, r));   // RLS emulation (read side)
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
  then<R1 = any, R2 = never>(onf?: ((v: any) => R1 | PromiseLike<R1>) | null, onr?: ((e: any) => R2 | PromiseLike<R2>) | null): Promise<R1 | R2> {
    const failure = this.mode === "select" ? demoFailure(this.table, this.trace) : null;
    const v = failure ? { data: null, error: { message: failure }, count: null } : this.run();
    return later(this.mode === "select" ? demoLatency(this.table, this.trace) : 0, v).then(onf ?? undefined, onr ?? undefined);
  }
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
  // every voucher and charge change re-checks «مغلق» (the triggers of 0033)
  emit("reservations"); syncClosed(resId); return f;
}
/** Half away from zero, like Postgres round() on numeric (decision 47: half up at the line, by magnitude). */
const roundHalfUp = (x: number) => Math.sign(x) * Math.round(Math.abs(x));
function taxBy(rate: number, incl: boolean, amount: number, taxable: boolean) { if (!taxable || !rate) return { net: amount, tax: 0 }; if (incl) { const tax = amount - roundHalfUp((amount * 10000) / (10000 + rate)); return { net: amount - tax, tax }; } return { net: amount, tax: roundHalfUp((amount * rate) / 10000) }; }
function applyTax(branchId: string, amount: number, taxable: boolean) { const b = byId("branches", branchId)!; return taxBy(b.tax_rate_bp ?? 0, !!b.prices_include_tax, amount, taxable); }
/** 0028: a reservation keeps the tax policy it was made under; a later change of the branch's policy only reaches new ones. */
function reservationTax(resId: string, amount: number, taxable: boolean) { const r = byId("reservations", resId)!; const b = byId("branches", r.branch_id)!; return taxBy(r.tax_rate_bp ?? b.tax_rate_bp ?? 0, r.prices_include_tax ?? !!b.prices_include_tax, amount, taxable); }
/** A line of the stay (fn_add_charge): the period it is for — the stay's nights for rent, discounts and stay-wide adjustments,
 *  the day it was added for the rest — and its tax as its own line that records its line (0036). */
function addCharge(resId: string, kind: string, description: string, qty: number, unit: number, taxable: boolean, reason: string | null, serviceId: string | null = null, serviceFrom: string | null = null, serviceTo: string | null = null) {
  const r = byId("reservations", resId)!; let gross = roundHalfUp(qty * unit); if (kind === "discount") gross = -Math.abs(gross);
  const { net, tax } = reservationTax(resId, gross, taxable);
  const stayWide = ["rent", "discount", "adjustment"].includes(kind); const today = branchToday(r.branch_id);
  const service_from = serviceFrom ?? (stayWide ? r.check_in : today), service_to = serviceTo ?? (stayWide ? r.check_out : today);
  if (service_to < service_from) throw new Error("VALIDATION: service_period");
  const id = uid(); const at = nowISO();
  T("reservation_charges").push({ id, organization_id: ORG, branch_id: r.branch_id, reservation_id: resId, kind, description, quantity: qty, unit_price_halalas: unit, total_halalas: net, taxable, service_definition_id: serviceId, invoice_id: null, reason, created_by: staffId(), created_at: at, service_from, service_to, base_charge_id: null });
  if (tax) T("reservation_charges").push({ id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: resId, kind: "tax", description: "ضريبة القيمة المضافة — " + description, quantity: 1, unit_price_halalas: tax, total_halalas: tax, taxable: false, service_definition_id: null, invoice_id: null, reason, created_by: staffId(), created_at: at, service_from, service_to, base_charge_id: id });
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
  // decision 7: a unit without a key box is ready when clean; one with a box also needs an active, tested code
  rm.status = maint ? "maintenance" : rm.cleanliness !== "clean" ? "cleaning" : kb && (kb.code_status !== "active" || !kb.field_tested) ? "cleaning" : "ready";
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
/** `at` is the moment of the departure or the cancellation itself, so that a correction finds exactly what it released. */
function releaseAllocations(resId: string, mode: "cancel" | "close", at = nowISO()) {
  for (const a of T("reservation_allocations").filter((x) => x.reservation_id === resId && x.status === "active")) {
    a.status = mode === "cancel" ? "cancelled" : "closed"; a.closed_at = at;
    if (a.from_date <= branchToday() && branchToday() < a.to_date) { const rm = byId("rooms", a.room_id)!; if (rm.status === "reserved") rm.status = "available"; if (mode === "cancel") recomputeRoomReady(a.room_id); }
  }
  emit("reservation_allocations"); emit("rooms");
}
function roomCleaningType(branchId: string) { let t = T("task_types").find((x) => x.branch_id === branchId && x.code === "room_cleaning"); if (!t) { t = { id: uid(), organization_id: ORG, branch_id: branchId, code: "room_cleaning", name: "تنظيف الوحدة وتعقيمها", description: null, is_active: true, archived_at: null, version: 1, created_at: nowISO(), updated_at: nowISO() }; T("task_types").push(t); emit("task_types"); } return t; }
function createCleaningTask(branchId: string, roomId: string, resId: string | null, desc: string, priority = "high") {
  const t = roomCleaningType(branchId); const rm = byId("rooms", roomId)!; rm.cleanliness = "dirty"; rm.status = "cleaning"; rm.updated_at = nowISO();
  const existing = T("housekeeping_tasks").find((h) => h.room_id === roomId && h.reservation_id === resId && ["pending", "in_progress"].includes(h.status));
  if (!existing) T("housekeeping_tasks").push({ id: uid(), organization_id: ORG, branch_id: branchId, room_id: roomId, facility_id: null, task_type_id: t.id, task_type_name_snapshot: t.name, reservation_id: resId, priority, status: "pending", assignee_id: null, scheduled_start: nowISO(), scheduled_end: null, started_at: null, completed_at: null, completed_by: null, cancelled_at: null, cancel_reason: null, description: desc, result_note: null, images: [], version: 1, created_by: staffId(), created_at: nowISO(), updated_at: nowISO() });
  const kb = T("keyboxes").find((k) => k.room_id === roomId); if (kb) { if (kb.code_status !== "needs_change" || !kb.needs_change_since) kb.needs_change_since = nowISO(); kb.code_status = "needs_change"; kb.field_tested = false; }
  emit("housekeeping_tasks"); emit("rooms"); emit("keyboxes");
}
/** a guest is in house in this unit (housekeeping never sees or changes its code) — mirrors fn_room_guest_in_house */
const guestInHouse = (roomId: string) => T("reservations").some((r) => r.room_id === roomId && r.status === "checked_in");
const guestName = (resId: string) => T("reservation_guests").find((g) => g.reservation_id === resId && g.is_primary)?.full_name ?? null;
const roomNo = (roomId: string | null) => (roomId ? byId("rooms", roomId)?.room_number ?? null : null);

// ---------------------------------------------------------------------------
// RPC implementations
// ---------------------------------------------------------------------------
/** what the phase 5 module (guests.ts) needs from the demo's core; every member is read at call time */
const guestCtx = {
  T, byId, myBranches, hasRole, requireRole, requireBranch, staffId, audit, emit, ...perm,
  staffName: (id: string | null | undefined) => staffName(id),
  addReview: (branch: string, kind: string, entityType: string, entityId: string, resId: string | null, summary: string, reason: string | null, details: Row) => addReview(branch, kind, entityType, entityId, resId, summary, reason, details),
  normPhone: (ph: unknown) => normPhone(ph),
  financeOf: (resId: string) => financeOf(resId),
  stayDue: (resId: string) => stayDue(resId),
  branchToday: (b?: string) => branchToday(b),
  roomNo: (roomId: string | null) => roomNo(roomId),
  releaseAllocations: (resId: string, mode: "cancel" | "close", at?: string) => releaseAllocations(resId, mode, at),
  createVoucher: (p: Row) => rpcs.fn_create_voucher({ p }),
  atomically: <V,>(fn: () => V): V => atomically(fn),
};
const rpcs: Record<string, (a: any) => any> = {
  fn_staff_id: () => staffId(),
  fn_user_branch_ids: () => myBranches(),
  fn_claim_staff_profile: () => ({ ok: true, claimed: true }),
  // 0040: a guest is no staff role; the invite re-opens a retired membership instead of a duplicate, and is logged
  fn_staff_invite: ({ p_email, p_full_name, p_role, p_branch_ids }) => { requireCap("staff.manage"); if (p_role === "guest") throw new Error("INVALID_ROLE"); if (!["owner", "manager", "supervisor", "finance", "housekeeping"].includes(String(p_role))) throw new Error("INVALID_ROLE");
    if (p_role === "owner" && !hasRole("owner")) throw new Error("FORBIDDEN: only the owner changes an owner");   // decision 44 (0043)
    if (!perm.roleWithinMine(String(p_role))) throw new Error("FORBIDDEN: a role beyond your own");                 // 0046
    const email = String(p_email ?? "").trim().toLowerCase(), name = String(p_full_name ?? "").trim(); if (!email || !name) throw new Error("VALIDATION: email_and_name");
    if (T("staff_profiles").some((x) => x.organization_id === ORG && String(x.email ?? "").toLowerCase() === email)) throw new Error("DUPLICATE_EMAIL");   // 0046
    const branches: string[] = Array.isArray(p_branch_ids) ? p_branch_ids : []; for (const b of branches) requireBranch(b);   // all or nothing, as the transaction
    const id = uid(); T("staff_profiles").push({ id, auth_user_id: null, organization_id: ORG, full_name: name, email, phone: null, role: p_role, is_active: true, created_at: nowISO(), sessions_ended_at: null, updated_at: null });
    for (const b of branches) { const m = T("branch_memberships").find((x) => x.staff_id === id && x.branch_id === b); if (m) { m.removed_at = null; m.removed_by = null; } else T("branch_memberships").push({ id: uid(), staff_id: id, branch_id: b, created_at: nowISO(), removed_at: null, removed_by: null }); }
    emit("staff_profiles"); emit("branch_memberships"); audit(null, "staff_invited", "staff_profile", id, { role: p_role, branch_ids: branches }); return { ok: true, staff_id: id }; },
  fn_admin_update_ai_settings: ({ p }) => { requireCap("security"); Object.assign(T("ai_settings")[0], p, { updated_at: nowISO() }); emit("ai_settings"); return { ok: true }; },
  fn_definition_dependencies: ({ p_entity, p_id }) => { requireCap("definitions"); return deps(p_entity, p_id); },

  // ---- definitions ----
  fn_admin_upsert_branch: ({ p }) => { requireCap("branch.settings"); nonEmpty(p.name_ar, "name_ar");
    // decision 31: the English name is required; the map link is a Google Maps https link; the platform link is https
    if ((!p.id || p.name_en !== undefined) && !String(p.name_en ?? "").trim()) throw new Error("VALIDATION: name_en");
    if (p.country_code != null && !/^[A-Z]{2}$/.test(String(p.country_code))) throw new Error("VALIDATION: country");
    if (p.default_language != null && !["ar", "en"].includes(String(p.default_language))) throw new Error("VALIDATION: language");
    const mapUrl = p.map_url === undefined ? undefined : String(p.map_url ?? "").trim() || null; if (mapUrl && !validMapUrl(mapUrl)) throw new Error("VALIDATION: map_url");
    const platformUrl = p.booking_platform_url === undefined ? undefined : String(p.booking_platform_url ?? "").trim() || null; if (platformUrl && !validHttpsUrl(platformUrl)) throw new Error("VALIDATION: booking_url");
    if (p.timezone) { try { new Intl.DateTimeFormat("en", { timeZone: p.timezone }); } catch { throw new Error("VALIDATION: timezone"); } }
    if (p.tax_rate_bp != null && (!/^[0-9]{1,4}$/.test(String(p.tax_rate_bp)) || Number(p.tax_rate_bp) > 10000)) throw new Error("VALIDATION: tax_rate");
    if (p.default_deposit_halalas != null && !/^[0-9]{1,12}$/.test(String(p.default_deposit_halalas))) throw new Error("VALIDATION: amount");
    if (p.supervisor_max_discount_bp != null && (!/^[0-9]{1,5}$/.test(String(p.supervisor_max_discount_bp)) || Number(p.supervisor_max_discount_bp) > 10000)) throw new Error("VALIDATION: discount_limit");
    if (!p.id) { requireRole("owner"); const b = { id: uid(), supervisor_max_discount_bp: Number(p.supervisor_max_discount_bp ?? 0), organization_id: ORG, name_ar: String(p.name_ar).trim(), name_en: String(p.name_en).trim(), city: p.city ?? null, address: p.address ?? null, map_url: mapUrl ?? null, phone: p.phone ?? null, email: p.email ?? null, check_in_time: p.check_in_time ?? "16:00", check_out_time: p.check_out_time ?? "12:00", logo_url: null, is_active: true, timezone: p.timezone ?? "Asia/Riyadh", tax_rate_bp: p.tax_rate_bp ?? 0, prices_include_tax: !!p.prices_include_tax, default_deposit_halalas: p.default_deposit_halalas ?? 5000, tax_number: (p.tax_number ?? "").trim() || null, commercial_register: p.commercial_register ?? null, country_code: p.country_code ?? "SA", default_language: p.default_language ?? "ar", booking_platform_url: platformUrl ?? null, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: nowISO(), updated_at: nowISO() }; T("branches").push(b); roomCleaningType(b.id); bootstrapAccounts(b.id); emit("branches"); audit(b.id, "branch.created", "branch", b.id, { after: b }); return { ok: true, id: b.id, version: 1 }; }
    const b = byId("branches", p.id); if (!b) throw new Error("NOT_FOUND"); requireBranch(b.id); checkVersionLenient(b.version, p.version); const before = { ...b };
    const newTaxNumber = p.tax_number !== undefined ? (String(p.tax_number ?? "").trim() || null) : b.tax_number;
    const taxChanged = (p.tax_rate_bp != null && Number(p.tax_rate_bp) !== b.tax_rate_bp) || (p.prices_include_tax != null && !!p.prices_include_tax !== !!b.prices_include_tax) || newTaxNumber !== b.tax_number;
    if (taxChanged && !can("branch.tax")) throw new Error("FORBIDDEN: tax settings are the owner's");
    if (p.name_en === undefined && !String(b.name_en ?? "").trim()) throw new Error("VALIDATION: name_en");
    for (const k of ["name_ar", "name_en", "city", "address", "phone", "email", "check_in_time", "check_out_time", "timezone", "tax_rate_bp", "prices_include_tax", "default_deposit_halalas", "supervisor_max_discount_bp", "commercial_register", "is_active", "country_code", "default_language"]) if (p[k] !== undefined) b[k] = p[k];
    b.name_ar = String(b.name_ar).trim(); b.name_en = String(b.name_en).trim(); if (mapUrl !== undefined) b.map_url = mapUrl; if (platformUrl !== undefined) b.booking_platform_url = platformUrl;
    b.tax_number = newTaxNumber;
    b.version++; b.updated_at = nowISO(); emit("branches"); audit(b.id, "branch.updated", "branch", b.id, { before, after: b });
    if (taxChanged) audit(b.id, "branch.tax_changed", "branch", b.id, { before: { tax_rate_bp: before.tax_rate_bp, prices_include_tax: before.prices_include_tax, tax_number: before.tax_number }, after: { tax_rate_bp: b.tax_rate_bp, prices_include_tax: b.prices_include_tax, tax_number: b.tax_number }, reason: "يسري على الحجوزات الجديدة فقط" });
    return { ok: true, id: b.id, version: b.version }; },
  fn_admin_upsert_block: ({ p }) => upsertDef("blocks", "block", p, ["name", "description", "sort_order", "is_active"], (x) => nonEmpty(x.name, "name"), ["name"]),
  fn_admin_upsert_floor: ({ p }) => { if (!p.id) { const blk = byId("blocks", p.block_id); if (!blk) throw new Error("NOT_FOUND: block"); p.branch_id = blk.branch_id; } return upsertDef("floors", "floor", p, ["name", "sort_order", "is_active", "block_id"], (x) => nonEmpty(x.name, "name"), ["name"], "block_id"); },
  fn_admin_upsert_room_category: ({ p }) => {
    requireCap("definitions"); const cur = p.id ? byId("room_categories", p.id) : null;
    for (const k of ["weekly_price_halalas", "monthly_price_halalas", "min_nightly_halalas"]) { if (p[k] === "") p[k] = null; if (p[k] != null && !(Number(p[k]) > 0)) throw new Error("VALIDATION: amount"); }
    if (p.price_mode !== undefined && !["unified", "by_channel"].includes(p.price_mode)) throw new Error("VALIDATION: price_mode");
    const pick = (k: string) => (p[k] !== undefined ? p[k] : cur?.[k]); const num = (k: string) => (pick(k) == null ? null : Number(pick(k)));
    const mn = num("min_nightly_halalas"), wk = num("weekly_price_halalas"), mo = num("monthly_price_halalas"), mode = pick("price_mode") ?? "unified";
    if (mn != null) {
      // no nightly price of the type under its minimum: base, weekly and monthly per night, and the calendar's coming nights
      if ((num("base_price_halalas") ?? 0) < mn || (wk != null && wk / 7 < mn) || (mo != null && mo / 30 < mn)) throw new Error("VALIDATION: below_minimum");
      if (cur && T("rate_calendar").some((x) => x.category_id === cur.id && x.night >= branchToday() && ((x.price_halalas != null && x.price_halalas < mn) || (mode === "by_channel" && x.platform_price_halalas != null && x.platform_price_halalas < mn)))) throw new Error("VALIDATION: calendar_below_minimum");
    }
    const oldMax = cur?.max_capacity;
    const res = upsertDef("room_categories", "room_category", p, ["name_ar", "name_en", "description", "base_capacity", "max_capacity", "base_price_halalas", "amenities", "is_public", "is_active", "sort_order", "weekly_price_halalas", "monthly_price_halalas", "min_nightly_halalas", "price_mode"], (x) => { nonEmpty(x.name_ar, "name_ar"); if (x.base_price_halalas < 0) throw new Error("VALIDATION: amount"); if (x.max_capacity < x.base_capacity) throw new Error("VALIDATION: capacity"); }, ["name_ar"]);
    const row = byId("room_categories", res.id)!; row.price_mode ??= "unified"; for (const k of ["weekly_price_halalas", "monthly_price_halalas", "min_nightly_halalas"]) row[k] ??= null;
    return { ...res, stays_over_capacity: cur && oldMax != null && row.max_capacity < oldMax ? capacityImpact(row.id, row.max_capacity).length : 0 };
  },
  fn_admin_upsert_room: ({ p }) => { requireCap("definitions"); const rows = T("rooms"); let r = p.id ? byId("rooms", p.id) : null; if (p.id && !r) throw new Error("NOT_FOUND");
    const branch = r ? r.branch_id : p.branch_id; requireBranch(branch); const cat = p.category_id ?? r?.category_id; const blk = p.block_id === undefined ? r?.block_id ?? null : p.block_id; const flr = p.floor_id === undefined ? r?.floor_id ?? null : p.floor_id;
    if (!cat || byId("room_categories", cat)?.branch_id !== branch) throw new Error("BRANCH_MISMATCH: category"); if (blk && byId("blocks", blk)?.branch_id !== branch) throw new Error("BRANCH_MISMATCH: block"); if (flr && (byId("floors", flr)?.branch_id !== branch || (blk && byId("floors", flr)?.block_id !== blk))) throw new Error("BRANCH_MISMATCH: floor");
    if (!r) { nonEmpty(p.room_number, "room_number"); if (rows.some((x) => x.branch_id === branch && x.room_number === p.room_number.trim())) throw new Error("DUPLICATE_ROOM_NUMBER"); r = { id: uid(), branch_id: branch, organization_id: ORG, category_id: cat, block_id: blk, floor_id: flr, room_number: p.room_number.trim(), floor: 1, status: "available", cleanliness: "clean", is_active: p.is_active ?? true, notes: p.notes ?? null, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_at: nowISO(), updated_at: nowISO() }; rows.push(r); emit("rooms"); audit(branch, "room.created", "room", r.id, { after: r }); return { ok: true, id: r.id, version: 1 }; }
    checkVersion(r.version, p.version); const before = { ...r };
    if (p.is_active === false && r.is_active && guestInHouse(r.id)) throw new Error("ROOM_HAS_GUEST: a guest is in house");
    if (p.is_active === false && r.is_active && T("reservation_allocations").some((a) => a.room_id === r!.id && a.status === "active" && a.to_date > branchToday() && ["confirmed", "checked_in", "pending_verification"].includes(byId("reservations", a.reservation_id)?.status))) throw new Error("HAS_FUTURE_COMMITMENTS");
    if (p.room_number && p.room_number.trim() !== r.room_number && rows.some((x) => x.id !== r!.id && x.branch_id === branch && x.room_number === p.room_number.trim())) throw new Error("DUPLICATE_ROOM_NUMBER");
    Object.assign(r, { room_number: p.room_number?.trim() || r.room_number, category_id: cat, block_id: blk, floor_id: flr, notes: p.notes ?? r.notes, is_active: p.is_active ?? r.is_active, version: r.version + 1, updated_at: nowISO() });
    if (!r.is_active) r.status = "out_of_service"; else if (r.status === "out_of_service") r.status = "available";
    emit("rooms"); audit(branch, "room.updated", "room", r.id, { before, after: r }); return { ok: true, id: r.id, version: r.version }; },
  fn_admin_upsert_facility: ({ p }) => upsertDef("facilities", "facility", p, ["name", "description", "block_id", "floor_id", "images", "is_active"], (x) => nonEmpty(x.name, "name"), ["name"]),
  fn_admin_upsert_task_type: ({ p }) => upsertDef("task_types", "task_type", p, ["name", "description", "is_active"], (x) => nonEmpty(x.name, "name"), ["name"]),
  // a late check-out service moves the departure to its hour: after the branch's check-out time, billed once (0033)
  fn_admin_upsert_service: ({ p }) => { requireCap("definitions"); const cur = p.id ? byId("service_definitions", p.id) : null;
    if ("late_checkout_until" in p) { const t = String(p.late_checkout_until ?? "").trim(); if (t && !/^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$/.test(t)) throw new Error("VALIDATION: late_checkout_until"); p.late_checkout_until = t ? t.slice(0, 5) + ":00" : null; }
    const late = "late_checkout_until" in p ? p.late_checkout_until : cur?.late_checkout_until ?? null;
    if (late) { const b = byId("branches", cur?.branch_id ?? p.branch_id); const cot = String(b?.check_out_time ?? "12:00").slice(0, 5) + ":00"; if (late <= cot) throw new Error("VALIDATION: late_checkout_until"); if ((p.billing_unit ?? cur?.billing_unit ?? "once") !== "once") throw new Error("VALIDATION: late_checkout_unit"); }
    const res = upsertDef("service_definitions", "service", p, ["name_ar", "name_en", "description", "billing_unit", "price_halalas", "is_free", "taxable", "task_type_id", "is_active", "late_checkout_until"], (x) => { nonEmpty(x.name_ar, "name_ar"); if (x.price_halalas < 0) throw new Error("VALIDATION: amount"); }, ["name_ar"]);
    const row = byId("service_definitions", res.id); if (row) row.late_checkout_until ??= null; return res; },
  fn_admin_archive_definition: ({ p_entity, p_id, p_reason, p_archive }) => { requireCap("definitions"); const table = TABLE_OF[p_entity]; const row = byId(table, p_id); if (!row) throw new Error("NOT_FOUND"); requireBranch(p_entity === "branch" ? row.id : row.branch_id);
    if (p_archive !== false) { nonEmpty(p_reason, "reason"); if (p_entity === "room" && guestInHouse(p_id)) throw new Error("ROOM_HAS_GUEST: a guest is in house"); const open = openCommitments(p_entity, p_id); if (open > 0) throw new Error(`HAS_OPEN_COMMITMENTS: ${open}`); Object.assign(row, { archived_at: nowISO(), archived_by: staffId(), archive_reason: p_reason, is_active: false, version: row.version + 1 }); if (p_entity === "room") row.status = "out_of_service"; }
    else { Object.assign(row, { archived_at: null, archived_by: null, archive_reason: null, is_active: true, version: row.version + 1 }); if (p_entity === "room" && row.status === "out_of_service") row.status = "available"; }
    emit(table); audit(p_entity === "branch" ? row.id : row.branch_id, p_entity + (p_archive !== false ? ".archived" : ".restored"), p_entity, p_id, { reason: p_reason }); return { ok: true }; },
  fn_admin_delete_definition: ({ p_entity, p_id }) => { requireRole("owner", "manager"); const table = TABLE_OF[p_entity]; const row = byId(table, p_id); if (!row) throw new Error("NOT_FOUND"); const d = deps(p_entity, p_id); if (Object.values(d).some((n) => n > 0)) return { ok: false, error: "HAS_DEPENDENCIES", dependencies: d }; if (p_entity === "task_type" && row.code) return { ok: false, error: "SYSTEM_DEFINITION" }; audit(p_entity === "branch" ? row.id : row.branch_id, p_entity + ".deleted", p_entity, p_id, { before: row }); S[table] = T(table).filter((x) => x.id !== p_id); emit(table); return { ok: true }; },

  // ---- reservations ----
  // ---- rates (0030) ----
  fn_quote_stay: ({ p }) => quoteStay(p),
  fn_discount_allowance: ({ p_reservation }) => { requireAnyCap(["disc.before", "disc.after"]); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id);
    const act = T("reservation_nights").filter((x) => x.reservation_id === r.id && x.status === "active"); let rent = act.reduce((s, x) => s + x.price_halalas, 0), n = act.length; if (n === 0) { rent = r.rent_amount_halalas ?? 0; n = nightsBetween(r.check_in, r.check_out).length; }
    const disc = discountsOf(r.id); const after = ["checked_in", "checked_out"].includes(r.status); const bp = byId("branches", r.branch_id)?.supervisor_max_discount_bp ?? 0; const mn = byId("room_categories", r.room_category_id)?.min_nightly_halalas ?? null;
    const max = can("disc.after") ? Math.max(0, rent - disc) : after || !["confirmed", "pending_verification"].includes(r.status) ? 0 : Math.max(0, Math.min(Math.floor((rent * bp) / 10000) - disc, rent - disc - (mn != null ? mn * n : 0)));
    return { rent, discounts: disc, nights: n, after_arrival: after, max, percent_bp: bp, min_nightly: mn, unlimited: can("disc.after") }; },
  fn_reservation_nights: ({ p_reservation }) => { const r = byId("reservations", p_reservation); if (!r || !seesMoney() || !myBranches().includes(r.branch_id)) return null; ensureNights(r.id);
    return T("reservation_nights").filter((x) => x.reservation_id === r.id).sort((a, b) => (a.night === b.night ? (a.created_at < b.created_at ? -1 : 1) : a.night < b.night ? -1 : 1)).map((x) => ({ night: x.night, price: x.price_halalas, basis: x.basis, status: x.status, removed_at: x.removed_at, removed_reason: x.removed_reason })); },
  // decision 36: by staff member, source, unit type and «بعد الوصول» (p_filters), the filters echoed back
  fn_reports_discounts: ({ p_branch, p_from, p_to, p_filters }) => { requireCap("reports.finance"); requireBranch(p_branch); if (!p_from || !p_to || p_to < p_from || nightsBetween(p_from, p_to).length > 366) throw new Error("VALIDATION: range");
    const full = capFull("reports.finance"); const f = p_filters ?? {}; const fStaff = f.staff_id || null, fSource = f.source_id || null, fCat = f.category_id || null, fAfter: boolean | null = f.after_arrival == null || f.after_arrival === "" ? null : f.after_arrival === true || f.after_arrival === "true";
    const rows = T("reservation_charges").filter((c) => c.branch_id === p_branch && c.kind === "discount" && dayOf(c.created_at) >= p_from && dayOf(c.created_at) <= p_to).map((c) => { const r = byId("reservations", c.reservation_id)!; const s = byId("staff_profiles", c.created_by);
      return { id: c.id, reservation_id: r.id, internal_ref: r.internal_ref, amount_halalas: roundHalfUp(Math.abs(Number(c.quantity) * c.unit_price_halalas)), reason: c.reason ?? c.description, staff: s?.full_name ?? null, role: s?.role ?? null, created_at: c.created_at, after_arrival: !!r.actual_check_in && c.created_at >= r.actual_check_in, _by: c.created_by ?? null, _source: r.source_id, _cat: r.room_category_id }; })
      .filter((x) => (!fStaff || x._by === fStaff) && (!fSource || x._source === fSource) && (!fCat || x._cat === fCat) && (fAfter == null || x.after_arrival === fAfter))
      .map(({ _by, _source, _cat, ...x }) => { void _by; void _source; void _cat; return x; })
      .sort((a, b) => (a.created_at < b.created_at ? 1 : -1));
    const by = new Map<string, { staff: string | null; role: string | null; count: number; total_halalas: number }>(); for (const x of rows) { const k = `${x.staff}|${x.role}`; const e = by.get(k) ?? { staff: x.staff, role: x.role, count: 0, total_halalas: 0 }; e.count++; e.total_halalas += x.amount_halalas; by.set(k, e); }
    const filters: Row = {}; if (fStaff) filters.staff_id = fStaff; if (fSource) filters.source_id = fSource; if (fCat) filters.category_id = fCat; if (fAfter != null) filters.after_arrival = fAfter;
    return { period: { from: p_from, to: p_to }, filters, total_halalas: rows.reduce((s, x) => s + x.amount_halalas, 0), count: rows.length, by_staff: [...by.values()].sort((a, b) => b.total_halalas - a.total_halalas), rows: full ? rows : null }; },
  fn_rate_calendar: ({ p_branch, p_from, p_to }) => { requireCap("rates"); requireBranch(p_branch); if (!p_from || !p_to || p_to < p_from || nightsBetween(p_from, p_to).length > 92) throw new Error("VALIDATION: range");
    const days = [...nightsBetween(p_from, p_to), p_to];
    return { today: branchToday(), from: p_from, to: p_to, categories: T("room_categories").filter((c) => c.branch_id === p_branch && !c.archived_at).sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0) || String(a.name_ar).localeCompare(String(b.name_ar))).map((c) => {
      const units = T("rooms").filter((rm) => rm.category_id === c.id && !rm.archived_at && rm.is_active !== false).length;
      return { id: c.id, name: c.name_ar, base_price: c.base_price_halalas, weekly_price: c.weekly_price_halalas ?? null, monthly_price: c.monthly_price_halalas ?? null, min_nightly: c.min_nightly_halalas ?? null, price_mode: c.price_mode ?? "unified", units,
        days: days.map((night) => { const rc = T("rate_calendar").find((x) => x.category_id === c.id && x.night === night); const busy = T("reservations").filter((r) => r.room_category_id === c.id && ["confirmed", "checked_in"].includes(r.status) && night >= r.check_in && night < r.check_out).length;
          return { night, price: rc?.price_halalas ?? null, platform_price: rc?.platform_price_halalas ?? null, available: Math.max(0, units - busy) }; }) }; }) }; },
  fn_rate_calendar_set: ({ p }) => { requireCap("rates"); requireBranch(p.branch_id); const today = branchToday();
    const setP = p.price_halalas != null && p.price_halalas !== "", setPP = p.platform_price_halalas != null && p.platform_price_halalas !== "";
    const clear: "both" | "price" | "platform" | null = p.clear === true ? "both" : p.clear === "price" || p.clear === "platform" ? p.clear : null;
    if (!clear && !setP && !setPP) throw new Error("VALIDATION: price"); if ((setP && !(Number(p.price_halalas) > 0)) || (setPP && !(Number(p.platform_price_halalas) > 0))) throw new Error("VALIDATION: amount");
    const cats = T("room_categories").filter((c) => c.branch_id === p.branch_id && !c.archived_at);
    let cells: Array<{ c: Row; night: string }>;
    if (Array.isArray(p.cells)) cells = p.cells.map((x: Row) => ({ c: cats.find((c) => c.id === x.category_id)!, night: x.night })).filter((x: { c: Row | undefined }) => !!x.c);
    else { if (!p.from || !p.to || p.to < p.from || nightsBetween(p.from, p.to).length > 731) throw new Error("VALIDATION: range"); const ids: string[] = Array.isArray(p.category_ids) ? p.category_ids : []; if (!ids.length) throw new Error("VALIDATION: categories");
      const wd: number[] | null = Array.isArray(p.weekdays) && p.weekdays.length ? p.weekdays.map(Number) : null; const nights = [...nightsBetween(p.from, p.to), p.to].filter((d) => !wd || wd.includes(new Date(d + "T00:00:00Z").getUTCDay()));
      cells = []; for (const night of nights) for (const c of cats.filter((x) => ids.includes(x.id))) cells.push({ c, night }); }
    if (!cells.length) throw new Error("VALIDATION: cells"); if (cells.length > 5000) throw new Error("VALIDATION: too_many_cells");
    const before: Row[] = []; let changed = 0;
    for (const { c, night } of cells) {
      if (night < today) throw new Error("VALIDATION: past_night");
      if (setP && c.min_nightly_halalas != null && Number(p.price_halalas) < c.min_nightly_halalas) throw new Error("VALIDATION: below_minimum");
      if (setPP && c.price_mode === "by_channel" && c.min_nightly_halalas != null && Number(p.platform_price_halalas) < c.min_nightly_halalas) throw new Error("VALIDATION: below_minimum");
    }
    for (const { c, night } of cells) {
      let rc = T("rate_calendar").find((x) => x.category_id === c.id && x.night === night); const oldP = rc?.price_halalas ?? null, oldPP = rc?.platform_price_halalas ?? null;
      const newP = clear === "both" || clear === "price" ? null : setP ? Number(p.price_halalas) : oldP; const newPP = clear === "both" || clear === "platform" ? null : setPP && c.price_mode === "by_channel" ? Number(p.platform_price_halalas) : oldPP;
      if (newP === oldP && newPP === oldPP) continue;
      if (!rc) { rc = { id: uid(), organization_id: ORG, branch_id: p.branch_id, category_id: c.id, night, created_at: nowISO() }; T("rate_calendar").push(rc); }
      Object.assign(rc, { price_halalas: newP, platform_price_halalas: newPP, updated_by: staffId(), updated_at: nowISO() }); changed++;
      if (before.length < 400) before.push({ category_id: c.id, night, price: oldP, platform_price: oldPP });
    }
    if (changed) { emit("rate_calendar"); audit(p.branch_id, "rates.updated", "rate_calendar", p.branch_id, { before: { cells: before, more: Math.max(changed - 400, 0) }, after: { changed, price_halalas: clear === "both" || clear === "price" ? null : setP ? Number(p.price_halalas) : null, platform_price_halalas: clear === "both" || clear === "platform" ? null : setPP ? Number(p.platform_price_halalas) : null, clear, from: p.from ?? null, to: p.to ?? null, cells: Array.isArray(p.cells) }, reason: p.reason ?? null }); }
    return { ok: true, changed, matched: cells.length }; },
  fn_category_capacity_impact: ({ p_category, p_max_capacity }) => { requireCap("definitions"); const c = byId("room_categories", p_category); if (!c) throw new Error("NOT_FOUND"); requireBranch(c.branch_id); return capacityImpact(c.id, Number(p_max_capacity)); },
  fn_staff_quote: ({ p_branch, p_category, p_check_in, p_check_out, p_nightly_override, p_discount_halalas }) => quote(p_branch, p_category, p_check_in, p_check_out, p_nightly_override, p_discount_halalas ?? 0),
  fn_available_rooms: ({ p_branch, p_from, p_to, p_category, p_exclude_reservation }) => T("rooms").filter((r) => r.branch_id === p_branch && myBranches().includes(p_branch) && r.is_active && !r.archived_at && !["blocked", "out_of_service", "maintenance"].includes(r.status) && (!p_category || r.category_id === p_category) && roomAvailable(r.id, p_from, p_to, p_exclude_reservation)).map((r) => ({ room_id: r.id, room_number: r.room_number, category_id: r.category_id, category_name: byId("room_categories", r.category_id)?.name_ar, status: r.status, cleanliness: r.cleanliness, block_name: byId("blocks", r.block_id)?.name ?? null, floor_name: byId("floors", r.floor_id)?.name ?? null })).sort((a, b) => a.room_number.localeCompare(b.room_number, "en", { numeric: true })),
  fn_room_available: ({ p_room, p_from, p_to, p_exclude_reservation }) => roomAvailable(p_room, p_from, p_to, p_exclude_reservation),
  // multi-unit booking (0011): one reservation per unit sharing group_ref, all-or-nothing
  fn_staff_create_reservation: ({ p }) => {
    requireCap("res.create");
    const units: any[] | null = Array.isArray(p.units) && p.units.length > 0 ? p.units : null;
    if (!units) return createReservationUnit(p, null);
    if (units.length > 20) throw new Error("VALIDATION: too many units");
    const g = units.length > 1 ? "G-" + Math.random().toString(16).slice(2, 10).toUpperCase() : null;
    const tables = ["reservations", "reservation_guests", "reservation_charges", "reservation_allocations", "rooms", "audit_events", "guest_profiles", "financial_vouchers", "reservation_nights"];
    const snapshot = Object.fromEntries(tables.map((t) => [t, JSON.parse(JSON.stringify(T(t)))]));
    try {
      const { units: _u, ...base } = p; void _u;
      const results = units.map((u) => createReservationUnit({ ...base, ...u }, g));
      return { ...results[0], ids: results.map((x) => x.id), internal_refs: results.map((x) => x.internal_ref), group_ref: g, units: units.length };
    } catch (e) { for (const t of tables) S[t] = snapshot[t]; emitAll(); throw e; }
  },
  fn_reservation_group: ({ p_reservation }) => { const r = byId("reservations", p_reservation); if (!r || !r.group_ref || !myBranches().includes(r.branch_id)) return []; return T("reservations").filter((x) => x.group_ref === r.group_ref).map((x) => ({ id: x.id, internal_ref: x.internal_ref, status: x.status, room_number: roomNo(x.room_id), category_name: byId("room_categories", x.room_category_id)?.name_ar ?? null, check_in: x.check_in, check_out: x.check_out, adults: x.adults, companions: x.companions })).sort((a, b) => a.internal_ref.localeCompare(b.internal_ref)); },
};
function createReservationUnit(p: any, groupRef: string | null) { requireCap("res.create"); requireBranch(p.branch_id); if (!p.check_in || !p.check_out || p.check_out <= p.check_in) throw new Error("VALIDATION: dates"); nonEmpty(p.guest_name, "guest_name"); checkPersonName(p.guest_name); p = { ...p, guest_phone: checkPhone(p.guest_phone, !p.guest_profile_id) };
    const details: any[] = Array.isArray(p.companions_details) ? p.companions_details : []; for (const d of details) { if (!String(d?.full_name ?? "").trim()) throw new Error("VALIDATION: companion_name"); checkPersonName(String(d.full_name)); checkPhone(d?.phone, false); }
    const timeOk = (t: any) => t == null || t === "" || /^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$/.test(String(t)); if (!timeOk(p.arrival_time) || !timeOk(p.departure_time)) throw new Error("VALIDATION: times");
    const br = byId("branches", p.branch_id); const arrival = p.arrival_time ? String(p.arrival_time).slice(0, 5) + ":00" : br?.check_in_time ?? "16:00:00"; const departure = p.departure_time ? String(p.departure_time).slice(0, 5) + ":00" : br?.check_out_time ?? "12:00:00";
    const src = byId("booking_sources", p.source_id); if (!src || !src.is_active) throw new Error("VALIDATION: source"); const ext = String(p.external_ref ?? "").trim() || null; if (src.external_reference_required && !ext) throw new Error("VALIDATION: external_ref_required");
    // decision 4: a platform's booking says who collects and when it was booked there
    const platform = src.kind === "external"; let collects: boolean | null = null; let bookedOn: string | null = null;
    if (platform) {
      if (p.platform_collects == null) throw new Error("VALIDATION: platform_collects"); collects = !!p.platform_collects;
      bookedOn = String(p.platform_booked_on ?? "").slice(0, 10) || null; const today = branchToday(p.branch_id);
      if (!bookedOn || !/^\d{4}-\d{2}-\d{2}$/.test(bookedOn) || bookedOn > today || Date.parse(p.check_in) - Date.parse(bookedOn) > 730 * 86400000) throw new Error("VALIDATION: platform_booked_on");
    }
    const cat = byId("room_categories", p.category_id); if (!cat || cat.branch_id !== p.branch_id) throw new Error("BRANCH_MISMATCH: category"); if (cat.archived_at) throw new Error("CATEGORY_ARCHIVED: this unit type is archived"); const adults = p.adults ?? 1, comp = Math.max(p.companions ?? 0, details.length); if (adults < 1 || comp < 0) throw new Error("VALIDATION: guests"); if (adults + comp > cat.max_capacity) throw new Error("CAPACITY_EXCEEDED");
    // decision 69: one platform number per booking or group (the units of a group share it)
    if (ext && T("reservations").some((r) => r.source_id === src.id && r.external_ref === ext && (r.group_ref ?? r.id) !== (groupRef ?? "-"))) throw new Error("DUPLICATE_EXTERNAL_REF");
    const disc = Number(p.discount_halalas ?? 0); const ovr = p.nightly_rate_halalas == null || p.nightly_rate_halalas === "" ? null : Number(p.nightly_rate_halalas);
    const q = quoteStay({ branch_id: p.branch_id, category_id: p.category_id, check_in: p.check_in, check_out: p.check_out, source_id: src.id, nightly_rate_halalas: ovr, discount_halalas: disc });
    // a manual nightly price under what the stay would cost is a discount by another name: the owner's or a manager's (0030)
    if (ovr != null && q.rent_gross < q.computed_rent && !hasRole("owner", "manager")) throw new Error("FORBIDDEN: rate below the quoted price requires manager");
    if (disc > 0 && !String(p.discount_reason ?? "").trim()) throw new Error("VALIDATION: discount_reason");
    checkDiscount(cat.id, p.branch_id, q.nights, q.rent_gross, 0, disc, false);
    const id = uid(); const ref = "R-" + Math.random().toString(16).slice(2, 10).toUpperCase();
    const r: Row = { id, organization_id: ORG, branch_id: p.branch_id, tax_rate_bp: br?.tax_rate_bp ?? 0, prices_include_tax: !!br?.prices_include_tax, internal_ref: ref, external_ref: ext, source_id: src.id, platform_booked_on: bookedOn, platform_collects: collects, platform_verified_at: null, platform_verified_by: null, cancel_reference: null, security_hold_by: null, security_hold_at: null, status: p.confirm === false ? "pending_verification" : "confirmed", booking_type: p.booking_type ?? "individual", company_name: p.company_name ?? null, visit_purpose: p.visit_purpose ?? null, check_in: p.check_in, check_out: p.check_out, adults, companions: comp, room_category_id: cat.id, room_id: null, rent_amount_halalas: 0, discount_halalas: 0, addons_halalas: 0, taxes_halalas: 0, total_halalas: 0, paid_halalas: 0, payment_status: "pending", identity_status: "not_started", government_registration: false, access_status: "locked", keybox_delivered: false, checkin_approved_by: null, checkin_approved_at: null, actual_check_in: null, actual_check_out: null, notes: p.notes ?? null, created_at: nowISO(), created_by: staffId(), security_hold: false, security_hold_reason: null, gov_registration_ref: null, updated_at: nowISO(), version: 1, rate_type: "daily", nightly_rate_halalas: q.nightly_rate, price_basis: q.basis, cancelled_at: null, cancel_reason: null, cancel_source: null, no_show_at: null, deposit_balance_halalas: 0, refunded_halalas: 0, balance_due_halalas: 0, expected_arrival_time: arrival, expected_departure_time: departure, group_ref: groupRef,
      checked_in_by: null, checked_out_by: null, closed_at: null, deposit_waiver_reason: null, deposit_waiver_by: null, deposit_waiver_at: null, gov_registration_by: null, gov_registration_at: null, shomoos_guest_count: null, shomoos_accepted_at: null, shomoos_accepted_by: null, late_checkout_until: null, status_before_cancel: null };
    // the guest profile: the one chosen, else the one with this phone, else a new one (never matched by name alone, never merged)
    let gp: Row | undefined = p.guest_profile_id ? byId("guest_profiles", p.guest_profile_id) : undefined; if (p.guest_profile_id && !gp) throw new Error("VALIDATION: guest_profile"); if (gp && !p.guest_phone) p = { ...p, guest_phone: checkPhone(gp.phone, true) };
    if (!gp && !p.new_profile && p.guest_phone) { const ph = normPhone(p.guest_phone); gp = T("guest_profiles").filter((x) => x.organization_id === ORG && (x.phone === p.guest_phone || (ph && normPhone(x.phone) === ph))).sort((a, b) => (a.created_at < b.created_at ? -1 : 1))[0]; }
    if (!gp) { gp = { id: uid(), organization_id: ORG, full_name: p.guest_name, phone: p.guest_phone ?? null, nationality: p.nationality ?? null, email: null, notes: null, identity_fingerprint: null, identity_type: null, identity_last4: null, rating: null, rating_note: null, rated_by: null, rated_at: null, created_at: nowISO(), updated_at: nowISO() }; T("guest_profiles").push(gp); emit("guest_profiles"); }
    T("reservations").push(r); T("reservation_guests").push({ id: uid(), reservation_id: id, guest_profile_id: gp.id, is_primary: true, full_name: p.guest_name, identity_type: null, identity_number_last4: null, nationality: p.nationality ?? null, birth_date: null, phone: p.guest_phone ?? null, relationship: null, verification_status: "not_started", data_submitted: false, created_at: nowISO() });
    for (const d of details) T("reservation_guests").push({ id: uid(), reservation_id: id, guest_profile_id: null, is_primary: false, full_name: String(d.full_name).trim(), identity_type: null, identity_number_last4: null, nationality: d.nationality?.trim() || null, birth_date: null, phone: checkPhone(d.phone, false), relationship: d.relationship?.trim() || null, verification_status: "not_started", data_submitted: false, created_at: nowISO() });
    bookNights(id, q.runs, "إيجار", null); if (disc > 0) addCharge(id, "discount", String(p.discount_reason).trim(), 1, disc, true, String(p.discount_reason).trim());
    if (p.room_id) { if (!roomAvailable(p.room_id, p.check_in, p.check_out)) throw new Error("ROOM_NOT_AVAILABLE"); allocate(id, p.room_id, p.check_in, p.check_out, "create"); }
    const f = recompute(id)!; let vch: Row | null = null;
    // decision 4: the platform collected the stay → its receipt «آجل عبر المنصات», matched later against the platform's deposit
    if (platform && collects && f.total > 0) vch = rpcs.fn_create_voucher({ p: { kind: "receipt", reservation_id: id, amount_halalas: f.total, method: "ota_deferred", reference: ext, note: "قبضته المنصة عند الحجز", idempotency_key: "platform-collect:" + id } });
    audit(p.branch_id, "reservation.created", "reservation", id, { after: { internal_ref: ref, check_in: p.check_in, check_out: p.check_out, quote: q, arrival_time: arrival, departure_time: departure, companions: comp, group_ref: groupRef, guest_profile_id: gp.id, platform_booked_on: bookedOn, platform_collects: collects, platform_voucher: vch?.number ?? null } }); emit("reservation_guests");
    return { ok: true, id, internal_ref: ref, quote: q, group_ref: groupRef, guest_profile_id: gp.id, platform_voucher: vch?.number ?? null }; }
const rpcsMore: Record<string, (a: any) => any> = {
  fn_staff_amend_stay: ({ p_reservation, p_new_check_out, p_pricing_mode, p_reason, p_expected_version }) => { requireCap("stay.extend"); nonEmpty(p_reason, "reason"); if (!["keep_rate", "reprice"].includes(p_pricing_mode)) throw new Error("VALIDATION: pricing_mode"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); checkVersion(r.version, p_expected_version);
    if (!["confirmed", "checked_in", "pending_verification"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID"); if (p_new_check_out <= r.check_in) throw new Error("VALIDATION: dates"); if (r.status === "checked_in" && p_new_check_out <= branchToday() && p_new_check_out < r.check_out) throw new Error("VALIDATION: checkout_in_past");
    const delta = Math.round((Date.parse(p_new_check_out) - Date.parse(r.check_out)) / 86400000); if (delta === 0) return { ok: true, unchanged: true };
    // decision 3: a night unpaid past its deadline stops the extension until it is paid or a reason is recorded
    if (delta > 0 && r.status === "checked_in" && overdueBlocked(r.id)) throw new Error("PAYMENT_OVERDUE: a night is unpaid past its deadline");
    // leaving a weekly or monthly stay early is settled by the owner or a manager (decision 15)
    if (delta < 0 && ["weekly", "monthly"].includes(r.price_basis) && !hasRole("owner", "manager")) throw new Error("FORBIDDEN: shortening a weekly or monthly stay requires manager");
    const before = { check_out: r.check_out, total_halalas: r.total_halalas }; ensureNights(r.id);
    const a = T("reservation_allocations").filter((x) => x.reservation_id === r.id && x.status === "active").sort((x, y) => (x.to_date < y.to_date ? 1 : -1))[0];
    if (a) { if (a.to_date !== r.check_out) throw new Error("ALLOCATION_MISMATCH"); if (p_new_check_out <= a.from_date) throw new Error("VALIDATION: dates"); if (T("reservation_allocations").some((o) => o.id !== a.id && o.room_id === a.room_id && o.status === "active" && overlaps(o.from_date, o.to_date, a.from_date, p_new_check_out))) throw new Error("ALLOCATION_CONFLICT: room is allocated during the added period"); a.to_date = p_new_check_out; emit("reservation_allocations"); }
    let refund = 0;
    if (delta > 0) {
      // keep_rate: the stay's last night's price; reprice: the calendar's (never re-priced as a weekly or monthly stay)
      const last = T("reservation_nights").filter((x) => x.reservation_id === r.id && x.status === "active").sort((x, y) => (x.night < y.night ? 1 : -1))[0];
      const src = byId("booking_sources", r.source_id);
      const runs: Run[] = p_pricing_mode === "keep_rate" ? [{ from: r.check_out, to: p_new_check_out, nights: delta, price: last?.price_halalas ?? r.nightly_rate_halalas, basis: "kept" }]
        : stayRuns(stayPrices(r.room_category_id, r.check_out, p_new_check_out, !!src && src.kind !== "direct", null, false));
      bookNights(r.id, runs, "تمديد", p_reason);
    } else {
      // the refund is exactly the removed nights' prices; the nights keep their rows, marked removed
      const gone = T("reservation_nights").filter((x) => x.reservation_id === r.id && x.status === "active" && x.night >= p_new_check_out && x.night < r.check_out);
      refund = gone.reduce((s, x) => s + x.price_halalas, 0);
      for (const x of gone) Object.assign(x, { status: "removed", removed_at: nowISO(), removed_by: staffId(), removed_reason: p_reason });
      emit("reservation_nights");
      addCharge(r.id, "adjustment", `تقصير الإقامة ${-delta} ليلة`, 1, -refund, true, p_reason, null, p_new_check_out, r.check_out);
    }
    const act = T("reservation_nights").filter((x) => x.reservation_id === r.id && x.status === "active");
    r.check_out = p_new_check_out; if (act.length) r.nightly_rate_halalas = roundHalfUp(act.reduce((s, x) => s + x.price_halalas, 0) / act.length); r.version++; const f = recompute(r.id)!; audit(r.branch_id, "reservation.departure_changed", "reservation", r.id, { before, after: { check_out: p_new_check_out, total_halalas: r.total_halalas, delta_nights: delta }, reason: p_reason }); return { ok: true, delta_nights: delta, finance: f }; },
  // B4 (0048): the platform's fields corrected before arrival and before «طابقتُ مع المنصة»; the group's units change together
  fn_staff_update_platform: ({ p_reservation, p, p_reason, p_expected_version }) => atomically(() => { requireCap("res.create"); nonEmpty(p_reason, "reason"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); checkVersion(r.version, p_expected_version);
    const src = byId("booking_sources", r.source_id); if (!src || src.kind !== "external") throw new Error("VALIDATION: not_platform");
    if (!["confirmed", "pending_verification"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID"); if (r.platform_verified_at) throw new Error("PLATFORM_VERIFIED");
    const q = p ?? {};
    // 0048 (the owner's decision, 30 Oct): another platform re-prices the whole stay by its prices
    let nsrc = src; let srcChanged = false;
    if (q.source_id && q.source_id !== r.source_id) { const x = byId("booking_sources", q.source_id); if (!x || x.organization_id !== r.organization_id || !x.is_active || x.kind !== "external") throw new Error("VALIDATION: source"); nsrc = x; srcChanged = true; requireMoney(); }
    const ext: string | null = "external_ref" in q ? (latinDigits(String(q.external_ref ?? "")).trim() || null) : r.external_ref; if (nsrc.external_reference_required && !ext) throw new Error("VALIDATION: external_ref_required");
    const booked: string | null = "platform_booked_on" in q ? q.platform_booked_on || null : r.platform_booked_on; if (!booked || !/^\d{4}-\d{2}-\d{2}$/.test(booked) || booked > branchToday() || booked < addDays(r.check_in, -730)) throw new Error("VALIDATION: platform_booked_on");
    const collects: boolean | null = "platform_collects" in q ? !!q.platform_collects : r.platform_collects; if (collects == null) throw new Error("VALIDATION: platform_collects");
    if (ext && T("reservations").some((x) => x.source_id === nsrc.id && x.external_ref === ext && (x.group_ref ?? x.id) !== (r.group_ref ?? r.id))) throw new Error("DUPLICATE_EXTERNAL_REF");
    const units = T("reservations").filter((x) => x.id === r.id || (r.group_ref && x.group_ref === r.group_ref && x.organization_id === r.organization_id)); for (const u of units) requireBranch(u.branch_id);
    for (const u of units) if (u.id !== r.id && !["confirmed", "pending_verification", "cancelled", "no_show"].includes(u.status)) throw new Error("GROUP_UNIT_IN_HOUSE");
    const vouchers: string[] = []; const repriced: Row[] = []; let n = 0;
    for (const u of units) {
      if (u.id !== r.id && ["cancelled", "no_show"].includes(u.status)) { if (u.external_ref !== ext || u.source_id !== nsrc.id) { const was = { external_ref: u.external_ref, source_id: u.source_id }; Object.assign(u, { external_ref: ext, source_id: nsrc.id }); u.version++; audit(u.branch_id, "reservation.platform_updated", "reservation", u.id, { before: was, after: { external_ref: ext, source_id: nsrc.id }, reason: p_reason }); } continue; }
      if (!!u.platform_collects !== collects) requireMoney();
      const before = { external_ref: u.external_ref, platform_booked_on: u.platform_booked_on, platform_collects: u.platform_collects };
      if (u.platform_collects && !collects) { for (const v of T("financial_vouchers").filter((x) => x.reservation_id === u.id && ["refund", "receipt"].includes(x.kind) && x.method === "ota_deferred" && x.status === "approved").sort((a, b) => (a.kind === b.kind ? (a.created_at < b.created_at ? -1 : 1) : a.kind === "refund" ? -1 : 1))) cancelVoucherCore(v.id, "تغيير من يقبض: المنشأة عند الوصول — " + p_reason); }
      else if (!u.platform_collects && collects) { const f = financeOf(u.id); const owed = f.total - (f.received - f.refunded); if (owed > 0) { const v = rpcs.fn_create_voucher({ p: { kind: "receipt", reservation_id: u.id, amount_halalas: owed, method: "ota_deferred", reference: ext, note: "قبضته المنصة عند الحجز", reason: p_reason, idempotency_key: "platform-collect:" + u.id + ":" + u.version } }); vouchers.push(v.number); } }
      let oldSum: number | null = null, newSum: number | null = null;
      if (srcChanged) {
        ensureNights(u.id); const gone = T("reservation_nights").filter((x) => x.reservation_id === u.id && x.status === "active"); oldSum = gone.reduce((a, x) => a + x.price_halalas, 0);
        for (const x of gone) Object.assign(x, { status: "removed", removed_at: nowISO(), removed_by: staffId(), removed_reason: "تغيير المنصة: " + p_reason });
        if (oldSum !== 0) addCharge(u.id, "adjustment", "تغيير المنصة: إلغاء سعر المنصة السابقة", 1, -oldSum, true, p_reason, null, u.check_in, u.check_out);
        const runs = stayRuns(stayPrices(u.room_category_id, u.check_in, u.check_out, true, null, true)); newSum = bookNights(u.id, runs, "تغيير المنصة", p_reason);
        const disc = T("reservation_charges").filter((c) => c.reservation_id === u.id && c.kind === "discount").reduce((a, c) => a - c.total_halalas, 0); if (disc > newSum) throw new Error("VALIDATION: discount_exceeds_rent");
        const act = T("reservation_nights").filter((x) => x.reservation_id === u.id && x.status === "active"); if (act.length) u.nightly_rate_halalas = roundHalfUp(act.reduce((a, x) => a + x.price_halalas, 0) / act.length);
        u.price_basis = runs.some((x) => x.basis === "monthly") ? "monthly" : runs.some((x) => x.basis === "weekly") ? "weekly" : "daily";
        repriced.push({ reservation_id: u.id, old_nights_halalas: oldSum, new_nights_halalas: newSum });
      }
      Object.assign(u, { external_ref: ext, source_id: nsrc.id, platform_booked_on: booked, platform_collects: collects, updated_at: nowISO() }); u.version++; recompute(u.id); n++;
      audit(u.branch_id, "reservation.platform_updated", "reservation", u.id, { before: { ...before, source_id: src.id }, after: { external_ref: ext, source_id: nsrc.id, platform_booked_on: booked, platform_collects: collects, vouchers, old_nights_halalas: oldSum, new_nights_halalas: newSum, total_halalas: u.total_halalas }, reason: p_reason });
    }
    emit("reservations"); return { ok: true, units: n, vouchers, repriced, finance: financeOf(r.id) }; }),
  fn_staff_switch_room: ({ p_reservation, p_room, p_effective, p_reason, p_expected_version }) => atomically(() => { requireCap("room.assign"); nonEmpty(p_reason, "reason"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); checkVersion(r.version, p_expected_version);
    if (!["confirmed", "checked_in", "pending_verification"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID"); const today = branchToday(); const eff = p_effective ?? (today > r.check_in ? today : r.check_in); if (eff < r.check_in || eff >= r.check_out) throw new Error("VALIDATION: effective_date"); if (r.status === "checked_in" && eff > today) throw new Error("VALIDATION: effective_date");
    const rm = byId("rooms", p_room); if (!rm || rm.branch_id !== r.branch_id) throw new Error("ROOM_NOT_FOUND"); if (r.room_id === p_room) throw new Error("SAME_ROOM"); if (r.status === "checked_in" && rm.cleanliness !== "clean") throw new Error("ROOM_NOT_CLEAN"); if (r.adults + r.companions > byId("room_categories", rm.category_id)!.max_capacity) throw new Error("CAPACITY_EXCEEDED");
    const old = T("reservation_allocations").find((a) => a.reservation_id === r.id && a.status === "active" && a.from_date <= eff && eff < a.to_date); let oldRoom: string | null = null;
    if (old) { oldRoom = old.room_id; if (old.from_date === eff) { old.status = "cancelled"; old.closed_at = nowISO(); } else { old.to_date = eff; if (r.status === "checked_in") { old.status = "closed"; old.closed_at = nowISO(); } } if (r.status === "checked_in") createCleaningTask(r.branch_id, oldRoom!, r.id, "تبديل وحدة"); else { const orm = byId("rooms", oldRoom!)!; if (orm.status === "reserved") orm.status = "available"; } }
    // B5 (0048): before check-in, another type re-prices the nights from the effective day; a platform-collected stay and a resident keep the price
    const fromCat = r.room_category_id; const total0 = r.total_halalas; const reprice = ["confirmed", "pending_verification"].includes(r.status) && fromCat !== rm.category_id; let oldSum = 0; let newSum = 0;
    if (r.room_category_id !== rm.category_id) r.room_category_id = rm.category_id;
    // the new unit's code is delivered as its own step (0033): nothing marks it the guest's before that; a unit without a box takes its key at reception
    allocate(r.id, p_room, eff, r.check_out, "switch: " + p_reason);
    if (reprice) {
      ensureNights(r.id); const gone = T("reservation_nights").filter((x) => x.reservation_id === r.id && x.status === "active" && x.night >= eff && x.night < r.check_out);
      oldSum = gone.reduce((s, x) => s + x.price_halalas, 0); for (const x of gone) Object.assign(x, { status: "removed", removed_at: nowISO(), removed_by: staffId(), removed_reason: "تبديل وحدة: " + p_reason });
      if (oldSum !== 0) addCharge(r.id, "adjustment", "تبديل وحدة: إلغاء سعر النوع السابق", 1, -oldSum, true, p_reason, null, eff, r.check_out);
      const src = byId("booking_sources", r.source_id); const runs = stayRuns(stayPrices(rm.category_id, eff, r.check_out, !!src && src.kind !== "direct", null, eff === r.check_in)); newSum = bookNights(r.id, runs, "تبديل وحدة", p_reason);
      const act = T("reservation_nights").filter((x) => x.reservation_id === r.id && x.status === "active");
      const disc = T("reservation_charges").filter((c) => c.reservation_id === r.id && c.kind === "discount").reduce((s, c) => s - c.total_halalas, 0);
      if (disc > act.reduce((s, x) => s + x.price_halalas, 0)) throw new Error("VALIDATION: discount_exceeds_rent");
      if (act.length) r.nightly_rate_halalas = roundHalfUp(act.reduce((s, x) => s + x.price_halalas, 0) / act.length);
      if (eff === r.check_in && r.price_basis !== "manual") r.price_basis = runs.some((x) => x.basis === "monthly") ? "monthly" : runs.some((x) => x.basis === "weekly") ? "weekly" : "daily";
      recompute(r.id);
    }
    const keptReason = reprice ? null : fromCat === rm.category_id ? "same_type" : "in_house"; const newKb = hasKeybox(p_room); if (r.status === "checked_in") { rm.status = "occupied"; Object.assign(r, { access_status: newKb ? "approved" : "key_handed", keybox_delivered: false }); }
    r.version++; r.updated_at = nowISO(); emit("rooms"); emit("reservations"); audit(r.branch_id, "reservation.room_switched", "reservation", r.id, { before: { room_id: oldRoom, category_id: fromCat, total_halalas: total0 }, after: { room_id: p_room, effective: eff, category_id: rm.category_id, repriced: reprice, old_nights_halalas: oldSum, new_nights_halalas: newSum, total_halalas: r.total_halalas }, reason: p_reason }); return { ok: true, from_room: oldRoom, to_room: p_room, effective: eff, entry_code_review_required: r.status === "checked_in", code_delivery_required: r.status === "checked_in" && newKb, repriced: reprice, price_delta_halalas: newSum - oldSum, price_kept_reason: keptReason }; }),
  fn_staff_adjust_price: ({ p_reservation, p_kind, p_amount_halalas, p_description, p_reason, p_expected_version }) => { if (!["discount", "adjustment", "penalty", "addon"].includes(p_kind)) throw new Error("VALIDATION: kind"); if (p_kind === "adjustment") requireCap("price.adjust"); else if (p_kind === "discount") requireAnyCap(["disc.before", "disc.after"]); else requireCap("charges.add"); nonEmpty(p_reason, "reason"); if (!p_amount_halalas || (p_kind !== "adjustment" && p_amount_halalas < 0)) throw new Error("VALIDATION: amount"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); checkVersion(r.version, p_expected_version); if (["cancelled", "rejected", "closed", "no_show"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID");
    if (p_kind === "discount") { ensureNights(r.id); const act = T("reservation_nights").filter((x) => x.reservation_id === r.id && x.status === "active"); checkDiscount(r.room_category_id, r.branch_id, act.length, act.reduce((s, x) => s + x.price_halalas, 0), discountsOf(r.id), p_amount_halalas, ["checked_in", "checked_out"].includes(r.status)); }
    const before = { total_halalas: r.total_halalas }; addCharge(r.id, p_kind, p_description || p_kind, 1, p_amount_halalas, true, p_reason); r.version++; const f = recompute(r.id)!; audit(r.branch_id, "reservation.total_changed", "reservation", r.id, { before, after: { total_halalas: r.total_halalas, kind: p_kind, amount_halalas: p_amount_halalas }, reason: p_reason }); return { ok: true, finance: f }; },
  fn_staff_add_service: ({ p_reservation, p_service, p_quantity, p_note }) => { requireCap("charges.add"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); if (["cancelled", "rejected", "closed", "no_show"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID"); const s = byId("service_definitions", p_service); if (!s || s.branch_id !== r.branch_id || s.archived_at || !s.is_active) throw new Error("SERVICE_NOT_AVAILABLE");
    // decision 3: an overdue night stops new services until it is paid or a reason is recorded; decision 10: late check-out is a service of an open stay
    if (r.status === "checked_in" && overdueBlocked(r.id)) throw new Error("PAYMENT_OVERDUE: a night is unpaid past its deadline");
    const late: string | null = s.late_checkout_until ?? null; if (late && !["pending_verification", "confirmed", "checked_in"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID");
    const nights = Math.round((Date.parse(r.check_out) - Date.parse(r.check_in)) / 86400000); const qty = s.billing_unit === "night" ? nights : s.billing_unit === "person" ? r.adults + r.companions : s.billing_unit === "quantity" ? p_quantity ?? 1 : 1; if (!(Number(qty) > 0)) throw new Error("VALIDATION: quantity");
    const cid = addCharge(r.id, "addon", s.name_ar + (p_note ? " — " + p_note : ""), qty, s.is_free ? 0 : s.price_halalas, s.taxable, null, s.id, s.billing_unit === "night" ? r.check_in : null, s.billing_unit === "night" ? r.check_out : null);
    if (late) { byId("reservation_charges", cid)!.purpose = "late_checkout"; const curLate = r.late_checkout_until ? String(r.late_checkout_until).slice(0, 5) + ":00" : null; r.late_checkout_until = curLate && curLate > late ? curLate : late; }
    r.version++; const f = recompute(r.id)!; audit(r.branch_id, "reservation.service_added", "reservation", r.id, { after: { service_id: s.id, name: s.name_ar, quantity: qty, unit_price: s.is_free ? 0 : s.price_halalas, late_checkout_until: late ? late.slice(0, 5) : null } }); return { ok: true, finance: f, late_checkout_until: late ? late.slice(0, 5) : null }; },
  fn_staff_cancel_reservation: ({ p_reservation, p_reason, p_source }) => { requireCap("res.cancel"); nonEmpty(p_reason, "reason"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); if (["cancelled", "rejected", "no_show"].includes(r.status)) return { ok: true, duplicate: true, status: r.status }; if (["checked_in", "checked_out", "closed"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID");
    // one moment for the cancellation and what it released, and the status it cancelled: the correction within the hour finds both (0033)
    const at = nowISO(); const was = r.status; releaseAllocations(r.id, "cancel", at); Object.assign(r, { status: "cancelled", status_before_cancel: was, cancelled_at: at, cancel_reason: p_reason, cancel_source: p_source ?? "staff", access_status: "locked", version: r.version + 1, updated_at: at }); emit("reservations"); const f = financeOf(r.id); audit(r.branch_id, "reservation.cancelled", "reservation", r.id, { before: { status: was }, after: { status: "cancelled", source: p_source ?? "staff" }, reason: p_reason }); return { ok: true, duplicate: false, status: "cancelled", refund_required_separately: f.net_collected > 0 || f.deposit_balance > 0 }; },
  // decision 4: a platform's booking is cancelled with the platform's cancellation number, once; the whole group at once; no refund by itself
  fn_staff_cancel: ({ p }) => atomically(() => {
    requireCap("res.cancel"); const reason = String(p.reason ?? "").trim(); if (!reason) throw new Error("VALIDATION: reason");
    const r = byId("reservations", p.reservation_id); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id);
    const src = byId("booking_sources", r.source_id); const byPlatform = src?.kind === "external" && p.by_platform !== false; const num = String(p.cancel_number ?? "").trim() || null;
    if (byPlatform && !num) throw new Error("VALIDATION: cancel_number"); if (num && num.length > 60) throw new Error("VALIDATION: cancel_number");
    const source = byPlatform ? "platform" : "staff"; const evSource = "platform:" + (src?.code ?? "");
    const units = p.whole_group && r.group_ref ? T("reservations").filter((x) => x.group_ref === r.group_ref).sort((a, b) => a.id.localeCompare(b.id)) : [r];
    let ev: Row | undefined;
    if (byPlatform) {
      ev = T("integration_events").find((e) => e.source === evSource && e.external_event_id === num);
      if (ev?.state === "processed") { ev.attempts = (ev.attempts ?? 1) + 1; return { ok: true, duplicate: true, cancelled: 0, status: r.status }; }
      if (!ev) { ev = { id: uid(), organization_id: ORG, source: evSource, external_event_id: num, kind: "reservation.cancelled", reference: r.external_ref, state: "received", payload_redacted: null, result: null, attempts: 1, created_at: nowISO(), processed_at: null }; T("integration_events").push(ev); }
    }
    let n = 0; let money = false; let collected = false;
    for (const t of units) {
      if (["cancelled", "rejected", "no_show"].includes(t.status)) continue;
      if (["checked_in", "checked_out", "closed"].includes(t.status)) throw new Error("RESERVATION_STATUS_INVALID");
      const at = nowISO(); const was = t.status; releaseAllocations(t.id, "cancel", at);
      Object.assign(t, { status: "cancelled", status_before_cancel: was, cancelled_at: at, cancel_reason: reason, cancel_source: source, cancel_reference: num, access_status: "locked", version: t.version + 1, updated_at: at });
      audit(t.branch_id, "reservation.cancelled", "reservation", t.id, { before: { status: was }, after: { status: "cancelled", source, cancel_reference: num, whole_group: !!(p.whole_group && t.group_ref) }, reason });
      const f = financeOf(t.id); money = money || f.net_collected > 0 || f.deposit_balance > 0;
      collected = collected || T("financial_vouchers").some((v) => v.reservation_id === t.id && v.method === "ota_deferred" && v.kind === "receipt" && v.status === "approved");
      n++;
    }
    if (ev) Object.assign(ev, { state: "processed", processed_at: nowISO(), result: { reservations: n, reservation_id: r.id } });
    emit("reservations"); emit("integration_events");
    return { ok: true, duplicate: n === 0, cancelled: n, status: "cancelled", refund_required_separately: money, platform_collected: collected };
  }),
  fn_staff_no_show: ({ p_reservation, p_reason }) => { requireCap("res.cancel"); nonEmpty(p_reason, "reason"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); if (!["confirmed", "pending_verification"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID"); if (r.check_in > branchToday()) throw new Error("VALIDATION: arrival_not_due"); releaseAllocations(r.id, "cancel"); Object.assign(r, { status: "no_show", no_show_at: nowISO(), cancel_reason: p_reason, access_status: "locked", version: r.version + 1 }); emit("reservations"); audit(r.branch_id, "reservation.no_show", "reservation", r.id, { reason: p_reason }); return { ok: true }; },
  fn_reservation_finance: ({ p_reservation }) => { const r = byId("reservations", p_reservation); if (!r || !myBranches().includes(r.branch_id) || !seesMoney()) return null; return financeOf(p_reservation); },
  fn_reservation_detail: ({ p_reservation }) => { const r = byId("reservations", p_reservation); if (!r || !myBranches().includes(r.branch_id)) return null; const money = seesMoney();
    const reservation = { ...r }; delete reservation.notes; if (!money) for (const k of ["total_halalas", "paid_halalas", "rent_amount_halalas", "discount_halalas", "addons_halalas", "taxes_halalas", "balance_due_halalas", "deposit_balance_halalas", "refunded_halalas", "nightly_rate_halalas", "payment_status", "platform_collects"]) delete reservation[k];
    const src = byId("booking_sources", r.source_id); const room = byId("rooms", r.room_id);
    return { reservation, notes: r.notes, source: src ? { name: src.name, code: src.code, kind: src.kind } : null, category: byId("room_categories", r.room_category_id)?.name_ar ?? null, room: room ? { id: room.id, room_number: room.room_number, status: room.status, cleanliness: room.cleanliness } : null,
      guests: money ? T("reservation_guests").filter((g) => g.reservation_id === r.id).sort((a, b) => Number(b.is_primary) - Number(a.is_primary) || (a.created_at < b.created_at ? -1 : 1)).map((g) => ({ id: g.id, is_primary: g.is_primary, full_name: g.full_name, identity_type: g.identity_type, identity_number_last4: g.identity_number_last4, nationality: g.nationality, phone: hasRole("owner", "manager", "supervisor") ? g.phone : null, relationship: g.relationship, birth_date: hasRole("owner", "manager", "supervisor") ? g.birth_date : null, verification_status: g.verification_status, data_submitted: g.data_submitted,
        entry_path: g.entry_path ?? null, verified_at: g.verified_at ?? null, verified_by: staffName(g.verified_by), profile_id: g.guest_profile_id ?? null,
        profile_mismatch: !!(g.guest_profile_id && g.identity_fingerprint && byId("guest_profiles", g.guest_profile_id)?.identity_fingerprint && byId("guest_profiles", g.guest_profile_id)!.identity_fingerprint !== g.identity_fingerprint) })) : null,
      ...detailExtras(guestCtx, rpcs, r),
      allocations: T("reservation_allocations").filter((a) => a.reservation_id === r.id).map((a) => ({ id: a.id, room_number: roomNo(a.room_id), from_date: a.from_date, to_date: a.to_date, status: a.status, reason: a.reason, created_at: a.created_at })).sort((a, b) => (a.from_date < b.from_date ? -1 : 1)),
      charges: money ? (() => { const done = invoicedShares(r.id); return T("reservation_charges").filter((c) => c.reservation_id === r.id).map((c) => ({ ...c, invoiced_halalas: done.get(c.id) ?? 0 })); })() : null,
      vouchers: money ? T("financial_vouchers").filter((v) => v.reservation_id === r.id).sort((a, b) => (a.occurred_at < b.occurred_at ? -1 : a.occurred_at > b.occurred_at ? 1 : 0)).map((v) => { const x: Row = { ...v }; delete x.content_hash;
        x.created_by_name = staffName(v.created_by); x.original_number = byId("financial_vouchers", v.original_voucher_id)?.number ?? null;
        x.replaced_by_number = T("financial_vouchers").filter((o) => o.original_voucher_id === v.id).sort((a, b) => (a.created_at < b.created_at ? 1 : -1))[0]?.number ?? null; return x; }) : null,
      invoices: money ? T("invoices").filter((i) => i.reservation_id === r.id).sort((a, b) => (a.issued_at < b.issued_at ? -1 : a.issued_at > b.issued_at ? 1 : 0)).map((i) => ({ id: i.id, number: i.number, status: i.status, scope: i.scope, origin: i.origin, version: i.version ?? 1,
        subtotal_halalas: i.subtotal_halalas, tax_halalas: i.tax_halalas, total_halalas: i.total_halalas, issued_at: i.issued_at, issued_by: staffName(i.issued_by), updated_at: i.updated_at ?? null, updated_by: staffName(i.updated_by),
        cancelled_at: i.cancelled_at, cancel_reason: i.cancel_reason, period_from: i.period_from, period_to: i.period_to, bill_to: i.bill_to ?? {}, lines: i.snapshot?.lines ?? [], versions: i.versions ?? [] })) : null,
      invoicing: money ? { uninvoiced_halalas: uninvoicedValue(r.id) } : null,
      finance: money ? financeOf(r.id) : null, history: hasRole("owner", "manager", "supervisor") ? T("audit_events").filter((e) => e.entity_id === r.id).slice(0, 50).map((e) => ({ action: e.action, at: e.created_at, actor: byId("staff_profiles", e.actor_id)?.full_name ?? null, details: e.details })) : null }; },
  // fn_reservation_list: the phase 6 module (src/demo/phase6.ts) — every filter of the reference, the picker's columns, an exact total

  // ---- money ----
  fn_create_voucher: ({ p }) => { if (!["receipt", "deposit"].includes(p.kind)) throw new Error("VALIDATION: kind"); requireCap("voucher.receipt"); const amount = parseHalalas(p.amount_halalas); nonEmpty(p.idempotency_key, "idempotency_key"); if (!p.method) throw new Error("VALIDATION: method"); const r = byId("reservations", p.reservation_id); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id);
    const hash = [r.id, p.kind, amount, p.method, p.reference ?? "", p.account_id ?? ""].join("|"); const ex = T("financial_vouchers").find((v) => v.idempotency_key === p.idempotency_key); if (ex) { if (ex.content_hash !== hash) throw new Error("IDEMPOTENCY_CONFLICT: same key, different content"); if (ex.status === "cancelled") throw new Error("IDEMPOTENCY_CANCELLED"); return { ok: true, duplicate: true, voucher_id: ex.id, number: ex.number, finance: financeOf(r.id) }; }
    if (!ACTIVE_METHODS.includes(p.method)) throw new Error("VALIDATION: method_retired");
    if (p.kind === "deposit" && p.method === "ota_deferred") throw new Error("VALIDATION: deposit_method");
    if (["cancelled", "rejected", "no_show"].includes(r.status) && p.kind === "deposit") throw new Error("RESERVATION_STATUS_INVALID");
    const reference = checkReference(p.method, p.reference); const account_id = voucherAccount(r.branch_id, p.method, p.account_id);
    const v = { id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: r.id, number: nextNumber(p.kind === "receipt" ? "RCP" : "DEP"), kind: p.kind, amount_halalas: amount, method: p.method, account_id, payout_id: null, status: "approved", reference, note: p.note ?? null, reason: p.reason ?? null, original_voucher_id: null, payment_transaction_id: null, idempotency_key: p.idempotency_key, content_hash: hash, occurred_at: nowISO(), created_by: staffId(), created_at: nowISO(), cancelled_by: null, cancelled_at: null, cancel_reason: null };
    T("financial_vouchers").push(v); emit("financial_vouchers"); const f = recompute(r.id)!; audit(r.branch_id, "voucher." + p.kind + "_created", "voucher", v.id, { after: { number: v.number, amount_halalas: v.amount_halalas, method: v.method, account_id, reference, reservation_id: r.id } }); return { ok: true, duplicate: false, voucher_id: v.id, number: v.number, finance: f }; },
  // decision 5: the supervisor may also refund a deposit and apply it; a stay's deposit goes back only after check-out and its inspection
  fn_refund: ({ p }) => { if (!["refund", "deposit_refund", "deposit_apply"].includes(p.kind)) throw new Error("VALIDATION: kind"); if (p.kind === "refund") requireCap("voucher.refund"); else if (p.kind === "deposit_apply") requireCap("deposit.apply"); else requireCap("deposit.refund"); const amount = parseHalalas(p.amount_halalas); p.amount_halalas = amount; nonEmpty(p.reason, "reason"); nonEmpty(p.idempotency_key, "idempotency_key");
    const method = p.kind === "deposit_apply" ? "cash" : p.method; if (!method) throw new Error("VALIDATION: method"); const r = byId("reservations", p.reservation_id); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id);
    const hash = [r.id, p.kind, amount, p.method ?? "", p.reference ?? "", p.account_id ?? ""].join("|"); const ex = T("financial_vouchers").find((v) => v.idempotency_key === p.idempotency_key); if (ex) { if (ex.content_hash !== hash) throw new Error("IDEMPOTENCY_CONFLICT"); if (ex.status === "cancelled") throw new Error("IDEMPOTENCY_CANCELLED"); return { ok: true, duplicate: true, voucher_id: ex.id, number: ex.number, finance: financeOf(r.id) }; }
    if (p.original_voucher_id && byId("financial_vouchers", p.original_voucher_id)?.reservation_id !== r.id) throw new Error("VALIDATION: original_voucher");
    if (p.kind === "deposit_refund" && (r.actual_check_in || ["checked_in", "checked_out", "closed"].includes(r.status))) {
      if (!["checked_out", "closed"].includes(r.status)) throw new Error("VALIDATION: deposit_refund_before_checkout");
      if (!T("checkout_inspections").some((i) => i.reservation_id === r.id && i.status === "active")) throw new Error("INSPECTION_REQUIRED: record the check-out inspection first");
    }
    let reference: string | null = null, account_id: string | null = null;
    if (p.kind !== "deposit_apply") { if (!ACTIVE_METHODS.includes(method)) throw new Error("VALIDATION: method_retired"); if (p.kind === "deposit_refund" && method === "ota_deferred") throw new Error("VALIDATION: deposit_method"); reference = checkReference(method, p.reference); account_id = voucherAccount(r.branch_id, method, p.account_id); }
    p.method = method; p.reference = reference;
    const f0 = financeOf(r.id); const available = p.kind === "refund" ? f0.received - f0.refunded : f0.deposit_balance; if (p.amount_halalas > available) throw new Error(`REFUND_EXCEEDS_AVAILABLE: available ${available} halalas`); if (p.kind === "deposit_apply" && p.amount_halalas > f0.balance_due) throw new Error("REFUND_EXCEEDS_AVAILABLE: nothing due");
    const v = { id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: r.id, number: nextNumber(p.kind === "refund" ? "RFD" : p.kind === "deposit_refund" ? "DRF" : "DAP"), kind: p.kind, amount_halalas: p.amount_halalas, method: p.method ?? "cash", account_id, payout_id: null, status: "approved", reference: p.reference ?? null, note: p.note ?? null, reason: p.reason, original_voucher_id: p.original_voucher_id ?? null, payment_transaction_id: null, idempotency_key: p.idempotency_key, content_hash: hash, occurred_at: nowISO(), created_by: staffId(), created_at: nowISO(), cancelled_by: null, cancelled_at: null, cancel_reason: null };
    T("financial_vouchers").push(v); emit("financial_vouchers"); recompute(r.id); audit(r.branch_id, "voucher." + p.kind + "_created", "voucher", v.id, { after: { number: v.number, amount_halalas: v.amount_halalas, available_before: available }, reason: p.reason });
    const invoice = ["deposit_refund", "deposit_apply"].includes(p.kind) && ["checked_out", "closed"].includes(r.status) && financeOf(r.id).deposit_balance === 0 ? autoInvoice(r.id, "deposit_settled") : null;
    return { ok: true, duplicate: false, voucher_id: v.id, number: v.number, finance: financeOf(r.id), invoice }; },
  // ---- cash boxes and bank accounts (decision 25) ----
  fn_admin_upsert_cash_account: ({ p }) => { requireCap("cash_accounts"); const name = String(p.name ?? "").trim(); if (!name || name.length > 60) throw new Error("VALIDATION: name");
    const last4 = String(p.account_last4 ?? "").trim() || null; if (last4 && !/^[0-9]{4}$/.test(last4)) throw new Error("VALIDATION: account_last4"); const bank = String(p.bank_name ?? "").trim() || null;
    const clash = (branch: string, id?: string) => T("cash_accounts").some((a) => a.branch_id === branch && !a.archived_at && a.id !== id && a.name.toLowerCase() === name.toLowerCase());
    const unsetDefault = (branch: string, kind: string) => { for (const a of T("cash_accounts")) if (a.branch_id === branch && a.kind === kind && a.is_default && !a.archived_at) { a.is_default = false; a.version++; a.updated_at = nowISO(); } };
    if (!p.id) { requireBranch(p.branch_id); if (!["cash_box", "bank_account"].includes(p.kind)) throw new Error("VALIDATION: kind"); if (clash(p.branch_id)) throw new Error("DUPLICATE_NAME");
      const hasDefault = T("cash_accounts").some((a) => a.branch_id === p.branch_id && a.kind === p.kind && a.is_default && !a.archived_at); if (p.is_default) unsetDefault(p.branch_id, p.kind);
      const a = { id: uid(), organization_id: ORG, branch_id: p.branch_id, kind: p.kind, name, bank_name: p.kind === "bank_account" ? bank : null, account_last4: p.kind === "bank_account" ? last4 : null, is_default: !!p.is_default || !hasDefault, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, created_by: staffId(), created_at: nowISO(), updated_at: nowISO() };
      T("cash_accounts").push(a); emit("cash_accounts"); audit(a.branch_id, "cash_account.created", "cash_account", a.id, { after: a }); return { ok: true, id: a.id, version: 1 }; }
    const a = byId("cash_accounts", p.id); if (!a) throw new Error("NOT_FOUND"); requireBranch(a.branch_id); checkVersion(a.version, p.version); if (a.archived_at) throw new Error("VALIDATION: account_archived"); if (clash(a.branch_id, a.id)) throw new Error("DUPLICATE_NAME");
    const before = { ...a }; if (p.is_default && !a.is_default) unsetDefault(a.branch_id, a.kind);
    Object.assign(a, { name, bank_name: a.kind === "bank_account" ? bank : null, account_last4: a.kind === "bank_account" ? last4 : null, is_default: p.is_default ? true : p.is_default === false ? false : a.is_default, is_active: p.is_active ?? a.is_active, version: a.version + 1, updated_at: nowISO() });
    emit("cash_accounts"); audit(a.branch_id, "cash_account.updated", "cash_account", a.id, { before, after: { ...a } }); return { ok: true, id: a.id, version: a.version }; },
  fn_admin_archive_cash_account: ({ p_id, p_archive, p_reason }) => { requireCap("cash_accounts"); nonEmpty(p_reason, "reason"); const a = byId("cash_accounts", p_id); if (!a) throw new Error("NOT_FOUND"); requireBranch(a.branch_id); const before = { ...a };
    const used = T("financial_vouchers").filter((v) => v.account_id === a.id).length;
    if (p_archive) { if (a.archived_at) return { ok: true, unchanged: true }; Object.assign(a, { archived_at: nowISO(), archived_by: staffId(), archive_reason: p_reason, is_default: false }); }
    else { if (!a.archived_at) return { ok: true, unchanged: true }; if (T("cash_accounts").some((x) => x.branch_id === a.branch_id && !x.archived_at && x.id !== a.id && x.name.toLowerCase() === a.name.toLowerCase())) throw new Error("DUPLICATE_NAME"); Object.assign(a, { archived_at: null, archived_by: null, archive_reason: null }); }
    a.version++; a.updated_at = nowISO(); emit("cash_accounts"); audit(a.branch_id, p_archive ? "cash_account.archived" : "cash_account.restored", "cash_account", a.id, { before, after: { ...a }, reason: p_reason });
    return { ok: true, used_by_vouchers: used, default_missing: !T("cash_accounts").some((x) => x.branch_id === a.branch_id && x.kind === a.kind && x.is_default && !x.archived_at) }; },

  // ---- the daily card-terminal settlement (decision 13) ----
  fn_pos_settlement_preview: ({ p_branch, p_account, p_date }) => { requireCap("pos.settle"); requireBranch(p_branch); const a = byId("cash_accounts", p_account); if (!a || a.branch_id !== p_branch || a.kind !== "bank_account") throw new Error("BRANCH_MISMATCH: account");
    const s = T("pos_settlements").find((x) => x.account_id === p_account && x.business_date === p_date) ?? null; return { ...posDayTotal(p_branch, p_account, p_date), settlement: s }; },
  fn_pos_settle: ({ p }) => { requireCap("pos.settle"); requireBranch(p.branch_id); const a = byId("cash_accounts", p.account_id); if (!a || a.branch_id !== p.branch_id || a.kind !== "bank_account") throw new Error("BRANCH_MISMATCH: account");
    if (!p.business_date || p.business_date > todayISO()) throw new Error("VALIDATION: business_date"); if (!/^-?[0-9]{1,15}$/.test(String(p.terminal_total_halalas ?? ""))) throw new Error("VALIDATION: amount");
    const terminal = Number(p.terminal_total_halalas); const t = posDayTotal(p.branch_id, p.account_id, p.business_date); const diff = terminal - t.system_total_halalas; const note = String(p.note ?? "").trim() || null; if (diff !== 0 && !note) throw new Error("VALIDATION: note_required");
    let s = T("pos_settlements").find((x) => x.account_id === p.account_id && x.business_date === p.business_date); const before = s ? { ...s } : null;
    const fields = { terminal_total_halalas: terminal, system_total_halalas: t.system_total_halalas, difference_halalas: diff, voucher_count: t.voucher_count, status: diff === 0 ? "matched" : "difference", note, updated_by: staffId(), updated_at: nowISO() };
    if (s) { checkVersion(s.version, p.version); Object.assign(s, fields, { version: s.version + 1 }); }
    else { s = { id: uid(), organization_id: ORG, branch_id: p.branch_id, account_id: p.account_id, business_date: p.business_date, ...fields, version: 1, created_by: staffId(), created_at: nowISO() }; T("pos_settlements").push(s); }
    emit("pos_settlements"); audit(p.branch_id, "pos.settled", "pos_settlement", s.id, { before, after: { ...s }, reason: note }); return { ok: true, settlement: { ...s } }; },

  // ---- the monthly platform payout matching (decision 24) ----
  fn_platform_unsettled: ({ p_branch }) => { requireCap("platform.payouts"); requireBranch(p_branch);
    return T("financial_vouchers").filter((v) => v.branch_id === p_branch && v.method === "ota_deferred" && v.status === "approved" && !v.payout_id && ["receipt", "refund"].includes(v.kind))
      .map((v) => { const r = byId("reservations", v.reservation_id)!; const s = byId("booking_sources", r.source_id); return { id: v.id, number: v.number, kind: v.kind, amount_halalas: v.amount_halalas, signed_halalas: v.kind === "receipt" ? v.amount_halalas : -v.amount_halalas, occurred_at: v.occurred_at, reservation_id: r.id, internal_ref: r.internal_ref, external_ref: r.external_ref, check_in: r.check_in, source_id: r.source_id, source_name: s?.name ?? null, commission_bp: Number(s?.commission_bp ?? 0) }; })
      .sort((a, b) => (String(a.source_name) + a.occurred_at < String(b.source_name) + b.occurred_at ? -1 : 1)); },
  fn_platform_payout_confirm: ({ p }) => { requireCap("platform.payouts"); requireBranch(p.branch_id); const ids: string[] = Array.isArray(p.voucher_ids) ? p.voucher_ids : []; if (!ids.length) throw new Error("VALIDATION: vouchers");
    const received = parseHalalas(p.received_halalas); const ref = String(p.reference ?? "").trim(); if (!ref) throw new Error("VALIDATION: reference_required"); if (!p.received_on || p.received_on > todayISO()) throw new Error("VALIDATION: received_on");
    const account_id = voucherAccount(p.branch_id, "bank_transfer", p.account_id);
    const vs = ids.map((id) => byId("financial_vouchers", id)).filter((v): v is Row => !!v && v.branch_id === p.branch_id && v.method === "ota_deferred" && v.status === "approved" && !v.payout_id && ["receipt", "refund"].includes(v.kind) && byId("reservations", v.reservation_id)?.source_id === p.source_id);
    if (vs.length !== ids.length) throw new Error("VALIDATION: payout_vouchers"); const expected = vs.reduce((s, v) => s + (v.kind === "receipt" ? v.amount_halalas : -v.amount_halalas), 0); const note = String(p.note ?? "").trim() || null;
    const bp = Number(byId("booking_sources", p.source_id)?.commission_bp ?? 0); const commission = roundHalfUp((expected * bp) / 10000); const net = expected - commission; if (received !== net && !note) throw new Error("VALIDATION: note_required");
    const pay = { id: uid(), organization_id: ORG, branch_id: p.branch_id, source_id: p.source_id, account_id, expected_halalas: expected, commission_bp: bp, commission_halalas: commission, received_halalas: received, difference_halalas: received - net, voucher_count: vs.length, received_on: p.received_on, reference: ref, note, status: "confirmed", created_by: staffId(), created_at: nowISO(), cancelled_by: null, cancelled_at: null, cancel_reason: null };
    T("platform_payouts").push(pay); for (const v of vs) v.payout_id = pay.id; emit("platform_payouts"); emit("financial_vouchers"); audit(p.branch_id, "platform.payout_confirmed", "platform_payout", pay.id, { after: pay, reason: note }); return { ok: true, payout: pay }; },
  fn_platform_payout_cancel: ({ p_payout, p_reason }) => { requireCapFull("platform.payouts"); nonEmpty(p_reason, "reason"); const pay = byId("platform_payouts", p_payout); if (!pay) throw new Error("NOT_FOUND"); requireBranch(pay.branch_id); if (pay.status !== "confirmed") throw new Error("VALIDATION: payout_status");
    const before = { ...pay }; for (const v of T("financial_vouchers")) if (v.payout_id === pay.id) v.payout_id = null; Object.assign(pay, { status: "cancelled", cancelled_by: staffId(), cancelled_at: nowISO(), cancel_reason: p_reason });
    emit("platform_payouts"); emit("financial_vouchers"); audit(pay.branch_id, "platform.payout_cancelled", "platform_payout", pay.id, { before, after: { ...pay }, reason: p_reason }); return { ok: true }; },
  fn_cancel_voucher: ({ p_voucher, p_reason }) => { requireCap("voucher.cancel"); nonEmpty(p_reason, "reason"); return cancelVoucherCore(p_voucher, p_reason); },
  fn_staff_confirm_payment: ({ p_reservation, p_method, p_amount_halalas, p_reference, p_idempotency_key }) => { requireCap("voucher.receipt"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); if (p_amount_halalas <= 0) throw new Error("VALIDATION: amount"); nonEmpty(p_reference, "reference_required"); const res = rpcs.fn_create_voucher({ p: { reservation_id: r.id, kind: "receipt", amount_halalas: p_amount_halalas, method: p_method, reference: p_reference, idempotency_key: p_idempotency_key } }); audit(r.branch_id, "confirm_payment", "reservation", r.id, { method: p_method, amount_halalas: p_amount_halalas, reference: p_reference }); return { ok: true, duplicate: res.duplicate, payment_status: r.payment_status, paid_halalas: r.paid_halalas, voucher: res.number }; },
  fn_create_invoice: ({ p_reservation, p_from, p_to }) => rpcs.fn_staff_issue_invoice({ p: { reservation_id: p_reservation, from: p_from ?? null, to: p_to ?? null } }),
  // decision 60: failed operations are recorded by their trace code only (the demo keeps them in memory)
  fn_log_client_error: ({ p_trace, p_code, p_context }) => { if (!staffId() || !/^[A-Z0-9]{6,16}$/.test(String(p_trace ?? ""))) return { ok: false }; T("client_errors").push({ id: uid(), trace_id: p_trace, error_code: /^[A-Z][A-Z0-9_]{1,48}(: [a-z_0-9]{1,48})?$/.test(String(p_code ?? "")) ? p_code : "UNKNOWN", context: p_context ?? null, staff_id: staffId(), created_at: nowISO() }); return { ok: true }; },
  fn_lookup_trace: ({ p_trace }) => {
    requireRole("owner", "manager"); if (!/^[A-Za-z0-9_-]{6,64}$/.test(String(p_trace ?? ""))) throw new Error("VALIDATION: trace");
    const name = (id: string | null) => (id ? byId("staff_profiles", id)?.full_name ?? null : null);
    const f = T("client_errors").find((e) => e.trace_id === p_trace);
    return { failure: f ? { id: f.id, staff_id: f.staff_id, staff_name: name(f.staff_id), trace_id: f.trace_id, error_code: f.error_code, context: f.context, created_at: f.created_at } : null,
      events: T("audit_events").filter((e) => e.correlation_id === p_trace && (e.category !== "security" || hasRole("owner"))).reverse()
        .map((e) => ({ action: e.action, entity_type: e.entity_type, entity_id: e.entity_id, actor_id: e.actor_id, actor_name: name(e.actor_id), source: e.source, result: e.result, created_at: e.created_at })) };
  },
  fn_cancel_invoice: ({ p_invoice, p_reason }) => { requireRole("owner", "manager"); nonEmpty(p_reason, "reason"); const inv = byId("invoices", p_invoice); if (!inv) throw new Error("NOT_FOUND"); requireBranch(inv.branch_id); if (inv.status !== "issued") throw new Error("INVOICE_STATUS_INVALID");
    Object.assign(inv, { status: "cancelled", cancelled_at: nowISO(), cancelled_by: staffId(), cancel_reason: p_reason }); emit("invoices"); syncInvoiceMarkers(inv.reservation_id);
    addReview(inv.branch_id, "invoice_cancelled", "invoice", inv.id, inv.reservation_id, `إلغاء الفاتورة ${inv.number}`, p_reason, { number: inv.number, total_halalas: inv.total_halalas });
    audit(inv.branch_id, "invoice.cancelled", "invoice", inv.id, { before: { status: "issued" }, after: { status: "cancelled" }, reason: p_reason }); syncClosed(inv.reservation_id); return { ok: true }; },

  // ---- housekeeping ----
  fn_hk_create_task: ({ p }) => { requireCap("task.work"); if (!!p.room_id === !!p.facility_id) throw new Error("VALIDATION: one_target"); const target = p.room_id ? byId("rooms", p.room_id) : byId("facilities", p.facility_id); if (!target || target.archived_at) throw new Error("NOT_FOUND: target"); requireBranch(target.branch_id); const tt = byId("task_types", p.task_type_id); if (!tt || tt.branch_id !== target.branch_id || tt.archived_at) throw new Error("BRANCH_MISMATCH: task_type"); if (p.reservation_id && byId("reservations", p.reservation_id)?.branch_id !== target.branch_id) throw new Error("BRANCH_MISMATCH: reservation"); if (p.assignee_id && !staffInBranch(p.assignee_id, target.branch_id)) throw new Error("ASSIGNEE_NOT_IN_BRANCH");
    // decision 28: the planned start (now by default) and the optional end are kept as given; an end before the start is refused; no reminder, no automatic end
    const start = p.scheduled_start ? String(p.scheduled_start) : nowISO(), end = p.scheduled_end ? String(p.scheduled_end) : null; if (Number.isNaN(Date.parse(start)) || (end && (Number.isNaN(Date.parse(end)) || Date.parse(end) < Date.parse(start)))) throw new Error("VALIDATION: schedule");
    const t = { id: uid(), organization_id: ORG, branch_id: target.branch_id, room_id: p.room_id ?? null, facility_id: p.facility_id ?? null, task_type_id: tt.id, task_type_name_snapshot: tt.name, reservation_id: p.reservation_id ?? null, priority: p.priority ?? "medium", status: "pending", assignee_id: p.assignee_id ?? null, scheduled_start: start, scheduled_end: end, started_at: null, completed_at: null, completed_by: null, cancelled_at: null, cancel_reason: null, description: p.description ?? null, result_note: null, images: [], version: 1, created_by: staffId(), created_at: nowISO(), updated_at: nowISO() }; T("housekeeping_tasks").push(t);
    if (p.room_id && tt.code === "room_cleaning") { const rm = byId("rooms", p.room_id)!; if (rm.cleanliness === "clean") rm.cleanliness = "dirty"; recomputeRoomReady(p.room_id); } emit("housekeeping_tasks"); audit(target.branch_id, "task.created", "housekeeping_task", t.id, { after: t }); return { ok: true, id: t.id }; },
  fn_hk_start_task: ({ p_task }) => { requireCap("task.work"); const t = byId("housekeeping_tasks", p_task); if (!t) throw new Error("TASK_NOT_FOUND"); requireBranch(t.branch_id); if (t.status !== "pending") throw new Error("TASK_STATUS_INVALID"); if (hasRole("housekeeping") && t.assignee_id && t.assignee_id !== staffId()) throw new Error("FORBIDDEN: not assignee"); Object.assign(t, { status: "in_progress", started_at: nowISO(), assignee_id: t.assignee_id ?? staffId(), version: t.version + 1 }); if (t.room_id && byId("task_types", t.task_type_id)?.code === "room_cleaning") { byId("rooms", t.room_id)!.cleanliness = "in_progress"; emit("rooms"); } emit("housekeeping_tasks"); return { ok: true }; },
  fn_hk_complete_task: ({ p_task, p_note, p_expected_version }) => { requireCap("task.work"); const t = byId("housekeeping_tasks", p_task); if (!t) throw new Error("TASK_NOT_FOUND"); requireBranch(t.branch_id); checkVersion(t.version, p_expected_version); if (!["pending", "in_progress"].includes(t.status)) throw new Error("TASK_STATUS_INVALID"); if (hasRole("housekeeping") && t.assignee_id && t.assignee_id !== staffId()) throw new Error("FORBIDDEN: not assignee"); Object.assign(t, { status: "completed", completed_at: nowISO(), completed_by: staffId(), assignee_id: t.assignee_id ?? staffId(), result_note: p_note ?? null, version: t.version + 1 }); let st: string | undefined; if (t.room_id) { if (byId("task_types", t.task_type_id)?.code === "room_cleaning") byId("rooms", t.room_id)!.cleanliness = "clean"; st = recomputeRoomReady(t.room_id); } emit("housekeeping_tasks"); audit(t.branch_id, "task.completed", "housekeeping_task", t.id, { after: { room_status: st, note: p_note } }); return { ok: true, room_status: st }; },
  fn_hk_cancel_task: ({ p_task, p_reason }) => { requireCap("task.manage"); nonEmpty(p_reason, "reason"); const t = byId("housekeeping_tasks", p_task); if (!t) throw new Error("TASK_NOT_FOUND"); if (!["pending", "in_progress"].includes(t.status)) throw new Error("TASK_STATUS_INVALID"); Object.assign(t, { status: "cancelled", cancelled_at: nowISO(), cancel_reason: p_reason, version: t.version + 1 }); if (t.room_id && byId("task_types", t.task_type_id)?.code === "room_cleaning") { const rm = byId("rooms", t.room_id)!; if (rm.cleanliness === "in_progress") rm.cleanliness = "dirty"; recomputeRoomReady(t.room_id); } emit("housekeeping_tasks"); return { ok: true }; },
  fn_hk_assign_task: ({ p_task, p_assignee }) => { requireCap("task.manage"); const t = byId("housekeeping_tasks", p_task); if (!t) throw new Error("TASK_NOT_FOUND"); if (p_assignee && !staffInBranch(p_assignee, t.branch_id)) throw new Error("ASSIGNEE_NOT_IN_BRANCH"); t.assignee_id = p_assignee; t.version++; emit("housekeeping_tasks"); return { ok: true }; },
  // decision 12: a manual change is free and recorded (who, when, and whether a cleaning task was open); the task keeps its own state
  fn_hk_set_cleanliness: ({ p_room, p_state, p_reason }) => { requireCap("cleanliness"); if (!["clean", "dirty"].includes(p_state)) throw new Error("VALIDATION: cleanliness"); const rm = byId("rooms", p_room); if (!rm) throw new Error("ROOM_NOT_FOUND"); requireBranch(rm.branch_id);
    const openTask = T("housekeeping_tasks").some((h) => h.room_id === p_room && ["pending", "in_progress"].includes(h.status) && byId("task_types", h.task_type_id)?.code === "room_cleaning");
    const before = rm.cleanliness; rm.cleanliness = p_state; rm.updated_at = nowISO(); recomputeRoomReady(p_room); audit(rm.branch_id, "room.cleanliness_changed", "room", p_room, { before: { cleanliness: before }, after: { cleanliness: p_state, open_cleaning_task: openTask }, reason: p_reason }); return { ok: true, room_status: rm.status }; },
  fn_staff_complete_cleaning: ({ p_task }) => rpcs.fn_hk_complete_task({ p_task }),
  // «الرموز» (0025): housekeeping may see and change a unit's code — never with a guest in house; the same code is refused
  fn_staff_rotate_keybox_code: ({ p_room, p_new_code, p_field_tested }) => {
    requireCap("keybox.code"); const rm = byId("rooms", p_room); if (!rm) throw new Error("ROOM_NOT_FOUND"); requireBranch(rm.branch_id);
    const inHouse = guestInHouse(p_room); if (inHouse && !hasRole("owner", "manager", "supervisor")) throw new Error("GUEST_IN_HOUSE");
    p_new_code = latinDigits(String(p_new_code ?? ""));
    if (!/^\d{4,8}$/.test(p_new_code)) throw new Error("VALIDATION: code_must_be_4_to_8_digits");
    // 0047: no two boxes of one branch open with the same code (a code in a box counts until it is changed)
    if (T("keyboxes").some((k) => k.branch_id === rm.branch_id && k.room_id !== p_room && k.code_plain === p_new_code)) throw new Error("CODE_IN_USE");
    const tested = !!p_field_tested; let kb = T("keyboxes").find((k) => k.room_id === p_room); let before: Row;
    if (!kb) {
      before = { code_status: "none" };
      kb = { id: uid(), room_id: p_room, branch_id: rm.branch_id, code_encrypted: null, code_plain: p_new_code, code_version: 1, code_status: "active", needs_change_since: null, last_changed_at: nowISO(), last_changed_by: staffId(), field_tested: tested, last_reservation_id: null, requires_rotation: true, last_delivered_at: null, created_at: nowISO() };
      T("keyboxes").push(kb); T("code_rotation_events").unshift({ id: uid(), keybox_id: kb.id, room_id: p_room, from_version: null, to_version: 1, rotated_by: staffId(), field_tested: tested, created_at: nowISO() });
    } else {
      before = { code_version: kb.code_version, code_status: kb.code_status, field_tested: kb.field_tested, needs_change_since: kb.needs_change_since ?? null };
      if (kb.code_plain && kb.code_plain === p_new_code) throw new Error("CODE_MUST_DIFFER_FROM_PREVIOUS");
      T("code_rotation_events").unshift({ id: uid(), keybox_id: kb.id, room_id: p_room, from_version: kb.code_version, to_version: kb.code_version + 1, rotated_by: staffId(), field_tested: tested, created_at: nowISO() });
      Object.assign(kb, { code_plain: p_new_code, code_version: kb.code_version + 1, code_status: "active", needs_change_since: null, field_tested: tested, last_changed_at: nowISO(), last_changed_by: staffId(), last_reservation_id: null });
    }
    emit("keyboxes"); emit("code_rotation_events"); const st = recomputeRoomReady(p_room);
    audit(rm.branch_id, "rotate_keybox_code", "room", p_room, { before, after: { code_version: kb.code_version, code_status: "active", field_tested: tested, room_status: st, guest_in_house: inHouse } });
    return { ok: true, room_status: st, code_version: kb.code_version };
  },
  fn_staff_mark_keybox_tested: ({ p_room }) => {
    requireCap("keybox.code"); const rm = byId("rooms", p_room); if (!rm) throw new Error("ROOM_NOT_FOUND"); requireBranch(rm.branch_id);
    if (guestInHouse(p_room) && !hasRole("owner", "manager", "supervisor")) throw new Error("GUEST_IN_HOUSE");
    const kb = T("keyboxes").find((k) => k.room_id === p_room); if (!kb || !kb.code_plain) throw new Error("NO_KEYBOX_CODE"); if (kb.code_status !== "active") throw new Error("CODE_NEEDS_CHANGE");
    const was = kb.field_tested; kb.field_tested = true; emit("keyboxes"); const st = recomputeRoomReady(p_room);
    audit(rm.branch_id, "keybox_field_tested", "room", p_room, { before: { field_tested: was }, after: { field_tested: true, code_version: kb.code_version, room_status: st } });
    return { ok: true, room_status: st };
  },
  fn_keybox_board: ({ p_branch }) => {
    requireCap("keybox.code"); requireBranch(p_branch); const full = hasRole("owner", "manager", "supervisor");
    return T("rooms").filter((r) => r.branch_id === p_branch && !r.archived_at && r.is_active).sort((a, b) => (a.room_number < b.room_number ? -1 : 1)).map((rm) => {
      const kb = T("keyboxes").find((k) => k.room_id === rm.id); const inHouse = guestInHouse(rm.id); const hasCode = !!kb?.code_plain;
      const state = !kb ? "none" : kb.code_status !== "active" || !hasCode ? "change" : !kb.field_tested ? "untested" : "ok";
      return { room_id: rm.id, room_number: rm.room_number, block: byId("blocks", rm.block_id)?.name ?? null, floor: byId("floors", rm.floor_id)?.name ?? null, room_status: rm.status, cleanliness: rm.cleanliness,
        guest_in_house: inHouse, state, has_code: hasCode, code_version: kb?.code_version ?? null, field_tested: !!kb?.field_tested, needs_change_since: kb?.needs_change_since ?? null,
        last_changed_at: kb?.last_changed_at ?? null, last_changed_by: byId("staff_profiles", kb?.last_changed_by)?.full_name ?? null, can_change: full || !inHouse, can_view: hasCode && (full || !inHouse) };
    });
  },
  fn_keybox_alerts: ({ p_branch }) => {
    requireCap("keybox.code"); requireBranch(p_branch);
    const waiting = T("keyboxes").filter((k) => k.branch_id === p_branch && (k.code_status !== "active" || !k.code_plain)).map((k) => ({ k, rm: byId("rooms", k.room_id) })).filter((x) => x.rm && !x.rm.archived_at && x.rm.is_active)
      .sort((a, b) => (a.k.needs_change_since ?? "~").localeCompare(b.k.needs_change_since ?? "~") || (a.rm!.room_number < b.rm!.room_number ? -1 : 1));
    return { count: waiting.length, oldest_since: waiting.map((x) => x.k.needs_change_since).filter(Boolean).sort()[0] ?? null, rooms: waiting.map((x) => x.rm!.room_number) };
  },
  fn_keybox_reveal: ({ p_room }) => {
    requireCap("keybox.code"); const rm = byId("rooms", p_room); if (!rm || rm.archived_at) throw new Error("ROOM_NOT_FOUND"); requireBranch(rm.branch_id);
    const inHouse = guestInHouse(p_room); if (inHouse && !hasRole("owner", "manager", "supervisor")) throw new Error("GUEST_IN_HOUSE");
    const kb = T("keyboxes").find((k) => k.room_id === p_room); if (!kb || !kb.code_plain) throw new Error("NO_KEYBOX_CODE");
    audit(rm.branch_id, "keybox.code_viewed", "room", p_room, { after: { code_version: kb.code_version, code_status: kb.code_status, guest_in_house: inHouse } });
    return { ok: true, code: kb.code_plain, code_version: kb.code_version };
  },
  fn_staff_create_maintenance: ({ p_room, p_title, p_description }) => { requireCap("maintenance.create"); nonEmpty(p_title, "title"); const rm = byId("rooms", p_room); if (!rm) throw new Error("ROOM_NOT_FOUND"); const id = uid(); T("maintenance_tickets").unshift({ id, room_id: p_room, branch_id: rm.branch_id, title: p_title, description: p_description ?? null, status: "open", created_by: staffId(), created_at: nowISO() }); if (!["occupied"].includes(rm.status)) rm.status = "maintenance"; emit("maintenance_tickets"); emit("rooms"); return { ok: true, ticket_id: id }; },
  fn_staff_resolve_maintenance: ({ p_ticket }) => { requireCap("maintenance.resolve"); const t = byId("maintenance_tickets", p_ticket); if (!t) throw new Error("TICKET_NOT_FOUND"); t.status = "resolved"; emit("maintenance_tickets"); const rm = byId("rooms", t.room_id)!; if (rm.status === "maintenance") rm.status = "available"; return { ok: true, room_status: recomputeRoomReady(t.room_id) }; },
  fn_staff_resolve_ticket: ({ p_ticket }) => { requireCap("maintenance.resolve"); const t = byId("human_handoff_tickets", p_ticket); if (!t) throw new Error("TICKET_NOT_FOUND"); Object.assign(t, { status: "resolved", resolved_by: staffId(), resolved_at: nowISO() }); emit("human_handoff_tickets"); return { ok: true }; },
  fn_staff_release_next_slot: ({ p_category }) => { requireRole("owner", "manager"); const slot = T("released_slots").find((x) => x.category_id === p_category && x.date === todayISO()); if (slot) slot.released_count++; else T("released_slots").push({ id: uid(), branch_id: byId("room_categories", p_category)?.branch_id, category_id: p_category, date: todayISO(), released_count: 1, updated_at: nowISO() }); emit("released_slots"); return (slot?.released_count ?? 1); },

  // ---- gate flow ----
  fn_evaluate_access: ({ p_reservation }) => [evaluate(p_reservation)],
  // the former one-step confirmation: Shomoos now needs its explicit «every guest is registered» (fn_staff_shomoos)
  fn_staff_confirm_gov_registration: ({ p_reservation, p_reference }) => rpcs.fn_staff_shomoos({ p: { reservation_id: p_reservation, action: "register", reference: p_reference, all_guests: false } }),
  fn_staff_assign_room: ({ p_reservation, p_room }) => { requireCap("room.assign"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id); if (!["confirmed", "pending_verification"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID"); if (T("reservation_allocations").some((a) => a.reservation_id === r.id && a.status === "active")) throw new Error("ALREADY_ALLOCATED"); if (!roomAvailable(p_room, r.check_in, r.check_out)) throw new Error("ROOM_NOT_AVAILABLE"); allocate(r.id, p_room, r.check_in, r.check_out, "assign"); r.version++; audit(r.branch_id, "assign_room", "reservation", r.id, { room_id: p_room }); return { ok: true }; },
  // the former «اعتماد الدخول» is the arrival now, with the same conditions (no other way in)
  fn_staff_approve_checkin: ({ p_reservation }) => rpcs.fn_staff_check_in({ p: { reservation_id: p_reservation } }),
  // «تسليم الرمز»: only after the arrival, only for a unit with a key box, with the code ready for this guest (decision 1)
  fn_staff_deliver_access_code: ({ p_reservation, p_channel }) => { requireCap("code.deliver"); if (!["screen", "whatsapp", "supervisor"].includes(p_channel ?? "screen")) throw new Error("VALIDATION: channel"); const channel = p_channel ?? "screen";
    const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id);
    if (["delivered", "acknowledged"].includes(r.access_status)) return { ok: false, reasons: ["تم تسليم الرمز مسبقًا لهذا الحجز"] };
    const v = codeBlockers(r); if (v.length) return { ok: false, reasons: v };
    const kb = T("keyboxes").find((k) => k.room_id === r.room_id)!; const was = r.access_status;
    Object.assign(r, { access_status: "delivered", keybox_delivered: true, version: r.version + 1, updated_at: nowISO() }); Object.assign(kb, { last_reservation_id: r.id, last_delivered_at: nowISO() });
    T("access_delivery_events").push({ id: uid(), reservation_id: r.id, keybox_id: kb.id, channel, delivered_by: staffId(), acknowledged: false, created_at: nowISO() });
    emit("reservations"); emit("keyboxes"); audit(r.branch_id, "deliver_access_code", "reservation", r.id, { before: { access_status: was }, after: { access_status: "delivered", channel, code_version: kb.code_version } });
    return channel === "supervisor" ? { ok: true, code: kb.code_plain } : { ok: true }; },
  fn_staff_mark_delivery_failed: ({ p_reservation, p_reason }) => { requireCap("code.deliver"); nonEmpty(p_reason, "reason"); const r = byId("reservations", p_reservation)!; r.access_status = "approved"; emit("reservations"); audit(r.branch_id, "mark_delivery_failed", "reservation", r.id, { reason: p_reason }); return { ok: true }; },
  // the former check-out: the same rules; the managers' override is gone (decision 8), a reason given to it changes nothing
  fn_staff_checkout: ({ p_reservation }) => rpcs.fn_staff_check_out({ p: { reservation_id: p_reservation } }),

  // ---- operations ----
  fn_ops_units_board: ({ p_branch }) => { if (!myBranches().includes(p_branch)) return []; const today = branchToday(); return T("rooms").filter((r) => r.branch_id === p_branch && !r.archived_at).map((r) => { const cur = T("reservation_allocations").filter((a) => a.room_id === r.id && a.status === "active" && a.from_date <= today).map((a) => ({ a, r: byId("reservations", a.reservation_id)! })).filter((x) => x.r && ["confirmed", "checked_in", "pending_verification"].includes(x.r.status) && (today < x.a.to_date || x.r.status === "checked_in")).map((x) => x.r).sort((a) => (a.status === "checked_in" ? -1 : 1))[0]; const next = T("reservation_allocations").filter((a) => a.room_id === r.id && a.status === "active" && a.from_date > today && ["confirmed", "pending_verification"].includes(byId("reservations", a.reservation_id)?.status)).sort((a, b) => (a.from_date < b.from_date ? -1 : 1))[0]; const kb = T("keyboxes").find((k) => k.room_id === r.id);
    return { room_id: r.id, room_number: r.room_number, category: byId("room_categories", r.category_id)?.name_ar, block: byId("blocks", r.block_id)?.name ?? null, floor: byId("floors", r.floor_id)?.name ?? null, is_active: r.is_active, status: r.status, cleanliness: r.cleanliness, open_tasks: T("housekeeping_tasks").filter((h) => h.room_id === r.id && ["pending", "in_progress"].includes(h.status)).length, open_maintenance: T("maintenance_tickets").filter((m) => m.room_id === r.id && m.status !== "resolved").length, keybox_ready: !!kb && kb.code_status === "active" && kb.field_tested, current: cur ? { reservation_id: cur.id, internal_ref: cur.internal_ref, status: cur.status, check_in: cur.check_in, check_out: cur.check_out, guest: guestName(cur.id) ?? "—", balance_due: cur.balance_due_halalas } : null, next: next ? { internal_ref: byId("reservations", next.reservation_id)!.internal_ref, check_in: next.from_date } : null }; }).sort((a, b) => a.room_number.localeCompare(b.room_number, "en", { numeric: true })); },
  fn_ops_daily_summary: ({ p_branch, p_date }) => summary(p_branch, p_date ?? branchToday()),
  // Ledger-based finance KPIs for reports (GAP05): revenue = vouchers, never reservation totals; deposits never count as revenue.
  // decision 36 (0040): the filters beside the period — staff member, payment method, box or account («none» = no account),
  // source and unit type; a source or unit-type filter follows the voucher's booking; the collection rate is not claimed
  // under a staff, method or account filter (its denominator is the whole stay)
  fn_reports_finance: ({ p_branch, p_from, p_to, p_filters }) => {
    requireCapFull("reports.finance"); requireBranch(p_branch);
    const from = p_from ?? addDays(branchToday(p_branch), -29), to = p_to ?? branchToday(p_branch); if (to < from) throw new Error("VALIDATION: period");
    const f = p_filters ?? {}; const fStaff: string | null = f.staff_id || null, fMethod: string | null = f.method || null, fAccount: string | null = f.account_id || null, fSource: string | null = f.source_id || null, fCat: string | null = f.category_id || null;
    const filtered = !!(fStaff || fMethod || fAccount || fSource || fCat); const accNone = fAccount === "none", acc = fAccount && fAccount !== "none" ? fAccount : null;
    const inPeriod = (iso: string) => { const d = dayOf(iso); return d >= from && d <= to; };
    const followsBooking = (r: Row | undefined) => (!fSource || r?.source_id === fSource) && (!fCat || r?.room_category_id === fCat);
    const vouchers = T("financial_vouchers").filter((v) => v.branch_id === p_branch && v.status === "approved" && inPeriod(v.occurred_at)
      && (!fStaff || v.created_by === fStaff) && (!fMethod || v.method === fMethod) && (!fAccount || (accNone && v.account_id == null) || v.account_id === acc) && followsBooking(byId("reservations", v.reservation_id)));
    const sumV = (kind: string) => vouchers.filter((v) => v.kind === kind).reduce((a, v) => a + v.amount_halalas, 0);
    const receipts = sumV("receipt"), refunds = sumV("refund"), deposits_received = sumV("deposit"), deposits_refunded = sumV("deposit_refund"), deposits_applied = sumV("deposit_apply");
    const net_collected = receipts - refunds + deposits_applied;
    const allRes = T("reservations").filter((r) => r.branch_id === p_branch && r.check_in <= to && r.check_out > from && followsBooking(r));
    const stays = allRes.filter((r) => !["cancelled", "rejected", "no_show"].includes(r.status)); const stayIds = new Set(stays.map((r) => r.id));
    const charges = T("reservation_charges").filter((c) => c.branch_id === p_branch && stayIds.has(c.reservation_id));
    const sumC = (kind: string) => charges.filter((c) => c.kind === kind).reduce((a, c) => a + c.total_halalas, 0);
    const rent = sumC("rent"), addons = sumC("addon") + sumC("penalty") + sumC("adjustment"), discounts = sumC("discount"), tax = sumC("tax");
    const total_charged = rent + addons + discounts + tax;
    const by_method = Object.values(vouchers.filter((v) => v.kind === "receipt").reduce((acc: Record<string, { method: string; amount_halalas: number }>, v) => { (acc[v.method] ??= { method: v.method, amount_halalas: 0 }).amount_halalas += v.amount_halalas; return acc; }, {})).sort((a, b) => b.amount_halalas - a.amount_halalas || a.method.localeCompare(b.method));
    const days: Record<string, { day: string; receipts: number; refunds: number }> = {};
    for (const v of vouchers) { const d = dayOf(v.occurred_at); const row = (days[d] ??= { day: d, receipts: 0, refunds: 0 }); if (v.kind === "receipt" || v.kind === "deposit_apply") row.receipts += v.amount_halalas; if (v.kind === "refund") row.refunds += v.amount_halalas; }
    const staffRows = new Map<string | null, { staff_id: string | null; staff: string; receipts: number; refunds: number; count: number }>();
    for (const v of vouchers.filter((x) => x.kind === "receipt" || x.kind === "refund")) { const k = v.created_by ?? null; const row = staffRows.get(k) ?? { staff_id: k, staff: staffName(k) ?? "—", receipts: 0, refunds: 0, count: 0 }; if (v.kind === "receipt") row.receipts += v.amount_halalas; else row.refunds += v.amount_halalas; row.count++; staffRows.set(k, row); }
    const by_staff = [...staffRows.values()].sort((a, b) => b.receipts - a.receipts);
    const accRows = new Map<string, { account_id: string; account: string; in_halalas: number; out_halalas: number }>();
    for (const v of vouchers.filter((x) => x.account_id != null)) { const row = accRows.get(v.account_id) ?? { account_id: v.account_id, account: byId("cash_accounts", v.account_id)?.name ?? "—", in_halalas: 0, out_halalas: 0 }; if (v.kind === "receipt" || v.kind === "deposit") row.in_halalas += v.amount_halalas; if (v.kind === "refund" || v.kind === "deposit_refund") row.out_halalas += v.amount_halalas; accRows.set(v.account_id, row); }
    const by_account = [...accRows.values()].sort((a, b) => b.in_halalas - a.in_halalas);
    const by_source = Object.values(allRes.reduce((acc: Record<string, { source: string; count: number; total_halalas: number }>, r) => { const s = byId("booking_sources", r.source_id)?.name ?? "—"; (acc[s] ??= { source: s, count: 0, total_halalas: 0 }); acc[s].count++; acc[s].total_halalas += r.total_halalas ?? 0; return acc; }, {})).sort((a, b) => b.count - a.count || a.source.localeCompare(b.source));
    const nights = stays.reduce((a, r) => a + Math.max(0, (new Date(r.check_out + "T00:00:00Z").getTime() - new Date(r.check_in + "T00:00:00Z").getTime()) / 86400000), 0);
    const openDeposits = T("reservations").filter((r) => r.branch_id === p_branch).reduce((a, r) => a + Math.max(0, r.deposit_balance_halalas ?? 0), 0);
    const filters: Row = {}; if (fStaff) filters.staff_id = fStaff; if (fMethod) filters.method = fMethod; if (fAccount) filters.account_id = fAccount; if (fSource) filters.source_id = fSource; if (fCat) filters.category_id = fCat;
    return {
      period: { from, to }, filters, filtered,
      ledger: { receipts, refunds, net_collected, deposits_received, deposits_refunded, deposits_applied, deposit_balance_open: openDeposits },
      charges: { total_charged, rent, addons, discounts, tax },
      collection_rate_pct: total_charged > 0 && !fStaff && !fMethod && !fAccount ? (() => { const pct = Math.round((Math.abs(net_collected) * 1000) / total_charged) / 10; return net_collected < 0 ? -pct || 0 : pct; })() : null,
      by_method, by_day: Object.values(days).sort((a, b) => a.day.localeCompare(b.day)), by_staff, by_account,
      reservations: { count: allRes.length, nights, cancelled: allRes.filter((r) => r.status === "cancelled").length, no_show: allRes.filter((r) => r.status === "no_show").length, by_source },
      definitions: {
        revenue: "صافي التحصيل = سندات قبض الإقامة − الاستردادات + التأمين المستخدم لتغطية رسوم، بتاريخ السند. التأمين المقبوض ليس إيرادًا.",
        collection_rate: "نسبة التحصيل = صافي التحصيل ÷ إجمالي الرسوم (إيجار + إضافات − خصومات + ضريبة) للإقامات المتقاطعة مع الفترة؛ لا تُحسب مع مرشح الموظف أو الطريقة أو الحساب.",
      },
    };
  },
  fn_ai_ops_context: ({ p_branch, p_date }) => { const ctx = opsContext(p_branch, p_date ?? branchToday()); if (!ctx || seesMoney()) return ctx; const strip = (rows: Row[]) => rows.map((e) => { const x = { ...e }; delete x.balance_due; delete x.deposit_balance; delete x.payment_status; return x; }); const c: any = { ...ctx, summary: { ...ctx.summary, finance: undefined }, arrivals: strip(ctx.arrivals), departures: strip(ctx.departures), overstays: strip(ctx.overstays) }; delete c.in_house_with_balance; delete c.checked_out_with_deposit; return c; },
  fn_ai_ops_find_reservation: ({ p_branch, p_query }) => findRes(p_branch, p_query),
  fn_ai_ops_propose: ({ p_conversation, p_action, p_args, p_summary }) => { const c = byId("ai_ops_conversations", p_conversation); if (!c) throw new Error("NOT_FOUND: conversation"); const id = uid(); const args = { ...(p_args ?? {}) }; if (["amend_stay", "switch_room", "complete_task"].includes(p_action) && args.expected_version == null) { const tgt = p_action === "complete_task" ? byId("housekeeping_tasks", args.task_id) : byId("reservations", args.reservation_id); if (tgt && tgt.branch_id === c.branch_id) args.expected_version = tgt.version; } T("ai_action_proposals").push({ id, organization_id: ORG, branch_id: c.branch_id, conversation_id: c.id, staff_id: staffId(), action: p_action, args, summary: p_summary, status: "proposed", result: null, error: null, created_at: nowISO(), expires_at: new Date(Date.now() + 30 * 60000).toISOString(), decided_at: null, decided_by: null }); return { ok: true, proposal_id: id, requires_confirmation: true }; },
  // the assistant's executions carry source = 'ops_assistant' on every audit row they write (decision 55: the usage report
  // tells a person from the assistant); the proposal stays the staff member's own
  fn_ai_ops_execute_proposal: ({ p_id }) => { const p = byId("ai_action_proposals", p_id); if (!p || p.staff_id !== staffId()) throw new Error("FORBIDDEN: not your proposal"); if (p.status !== "proposed") throw new Error("PROPOSAL_STATUS_INVALID"); const a = p.args ?? {}; const key = "ai:" + p.id;
    if (Date.parse(p.expires_at) < Date.now()) { Object.assign(p, { status: "expired", decided_at: nowISO(), decided_by: staffId() }); return { ok: false, error: "PROPOSAL_EXPIRED" }; }
    requireBranch(p.branch_id);
    const snapshot = JSON.stringify(S); auditSource = "ops_assistant";
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
    } catch (e) { S = JSON.parse(snapshot); const p2 = byId("ai_action_proposals", p_id)!; Object.assign(p2, { status: "failed", error: (e as Error).message, decided_at: nowISO(), decided_by: staffId() }); emitAll(); return { ok: false, error: (e as Error).message }; }
    finally { auditSource = null; } },
  fn_ai_ops_reject_proposal: ({ p_id, p_reason }) => { const p = byId("ai_action_proposals", p_id); if (!p || p.staff_id !== staffId() || p.status !== "proposed") throw new Error("NOT_FOUND"); Object.assign(p, { status: "rejected", error: p_reason ?? null, decided_at: nowISO(), decided_by: staffId() }); return { ok: true }; },

  // ---- guest ----
  // decision 23: staff only (visitors see no availability)
  fn_get_public_availability: ({ p_branch, p_date }) => { if (!myBranches().includes(p_branch)) throw new Error("permission denied for function fn_get_public_availability"); return T("room_categories").filter((c) => c.branch_id === p_branch && c.is_public && c.is_active && !c.archived_at).map((c) => { const rooms = T("rooms").filter((r) => r.category_id === c.id && r.is_active && !r.archived_at); const free = rooms.filter((r) => roomAvailablePublic(r.id, p_date, addDays(p_date, 1))).length; return { category_id: c.id, category_name: c.name_ar, base_price_halalas: c.base_price_halalas, base_capacity: c.base_capacity, max_capacity: c.max_capacity, available_to_show: Math.min(free, 2), total_available: free }; }); },
  fn_guest_lookup: ({ p_external_ref, p_phone_last4 }) => { const r = T("reservations").find((x) => (x.external_ref ?? "").toLowerCase() === String(p_external_ref).toLowerCase() || x.internal_ref.toLowerCase() === String(p_external_ref).toLowerCase()); if (!r) { T("human_handoff_tickets").unshift({ id: uid(), organization_id: ORG, branch_id: null, conversation_id: null, reservation_id: null, kind: "unmatched_reservation", external_ref: p_external_ref, source_name: null, details: "رقم حجز غير مطابق", status: "open", resolved_by: null, resolved_at: null, created_at: nowISO() }); emit("human_handoff_tickets"); return { status: "unmatched" }; } const g = T("reservation_guests").find((x) => x.reservation_id === r.id && x.is_primary); if (!g?.phone || !g.phone.endsWith(p_phone_last4)) return { status: "mismatch" }; const token = "DEMO" + Math.random().toString(16).slice(2, 14).toUpperCase(); T("registration_sessions").push({ id: uid(), reservation_id: r.id, token, expires_at: new Date(Date.now() + 86400000).toISOString(), used_at: null, created_at: nowISO() }); return { status: "ok", token }; },
  // phone-first lookup (0020). The demo has no WhatsApp: guest-otp answers channel_unavailable, so the page asks for a booking number
  fn_guest_phone_verify: () => ({ status: "expired" }),
  fn_guest_phone_verify_ref: ({ p_phone, p_ref }) => { const ph = normPhone(p_phone); if (!ph) return { status: "invalid" }; const ids = phoneReservationIds(ph); const ok = T("reservations").some((r) => ids.includes(r.id) && [r.external_ref, r.internal_ref].some((x) => String(x ?? "").toUpperCase() === String(p_ref ?? "").trim().toUpperCase())); if (!ok) return { status: "mismatch" }; const token = "PH" + Math.random().toString(16).slice(2, 14).toUpperCase(); phoneSessions.set(token, ph); return { status: "ok", token }; },
  fn_guest_phone_reservations: ({ p_token }) => { const ph = phoneSessions.get(p_token); if (!ph) throw new Error("TOKEN_INVALID"); const ids = phoneReservationIds(ph); return { phone_last4: ph.slice(-4), reservations: T("reservations").filter((r) => ids.includes(r.id)).sort((a, b) => (a.check_in < b.check_in ? -1 : 1)).map((r) => ({ ref: r.external_ref ?? r.internal_ref, internal_ref: r.internal_ref, status: r.status, check_in: r.check_in, check_out: r.check_out, nights: Math.round((Date.parse(r.check_out) - Date.parse(r.check_in)) / 86400000), branch_name: byId("branches", r.branch_id)?.name_ar ?? null, category_name: byId("room_categories", r.room_category_id)?.name_ar ?? null, payment_status: r.payment_status, access_status: r.access_status, identity_status: r.identity_status })) }; },
  fn_guest_phone_open: ({ p_token, p_internal_ref }) => { const ph = phoneSessions.get(p_token); if (!ph) throw new Error("TOKEN_INVALID"); const r = T("reservations").find((x) => x.internal_ref === p_internal_ref && phoneReservationIds(ph).includes(x.id)); if (!r) throw new Error("NOT_FOUND"); const token = "DEMO" + Math.random().toString(16).slice(2, 14).toUpperCase(); T("registration_sessions").push({ id: uid(), reservation_id: r.id, token, expires_at: new Date(Date.now() + 86400000).toISOString(), used_at: null, created_at: nowISO() }); return { status: "ok", token }; },
  fn_guest_session: ({ p_token }) => { const s = T("registration_sessions").find((x) => x.token === p_token); if (!s) throw new Error("TOKEN_INVALID"); const r = byId("reservations", s.reservation_id)!; const ev = evaluate(r.id); const d = stayDue(r.id); return { reservation: { id: r.id, internal_ref: r.internal_ref, external_ref: r.external_ref, status: r.status, check_in: r.check_in, check_out: r.check_out, adults: r.adults, companions: r.companions, payment_status: r.payment_status, identity_status: r.identity_status, government_registration: r.government_registration, access_status: r.access_status, total_halalas: r.total_halalas, paid_halalas: r.paid_halalas, has_keybox: hasKeybox(r.room_id), first_night_paid: d.collected >= d.first_night, branch_id: r.branch_id, branch_name: byId("branches", r.branch_id)?.name_ar ?? null, room_number: roomNo(r.room_id), category_name: byId("room_categories", r.room_category_id)?.name_ar ?? null, summary_accepted: T("stay_acknowledgements").some((a) => a.reservation_id === r.id) }, guests: T("reservation_guests").filter((g) => g.reservation_id === r.id).map((g) => ({ id: g.id, is_primary: g.is_primary, full_name: g.full_name, identity_type: g.identity_type, identity_number_last4: g.identity_number_last4, nationality: g.nationality, birth_date: g.birth_date, relationship: g.relationship, verification_status: g.verification_status, data_submitted: g.data_submitted })), access: { allowed: ev.allowed, reasons: [...new Set(ev.reasons.map((x: string) => (["الضيف محظور من الإدارة", "يوجد حظر أمني على الحجز"].includes(x) ? "يرجى مراجعة الاستقبال" : x)))] }, expires_at: s.expires_at }; },
  fn_guest_submit: ({ p_token, p_guest_id, p_payload }) => { const s = T("registration_sessions").find((x) => x.token === p_token); if (!s) throw new Error("TOKEN_INVALID"); const r = byId("reservations", s.reservation_id)!; const p = p_payload ?? {}; if (!p.full_name || p.full_name.trim().split(/\s+/).length < 3) throw new Error("VALIDATION: full_name_three_parts"); if (!["national_id", "iqama", "passport", "gcc_id"].includes(p.identity_type)) throw new Error("VALIDATION: identity_type"); checkPersonName(p.full_name); const number = latinDigits(String(p.identity_number ?? "")).replace(/\s/g, ""); checkIdentity(p.identity_type, number); const phone = checkPhone(p.phone, false); checkMinAge(p.birth_date, todayISO()); if (String(p.consent) !== "true") throw new Error("VALIDATION: consent_required"); if (["cancelled", "rejected", "closed", "checked_out", "no_show"].includes(r.status)) throw new Error("RESERVATION_NOT_EDITABLE"); const fp = fingerprint(p.identity_type, number); let g = p_guest_id ? byId("reservation_guests", p_guest_id) : null;
    if (g?.is_primary && !p.ack_hash && !T("stay_acknowledgements").some((a) => a.reservation_id === r.id)) throw new Error("VALIDATION: acknowledgement_required");
    if (T("reservation_guests").some((x) => x.reservation_id === r.id && x.identity_fingerprint === fp && x.id !== g?.id)) throw new Error("DUPLICATE_GUEST"); if (!g) { const n = T("reservation_guests").filter((x) => x.reservation_id === r.id).length; if (n >= r.adults + r.companions) throw new Error("GUEST_LIMIT_REACHED"); g = { id: uid(), reservation_id: r.id, guest_profile_id: null, is_primary: n === 0, full_name: "", identity_type: null, identity_number_last4: null, nationality: null, birth_date: null, phone: null, relationship: null, verification_status: "not_started", data_submitted: false, created_at: nowISO() }; T("reservation_guests").push(g); } if (g.verification_status === "verified") throw new Error("GUEST_ALREADY_VERIFIED"); if (g.is_primary && p.ack_hash) rpcs.fn_guest_acknowledge({ p_token, p_hash: p.ack_hash });   // the summary as the guest read it, before their name changes it
    Object.assign(g, { full_name: p.full_name, identity_type: p.identity_type, identity_number_last4: number.slice(-4), identity_fingerprint: fp, nationality: p.nationality, birth_date: p.birth_date, relationship: g.is_primary ? "self" : p.relationship ?? null, phone: phone ?? g.phone, verification_status: "data_submitted", data_submitted: true, entry_path: "guest", entered_by: null, entered_at: nowISO(), verified_by: null, verified_at: null });
    const all = T("reservation_guests").filter((x) => x.reservation_id === r.id); r.identity_status = all.length >= r.adults + r.companions && all.every((x) => x.data_submitted) ? "pending_supervisor" : "data_submitted"; emit("reservation_guests"); emit("reservations"); return { ok: true, guest_id: g.id }; },
  fn_guest_submit_checkin: ({ p_token }) => { const s = T("registration_sessions").find((x) => x.token === p_token); if (!s) throw new Error("TOKEN_INVALID"); const r = byId("reservations", s.reservation_id)!; if (r.access_status === "locked") r.access_status = "eligibility_review"; emit("reservations"); return { ok: true, access_status: r.access_status }; },
  fn_guest_access_code: ({ p_token }) => { const s = T("registration_sessions").find((x) => x.token === p_token); if (!s) throw new Error("TOKEN_INVALID"); const r = byId("reservations", s.reservation_id)!; const ev = evaluate(r.id); if (!ev.allowed || !["delivered", "acknowledged"].includes(r.access_status)) return { allowed: false, reasons: ev.allowed ? ["لم يُسلَّم الرمز بعد"] : ev.reasons };
    // the code shown is the one delivered to this stay, never another (0005)
    const kb = T("keyboxes").find((k) => k.room_id === r.room_id); if (!kb?.code_plain || kb.last_reservation_id !== r.id) return { allowed: false, reasons: ["الرمز غير مخصص لهذا الحجز"] };
    if (r.access_status === "delivered") { r.access_status = "acknowledged"; r.updated_at = nowISO(); emit("reservations"); } for (const e of T("access_delivery_events")) if (e.reservation_id === r.id) e.acknowledged = true;
    return { allowed: true, code: kb.code_plain, room_number: roomNo(r.room_id) }; },
  ...knowledgeRpcs({ T, byId, me, myBranches, hasRole, requireRole, requireBranch, checkVersion, audit, emit, staffId, ...perm }),
  ...guestRpcs(guestCtx),

  // ---- WhatsApp per branch (0021) + the reception computer (0023): the demo sends nothing; the WhatsApp simulator
  //      (src/demo/whatsappSim.ts) stands in for the reception computer and runs the server's own code ----
  fn_admin_whatsapp_channels: () => { requireCap("security"); return T("branches").filter((b) => !b.archived_at).map((b) => { const c = T("branch_whatsapp_channels").find((x) => x.branch_id === b.id); return { branch_id: b.id, branch_name: b.name_ar, branch_phone: b.phone, mode: c?.mode ?? "web_bridge", enabled: !!c?.enabled, display_phone: c?.display_phone ?? null, phone_number_id: c?.phone_number_id ?? null, waba_id: c?.waba_id ?? null, has_token: !!c?.has_token, token_last4: c?.token_last4 ?? null, has_app_secret: !!c?.has_app_secret, verify_token: c?.verify_token ?? null, otp_template: c?.otp_template ?? null, template_lang: c?.template_lang ?? "ar", status: c?.status ?? "not_configured", last_error: c?.last_error ?? null, last_checked_at: c?.last_checked_at ?? null, verified_name: c?.verified_name ?? null, updated_at: c?.updated_at ?? null,
    auto_reply: c?.auto_reply ?? true, human_pause_minutes: c?.human_pause_minutes ?? 60, has_bridge_key: !!c?.has_bridge_key, bridge_key_last4: c?.bridge_key_last4 ?? null, bridge_key_created_at: c?.bridge_key_created_at ?? null, bridge_status: c?.bridge_status ?? null, bridge_phone: c?.bridge_phone ?? null, bridge_name: c?.bridge_name ?? null, bridge_version: c?.bridge_version ?? null, bridge_last_seen: c?.bridge_last_seen ?? null, bridge_online: !!c?.bridge_last_seen && Date.now() - Date.parse(c.bridge_last_seen) < 90_000 }; }); },
  fn_admin_whatsapp_save: ({ p_branch, p }) => { requireCap("security"); if (!byId("branches", p_branch)) throw new Error("NOT_FOUND: branch");
    let c = T("branch_whatsapp_channels").find((x) => x.branch_id === p_branch); if (!c) { c = { branch_id: p_branch, organization_id: ORG, mode: "web_bridge", enabled: false, display_phone: null, phone_number_id: null, waba_id: null, has_token: false, token_last4: null, has_app_secret: false, verify_token: "demo-" + uid().replace(/-/g, ""), otp_template: null, template_lang: "ar", status: "not_configured", last_error: null, last_checked_at: null, verified_name: null, auto_reply: true, human_pause_minutes: 60, has_bridge_key: false, bridge_key: null, bridge_key_last4: null, bridge_key_created_at: null, bridge_status: null, bridge_phone: null, bridge_name: null, bridge_version: null, bridge_last_seen: null, created_at: nowISO() }; T("branch_whatsapp_channels").push(c); }
    const changed: string[] = []; let key: string | null = null;
    if ("mode" in p) { if (!["cloud_api", "web_bridge"].includes(p.mode)) throw new Error("VALIDATION: mode"); if (p.mode !== c.mode) { c.mode = p.mode; changed.push("mode"); } }
    if ("display_phone" in p) { const v = String(p.display_phone ?? "").trim() ? normPhone(p.display_phone) : null; if (String(p.display_phone ?? "").trim() && !v) throw new Error("VALIDATION: display_phone"); if (v !== c.display_phone) { c.display_phone = v; changed.push("display_phone"); } }
    if ("phone_number_id" in p) { const v = String(p.phone_number_id ?? "").trim() || null; if (v && !/^\d{5,30}$/.test(v)) throw new Error("VALIDATION: phone_number_id"); if (v && T("branch_whatsapp_channels").some((x) => x.phone_number_id === v && x.branch_id !== p_branch)) throw new Error("VALIDATION: phone_number_id already used by another branch"); if (v !== c.phone_number_id) { c.phone_number_id = v; changed.push("phone_number_id"); } }
    if ("waba_id" in p) c.waba_id = String(p.waba_id ?? "").trim() || null;
    if ("otp_template" in p) c.otp_template = String(p.otp_template ?? "").trim().toLowerCase() || null;
    if ("template_lang" in p) c.template_lang = String(p.template_lang ?? "").trim() || "ar";
    const tok = String(p.access_token ?? "").trim(); if (tok) { if (tok.length < 20 || /\s/.test(tok)) throw new Error("VALIDATION: access_token"); c.has_token = true; c.token_last4 = tok.slice(-4); changed.push("access_token"); }
    const sec = String(p.app_secret ?? "").trim(); if (sec) { if (sec.length < 16 || /\s/.test(sec)) throw new Error("VALIDATION: app_secret"); c.has_app_secret = true; changed.push("app_secret"); }
    if (p.regenerate_verify_token) { c.verify_token = "demo-" + uid().replace(/-/g, ""); changed.push("verify_token"); }
    // the reception computer's key: shown once (the real server keeps only its SHA-256; the demo keeps it to simulate the program)
    if (p.regenerate_bridge_key) { key = "zb_" + randomHex(32); Object.assign(c, { bridge_key: key, has_bridge_key: true, bridge_key_last4: key.slice(-4), bridge_key_created_at: nowISO(), bridge_status: null, bridge_phone: null, bridge_name: null, bridge_version: null, bridge_last_seen: null }); changed.push("bridge_key"); }
    else if (p.revoke_bridge_key && c.has_bridge_key) { Object.assign(c, { bridge_key: null, has_bridge_key: false, bridge_key_last4: null, bridge_key_created_at: null, bridge_status: null, bridge_last_seen: null }); changed.push("bridge_key_revoked"); }
    if ("auto_reply" in p) { if (typeof p.auto_reply !== "boolean") throw new Error("VALIDATION: auto_reply"); if (p.auto_reply !== c.auto_reply) { c.auto_reply = p.auto_reply; changed.push("auto_reply"); } }
    if ("human_pause_minutes" in p) { if (typeof p.human_pause_minutes !== "number") throw new Error("VALIDATION: human_pause_minutes"); const v = Math.round(p.human_pause_minutes); if (v < 5 || v > 720) throw new Error("VALIDATION: human_pause_minutes"); if (v !== c.human_pause_minutes) { c.human_pause_minutes = v; changed.push("human_pause_minutes"); } }
    if (changed.some((k) => ["mode", "display_phone", "phone_number_id", "access_token", "app_secret", "bridge_key", "bridge_key_revoked"].includes(k))) { c.status = "configured"; c.last_error = null; c.verified_name = null; }
    c.status = waStatus(c);
    if ("enabled" in p) { if (p.enabled && c.status === "not_configured") throw new Error("VALIDATION: channel_incomplete"); if (!!p.enabled !== c.enabled) { c.enabled = !!p.enabled; changed.push("enabled"); } }
    if (c.status === "not_configured") c.enabled = false;
    c.updated_at = nowISO(); emit("branch_whatsapp_channels"); audit(p_branch, "whatsapp_channel_updated", "branch", p_branch, { changed, mode: c.mode, enabled: c.enabled, status: c.status, auto_reply: c.auto_reply });
    return { ok: true, status: c.status, enabled: c.enabled, mode: c.mode, changed, ...(key ? { bridge_key: key } : {}) }; },
  fn_public_whatsapp: ({ p_branch }) => { const b = byId("branches", p_branch); if (!b || !b.is_active || b.archived_at) return null; const c = T("branch_whatsapp_channels").find((x) => x.branch_id === p_branch); const active = !!c?.enabled && (["configured", "active"].includes(c.status) || (c.mode === "web_bridge" && c.status === "error")); return { active, wa_phone: active ? c!.display_phone : null, branch_name: b.name_ar, branch_phone: b.phone }; },
  // inbox: take a conversation (the assistant steps back; on WhatsApp for the branch's pause) or return it — audited (0023)
  fn_conversation_take: ({ p_conversation, p_take }) => { requireCap("conversation.take"); const cv = byId("conversations", p_conversation); if (!cv) throw new Error("NOT_FOUND: conversation"); if (cv.branch_id && !myBranches().includes(cv.branch_id)) throw new Error("FORBIDDEN: branch"); const before = cv.status;
    if (p_take) { const pause = T("branch_whatsapp_channels").find((x) => x.branch_id === cv.branch_id)?.human_pause_minutes ?? 60; Object.assign(cv, { status: "handed_off", handed_off_at: cv.handed_off_at ?? nowISO(), human_active_until: cv.channel === "whatsapp" ? new Date(Date.now() + pause * 60_000).toISOString() : cv.human_active_until ?? null }); }
    else Object.assign(cv, { status: "active", handed_off_at: null, human_active_until: null });
    emit("conversations"); audit(cv.branch_id ?? null, p_take ? "conversation_taken" : "conversation_returned_to_assistant", "conversation", cv.id, { before, after: cv.status, channel: cv.channel });
    return { ok: true, status: cv.status, human_active_until: p_take ? cv.human_active_until : null }; },

  // ---- data purge (0022): the same kinds, period and three confirmations; the demo resets with the seed ----
  fn_admin_purge_preview: ({ p_branch, p_from, p_to, p_categories }) => { /* purgeValidate asks «security» first (fn_purge_validate) */ const cats = purgeValidate(p_branch, p_from, p_to, p_categories); const snapshot = JSON.stringify(S); const counts = purgeRun(p_branch, p_from, p_to, cats); S = JSON.parse(snapshot); const token = "PURGE" + uid().replace(/-/g, ""); purgeRequests.set(token, { branch: p_branch ?? null, from: p_from, to: p_to, cats, staff: staffId(), expires: Date.now() + 15 * 60_000, used: false }); return { request_id: uid(), token, counts, categories: cats, phrase: "احذف نهائيا", expires_in_minutes: 15 }; },
  fn_admin_purge_execute: ({ p_token, p_phrase }) => { requireCap("security"); const q = purgeRequests.get(p_token); if (!q || q.used || q.expires < Date.now()) throw new Error("VALIDATION: preview_expired"); if (q.staff !== staffId()) throw new Error("FORBIDDEN: only the owner who previewed can confirm"); if (String(p_phrase ?? "").replace(/[\u064B-\u0652]/g, "").trim() !== "احذف نهائيا") throw new Error("VALIDATION: confirmation_phrase"); if (Date.now() - lastSignInAt > 10 * 60_000) throw new Error("REAUTH_REQUIRED: sign in again to confirm"); const counts = purgeRun(q.branch, q.from, q.to, q.cats); q.used = true; emitAll(); audit(q.branch, "data_purge_executed", "organization", ORG, { from: q.from, to: q.to, categories: q.cats, counts }); purgeHistory.unshift({ id: uid(), branch_name: q.branch ? byId("branches", q.branch)?.name_ar ?? null : null, from: q.from, to: q.to, categories: q.cats, counts, executed_at: nowISO(), by: me()?.full_name ?? null }); return { ok: true, counts }; },
  fn_admin_purge_history: () => { requireCap("security"); return purgeHistory; },
};
// ---------------------------------------------------------------------------
// the stay cycle (0032–0033): the arrival and its two entries, Shomoos, the code after the arrival, night-by-night
// payment, check-out with nothing owed, the inspection and the deposit, damages, corrections, «مغلق» by itself
// ---------------------------------------------------------------------------
const sarText = (h: number) => `${(h / 100).toFixed(2)} ر.س`;
/** A branch-local wall-clock moment as an instant (the demo's branches are all in Asia/Riyadh: UTC+3, no daylight saving). */
const localMs = (day: string, hhmm: string) => Date.parse(`${day}T${String(hhmm).slice(0, 5)}:00+03:00`);
const checkOutTime = (branchId: string) => String(byId("branches", branchId)?.check_out_time ?? "12:00").slice(0, 5);
const departureTime = (r: Row) => String(r.late_checkout_until ?? checkOutTime(r.branch_id)).slice(0, 5);
const hasKeybox = (roomId: string | null | undefined) => !!roomId && T("keyboxes").some((k) => k.room_id === roomId);
const staffName = (id: string | null | undefined) => (id ? byId("staff_profiles", id)?.full_name ?? null : null);

/** What is due night by night (decision 3) — the same computation as fn_stay_due_internal. */
function stayDue(resId: string, at = Date.now()) {
  const r = byId("reservations", resId)!; ensureNights(resId);
  const f = financeOf(resId); const b = byId("branches", r.branch_id)!; const cot = checkOutTime(r.branch_id);
  // services, fees and added amounts are due when added; the rest (nights with their tax, less discounts) night by night
  const extras = f.addons + f.penalties + Math.max(f.adjustments, 0);
  const nights = T("reservation_nights").filter((x) => x.reservation_id === resId && x.status === "active").sort((a, c) => (a.night < c.night ? -1 : 1));
  const cum = [0]; for (const x of nights) { const t = reservationTax(resId, x.price_halalas, true); cum.push(cum[cum.length - 1] + t.net + t.tax); }
  const n = nights.length; const rn = cum[n];
  const share = (k: number) => Math.max(0, rn <= 0 ? f.total : roundHalfUp(((f.total - extras) * cum[k]) / rn) + extras);
  let kDue = 0, kOver = 0, covered = 0;
  if (n > 0) {
    kDue = 1; for (let i = 2; i <= n; i++) { if (at < localMs(nights[i - 1].night, cot)) break; kDue = i; }
    if (r.status === "checked_in") { kOver = 1; for (let i = 2; i <= n; i++) { if (at < localMs(nights[i - 1].night, cot) + 3_600_000) break; kOver = i; } }
    for (let i = 1; i <= n; i++) { if (share(i) > f.net_collected) break; covered = i; }
  }
  const dueNow = share(kDue); const over = kOver > covered;
  return {
    nights: n, nights_due: kDue, nights_covered: covered, total: f.total, collected: f.net_collected, first_night: share(Math.min(n, 1)),
    due_now: dueNow, shortfall_now: Math.max(dueNow - f.net_collected, 0), overdue: over, overdue_amount: over ? Math.max(share(kOver) - f.net_collected, 0) : 0,
    overdue_since: over ? (covered === 0 ? r.actual_check_in ?? new Date(at).toISOString() : new Date(localMs(nights[covered].night, cot) + 3_600_000).toISOString()) : null,
    overdue_through: over ? (nights[kOver - 1].night as string) : null, next_unpaid_night: covered < n ? nights[covered].night : null,
    next_deadline: covered < n && covered > 0 ? new Date(localMs(nights[covered].night, cot)).toISOString() : null, deadline_time: cot,
    balance_due: f.balance_due, deposit_required: Number(b.default_deposit_halalas ?? 0), deposit_balance: f.deposit_balance,
  };
}
/** An overdue night stops extending and services until it is paid or a reason covering it is recorded. */
function overdueBlocked(resId: string) { const d = stayDue(resId); if (!d.overdue) return false; return !T("stay_payment_exceptions").some((e) => e.reservation_id === resId && e.through_night >= d.overdue_through!); }
/** The arrival's conditions that are not money: the same in every branch, no override (decisions 1, 2, 6). */
function checkinCoreBlockers(r: Row): string[] {
  if (r.status === "checked_in") return ["سُجِّل وصول هذا الحجز مسبقًا"];
  const v: string[] = []; const today = branchToday(r.branch_id);
  if (r.status !== "confirmed") v.push("الحجز غير مؤكد");
  if (r.security_hold) v.push("يوجد حظر أمني على الحجز");
  if (rpcs.fn_reservation_ban_matches({ p_reservation: r.id }).length > 0) v.push("الضيف محظور من الإدارة");
  if (today < r.check_in) v.push(`لم يحن تاريخ الوصول (${r.check_in})`); else if (today >= r.check_out) v.push("انتهت فترة الإقامة");
  const g = T("reservation_guests").filter((x) => x.reservation_id === r.id); const sc = g.filter((x) => x.data_submitted).length; const vc = g.filter((x) => x.verification_status === "verified").length;
  if (g.length === 0) v.push("لم تُسجَّل بيانات النزلاء"); else if (sc < g.length) v.push("بيانات أحد النزلاء ناقصة"); else if (g.length < r.adults + r.companions) v.push("عدد النزلاء المسجلين أقل من عدد الحجز");
  if (r.identity_status !== "verified" || vc < g.length) v.push("لم تُعتمد مطابقة الهوية لجميع النزلاء");
  if (!r.government_registration || !String(r.gov_registration_ref ?? "").trim()) v.push("لم يُسجَّل النزلاء في شموس");
  else if ((r.shomoos_guest_count ?? null) !== r.adults + r.companions) v.push("تغيّر عدد النزلاء بعد تسجيل شموس؛ حدِّث التسجيل");
  else if (!r.shomoos_accepted_at) v.push("لم يُؤكَّد قبول شموس للتسجيل");
  if (!r.room_id) v.push("لم تُخصَّص وحدة");
  else {
    const rm = byId("rooms", r.room_id)!;
    if (!rm.is_active || rm.archived_at) v.push("الوحدة موقوفة عن العمل");
    else if (["maintenance", "blocked", "out_of_service"].includes(rm.status) || T("maintenance_tickets").some((m) => m.room_id === rm.id && m.status !== "resolved")) v.push("الوحدة تحت الصيانة");
    else if (rm.cleanliness !== "clean") v.push("الوحدة غير نظيفة");
    if (T("reservations").some((o) => o.room_id === rm.id && o.status === "checked_in" && o.id !== r.id)) v.push("في الوحدة نزيل لم تُسجَّل مغادرته");
    const mine = T("reservation_allocations").some((a) => a.reservation_id === r.id && a.room_id === rm.id && a.status === "active" && a.from_date <= today && today < a.to_date);
    const end = r.check_out > today ? r.check_out : addDays(today, 1);
    if (!mine && T("reservation_allocations").some((a) => a.room_id === rm.id && a.status === "active" && a.reservation_id !== r.id && overlaps(a.from_date, a.to_date, today, end))) v.push("الوحدة محجوزة لحجز آخر في هذه الفترة");
  }
  return v;
}
/** The arrival's money conditions, with what the arrival screen is about to record (decision 3). */
function checkinMoneyBlockers(r: Row, addCollected = 0, addDeposit = 0, reason: string | null = null): string[] {
  const d = stayDue(r.id); const v: string[] = [];
  const need = d.first_night - d.collected - addCollected; if (need > 0) v.push(`الليلة الأولى غير مدفوعة كاملة: المتبقي ${sarText(need)}`);
  if (d.deposit_balance + addDeposit < d.deposit_required && !String(reason ?? "").trim()) v.push(`التأمين لم يُستلم كاملًا: المطلوب ${sarText(d.deposit_required)}`);
  return v;
}
/** What stands before delivering (or showing) the key-box code: only after the arrival, only a unit with a box (decision 1). */
function codeBlockers(r: Row): string[] {
  if (r.status !== "checked_in") return ["لم يُسجَّل الوصول بعد"];
  const v: string[] = []; if (r.security_hold) v.push("يوجد حظر أمني على الحجز");
  if (rpcs.fn_reservation_ban_matches({ p_reservation: r.id }).length > 0) v.push("الضيف محظور من الإدارة");
  if (Date.now() > localMs(r.check_out, departureTime(r))) v.push("انتهى موعد المغادرة");
  if (!r.room_id) return [...v, "لم تُخصَّص وحدة"];
  const kb = T("keyboxes").find((k) => k.room_id === r.room_id);
  if (!kb) v.push("الوحدة بلا صندوق مفتاح؛ يُسلَّم مفتاحها يدويًا");
  else if (!kb.code_plain) v.push("لم يُعيَّن رمز الصندوق");
  else if (kb.code_status !== "active") v.push("رمز الصندوق يحتاج إلى تغيير");
  else if (!kb.field_tested) v.push("لم يُجرَّب رمز الصندوق على الصندوق");
  else if (kb.last_reservation_id && kb.last_reservation_id !== r.id) v.push("الرمز الحالي سُلِّم لحجز آخر ويجب تغييره");
  return v;
}
/** What keeps a departed stay from «مغلق» (decision 59). */
function closureMissing(resId: string): string[] {
  const f = financeOf(resId); const v: string[] = [];
  if (f.balance_due > 0) v.push(`مبلغ مستحق ${sarText(f.balance_due)}`);
  if (f.credit > 0) v.push(`رصيد للضيف لم يُرد ${sarText(f.credit)}`);
  if (f.deposit_balance !== 0) v.push(`تأمين لم يُسوَّ ${sarText(f.deposit_balance)}`);
  const u = uninvoicedValue(resId); if (u > 0) v.push(`قيمة لم تُفوتر ${sarText(u)}`); else if (u < 0) v.push(`الفواتير تزيد على قيمة الإقامة ${sarText(-u)}؛ عدّل الفاتورة`);
  return v;
}
/** Closes a departed stay once nothing is missing, and takes it back to «غادر» when something breaks (the triggers of 0033). */
function syncClosed(resId: string): string | null {
  const r = byId("reservations", resId); if (!r) return null; if (!["checked_out", "closed"].includes(r.status)) return r.status;
  const missing = closureMissing(resId);
  if (r.status === "checked_out" && missing.length === 0) { Object.assign(r, { status: "closed", closed_at: nowISO(), version: r.version + 1, updated_at: nowISO() }); emit("reservations"); audit(r.branch_id, "reservation.closed", "reservation", r.id, { before: { status: "checked_out" }, after: { status: "closed" } }); }
  else if (r.status === "closed" && missing.length > 0) { Object.assign(r, { status: "checked_out", closed_at: null, version: r.version + 1, updated_at: nowISO() }); emit("reservations"); audit(r.branch_id, "reservation.unclosed", "reservation", r.id, { before: { status: "closed" }, after: { status: "checked_out", missing } }); }
  return r.status;
}
/** «بحاجة لمراجعة وتدقيق» (the owner's list; Phase 4 shows it) */
function addReview(branch: string, kind: string, entityType: string, entityId: string, resId: string | null, summary: string, reason: string | null, details: Row) {
  T("review_items").unshift({ id: uid(), organization_id: ORG, branch_id: branch, kind, entity_type: entityType, entity_id: entityId, reservation_id: resId, summary, reason, details, created_by: staffId(), created_at: nowISO(), reviewed_at: null, reviewed_by: null, review_note: null });
  emit("review_items");
}
/** Runs a write as one unit: anything thrown restores the store as it was (a transaction rolled back). */
function atomically<V>(fn: () => V): V { const snap = JSON.stringify(S); try { return fn(); } catch (e) { S = JSON.parse(snap); emitAll(); throw e; } }

// ---------------------------------------------------------------------------
// invoices and the owner's review list (0036–0037): an invoice carries a SHARE of each line, so a line can be split over
// period invoices; the automatic invoice at the departure and when the deposit is settled; edits with a reason keep the
// version before; «تصحيح سند»; «بحاجة لمراجعة وتدقيق»; the seven monitors
// ---------------------------------------------------------------------------
type Share = { charge_id: string; kind: string; description: string; quantity: number; unit_price_halalas: number; total_halalas: number; invoiced_halalas: number; share_halalas: number; service_from: string; service_to: string; created_at: string };
/** a × b ÷ d in whole halalas, half away from zero, exactly: multiplied before it is divided (fn_round_div, decision 47) */
function mulDivRound(a: number, b: number, d: number): number {
  const n = BigInt(a) * BigInt(b), den = BigInt(d);
  const neg = n !== 0n && (n < 0n) !== (den < 0n); const x = n < 0n ? -n : n, y = den < 0n ? -den : den;
  const q = (2n * x + y) / (2n * y); return Number(neg ? -q : q);
}
const daysBetween = (a: string, b: string) => Math.round((Date.parse(b + "T00:00:00Z") - Date.parse(a + "T00:00:00Z")) / 86400000);
/** fn_charge_part: the part of a line's total that falls before a day. Over nights: the nights before it; a discount or a
 *  stay-wide adjustment: the rent of the active nights before it, out of the rent of its nights (by count without rent). */
function chargePart(resId: string, total: number, weighted: boolean, from: string, to: string, at: string): number {
  if (at <= from) return 0; if (at >= to) return total;
  if (weighted) {
    const ns = T("reservation_nights").filter((x) => x.reservation_id === resId && x.status === "active" && x.night >= from && x.night < to);
    const all = ns.reduce((a, x) => a + Number(x.price_halalas), 0);
    if (all > 0) return mulDivRound(total, ns.filter((x) => x.night < at).reduce((a, x) => a + Number(x.price_halalas), 0), all);
  }
  return mulDivRound(total, daysBetween(from, at), daysBetween(from, to));
}
/** what the issued invoices (but one being edited) carry of each line */
function invoicedShares(resId: string, exclude: string | null = null): Map<string, number> {
  const m = new Map<string, number>();
  for (const i of T("invoices")) if (i.reservation_id === resId && i.status === "issued" && i.id !== exclude) for (const l of i.snapshot?.lines ?? []) m.set(l.charge_id, (m.get(l.charge_id) ?? 0) + Number(l.amount_halalas));
  return m;
}
/** a stay's lines in the order they were added, each tax line after its own line */
const lineOrder = (a: Row, b: Row) => (a.created_at < b.created_at ? -1 : a.created_at > b.created_at ? 1 : (a.kind === "tax" ? 1 : 0) - (b.kind === "tax" ? 1 : 0));
/** fn_invoice_shares: what an invoice for [from, to] would carry of each line — the nights from..to-1 at their saved price, a
 *  discount and a stay-wide adjustment in the same proportion as the period's rent, a tax line with its line, a one-off
 *  line when its day is in from..to. Shares are cumulative, so periods add up to each line to the halala. No period: all
 *  that no issued invoice carries yet. */
function invoiceShares(resId: string, from: string | null, to: string | null, exclude: string | null = null): Share[] {
  const done = invoicedShares(resId, exclude); const out: Share[] = [];
  for (const c of T("reservation_charges").filter((x) => x.reservation_id === resId && Number(x.total_halalas) !== 0).sort(lineOrder)) {
    const total = Number(c.total_halalas), invoiced = done.get(c.id) ?? 0, left = total - invoiced;
    if (left === 0) continue;
    let s = left;
    if (from && to) {
      const b = c.base_charge_id ? byId("reservation_charges", c.base_charge_id) : undefined;
      const k = b?.kind ?? c.kind, sf: string = b?.service_from ?? c.service_from, st: string = b?.service_to ?? c.service_to;
      if (sf === st) s = sf >= from && sf <= to ? left : 0;
      else {
        const w = k === "discount" || k === "adjustment";
        s = chargePart(resId, total, w, sf, st, to) - chargePart(resId, total, w, sf, st, from);
        s = total > 0 ? Math.max(0, Math.min(s, left)) : Math.min(0, Math.max(s, left));
      }
    }
    if (s === 0) continue;
    out.push({ charge_id: c.id, kind: c.kind, description: c.description, quantity: Number(c.quantity), unit_price_halalas: Number(c.unit_price_halalas), total_halalas: total, invoiced_halalas: invoiced, share_halalas: s, service_from: c.service_from, service_to: c.service_to, created_at: c.created_at });
  }
  return out;
}
const shareLine = (x: Share) => ({ charge_id: x.charge_id, kind: x.kind, description: x.description, quantity: x.quantity, unit_price_halalas: x.unit_price_halalas, total_halalas: x.total_halalas, amount_halalas: x.share_halalas, service_from: x.service_from, service_to: x.service_to });
const sumShares = (sh: Share[], tax: boolean) => sh.filter((x) => (x.kind === "tax") === tax).reduce((a, x) => a + x.share_halalas, 0);
/** the stay's value not yet carried by an issued invoice (negative: the invoices carry more than its lines) */
function uninvoicedValue(resId: string): number {
  return T("reservation_charges").filter((c) => c.reservation_id === resId).reduce((a, c) => a + Number(c.total_halalas), 0)
    - T("invoices").filter((i) => i.reservation_id === resId && i.status === "issued").reduce((a, i) => a + Number(i.total_halalas), 0);
}
/** reservation_charges.invoice_id = the issued invoice that completed the line, or nothing (fn_sync_invoice_markers) */
function syncInvoiceMarkers(resId: string) {
  const sums = new Map<string, number>(), last = new Map<string, Row>(); const at = (i: Row) => String(i.updated_at ?? i.issued_at);
  for (const i of T("invoices")) if (i.reservation_id === resId && i.status === "issued") for (const l of i.snapshot?.lines ?? []) {
    sums.set(l.charge_id, (sums.get(l.charge_id) ?? 0) + Number(l.amount_halalas));
    const cur = last.get(l.charge_id); if (!cur || at(i) > at(cur) || (at(i) === at(cur) && i.id > cur.id)) last.set(l.charge_id, i);
  }
  let changed = false;
  for (const c of T("reservation_charges")) if (c.reservation_id === resId) {
    const done = Number(c.total_halalas) !== 0 && (sums.get(c.id) ?? 0) === Number(c.total_halalas) ? last.get(c.id)?.id ?? null : null;
    if ((c.invoice_id ?? null) !== done) { c.invoice_id = done; changed = true; }
  }
  if (changed) emit("reservation_charges");
}
const OVERLAP = "INVOICE_PERIOD_OVERLAP: another invoice of this stay covers part of the period";
function periodOverlap(resId: string, from: string, to: string, exclude: string | null) {
  return T("invoices").some((i) => i.reservation_id === resId && i.status === "issued" && i.scope === "period" && i.id !== exclude && i.period_from < to && from < i.period_to);
}
/** a day sent by the screen ("" or nothing: none) */
function dayParam(v: unknown): string | null {
  if (v == null || v === "") return null;
  if (typeof v !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(v) || Number.isNaN(Date.parse(v + "T00:00:00Z"))) throw new Error("VALIDATION: period");
  return v;
}
const trimOrNull = (v: unknown) => { const t = String(v ?? "").trim(); return t || null; };
const stripNulls = (o: Row): Row => Object.fromEntries(Object.entries(o).filter(([, v]) => v != null));
const canon = (o: Row | null | undefined) => JSON.stringify(Object.keys(o ?? {}).sort().map((k) => [k, (o as Row)[k]]));
/** fn_issue_invoice: the caller checked the role and the branch; a period that overlaps another is refused; null when the
 *  period (or the stay) has nothing left to carry */
function issueInvoice(r: Row, scope: "period" | "remaining", from: string | null, to: string | null, origin: "manual" | "checkout" | "deposit_settled", billTo: Row | null): Row | null {
  if (scope === "period") { if (!from || !to || to <= from) throw new Error("VALIDATION: period"); if (periodOverlap(r.id, from, to, null)) throw new Error(OVERLAP); }
  const sh = invoiceShares(r.id, scope === "period" ? from : null, scope === "period" ? to : null);
  if (!sh.length) return null;
  const lines = sh.map(shareLine), sub = sumShares(sh, false), tax = sumShares(sh, true);
  // a period invoice keeps its period; the rest of a stay is dated by the lines it carries
  const pf = scope === "period" ? from! : sh.reduce((m, x) => (x.service_from < m ? x.service_from : m), sh[0].service_from);
  const pt = scope === "period" ? to! : sh.reduce((m, x) => (x.service_to > m ? x.service_to : m), sh[0].service_to);
  const b = byId("branches", r.branch_id)!; const gname = guestName(r.id);
  const bt = stripNulls({ name: trimOrNull(billTo?.name) ?? gname, note: trimOrNull(billTo?.note) });
  const inv: Row = { id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: r.id, number: nextNumber("INV"), period_from: pf, period_to: pt, scope, origin, version: 1, versions: [], bill_to: bt, status: "issued",
    snapshot: { property: { name: b.name_ar, tax_number: b.tax_number ?? null, commercial_register: b.commercial_register ?? null, address: b.address ?? null }, guest: { name: gname }, bill_to: bt,
      reservation: { internal_ref: r.internal_ref, external_ref: r.external_ref ?? null, check_in: r.check_in, check_out: r.check_out, room: roomNo(r.room_id) },
      period: { from: pf, to: pt, scope, requested: scope === "period" }, origin, charge_ids: lines.map((l) => l.charge_id), lines, tax_rate_bp: r.tax_rate_bp ?? b.tax_rate_bp ?? 0 },
    subtotal_halalas: sub, tax_halalas: tax, total_halalas: sub + tax, issued_by: staffId(), issued_at: nowISO(), updated_at: null, updated_by: null, cancelled_by: null, cancelled_at: null, cancel_reason: null };
  T("invoices").push(inv); emit("invoices"); syncInvoiceMarkers(r.id);
  audit(r.branch_id, "invoice.issued", "invoice", inv.id, { after: { number: inv.number, total_halalas: inv.total_halalas, reservation_id: r.id, scope, origin, period_from: pf, period_to: pt, line_count: lines.length } });
  syncClosed(r.id);   // the trigger of 0036: an invoice re-checks «مغلق»
  return inv;
}
/** fn_auto_invoice: everything not yet invoiced, only when something positive is left */
function autoInvoice(resId: string, origin: "checkout" | "deposit_settled"): string | null {
  if (invoiceShares(resId, null, null).reduce((a, x) => a + x.share_halalas, 0) <= 0) return null;
  return issueInvoice(byId("reservations", resId)!, "remaining", null, null, origin, null)?.number ?? null;
}
/** one finding into the review list, unless the same one is open or was raised within the last day (0037) */
function monitorFinding(branch: string | null, kind: string, entityType: string, entityId: string, resId: string | null, summary: string, details: Row): boolean {
  const k = "monitor:" + kind, dayAgo = new Date(Date.now() - 86_400_000).toISOString();
  if (T("review_items").some((ri) => ri.kind === k && ri.entity_id === entityId && (ri.reviewed_at == null || ri.created_at > dayAgo))) return false;
  T("review_items").unshift({ id: uid(), organization_id: ORG, branch_id: branch, kind: k, entity_type: entityType, entity_id: entityId, reservation_id: resId, summary, reason: null, details, created_by: null, created_at: nowISO(), reviewed_at: null, reviewed_by: null, review_note: null });
  emit("review_items"); return true;
}
/** fn_run_monitors for one branch, then the organisation's own checks: counts, references, unit numbers and staff names
 *  only — never a phone number or an identity */
function runMonitors(branch: string): Record<string, number> {
  const found: Record<string, number> = {}; const hit = (k: string, raised: boolean) => { if (raised) found[k] = (found[k] ?? 0) + 1; };
  const ago = (ms: number) => new Date(Date.now() - ms).toISOString(); const ref = (id: string) => byId("reservations", id)?.internal_ref ?? "—";
  // 1 two active allocations of a unit that overlap, or two guests in house in one unit
  for (const rm of T("rooms").filter((x) => x.branch_id === branch)) {
    const act = T("reservation_allocations").filter((a) => a.room_id === rm.id && a.status === "active"); const refs = new Set<string>();
    for (let i = 0; i < act.length; i++) for (let j = i + 1; j < act.length; j++) if (overlaps(act[i].from_date, act[i].to_date, act[j].from_date, act[j].to_date)) { refs.add(ref(act[i].reservation_id)); refs.add(ref(act[j].reservation_id)); }
    const inHouse = T("reservations").filter((r) => r.branch_id === branch && r.status === "checked_in" && r.room_id === rm.id);
    if (inHouse.length > 1) for (const r of inHouse) refs.add(r.internal_ref);
    if (refs.size) hit("allocation_conflict", monitorFinding(branch, "allocation_conflict", "room", rm.id, null, `تعارض تخصيص في الوحدة ${rm.room_number}`, { room: rm.room_number, reservations: [...refs] }));
  }
  // 2 and 3: the stays of the last 90 days and every open one, against their ledger
  for (const r of T("reservations").filter((x) => x.branch_id === branch && (["pending_verification", "confirmed", "checked_in", "checked_out"].includes(x.status) || String(x.updated_at ?? x.created_at) > ago(90 * 86_400_000)))) {
    const f = financeOf(r.id);
    if (r.total_halalas !== f.total || r.paid_halalas !== f.net_collected || r.balance_due_halalas !== f.balance_due || r.deposit_balance_halalas !== f.deposit_balance)
      hit("ledger_mismatch", monitorFinding(branch, "ledger_mismatch", "reservation", r.id, r.id, `الملخص المالي للحجز ${r.internal_ref} يختلف عن الدفتر`,
        { stored: { total: r.total_halalas, paid: r.paid_halalas, balance_due: r.balance_due_halalas, deposit: r.deposit_balance_halalas }, ledger: { total: f.total, paid: f.net_collected, balance_due: f.balance_due, deposit: f.deposit_balance } }));
    if (f.deposit_balance < 0 || (r.status === "closed" && f.deposit_balance !== 0))
      hit("deposit_invalid", monitorFinding(branch, "deposit_invalid", "reservation", r.id, r.id, `رصيد التأمين في الحجز ${r.internal_ref} غير صالح (${sarText(f.deposit_balance)})`, { deposit_balance: f.deposit_balance, status: r.status }));
  }
  // 4 (the branch's part): WhatsApp replies waiting for more than an hour while the channel is on
  const waiting = T("branch_whatsapp_channels").some((c) => c.branch_id === branch && c.enabled) ? T("whatsapp_outbox").filter((o) => o.branch_id === branch && ["pending", "sending"].includes(o.status) && o.created_at < ago(3_600_000)).length : 0;
  if (waiting > 0) hit("provider_stuck", monitorFinding(branch, "provider_stuck", "branch", branch, null, `${waiting} رد واتساب لم يُرسل منذ أكثر من ساعة`, { whatsapp_waiting: waiting }));
  // 6 two open departure cleanings for one stay
  const open = new Map<string, Row[]>();
  for (const t of T("housekeeping_tasks")) if (t.branch_id === branch && t.reservation_id && ["pending", "in_progress"].includes(t.status) && t.description === "تنظيف بعد المغادرة") open.set(t.reservation_id, [...(open.get(t.reservation_id) ?? []), t]);
  for (const [resId, ts] of open) if (ts.length > 1) hit("duplicate_departure", monitorFinding(branch, "duplicate_departure", "reservation", resId, resId, `${ts.length} مهام تنظيف مغادرة مفتوحة للحجز ${ref(resId)}`, { room: roomNo(ts[0].room_id), open_tasks: ts.length }));
  // 7 (the organisation's): a staff member refused three times or more in a day (4 and 5: the demo has no provider events or guest look-ups to check)
  const refused = new Map<string, Row[]>();
  for (const e of T("client_errors")) if (e.staff_id && String(e.error_code ?? "").startsWith("FORBIDDEN") && e.created_at > ago(86_400_000)) refused.set(e.staff_id, [...(refused.get(e.staff_id) ?? []), e]);
  for (const [sid, es] of refused) if (es.length >= 3) hit("out_of_scope", monitorFinding(null, "out_of_scope", "staff", sid, null, `${staffName(sid) ?? "موظف"}: ${es.length} محاولات مرفوضة خارج صلاحياته خلال يوم`, { attempts: es.length, operations: [...new Set(es.map((e) => e.context).filter(Boolean))] }));
  const run = { branch_id: branch, last_run_at: nowISO(), result: found }; const at = T("monitor_runs").findIndex((x) => x.branch_id === branch);
  if (at >= 0) T("monitor_runs")[at] = run; else T("monitor_runs").push(run);
  return found;
}
function reviewSummary(): Row | null {
  const m = me(); if (!m || m.role !== "owner") return null; const mine = myBranches();
  const open = T("review_items").filter((ri) => ri.organization_id === m.organization_id && ri.reviewed_at == null && (ri.branch_id == null || mine.includes(ri.branch_id)));
  const by_kind: Record<string, number> = {}; for (const ri of open) by_kind[ri.kind] = (by_kind[ri.kind] ?? 0) + 1;
  return { open: open.length, oldest_at: open.reduce<string | null>((x, ri) => (x == null || ri.created_at < x ? ri.created_at : x), null), monitors: open.filter((ri) => String(ri.kind).startsWith("monitor:")).length, by_kind };
}

const rpcsInvoices: Record<string, (a: any) => any> = {
  // «إصدار فاتورة» (decision 27): with a period, a partial invoice; without, everything left. Refused when nothing positive is left
  fn_staff_issue_invoice: ({ p }) => {
    requireCap("invoice.issue");
    const pf = dayParam(p?.from), pt = dayParam(p?.to); if ((pf == null) !== (pt == null)) throw new Error("VALIDATION: period");
    const r = byId("reservations", p?.reservation_id); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id);
    if (pf && pt) { if (pt <= pf) throw new Error("VALIDATION: period"); if (periodOverlap(r.id, pf, pt, null)) throw new Error(OVERLAP); }
    const sh = invoiceShares(r.id, pf, pt);
    // nothing, or only lines that lower the bill: those go into an issued invoice by editing it (no credit notes, decision 26)
    if (sh.reduce((a, x) => a + x.share_halalas, 0) <= 0) throw new Error(sh.length ? "INVOICE_NOT_POSITIVE" : "NOTHING_TO_INVOICE");
    return atomically(() => {
      const inv = issueInvoice(r, pf ? "period" : "remaining", pf, pt, "manual", p.bill_to ?? null)!;
      return { ok: true, id: inv.id, number: inv.number, total_halalas: inv.total_halalas, period_from: inv.period_from, period_to: inv.period_to, scope: inv.scope, line_count: inv.snapshot.lines.length, charge_count: inv.snapshot.lines.length };
    });
  },
  // what an invoice would carry, before «إنشاء» (or an edit, with invoice_id): the lines, the totals, and what stops it
  fn_invoice_preview: ({ p }) => {
    requireCap("invoice.issue");
    let pf = dayParam(p?.from), pt = dayParam(p?.to); let r: Row | undefined; let inv: Row | undefined; let scope: string;
    if (p?.invoice_id) {
      inv = byId("invoices", p.invoice_id); if (!inv) throw new Error("NOT_FOUND"); r = byId("reservations", inv.reservation_id)!; scope = inv.scope;
      if (scope === "period") { pf = pf ?? inv.period_from; pt = pt ?? inv.period_to; } else { pf = null; pt = null; }
    } else {
      r = byId("reservations", p?.reservation_id); if (!r) throw new Error("RESERVATION_NOT_FOUND");
      if ((pf == null) !== (pt == null)) throw new Error("VALIDATION: period"); scope = pf ? "period" : "remaining";
    }
    requireBranch(r.branch_id);
    const problems: string[] = [];
    if (scope === "period") {
      if (pt! <= pf!) problems.push("نهاية الفترة يجب أن تكون بعد بدايتها");
      else if (periodOverlap(r.id, pf!, pt!, inv?.id ?? null)) problems.push("فاتورة أخرى لهذا الحجز تغطي جزءًا من الفترة");
    }
    let lines: Row[] = [], sub = 0, tax = 0;
    if (!problems.length) {
      const sh = invoiceShares(r.id, scope === "period" ? pf : null, scope === "period" ? pt : null, inv?.id ?? null);
      lines = sh.map((x) => ({ ...shareLine(x), invoiced_halalas: x.invoiced_halalas })); sub = sumShares(sh, false); tax = sumShares(sh, true);
      if (!sh.length) problems.push("لا شيء لم يُفوتر في هذه الفترة");
      else if (sub + tax <= 0) problems.push("ما بقي يخفّض الفاتورة فقط؛ يُضاف إلى فاتورة صادرة بتعديلها");
    }
    return { ok: problems.length === 0, problems, scope, from: pf, to: pt, lines, subtotal_halalas: sub, tax_halalas: tax, total_halalas: sub + tax,
      reservation: { id: r.id, internal_ref: r.internal_ref, external_ref: r.external_ref ?? null, guest: guestName(r.id), check_in: r.check_in, check_out: r.check_out, status: r.status },
      uninvoiced_halalas: uninvoicedValue(r.id) };
  },
  // an invoice edited with a reason (decision 26): its bill-to, its period, and its amounts, which follow the stay's lines as
  // they stand; the version before is kept in the invoice, and the edit waits in the owner's review list
  fn_staff_edit_invoice: ({ p }) => {
    requireCap("invoice.edit");
    const reason = trimOrNull(p?.reason); if (!reason) throw new Error("VALIDATION: reason");
    const inv = byId("invoices", p?.invoice_id); if (!inv) throw new Error("NOT_FOUND"); requireBranch(inv.branch_id); const r = byId("reservations", inv.reservation_id)!;
    if (inv.status !== "issued") throw new Error("INVOICE_STATUS_INVALID");
    let pf: string = inv.period_from, pt: string = inv.period_to;
    if (inv.scope === "period") {
      pf = dayParam(p.from) ?? inv.period_from; pt = dayParam(p.to) ?? inv.period_to;
      if (pt <= pf) throw new Error("VALIDATION: period"); if (periodOverlap(r.id, pf, pt, inv.id)) throw new Error(OVERLAP);
    }
    let bt: Row = { ...(inv.bill_to ?? {}) };
    if (p.bill_to && typeof p.bill_to === "object" && !Array.isArray(p.bill_to)) {
      // a key sent empty is cleared
      if ("name" in p.bill_to) bt.name = trimOrNull(p.bill_to.name); if ("note" in p.bill_to) bt.note = trimOrNull(p.bill_to.note);
      bt = stripNulls(bt); if (!bt.name) throw new Error("VALIDATION: bill_to_name");
    }
    const sh = invoiceShares(r.id, inv.scope === "period" ? pf : null, inv.scope === "period" ? pt : null, inv.id);
    if (!sh.length) throw new Error("NOTHING_TO_INVOICE");
    const sub = sumShares(sh, false), tax = sumShares(sh, true); if (sub + tax <= 0) throw new Error("INVOICE_NOT_POSITIVE");
    const lines = sh.map(shareLine);
    const shares = (ls: Row[]) => JSON.stringify(ls.map((l) => [String(l.charge_id), String(l.amount_halalas)]).sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)));
    if (shares(inv.snapshot?.lines ?? []) === shares(lines) && pf === inv.period_from && pt === inv.period_to && canon(bt) === canon(inv.bill_to)) return { ok: true, unchanged: true, id: inv.id, number: inv.number, version: inv.version };
    const prev = { version: inv.version, period_from: inv.period_from, period_to: inv.period_to, bill_to: inv.bill_to, subtotal_halalas: inv.subtotal_halalas, tax_halalas: inv.tax_halalas, total_halalas: inv.total_halalas,
      lines: inv.snapshot?.lines ?? [], since: inv.updated_at ?? inv.issued_at, by: staffName(inv.updated_by ?? inv.issued_by), replaced_at: nowISO(), replaced_by: staffName(staffId()), reason };
    Object.assign(inv, { versions: [...(inv.versions ?? []), prev], version: inv.version + 1, period_from: pf, period_to: pt, bill_to: bt,
      snapshot: { ...inv.snapshot, lines, bill_to: bt, period: { from: pf, to: pt, scope: inv.scope, requested: inv.scope === "period" }, charge_ids: lines.map((l) => l.charge_id) },
      subtotal_halalas: sub, tax_halalas: tax, total_halalas: sub + tax, updated_at: nowISO(), updated_by: staffId() });
    emit("invoices"); syncInvoiceMarkers(r.id);
    addReview(inv.branch_id, "invoice_edited", "invoice", inv.id, r.id, `تعديل الفاتورة ${inv.number} (الإصدار ${inv.version})`, reason,
      { number: inv.number, version: inv.version, before_total_halalas: prev.total_halalas, after_total_halalas: inv.total_halalas, before_period: [prev.period_from, prev.period_to], after_period: [pf, pt] });
    audit(inv.branch_id, "invoice.edited", "invoice", inv.id, { before: { version: prev.version, total_halalas: prev.total_halalas, period_from: prev.period_from, period_to: prev.period_to, bill_to: prev.bill_to }, after: { version: inv.version, total_halalas: inv.total_halalas, period_from: pf, period_to: pt, bill_to: bt }, reason });
    syncClosed(r.id);
    return { ok: true, unchanged: false, id: inv.id, number: inv.number, version: inv.version, total_halalas: inv.total_halalas };
  },
  // «تصحيح سند» (decision 11): the original cancelled and its replacement issued in one step, with a reason, through the
  // same checks as any new voucher, linked to it. The supervisor: the vouchers they issued, within 24 hours
  fn_staff_correct_voucher: ({ p }) => {
    requireCap("voucher.correct");
    const reason = trimOrNull(p?.reason); if (!reason) throw new Error("VALIDATION: reason");
    const key = trimOrNull(p?.idempotency_key); if (!key) throw new Error("VALIDATION: idempotency_key");
    const v = byId("financial_vouchers", p?.voucher_id); if (!v) throw new Error("NOT_FOUND"); requireBranch(v.branch_id); const r = byId("reservations", v.reservation_id)!;
    // the same correction again answers with its replacement
    const ex = T("financial_vouchers").find((x) => x.idempotency_key === key);
    if (ex) { if (ex.original_voucher_id !== v.id) throw new Error("IDEMPOTENCY_CONFLICT: key already used"); return { ok: true, duplicate: true, voucher_id: ex.id, number: ex.number, original_number: v.number, finance: financeOf(r.id) }; }
    if (v.status !== "approved") throw new Error("VOUCHER_STATUS_INVALID");
    if (v.payout_id) throw new Error("VOUCHER_IN_PAYOUT");
    if (!capFull("voucher.correct")) {
      if (v.created_by !== staffId()) throw new Error("FORBIDDEN: a supervisor corrects only the vouchers they issued");
      if (Date.parse(v.created_at) < Date.now() - 24 * 3_600_000) throw new Error("CORRECTION_WINDOW_PASSED: after 24 hours a voucher is corrected by a manager");
    }
    const amt = p.amount_halalas != null && String(p.amount_halalas) !== "" ? p.amount_halalas : v.amount_halalas;
    const m: string = trimOrNull(p.method) ?? v.method;
    const ref = "reference" in p ? trimOrNull(p.reference) : v.reference ?? null;
    // another method takes its own account: the one given, or that method's default
    const acc = "account_id" in p ? p.account_id || null : m !== v.method ? null : v.account_id ?? null;
    const note = "note" in p ? trimOrNull(p.note) : v.note ?? null;
    if (String(amt) === String(v.amount_halalas) && (v.kind === "deposit_apply" || m === v.method) && ref === (v.reference ?? null) && acc === (v.account_id ?? null) && note === (v.note ?? null)) throw new Error("VALIDATION: nothing_changed");
    return atomically(() => {
      Object.assign(v, { status: "cancelled", cancelled_at: nowISO(), cancelled_by: staffId(), cancel_reason: "تصحيح: " + reason });
      const payload = stripNulls({ reservation_id: r.id, kind: v.kind, idempotency_key: key, amount_halalas: amt, method: m, reference: ref, account_id: acc, note, reason: v.reason ?? "تصحيح السند " + v.number, original_voucher_id: v.id });
      const res = ["receipt", "deposit"].includes(v.kind) ? rpcs.fn_create_voucher({ p: payload }) : rpcs.fn_refund({ p: payload });
      const nv = byId("financial_vouchers", res.voucher_id)!; if (!nv.original_voucher_id) nv.original_voucher_id = v.id;
      const f = financeOf(r.id); if (f.deposit_balance < 0 || f.received - f.refunded < 0) throw new Error("CANCEL_WOULD_GO_NEGATIVE");
      emit("financial_vouchers"); recompute(r.id);
      const pick = (x: Row) => ({ amount_halalas: x.amount_halalas, method: x.method, reference: x.reference ?? null, account_id: x.account_id ?? null });
      addReview(v.branch_id, "voucher_corrected", "voucher", nv.id, r.id, `تصحيح السند ${v.number} بالسند ${nv.number}`, reason, { original: v.number, replacement: nv.number, kind: v.kind, before: pick(v), after: pick(nv), issued_by_self: v.created_by === staffId() });
      audit(v.branch_id, "voucher.corrected", "voucher", nv.id, { before: { number: v.number, ...pick(v) }, after: { number: nv.number, ...pick(nv), original_voucher_id: v.id }, reason });
      return { ok: true, duplicate: false, voucher_id: nv.id, number: nv.number, original_number: v.number, finance: financeOf(r.id) };
    });
  },
  // «بحاجة لمراجعة وتدقيق»: the owner reads and marks (§16)
  fn_review_list: ({ p }) => {
    requireCap("review.list"); const st = trimOrNull(p?.status) ?? "open"; if (!["open", "reviewed", "all"].includes(st)) throw new Error("VALIDATION: status");
    const n = p?.limit == null || p.limit === "" ? 100 : Math.trunc(Number(p.limit)); const lim = Math.min(Math.max(Number.isFinite(n) ? n : 100, 1), 500);
    const m = me()!; const mine = myBranches(); const kind = trimOrNull(p?.kind), branch = trimOrNull(p?.branch_id), before = trimOrNull(p?.before);
    const scoped = T("review_items").filter((ri) => ri.organization_id === m.organization_id && (ri.branch_id == null || mine.includes(ri.branch_id)));
    const items = scoped.filter((ri) => (st === "all" || (st === "open") === (ri.reviewed_at == null)) && (!kind || ri.kind === kind || (kind === "monitor" && String(ri.kind).startsWith("monitor:")))
        && (!branch || ri.branch_id === branch) && (!before || ri.created_at < before))
      .sort((a, b) => (a.created_at < b.created_at ? 1 : a.created_at > b.created_at ? -1 : 0)).slice(0, lim)
      .map((ri) => ({ id: ri.id, kind: ri.kind, entity_type: ri.entity_type, entity_id: ri.entity_id, reservation_id: ri.reservation_id, internal_ref: byId("reservations", ri.reservation_id)?.internal_ref ?? null,
        branch_id: ri.branch_id, branch_name: byId("branches", ri.branch_id)?.name_ar ?? null, summary: ri.summary, reason: ri.reason, details: ri.details,
        created_at: ri.created_at, created_by: staffName(ri.created_by), reviewed_at: ri.reviewed_at, reviewed_by: staffName(ri.reviewed_by), review_note: ri.review_note }));
    return { items, open_count: scoped.filter((ri) => ri.reviewed_at == null).length };
  },
  fn_review_mark: ({ p }) => {
    requireCap("review.list"); const ids: string[] = Array.isArray(p?.ids) ? p.ids.map(String) : []; if (!ids.length) throw new Error("VALIDATION: ids");
    const note = trimOrNull(p?.note); const m = me()!; const mine = myBranches(); let n = 0;
    for (const ri of T("review_items")) if (ids.includes(ri.id) && ri.reviewed_at == null && ri.organization_id === m.organization_id && (ri.branch_id == null || mine.includes(ri.branch_id))) { Object.assign(ri, { reviewed_at: nowISO(), reviewed_by: staffId(), review_note: note }); n++; }
    emit("review_items"); audit(null, "review.marked", "review_items", null as unknown as string, { after: { count: n, ids }, reason: note });
    return { ok: true, marked: n };
  },
  // the owner's banner: how many wait, by kind (anyone else: nothing)
  fn_review_summary: () => reviewSummary(),
  // the owner's dashboard: the checks of this branch, unless they ran in the last 10 minutes (0037)
  fn_monitors_if_due: ({ p_branch }) => {
    requireRole("owner"); requireBranch(p_branch);
    const last = T("monitor_runs").find((x) => x.branch_id === p_branch)?.last_run_at ?? null;
    if (last && Date.parse(last) > Date.now() - 10 * 60_000) return { ran: false, last_run_at: last, summary: reviewSummary() };
    const found = runMonitors(p_branch);
    return { ran: true, last_run_at: T("monitor_runs").find((x) => x.branch_id === p_branch)!.last_run_at, found, summary: reviewSummary() };
  },
};

const rpcsStay: Record<string, (a: any) => any> = {
  // «تسجيل الوصول»: the conditions, then the rent and the deposit entries, then the arrival — all or nothing
  fn_staff_check_in: ({ p }) => {
    requireCap("checkin"); const r0 = byId("reservations", p?.reservation_id); if (!r0) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r0.branch_id);
    if (r0.status === "checked_in") return { ok: true, duplicate: true, status: r0.status };
    if (p.expected_version != null) checkVersionLenient(r0.version, p.expected_version);
    const addRent = p.rent ? parseHalalas(p.rent.amount_halalas) : 0; const addDep = p.deposit ? parseHalalas(p.deposit.amount_halalas) : 0; const reason = String(p.deposit_reason ?? "").trim() || null;
    const reasons = [...checkinCoreBlockers(r0), ...checkinMoneyBlockers(r0, addRent, addDep, reason)];
    if (reasons.length) return { ok: false, reasons };
    return atomically(() => {
      const vr = addRent ? rpcs.fn_create_voucher({ p: { ...p.rent, reservation_id: r0.id, kind: "receipt" } }) : null;
      const vd = addDep ? rpcs.fn_create_voucher({ p: { ...p.deposit, reservation_id: r0.id, kind: "deposit" } }) : null;
      const r = byId("reservations", r0.id)!; const d = stayDue(r.id);
      if (d.collected < d.first_night) throw new Error("VALIDATION: first_night_unpaid");
      const short = Math.max(d.deposit_required - d.deposit_balance, 0); if (short > 0 && !reason) throw new Error("VALIDATION: deposit_reason");
      const kb = hasKeybox(r.room_id); const before = { status: r.status, access_status: r.access_status };
      Object.assign(r, { status: "checked_in", actual_check_in: nowISO(), checked_in_by: staffId(), checkin_approved_by: staffId(), checkin_approved_at: nowISO(), access_status: kb ? "approved" : "key_handed", keybox_delivered: false,
        deposit_waiver_reason: short > 0 ? reason : null, deposit_waiver_by: short > 0 ? staffId() : null, deposit_waiver_at: short > 0 ? nowISO() : null, version: r.version + 1, updated_at: nowISO() });
      const rm = byId("rooms", r.room_id); if (rm) rm.status = "occupied";
      if (!T("reservation_allocations").some((a) => a.reservation_id === r.id && a.status === "active")) T("reservation_allocations").push({ id: uid(), reservation_id: r.id, room_id: r.room_id, branch_id: r.branch_id, from_date: r.check_in, to_date: r.check_out, status: "active", reason: "auto:checkin", created_by: staffId(), created_at: nowISO(), closed_at: null });
      emit("reservations"); emit("rooms"); emit("reservation_allocations");
      audit(r.branch_id, "reservation.checked_in", "reservation", r.id, { before, after: { status: "checked_in", room_id: r.room_id, key_box: kb, rent_voucher: vr?.number ?? null, deposit_voucher: vd?.number ?? null, deposit_short_halalas: short || null }, ...(short > 0 ? { reason } : {}) });
      return { ok: true, duplicate: false, has_keybox: kb, released_count: null, rent_voucher: vr?.number ?? null, deposit_voucher: vd?.number ?? null, finance: financeOf(r.id) };
    });
  },
  // Shomoos (decision 6): the reference with «every guest registered», then Shomoos's acceptance — who and when for each
  fn_staff_shomoos: ({ p }) => {
    requireCap("shomoos"); if (!["register", "accept"].includes(p?.action)) throw new Error("VALIDATION: action");
    const r = byId("reservations", p.reservation_id); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id);
    if (!["pending_verification", "confirmed", "checked_in"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID");
    const cnt = r.adults + r.companions; const before = { reference: r.gov_registration_ref ?? null, guest_count: r.shomoos_guest_count ?? null, accepted: !!r.shomoos_accepted_at };
    if (p.action === "register") {
      if (r.identity_status !== "verified") throw new Error("IDENTITY_NOT_VERIFIED");
      const ref = String(p.reference ?? "").trim(); if (ref.length < 3 || ref.length > 60) throw new Error("VALIDATION: shomoos_reference");
      if (p.all_guests !== true) throw new Error("VALIDATION: shomoos_all_guests");
      if (r.government_registration && r.gov_registration_ref === ref && r.shomoos_guest_count === cnt) return { ok: true, unchanged: true };
      Object.assign(r, { government_registration: true, gov_registration_ref: ref, gov_registration_by: staffId(), gov_registration_at: nowISO(), shomoos_guest_count: cnt, shomoos_accepted_at: null, shomoos_accepted_by: null, version: r.version + 1, updated_at: nowISO() });
      audit(r.branch_id, "reservation.shomoos_registered", "reservation", r.id, { before, after: { reference: ref, guest_count: cnt, accepted: false } });
    } else {
      if (!r.government_registration || !r.gov_registration_ref) throw new Error("VALIDATION: shomoos_not_registered");
      if ((r.shomoos_guest_count ?? null) !== cnt) throw new Error("VALIDATION: shomoos_guest_count");
      if (r.shomoos_accepted_at) return { ok: true, unchanged: true };
      Object.assign(r, { shomoos_accepted_at: nowISO(), shomoos_accepted_by: staffId(), version: r.version + 1, updated_at: nowISO() });
      audit(r.branch_id, "reservation.shomoos_accepted", "reservation", r.id, { before, after: { reference: r.gov_registration_ref, guest_count: cnt, accepted: true } });
    }
    emit("reservations"); return { ok: true, unchanged: false };
  },
  // check-out (decision 8): nothing owed, for anyone; no override
  fn_staff_check_out: ({ p }) => {
    requireCap("checkout"); const r = byId("reservations", p?.reservation_id); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id);
    if (["checked_out", "closed"].includes(r.status)) return { ok: true, duplicate: true, status: r.status };
    if (r.status !== "checked_in") throw new Error("NOT_CHECKED_IN");
    if (p.expected_version != null) checkVersionLenient(r.version, p.expected_version);
    const f = recompute(r.id)!;
    if (f.balance_due > 0) return { ok: false, balance_due: f.balance_due, reasons: [`على الحجز مبلغ مستحق ${sarText(f.balance_due)}. يُصفَّر بسند قبض، أو بالخصم من التأمين بسبب، أو بتسوية سعر من المالك أو المدير بسبب.`] };
    const at = nowISO();
    Object.assign(r, { status: "checked_out", actual_check_out: at, checked_out_by: staffId(), version: r.version + 1, updated_at: at });
    releaseAllocations(r.id, "close", at);
    if (r.room_id) createCleaningTask(r.branch_id, r.room_id, r.id, "تنظيف بعد المغادرة");
    emit("reservations");
    audit(r.branch_id, "reservation.checked_out", "reservation", r.id, { before: { status: "checked_in" }, after: { status: "checked_out", deposit_balance_halalas: f.deposit_balance, credit_halalas: f.credit } });
    const invoice = autoInvoice(r.id, "checkout");
    const st = syncClosed(r.id);
    return { ok: true, duplicate: false, status: st, deposit_to_settle_halalas: f.deposit_balance, credit_halalas: f.credit, invoice, missing: closureMissing(r.id) };
  },
  // «فحص المغادرة» (decision 5): sound, or notes with a suggested deduction
  fn_staff_record_inspection: ({ p }) => {
    requireCap("inspection"); if (!["ok", "notes"].includes(p?.result)) throw new Error("VALIDATION: inspection_result");
    const notes = String(p.notes ?? "").trim() || null; if (p.result === "notes" && !notes) throw new Error("VALIDATION: inspection_notes");
    const sug = p.result === "notes" && p.suggested_deduction_halalas != null && String(p.suggested_deduction_halalas) !== "" && String(p.suggested_deduction_halalas) !== "0" ? parseHalalas(p.suggested_deduction_halalas) : 0;
    const r = byId("reservations", p.reservation_id); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id);
    if (!(r.status === "checked_out" || (r.status === "checked_in" && branchToday(r.branch_id) >= r.check_out))) throw new Error("VALIDATION: inspection_not_due");
    for (const i of T("checkout_inspections")) if (i.reservation_id === r.id && i.status === "active") Object.assign(i, { status: "superseded", superseded_at: nowISO(), superseded_by: staffId() });
    const row = { id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: r.id, room_id: r.room_id, result: p.result, notes, suggested_deduction_halalas: sug, status: "active", inspected_by: staffId(), inspected_at: nowISO(), superseded_at: null, superseded_by: null };
    T("checkout_inspections").push(row); emit("checkout_inspections");
    audit(r.branch_id, "reservation.inspected", "reservation", r.id, { after: { result: p.result, suggested_deduction_halalas: sug, room_id: r.room_id } });
    return { ok: true, id: row.id };
  },
  // «رسم ضرر»: a charge with its reason, taken from the deposit as far as it goes (decision 5)
  fn_staff_add_damage: ({ p }) => {
    requireCap("damage.charge"); const amount = parseHalalas(p?.amount_halalas); const reason = String(p.reason ?? "").trim(); if (!reason) throw new Error("VALIDATION: reason"); nonEmpty(p.idempotency_key, "idempotency_key");
    const r = byId("reservations", p.reservation_id); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id);
    const ex = T("reservation_charges").find((c) => c.reservation_id === r.id && c.idempotency_key === p.idempotency_key); if (ex) return { ok: true, duplicate: true, charge_id: ex.id, finance: financeOf(r.id) };
    if (!["checked_in", "checked_out", "closed"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID");
    return atomically(() => {
      const descr = String(p.description ?? "").trim() || null;
      const cid = addCharge(r.id, "penalty", "رسم ضرر — " + (descr ?? reason), 1, amount, false, reason); Object.assign(byId("reservation_charges", cid)!, { purpose: "damage", idempotency_key: p.idempotency_key });
      recompute(r.id); let applied = 0; let v: any = null;
      if (p.apply_deposit !== false) { const f = financeOf(r.id); applied = Math.min(amount, f.deposit_balance, f.balance_due); if (applied > 0) v = rpcs.fn_refund({ p: { reservation_id: r.id, kind: "deposit_apply", amount_halalas: applied, reason: "رسم ضرر: " + reason, idempotency_key: p.idempotency_key + ":apply" } }); }
      r.version++; recompute(r.id);
      const invoice: string | null = ["checked_out", "closed"].includes(r.status) && financeOf(r.id).deposit_balance === 0 ? v?.invoice ?? autoInvoice(r.id, "deposit_settled") : null;
      audit(r.branch_id, "reservation.damage_charged", "reservation", r.id, { after: { amount_halalas: amount, description: descr, from_deposit_halalas: applied, voucher: v?.number ?? null, invoice }, reason });
      return { ok: true, duplicate: false, charge_id: cid, from_deposit_halalas: applied, invoice, finance: financeOf(r.id) };
    });
  },
  // an overdue night: the reason that lets the stay go on (decision 3)
  fn_staff_payment_exception: ({ p }) => {
    requireCap("checkin"); const reason = String(p?.reason ?? "").trim(); if (!reason) throw new Error("VALIDATION: reason");
    const r = byId("reservations", p.reservation_id); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id);
    const d = stayDue(r.id); if (!d.overdue) throw new Error("VALIDATION: not_overdue");
    T("stay_payment_exceptions").push({ id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: r.id, through_night: d.overdue_through, shortfall_halalas: d.overdue_amount, reason, created_by: staffId(), created_at: nowISO() }); emit("stay_payment_exceptions");
    audit(r.branch_id, "reservation.payment_exception", "reservation", r.id, { after: { through_night: d.overdue_through, overdue_halalas: d.overdue_amount }, reason });
    return { ok: true, through_night: d.overdue_through };
  },
  // corrections with time windows (decisions 10, 46): the owner or a manager, with a reason; each one goes to the owner's review list
  fn_staff_undo_check_in: ({ p }) => {
    requireCap("checkin.undo"); const reason = String(p?.reason ?? "").trim(); if (!reason) throw new Error("VALIDATION: reason");
    const r = byId("reservations", p.reservation_id); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id);
    if (r.status !== "checked_in") throw new Error("RESERVATION_STATUS_INVALID");
    if (!r.actual_check_in || Date.now() - Date.parse(r.actual_check_in) > 30 * 60_000) throw new Error("CORRECTION_WINDOW_PASSED: an arrival is undone within 30 minutes");
    if (p.expected_version != null) checkVersionLenient(r.version, p.expected_version);
    const shown = ["delivered", "acknowledged"].includes(r.access_status); const was = r.actual_check_in;
    Object.assign(r, { status: "confirmed", actual_check_in: null, checked_in_by: null, checkin_approved_by: null, checkin_approved_at: null, access_status: "locked", keybox_delivered: false, version: r.version + 1, updated_at: nowISO() });
    const rm = byId("rooms", r.room_id); if (rm && rm.status === "occupied") rm.status = "reserved";
    if (shown) { const kb = T("keyboxes").find((k) => k.room_id === r.room_id && k.last_reservation_id === r.id); if (kb) Object.assign(kb, { code_status: "needs_change", field_tested: false, needs_change_since: nowISO() }); }
    emit("reservations"); emit("rooms"); emit("keyboxes");
    addReview(r.branch_id, "check_in_undone", "reservation", r.id, r.id, `تراجع عن تسجيل وصول ${r.internal_ref}`, reason, { checked_in_at: was, code_was_given: shown });
    audit(r.branch_id, "reservation.check_in_undone", "reservation", r.id, { before: { status: "checked_in", actual_check_in: was }, after: { status: "confirmed", code_needs_change: shown }, reason });
    return { ok: true, code_needs_change: shown };
  },
  fn_staff_reopen_stay: ({ p }) => {
    requireCap("stay.reopen"); const reason = String(p?.reason ?? "").trim(); if (!reason) throw new Error("VALIDATION: reason");
    const r = byId("reservations", p.reservation_id); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id);
    if (!["checked_out", "closed"].includes(r.status)) throw new Error("RESERVATION_STATUS_INVALID");
    if (!r.actual_check_out || Date.now() - Date.parse(r.actual_check_out) > 2 * 3_600_000) throw new Error("CORRECTION_WINDOW_PASSED: a departure is reopened within 2 hours");
    if (p.expected_version != null) checkVersionLenient(r.version, p.expected_version);
    const rm = byId("rooms", r.room_id);
    if (rm) { if (!rm.is_active || rm.archived_at || ["blocked", "out_of_service"].includes(rm.status)) throw new Error("ROOM_NOT_AVAILABLE"); if (T("reservations").some((o) => o.room_id === rm.id && o.status === "checked_in" && o.id !== r.id)) throw new Error("ALLOCATION_CONFLICT: another guest is in the unit"); }
    const back = T("reservation_allocations").filter((a) => a.reservation_id === r.id && a.status === "closed" && a.closed_at === r.actual_check_out);
    for (const a of back) if (T("reservation_allocations").some((o) => o.id !== a.id && o.room_id === a.room_id && o.status === "active" && overlaps(o.from_date, o.to_date, a.from_date, a.to_date))) throw new Error("ALLOCATION_CONFLICT: the unit is booked for someone else in this stay's period");
    for (const a of back) Object.assign(a, { status: "active", closed_at: null });
    let kept = false; const kb = rm ? T("keyboxes").find((k) => k.room_id === rm.id) : undefined;
    if (rm) {
      rm.status = "occupied";
      for (const t of T("housekeeping_tasks")) if (t.reservation_id === r.id && t.room_id === rm.id && ["pending", "in_progress"].includes(t.status) && t.description === "تنظيف بعد المغادرة") Object.assign(t, { status: "cancelled", cancelled_at: nowISO(), cancel_reason: "أُعيد فتح الإقامة: " + reason, version: t.version + 1 });
      if (rm.cleanliness === "in_progress") rm.cleanliness = "dirty";
      if (kb && kb.code_status === "needs_change" && kb.last_reservation_id === r.id) { Object.assign(kb, { code_status: "active", field_tested: true, needs_change_since: null }); kept = true; }
    }
    const was = { status: r.status, actual_check_out: r.actual_check_out }; const access = !kb ? "key_handed" : kept ? r.access_status : "approved";
    Object.assign(r, { status: "checked_in", actual_check_out: null, checked_out_by: null, closed_at: null, access_status: access, keybox_delivered: kept ? r.keybox_delivered : false, version: r.version + 1, updated_at: nowISO() });
    for (const i of T("checkout_inspections")) if (i.reservation_id === r.id && i.status === "active") Object.assign(i, { status: "superseded", superseded_at: nowISO(), superseded_by: staffId() });
    recompute(r.id); emit("reservation_allocations"); emit("rooms"); emit("housekeeping_tasks"); emit("keyboxes"); emit("checkout_inspections");
    addReview(r.branch_id, "stay_reopened", "reservation", r.id, r.id, `إعادة فتح إقامة ${r.internal_ref}`, reason, { checked_out_at: was.actual_check_out, was_closed: was.status === "closed", code_kept: kept });
    audit(r.branch_id, "reservation.stay_reopened", "reservation", r.id, { before: was, after: { status: "checked_in", access_status: access }, reason });
    return { ok: true, access_status: access };
  },
  fn_staff_undo_cancel: ({ p }) => {
    requireCap("res.undo_cancel"); const reason = String(p?.reason ?? "").trim(); if (!reason) throw new Error("VALIDATION: reason");
    const r = byId("reservations", p.reservation_id); if (!r) throw new Error("RESERVATION_NOT_FOUND"); requireBranch(r.branch_id);
    if (r.status !== "cancelled") throw new Error("RESERVATION_STATUS_INVALID");
    if (!r.cancelled_at || Date.now() - Date.parse(r.cancelled_at) > 3_600_000) throw new Error("CORRECTION_WINDOW_PASSED: a cancellation is undone within 1 hour");
    if (p.expected_version != null) checkVersionLenient(r.version, p.expected_version);
    const today = branchToday(r.branch_id); if (r.check_out <= today) throw new Error("VALIDATION: stay_ended");
    if (byId("room_categories", r.room_category_id)?.archived_at) throw new Error("CATEGORY_ARCHIVED: this unit type is archived");
    const back = T("reservation_allocations").filter((a) => a.reservation_id === r.id && a.status === "cancelled" && a.closed_at === r.cancelled_at);
    for (const a of back) {
      const rm = byId("rooms", a.room_id); if (!rm || !rm.is_active || rm.archived_at || ["blocked", "out_of_service", "maintenance"].includes(rm.status)) throw new Error("ROOM_NOT_AVAILABLE");
      if (T("reservation_allocations").some((o) => o.id !== a.id && o.room_id === a.room_id && o.status === "active" && overlaps(o.from_date, o.to_date, a.from_date, a.to_date))) throw new Error("ALLOCATION_CONFLICT: the unit was booked for someone else after the cancellation");
    }
    for (const a of back) { Object.assign(a, { status: "active", closed_at: null }); const rm = byId("rooms", a.room_id)!; if (a.from_date <= today && today < a.to_date && ["available", "ready", "cleaning"].includes(rm.status)) rm.status = "reserved"; }
    const was = { status: "cancelled", cancel_reason: r.cancel_reason, cancelled_at: r.cancelled_at };
    const backTo = ["pending_verification", "confirmed"].includes(r.status_before_cancel) ? r.status_before_cancel : "confirmed";
    if (r.cancel_reference && r.cancel_source === "platform") for (const e of T("integration_events")) if (e.source?.startsWith("platform:") && e.external_event_id === r.cancel_reference && e.state === "processed") Object.assign(e, { state: "reverted", result: { ...(e.result ?? {}), reverted_at: nowISO(), reverted_reservation: r.id } });
    Object.assign(r, { status: backTo, cancelled_at: null, cancel_reason: null, cancel_source: null, status_before_cancel: null, cancel_reference: null, version: r.version + 1, updated_at: nowISO() });
    recompute(r.id); emit("reservation_allocations"); emit("rooms");
    addReview(r.branch_id, "cancel_undone", "reservation", r.id, r.id, `تراجع عن إلغاء ${r.internal_ref}`, reason, { cancelled_at: was.cancelled_at, cancel_reason: was.cancel_reason, allocations_restored: back.length });
    audit(r.branch_id, "reservation.cancel_undone", "reservation", r.id, { before: was, after: { status: backTo, allocations_restored: back.length }, reason });
    return { ok: true, status: backTo };
  },
  // the stay page: everything the arrival, the code, the nights, the departure and the corrections need (fn_stay_status)
  fn_stay_status: ({ p_reservation }) => {
    const r = byId("reservations", p_reservation); if (!r || !myBranches().includes(r.branch_id) || !hasRole("owner", "manager", "supervisor", "finance", "housekeeping")) return null;
    const money = seesMoney(); const mgr = hasRole("owner", "manager");
    const kb = r.room_id ? T("keyboxes").find((k) => k.room_id === r.room_id) : undefined; const d = money ? stayDue(r.id) : null;
    const insp = T("checkout_inspections").filter((i) => i.reservation_id === r.id && i.status === "active").sort((a, b) => (a.inspected_at < b.inspected_at ? 1 : -1))[0];
    const exc = T("stay_payment_exceptions").filter((e) => e.reservation_id === r.id).sort((a, b) => (a.created_at < b.created_at ? 1 : -1))[0];
    const stayed = !!r.actual_check_in || ["checked_in", "checked_out", "closed"].includes(r.status);
    const refundBlocker = !stayed ? null : !["checked_out", "closed"].includes(r.status) ? "يُرد التأمين بعد تسجيل المغادرة" : !insp ? "سجّل فحص المغادرة أولًا" : null;
    const now = Date.now(); const within = (iso: string | null | undefined, ms: number) => (iso && now - Date.parse(iso) <= ms ? new Date(Date.parse(iso) + ms).toISOString() : null);
    const checkin = ["draft", "pending_verification", "confirmed"].includes(r.status) ? { blockers: checkinCoreBlockers(r), ...(money && d ? { money_blockers: checkinMoneyBlockers(r), first_night: d.first_night, collected: d.collected, first_night_short: Math.max(d.first_night - d.collected, 0), deposit_required: d.deposit_required, deposit_balance: d.deposit_balance, deposit_short: Math.max(d.deposit_required - d.deposit_balance, 0) } : {}) } : null;
    return {
      status: r.status, version: r.version, access_status: r.access_status, room_number: roomNo(r.room_id), has_keybox: !!kb,
      keybox_state: !kb ? "none" : !kb.code_plain ? "unset" : kb.code_status !== "active" ? "needs_change" : !kb.field_tested ? "untested" : "ready",
      departure_time: departureTime(r), late_checkout_until: r.late_checkout_until ? String(r.late_checkout_until).slice(0, 5) : null,
      late_departure: r.status === "checked_in" && now > localMs(r.check_out, departureTime(r)),
      checked_in_at: r.actual_check_in, checked_in_by: staffName(r.checked_in_by), checked_out_at: r.actual_check_out, checked_out_by: staffName(r.checked_out_by),
      checkin, code: r.status === "checked_in" ? { blockers: codeBlockers(r), delivered: ["delivered", "acknowledged"].includes(r.access_status) } : null,
      due: d, overdue_blocked: money && r.status === "checked_in" ? overdueBlocked(r.id) : null,
      payment_exception: money && exc ? { reason: exc.reason, through_night: exc.through_night, by: staffName(exc.created_by), at: exc.created_at } : null,
      deposit_waiver: money && r.deposit_waiver_reason ? { reason: r.deposit_waiver_reason, at: r.deposit_waiver_at, by: staffName(r.deposit_waiver_by) } : null,
      shomoos: { registered: !!r.government_registration && !!r.gov_registration_ref, reference: money ? r.gov_registration_ref ?? null : null, registered_at: r.gov_registration_at ?? null, registered_by: staffName(r.gov_registration_by), guest_count: r.shomoos_guest_count ?? null, guests_now: r.adults + r.companions, accepted_at: r.shomoos_accepted_at ?? null, accepted_by: staffName(r.shomoos_accepted_by) },
      inspection: insp ? { result: insp.result, notes: insp.notes, suggested: money ? insp.suggested_deduction_halalas : null, by: staffName(insp.inspected_by), at: insp.inspected_at } : null,
      inspection_due: r.status === "checked_out" || (r.status === "checked_in" && branchToday(r.branch_id) >= r.check_out),
      deposit_refund_blocker: money ? refundBlocker : null,
      corrections: { allowed: mgr, undo_check_in_until: r.status === "checked_in" ? within(r.actual_check_in, 30 * 60_000) : null, reopen_until: ["checked_out", "closed"].includes(r.status) ? within(r.actual_check_out, 2 * 3_600_000) : null, undo_cancel_until: r.status === "cancelled" ? within(r.cancelled_at, 3_600_000) : null },
      closure: ["checked_out", "closed"].includes(r.status) ? { closed: r.status === "closed", closed_at: r.closed_at ?? null, missing: money ? closureMissing(r.id) : [] } : null,
    };
  },
  // the supervisor's daily follow-up: overdue nights, departures not closed, guests past their departure time
  fn_stay_followups: ({ p_branch }) => {
    requireMoney(); requireBranch(p_branch); const now = Date.now();
    const res = T("reservations").filter((r) => r.branch_id === p_branch);
    const overdue = res.filter((r) => r.status === "checked_in").map((r) => ({ r, d: stayDue(r.id) })).filter((x) => x.d.overdue)
      .map(({ r, d }) => ({ id: r.id, internal_ref: r.internal_ref, room_number: roomNo(r.room_id), guest: guestName(r.id), overdue_amount: d.overdue_amount, overdue_since: d.overdue_since, check_out: r.check_out, excused: !overdueBlocked(r.id) }))
      .sort((a, b) => String(a.overdue_since).localeCompare(String(b.overdue_since)));
    const departed_open = res.filter((r) => r.status === "checked_out").map((r) => ({ id: r.id, internal_ref: r.internal_ref, room_number: roomNo(r.room_id), guest: guestName(r.id), checked_out_at: r.actual_check_out, missing: closureMissing(r.id), inspected: T("checkout_inspections").some((i) => i.reservation_id === r.id && i.status === "active"), deposit_balance: financeOf(r.id).deposit_balance }))
      .sort((a, b) => String(a.checked_out_at).localeCompare(String(b.checked_out_at)));
    const late_departures = res.filter((r) => r.status === "checked_in" && now > localMs(r.check_out, departureTime(r))).map((r) => ({ id: r.id, internal_ref: r.internal_ref, room_number: roomNo(r.room_id), guest: guestName(r.id), check_out: r.check_out, departure_time: departureTime(r) }))
      .sort((a, b) => (a.check_out < b.check_out ? -1 : 1));
    return { generated_at: nowISO(), overdue, departed_open, late_departures };
  },
  // what each employee received and paid back on one branch day, by method; a supervisor sees their own (decision 5)
  fn_staff_day_summary: ({ p_branch, p_date }) => {
    requireMoney(); requireBranch(p_branch); if (!p_date) throw new Error("VALIDATION: business_date");
    const everyone = hasRole("owner", "manager", "finance"); const groups = new Map<string, Row>();
    for (const v of T("financial_vouchers").filter((x) => x.branch_id === p_branch && x.status === "approved" && dayOf(x.occurred_at) === p_date && (everyone || x.created_by === staffId()))) {
      const method = v.kind === "deposit_apply" ? null : v.method; const k = `${v.created_by}|${v.kind}|${method}`;
      const g = groups.get(k) ?? { staff_id: v.created_by, staff_name: staffName(v.created_by) ?? "—", kind: v.kind, method, count: 0, total: 0 }; g.count++; g.total += v.amount_halalas; groups.set(k, g);
    }
    return { date: p_date, everyone, rows: [...groups.values()].sort((a, b) => String(a.staff_name).localeCompare(String(b.staff_name)) || String(a.kind).localeCompare(String(b.kind)) || String(a.method ?? "").localeCompare(String(b.method ?? ""))) };
  },
};
Object.assign(rpcs, rpcsMore);
Object.assign(rpcs, rpcsStay);
Object.assign(rpcs, rpcsInvoices);
/** what the phase 6 module (phase6.ts) needs from the demo's core; registered last, so it supersedes the older emulations it replaces */
const phase6Ctx = {
  T, byId, me, myBranches, hasRole, requireRole, requireBranch, staffId, audit, emit, ...perm,
  staffName: (id: string | null | undefined) => staffName(id),
  branchToday: (b?: string) => branchToday(b),
  roomNo: (roomId: string | null) => roomNo(roomId),
  guestName: (resId: string) => guestName(resId),
  isMember: (sid: string, branch: string) => staffInBranch(sid, branch),
  banMatches: (resId: string): Row[] => rpcs.fn_reservation_ban_matches({ p_reservation: resId }),
};
Object.assign(rpcs, phase6Rpcs(phase6Ctx));
// the permissions matrix (0043): the owner's editor and «ما يحق لي»
Object.assign(rpcs, permissionRpcs({ T, me, staffId, emit, atomically: <V,>(fn: () => V): V => atomically(fn),
  audit: (branch, action, entity, entityId, details) => audit(branch, action, entity, entityId as string, details) }, perm));

// ---- data purge (demo): same rules as fn_purge_run in 0022 ----
const purgeRequests = new Map<string, { branch: string | null; from: string; to: string; cats: string[]; staff: string | null; expires: number; used: boolean }>();
const purgeHistory: Row[] = [];
let lastSignInAt = Date.now();
const PURGE_KINDS = ["conversations", "reservations", "finance", "guests", "operations", "logs", "audit"];
function purgeValidate(branch: string | null, from: string, to: string, cats: string[]): string[] {
  requireCap("security");
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
    // the period's terminal settlements, and its platform payouts none of whose payments remain (0031)
    c.pos_settlements = drop("pos_settlements", (s) => inBranch(s.branch_id) && s.business_date >= from && s.business_date <= to);
    c.platform_payouts = drop("platform_payouts", (p) => inBranch(p.branch_id) && p.received_on >= from && p.received_on <= to && !T("financial_vouchers").some((v) => v.payout_id === p.id));
  }
  if (has("reservations")) {
    for (const t of ["reservation_guests", "reservation_charges", "reservation_allocations", "reservation_nights", "registration_sessions", "access_release_requests", "access_delivery_events", "payment_transactions", "checkout_inspections", "stay_payment_exceptions", "review_items"]) drop(t, (x) => res.includes(x.reservation_id));
    c.reservations = drop("reservations", (r) => res.includes(r.id));
  }
  if (has("guests")) c.guest_profiles = drop("guest_profiles", (g) => !T("reservation_guests").some((x) => x.guest_profile_id === g.id) && (!branch && inRange(g.created_at)));
  if (has("logs")) { c.notifications = drop("notifications", (n) => inBranch(n.branch_id) && inRange(n.created_at)); if (!branch) c.integration_events = drop("integration_events", (e) => inRange(e.created_at)); }
  if (has("audit")) c.audit_events = drop("audit_events", (a) => inBranch(a.branch_id) && inRange(a.created_at));
  return c;
}

const TABLE_OF: Record<string, string> = { branch: "branches", block: "blocks", floor: "floors", room_category: "room_categories", room: "rooms", facility: "facilities", task_type: "task_types", service: "service_definitions" };
function upsertDef(table: string, entity: string, p: Row, fields: string[], validate: (x: Row) => void, uniqueOn: string[], scopeCol = "branch_id") {
  requireCap("definitions"); validate(p); const rows = T(table);
  if (!p.id) { requireBranch(p.branch_id); const scopeVal = scopeCol === "block_id" ? p.block_id : p.branch_id; for (const u of uniqueOn) if (rows.some((x) => x[scopeCol] === scopeVal && String(x[u]).trim() === String(p[u]).trim())) throw new Error("DUPLICATE_NAME"); const r: Row = { id: uid(), organization_id: ORG, branch_id: p.branch_id, is_active: true, archived_at: null, archived_by: null, archive_reason: null, version: 1, sort_order: 0, created_by: staffId(), created_at: nowISO(), updated_at: nowISO() }; for (const f of fields) if (p[f] !== undefined) r[f] = p[f]; if (table === "service_definitions") Object.assign(r, { billing_unit: r.billing_unit ?? "once", price_halalas: r.price_halalas ?? 0, is_free: !!r.is_free, taxable: r.taxable ?? true, task_type_id: r.task_type_id ?? null }); if (table === "room_categories") Object.assign(r, { base_capacity: r.base_capacity ?? 2, max_capacity: r.max_capacity ?? 4, base_price_halalas: r.base_price_halalas ?? 0, amenities: r.amenities ?? [], is_public: r.is_public ?? true, images: [] }); if (table === "facilities") r.images = r.images ?? []; rows.push(r); emit(table); audit(r.branch_id, entity + ".created", entity, r.id, { after: r }); return { ok: true, id: r.id, version: 1 }; }
  const r = byId(table, p.id); if (!r) throw new Error("NOT_FOUND"); requireBranch(r.branch_id); checkVersion(r.version, p.version); const before = { ...r }; const scopeVal = r[scopeCol];
  for (const u of uniqueOn) if (p[u] !== undefined && rows.some((x) => x.id !== r.id && x[scopeCol] === scopeVal && String(x[u]).trim() === String(p[u]).trim())) throw new Error("DUPLICATE_NAME");
  for (const f of fields) if (p[f] !== undefined) r[f] = p[f]; r.version++; r.updated_at = nowISO(); emit(table); audit(r.branch_id, entity + ".updated", entity, r.id, { before, after: r }); return { ok: true, id: r.id, version: r.version };
}
function deps(entity: string, id: string): Record<string, number> {
  const n = (t: string, f: (r: Row) => boolean) => T(t).filter(f).length;
  switch (entity) {
    case "branch": return { rooms: n("rooms", (r) => r.branch_id === id), room_categories: n("room_categories", (r) => r.branch_id === id), reservations: n("reservations", (r) => r.branch_id === id), staff: n("branch_memberships", (r) => r.branch_id === id), blocks: n("blocks", (r) => r.branch_id === id), facilities: n("facilities", (r) => r.branch_id === id), vouchers: n("financial_vouchers", (r) => r.branch_id === id) , pos_settlements: n("pos_settlements", (r) => r.branch_id === id), platform_payouts: n("platform_payouts", (r) => r.branch_id === id), rate_calendar: n("rate_calendar", (r) => r.branch_id === id && (r.price_halalas != null || r.platform_price_halalas != null)) };
    case "block": return { floors: n("floors", (r) => r.block_id === id), rooms: n("rooms", (r) => r.block_id === id), facilities: n("facilities", (r) => r.block_id === id) };
    case "floor": return { rooms: n("rooms", (r) => r.floor_id === id), facilities: n("facilities", (r) => r.floor_id === id) };
    case "room_category": return { rooms: n("rooms", (r) => r.category_id === id), reservations: n("reservations", (r) => r.room_category_id === id), rate_calendar: n("rate_calendar", (r) => r.category_id === id && (r.price_halalas != null || r.platform_price_halalas != null)) };
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
  // a type with open stays is not archived, even before a unit is allocated to them (0033)
  if (entity === "room_category") return T("rooms").filter((r) => r.category_id === id && !r.archived_at).length + T("reservations").filter((r) => r.room_category_id === id && ["confirmed", "checked_in", "pending_verification"].includes(r.status) && r.check_out > today).length;
  if (entity === "branch") { if (T("branches").filter((b) => !b.archived_at && b.is_active).length <= 1) throw new Error("LAST_ACTIVE_BRANCH"); return T("reservations").filter((r) => r.branch_id === id && ["confirmed", "checked_in", "pending_verification"].includes(r.status) && r.check_out > today).length; }
  return 0;
}
/** fn_is_member (0040): an active owner of the organisation, or an active member whose membership was not retired */
function staffInBranch(sid: string, branch: string) { const s = byId("staff_profiles", sid); return !!s && s.is_active && ((s.role === "owner" && s.organization_id === byId("branches", branch)?.organization_id) || T("branch_memberships").some((m) => m.staff_id === sid && m.branch_id === branch && !m.removed_at)); }
// ---------------------------------------------------------------------------
// rates (0030): the price calendar, weekly and monthly prices, the nights of a stay, the supervisor's discount limits
// ---------------------------------------------------------------------------
const nightsBetween = (ci: string, co: string) => { const out: string[] = []; for (let d = ci; d < co; d = addDays(d, 1)) out.push(d); return out; };
type NightPrice = { night: string; price: number; basis: string };
type Run = { from: string; to: string; nights: number; price: number; basis: string };
/** The price of each night: a manual price; 30+ nights → monthly, 7+ → weekly (spread evenly, remainder on the last night);
 *  else the calendar's price (its platform row for a platform booking of a type priced by channel), else the base price. */
function stayPrices(categoryId: string, ci: string, co: string, platform: boolean, override: number | null, periods = true): NightPrice[] {
  const c = byId("room_categories", categoryId); if (!c) throw new Error("BRANCH_MISMATCH: category");
  const days = nightsBetween(ci, co); const n = days.length; if (n <= 0) throw new Error("VALIDATION: dates");
  if (override != null) { if (override < 0) throw new Error("VALIDATION: amount"); return days.map((night) => ({ night, price: override, basis: "manual" })); }
  const period: [number, number, string] | null = periods && n >= 30 && c.monthly_price_halalas ? [30, c.monthly_price_halalas, "monthly"] : periods && n >= 7 && c.weekly_price_halalas ? [7, c.weekly_price_halalas, "weekly"] : null;
  if (period) { const total = roundHalfUp((period[1] * n) / period[0]); const each = Math.floor(total / n); return days.map((night, i) => ({ night, price: i === n - 1 ? total - each * (n - 1) : each, basis: period[2] })); }
  return days.map((night) => {
    const rc = T("rate_calendar").find((x) => x.category_id === c.id && x.night === night);
    const pp = platform && c.price_mode === "by_channel" ? rc?.platform_price_halalas ?? null : null;
    return pp != null ? { night, price: pp, basis: "platform" } : rc?.price_halalas != null ? { night, price: rc.price_halalas, basis: "calendar" } : { night, price: c.base_price_halalas, basis: "base" };
  });
}
function stayRuns(prices: NightPrice[]): Run[] {
  const runs: Run[] = [];
  for (const x of prices) { const cur = runs[runs.length - 1]; if (cur && cur.price === x.price && cur.basis === x.basis && cur.to === x.night) { cur.to = addDays(x.night, 1); cur.nights++; } else runs.push({ from: x.night, to: addDays(x.night, 1), nights: 1, price: x.price, basis: x.basis }); }
  return runs;
}
function nightRow(r: Row, night: string, price: number, basis: string): Row { return { id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: r.id, night, price_halalas: price, basis, status: "active", removed_at: null, removed_by: null, removed_reason: null, created_by: staffId(), created_at: nowISO() }; }
/** fn_cancel_voucher without its capability check (0048: the platform correction cancels the deferred receipt). */
function cancelVoucherCore(p_voucher: string, p_reason: string) {
  const v = byId("financial_vouchers", p_voucher); if (!v) throw new Error("NOT_FOUND"); requireBranch(v.branch_id); if (v.status !== "approved") throw new Error("VOUCHER_STATUS_INVALID");
    if (v.payout_id) throw new Error("VOUCHER_IN_PAYOUT");   // a voucher in a platform payout: the payout is cancelled first (0036)
    v.status = "cancelled"; const f = financeOf(v.reservation_id); if (f.deposit_balance < 0 || f.received - f.refunded < 0) { v.status = "approved"; throw new Error("CANCEL_WOULD_GO_NEGATIVE"); }
    Object.assign(v, { cancelled_at: nowISO(), cancelled_by: staffId(), cancel_reason: p_reason }); emit("financial_vouchers"); recompute(v.reservation_id);
    addReview(v.branch_id, "voucher_cancelled", "voucher", v.id, v.reservation_id, `إلغاء السند ${v.number}`, p_reason, { number: v.number, kind: v.kind, amount_halalas: v.amount_halalas, method: v.method });
    audit(v.branch_id, "voucher.cancelled", "voucher", v.id, { before: { status: "approved" }, after: { status: "cancelled", number: v.number, amount_halalas: v.amount_halalas }, reason: p_reason }); return { ok: true, finance: f, provider_refund_note: "إلغاء السند محلي؛ لا يعني أن مزود الدفع ردّ المبلغ." }; }
/** Books the runs' nights on a stay and writes one rent line per run (tax per line). */
function bookNights(resId: string, runs: Run[], label: string, reason: string | null) {
  const r = byId("reservations", resId)!; let total = 0;
  for (const x of runs) {
    for (const night of nightsBetween(x.from, x.to)) T("reservation_nights").push(nightRow(r, night, x.price, x.basis));
    addCharge(r.id, "rent", `${label} ${x.nights} ليلة × ${(x.price / 100).toFixed(2)} ر.س${x.basis === "weekly" ? " (السعر الأسبوعي)" : x.basis === "monthly" ? " (السعر الشهري)" : x.basis === "platform" ? " (سعر المنصات)" : ""}`, x.nights, x.price, true, reason, null, x.from, x.to);
    total += x.nights * x.price;
  }
  emit("reservation_nights"); return total;
}
/** A stay without nights (the seed, or made before 0030) gets them from its rent line, else its nightly rate. */
function ensureNights(resId: string) {
  const r = byId("reservations", resId); if (!r || T("reservation_nights").some((x) => x.reservation_id === r.id)) return;
  const days = nightsBetween(r.check_in, r.check_out); const rent = T("reservation_charges").filter((c) => c.reservation_id === r.id && c.kind === "rent");
  const price = rent.length === 1 && Number(rent[0].quantity) === days.length ? rent[0].unit_price_halalas : r.nightly_rate_halalas ?? 0;
  for (const night of days) T("reservation_nights").push({ ...nightRow(r, night, price, "legacy"), created_at: r.created_at ?? nowISO(), created_by: null });
  emit("reservation_nights");
}
/** Decision 9: the supervisor discounts before arrival within the branch's percentage and never under the type's minimum. */
function checkDiscount(categoryId: string, branchId: string, nights: number, rent: number, existing: number, add: number, afterArrival: boolean) {
  if (!(add > 0)) return;
  if (existing + add > rent) throw new Error("VALIDATION: discount_exceeds_rent");
  if (can("disc.after")) return;
  if (!can("disc.before")) throw new Error("FORBIDDEN: discount");
  if (afterArrival) throw new Error("FORBIDDEN: post-arrival discount");
  const bp = byId("branches", branchId)?.supervisor_max_discount_bp ?? 0;
  if (existing + add > Math.floor((rent * bp) / 10000)) throw new Error("VALIDATION: discount_percent");
  const mn = byId("room_categories", categoryId)?.min_nightly_halalas;
  if (mn != null && rent - existing - add < mn * nights) throw new Error("VALIDATION: discount_minimum");
}
const discountsOf = (resId: string) => T("reservation_charges").filter((c) => c.reservation_id === resId && c.kind === "discount").reduce((s, c) => s + roundHalfUp(Math.abs(Number(c.quantity) * c.unit_price_halalas)), 0);
/** The quote of a stay, exactly as the reservation would store it, and how much discount the caller may give (fn_quote_stay). */
function quoteStay(p: Row) {
  requireBranch(p.branch_id); const ci = p.check_in, co = p.check_out; if (!ci || !co || co <= ci) throw new Error("VALIDATION: dates");
  const c = byId("room_categories", p.category_id); if (!c || c.branch_id !== p.branch_id) throw new Error("BRANCH_MISMATCH: category");
  const b = byId("branches", p.branch_id)!; const src = p.source_id ? byId("booking_sources", p.source_id) : null; const platform = !!src && src.kind !== "direct";
  const ovr = p.nightly_rate_halalas == null || p.nightly_rate_halalas === "" ? null : Number(p.nightly_rate_halalas); const disc = Number(p.discount_halalas ?? 0);
  if (disc < 0) throw new Error("VALIDATION: amount");
  const periods = p.periods !== false; const prices = stayPrices(c.id, ci, co, platform, ovr, periods); const n = prices.length; if (n > 366) throw new Error("VALIDATION: dates"); const runs = stayRuns(prices);
  let rentGross = 0, rentNet = 0, tax = 0;
  for (const x of runs) { const g = x.nights * x.price; rentGross += g; const t = applyTax(p.branch_id, g, true); rentNet += t.net; tax += t.tax; }
  if (disc > rentGross) throw new Error("VALIDATION: discount_exceeds_rent");
  const d = disc > 0 ? applyTax(p.branch_id, -disc, true) : { net: 0, tax: 0 };
  const computed = stayPrices(c.id, ci, co, platform, null).reduce((s, x) => s + x.price, 0);
  const minTotal = c.min_nightly_halalas != null ? c.min_nightly_halalas * n : 0;
  const supMax = Math.max(0, Math.min(Math.floor((rentGross * (b.supervisor_max_discount_bp ?? 0)) / 10000), rentGross - minTotal));
  const myMax = can("disc.after") ? rentGross : can("disc.before") ? supMax : 0;
  return { nights: n, runs, channel: platform ? "platform" : "system", basis: ovr != null ? "manual" : !periods ? "daily" : n >= 30 && c.monthly_price_halalas ? "monthly" : n >= 7 && c.weekly_price_halalas ? "weekly" : "daily",
    nightly_rate: roundHalfUp(rentGross / n), rent_gross: rentGross, computed_rent: computed, rent: rentNet, discount: d.net, tax: tax + d.tax, total: rentNet + d.net + tax + d.tax,
    tax_rate_bp: b.tax_rate_bp, prices_include_tax: b.prices_include_tax, min_nightly: c.min_nightly_halalas ?? null, discount_max: myMax, supervisor_discount_max: supMax, supervisor_max_discount_bp: b.supervisor_max_discount_bp ?? 0 };
}
/** The upcoming stays of a type with more guests than a new capacity (decision 32). */
function capacityImpact(categoryId: string, maxCapacity: number) {
  const today = branchToday();
  return T("reservations").filter((r) => r.room_category_id === categoryId && ["pending_verification", "confirmed", "checked_in"].includes(r.status) && r.check_out > today && r.adults + r.companions > maxCapacity)
    .sort((a, b) => (a.check_in < b.check_in ? -1 : 1)).map((r) => ({ id: r.id, internal_ref: r.internal_ref, check_in: r.check_in, check_out: r.check_out, guests: r.adults + r.companions, status: r.status }));
}
function quote(branch: string, category: string, ci: string, co: string, override: number | null, discount: number) {
  return quoteStay({ branch_id: branch, category_id: category, check_in: ci, check_out: co, nightly_rate_halalas: override, discount_halalas: discount ?? 0 });
}
function roomAvailablePublic(roomId: string, from: string, to: string) { const rm = byId("rooms", roomId)!; if (["blocked", "out_of_service", "maintenance"].includes(rm.status)) return false; return !T("reservation_allocations").some((a) => a.room_id === roomId && a.status === "active" && overlaps(a.from_date, a.to_date, from, to)); }
/** What still stands before the code (fn_evaluate_access of 0033): before the arrival, the arrival's own conditions; after it, the code's. */
function evaluate(resId: string, _skipSupervisor = false) {
  const r = byId("reservations", resId); if (!r) return { allowed: false, reasons: ["الحجز غير موجود"] };
  const reasons = r.status === "checked_in" ? codeBlockers(r)
    : ["draft", "pending_verification", "confirmed"].includes(r.status) ? [...checkinCoreBlockers(r), ...checkinMoneyBlockers(r), "يُسجَّل الوصول في الاستقبال ثم يُسلَّم الرمز"]
    : ["الإقامة غير قائمة"];
  return { allowed: reasons.length === 0, reasons };
}
function summary(branch: string, date: string) {
  if (!myBranches().includes(branch)) return null; const rooms = T("rooms").filter((r) => r.branch_id === branch && !r.archived_at); const res = T("reservations").filter((r) => r.branch_id === branch); const hk = T("housekeeping_tasks").filter((h) => h.branch_id === branch); const v = T("financial_vouchers").filter((x) => x.branch_id === branch && x.status === "approved");
  const active = rooms.filter((r) => r.is_active).length, occupied = rooms.filter((r) => r.status === "occupied").length;
  return { date, units: { active, occupied, reserved: rooms.filter((r) => r.status === "reserved").length, ready: rooms.filter((r) => r.status === "ready").length, dirty: rooms.filter((r) => r.is_active && r.cleanliness !== "clean").length, maintenance: rooms.filter((r) => r.status === "maintenance").length, out_of_service: rooms.filter((r) => r.status === "out_of_service" || !r.is_active).length },
    occupancy_pct: active ? Math.round((1000 * occupied) / active) / 10 : 0,
    arrivals: { expected: res.filter((r) => r.check_in === date && ["confirmed", "pending_verification"].includes(r.status)).length, arrived: res.filter((r) => r.check_in === date && r.status === "checked_in").length, pending_identity: res.filter((r) => r.check_in <= date && r.check_out > date && ["confirmed", "pending_verification"].includes(r.status) && r.identity_status !== "verified").length, unpaid: res.filter((r) => r.check_in === date && ["confirmed", "pending_verification"].includes(r.status) && r.balance_due_halalas > 0).length, overdue: res.filter((r) => r.check_in < date && ["confirmed", "pending_verification"].includes(r.status)).length },
    departures: { expected: res.filter((r) => r.check_out === date && r.status === "checked_in").length, done: res.filter((r) => r.check_out === date && ["checked_out", "closed"].includes(r.status)).length, overstay: res.filter((r) => r.check_out < date && r.status === "checked_in").length, with_balance: res.filter((r) => r.check_out === date && r.status === "checked_in" && r.balance_due_halalas > 0).length },
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
// ---- WhatsApp on the reception computer (0023) ----
function waStatus(c: Row): string {
  const complete = c.mode === "web_bridge" ? !!(c.display_phone && c.has_bridge_key) : !!(c.display_phone && c.phone_number_id && c.has_token && c.has_app_secret);
  if (!complete) return "not_configured";
  return ["active", "error"].includes(c.status) ? c.status : "configured";
}
function randomHex(bytes: number): string {
  const a = new Uint8Array(bytes);
  try { crypto.getRandomValues(a); } catch { for (let i = 0; i < bytes; i++) a[i] = Math.floor(Math.random() * 256); }
  return Array.from(a, (b) => b.toString(16).padStart(2, "0")).join("");
}
const bridgeOnline = (c: Row | undefined) => !!c?.bridge_last_seen && Date.now() - Date.parse(c.bridge_last_seen) < 90_000;
/** server-only functions (service role in the real system): only the service client below reaches them */
const serviceRpcs: Record<string, (a: any) => any> = {
  fn_whatsapp_phone_session: ({ p_phone }) => { const ph = normPhone(p_phone); if (!ph) throw new Error("VALIDATION: phone"); const token = "PH" + randomHex(8).toUpperCase(); phoneSessions.set(token, ph); return token; },
  fn_wa_bridge_auth: ({ p_key }) => { if (!/^zb_[0-9a-f]{64}$/.test(String(p_key ?? ""))) return null; const c = T("branch_whatsapp_channels").find((x) => x.mode === "web_bridge" && !!x.bridge_key && x.bridge_key === p_key); if (!c) return null; return { branch_id: c.branch_id, organization_id: c.organization_id, enabled: !!c.enabled, auto_reply: c.auto_reply ?? true, status: c.status, display_phone: c.display_phone, human_pause_minutes: c.human_pause_minutes ?? 60, branch_name: byId("branches", c.branch_id)?.name_ar ?? null }; },
  fn_wa_bridge_beat: ({ p_branch, p_status, p_phone, p_name, p_version, p_detail }) => { if (!["starting", "qr", "connected", "disconnected", "stopped"].includes(p_status)) throw new Error("VALIDATION: status"); const c = T("branch_whatsapp_channels").find((x) => x.branch_id === p_branch && x.mode === "web_bridge"); if (!c) return null; const ph = String(p_phone ?? "").replace(/\D/g, ""); const complete = waStatus(c) !== "not_configured";
    Object.assign(c, { bridge_status: p_status, bridge_last_seen: nowISO(), bridge_phone: /^\d{8,15}$/.test(ph) ? ph : c.bridge_phone ?? null, bridge_name: p_name || c.bridge_name || null, bridge_version: p_version || c.bridge_version || null });
    if (complete && p_status === "connected") Object.assign(c, { status: "active", last_error: null, last_checked_at: nowISO() });
    if (complete && p_status === "disconnected") Object.assign(c, { status: "error", last_error: String(p_detail || "disconnected").slice(0, 300), last_checked_at: nowISO() });
    emit("branch_whatsapp_channels"); return { enabled: !!c.enabled, auto_reply: c.auto_reply ?? true, human_pause_minutes: c.human_pause_minutes ?? 60 }; },
  fn_wa_bridge_poll: ({ p_branch, p_limit }) => { const now = Date.now(); const out: Row[] = [];
    const fail = (o: Row, status: string, error: string) => { Object.assign(o, { status, error, finished_at: nowISO() }); const m = byId("conversation_messages", o.message_id); if (m) m.meta = { ...(m.meta ?? {}), delivery: "failed", error }; };
    for (const o of T("whatsapp_outbox").filter((x) => x.branch_id === p_branch)) { if (o.status === "sending" && now - Date.parse(o.picked_at) > 5 * 60_000) fail(o, "failed", "no_ack"); else if (o.status === "pending" && now - Date.parse(o.created_at) > 12 * 3600_000) fail(o, "expired", "expired"); }
    for (const o of T("whatsapp_outbox").filter((x) => x.branch_id === p_branch && x.status === "pending").sort((a, b) => (a.created_at < b.created_at ? -1 : 1)).slice(0, Math.max(1, Math.min(Number(p_limit) || 5, 20)))) {
      const m = byId("conversation_messages", o.message_id); const cv = m ? byId("conversations", m.conversation_id) : undefined;
      if (!m || !cv?.wa_chat_id || cv.branch_id !== p_branch) { Object.assign(o, { status: "expired", error: "message_gone", finished_at: nowISO() }); continue; }
      Object.assign(o, { status: "sending", picked_at: nowISO(), attempts: (o.attempts ?? 0) + 1 }); out.push({ id: o.id, chat_id: cv.wa_chat_id, text: m.content });
    }
    emit("conversation_messages"); return out; },
  // 0024: a confirmation that arrives after the 5-minute wait (the reply WAS typed) still turns it into "sent"
  fn_wa_bridge_ack: ({ p_branch, p_id, p_ok, p_wa_id, p_error }) => { const o = T("whatsapp_outbox").find((x) => x.id === p_id && x.branch_id === p_branch && (x.status === "sending" || (!!p_ok && x.status === "failed" && x.error === "no_ack"))); if (!o) return false;
    Object.assign(o, { status: p_ok ? "sent" : "failed", wa_id: p_wa_id ?? null, error: p_ok ? null : String(p_error || "send_failed").slice(0, 200), finished_at: nowISO() });
    const m = byId("conversation_messages", o.message_id);
    if (m) { const { error: _gone, ...rest } = (m.meta ?? {}) as Row; void _gone; m.meta = p_ok ? { ...rest, delivery: "sent" } : { ...(m.meta ?? {}), delivery: "failed", error: o.error }; }
    emit("conversation_messages"); return true; },
  fn_wa_bridge_enqueue: ({ p_message }) => { const m = T("conversation_messages").find((x) => x.id === p_message && x.sender === "supervisor"); if (!m) return { queued: false, error: "not_found" };
    const cv = byId("conversations", m.conversation_id)!; const c = T("branch_whatsapp_channels").find((x) => x.branch_id === cv.branch_id); let err: string | null = null;
    if (cv.channel !== "whatsapp" || !cv.wa_chat_id) err = "not_whatsapp";
    else if (!c || c.mode !== "web_bridge" || !c.enabled || !c.has_bridge_key) err = "channel_unavailable";
    else { const threads = new Set(T("conversations").filter((y) => y.branch_id === cv.branch_id && y.wa_contact === cv.wa_contact).map((y) => y.id)); const last = Math.max(0, ...T("conversation_messages").filter((x) => x.sender === "guest" && threads.has(x.conversation_id)).map((x) => Date.parse(x.created_at))); if (!last || Date.now() - last > 24 * 3600_000) err = "window_closed"; }
    if (err) { m.meta = { ...(m.meta ?? {}), channel: "whatsapp", delivery: "failed", error: err }; emit("conversation_messages"); return { queued: false, error: err }; }
    T("whatsapp_outbox").push({ id: uid(), branch_id: cv.branch_id, message_id: m.id, status: "pending", attempts: 0, wa_id: null, error: null, created_at: nowISO(), picked_at: null, finished_at: null });
    Object.assign(cv, { human_active_until: new Date(Date.now() + (c!.human_pause_minutes ?? 60) * 60_000).toISOString(), last_message_at: nowISO() });
    m.meta = { ...(m.meta ?? {}), channel: "whatsapp", delivery: "queued" }; emit("conversations"); emit("conversation_messages");
    return { queued: true, bridge_online: bridgeOnline(c) }; },
};

function invoke(name: string, opts: any) {
  const body = opts?.body ?? {};
  if (name === "guest-otp") return { data: { status: "channel_unavailable" }, error: null };
  // WhatsApp (demo): the connection test answers from the demo row; a supervisor's reply is stored but nothing is sent
  if (name === "whatsapp-send") {
    if (body.mode === "check") { if (!hasRole("owner")) return { data: null, error: { message: "forbidden" } }; const ch = T("branch_whatsapp_channels").find((x) => x.branch_id === body.branch_id); if (!ch || ch.status === "not_configured") return { data: { ok: false, error: "channel_incomplete" }, error: null }; Object.assign(ch, { last_checked_at: nowISO() }); return { data: { ok: false, error: "وضع العرض التجريبي — لا اتصال حقيقي بـ Meta" }, error: null }; }
    const conv = byId("conversations", body.conversation_id); if (!conv || (conv.branch_id && !myBranches().includes(conv.branch_id))) return { data: null, error: { message: "forbidden" } };
    const text = String(body.text ?? "").trim(); if (!text || text.length > 4000) return { data: null, error: { message: "invalid_text" } };
    const msg = { id: uid(), conversation_id: conv.id, sender: "supervisor", content: text, meta: { channel: "whatsapp" } as Row, created_at: nowISO() }; T("conversation_messages").push(msg); conv.last_message_at = nowISO(); emit("conversation_messages");
    if (conv.channel !== "whatsapp" || !conv.wa_contact) return { data: { ok: true, delivered: false, error: "not_whatsapp" }, error: null };
    const ch = T("branch_whatsapp_channels").find((x) => x.branch_id === conv.branch_id);
    if (ch?.mode === "web_bridge") { const q = serviceRpcs.fn_wa_bridge_enqueue({ p_message: msg.id }); return { data: { ok: true, delivered: false, queued: !!q.queued, bridge_online: !!q.bridge_online, error: q.queued ? undefined : q.error }, error: null }; }
    msg.meta = { channel: "whatsapp", delivery: "failed", error: "demo" };
    return { data: { ok: true, delivered: false, error: "channel_unavailable" }, error: null };
  }
  if (name === "ai-health") return { data: { configured: false, ok: false, model: null, error: "وضع العرض التجريبي — لا مزود متصل" }, error: null };
  if (name === "ai-ops") { if (body.mode === "briefing") { const ctx = rpcs.fn_ai_ops_context({ p_branch: body.branch_id, p_date: body.date ?? null }); if (!ctx) return { data: null, error: { message: "forbidden" } }; const b = buildBriefing(ctx); return { data: { ...b, insights: null, mode: "deterministic", ai_status: "demo", generated_at: ctx.generated_at, date: ctx.summary?.date }, error: null }; } const r = opsChat(body); return r.error ? { data: null, error: r.error } : { data: r.data, error: null }; }
  if (name === "ai-reception") { const branch = body.branch_id ?? T("branches")[0]?.id; let conv = body.conversation_id ? byId("conversations", body.conversation_id) : null; if (!conv) { conv = { id: uid(), reservation_id: null, channel: "screen", status: "active", branch_id: branch, guest_token: body.guest_token ?? null, client_fingerprint: body.client_fingerprint ?? null, created_at: nowISO(), last_message_at: nowISO(), handed_off_at: null, handoff_reason: null }; T("conversations").unshift(conv); } const msg = String(body.message ?? ""); T("conversation_messages").push({ id: uid(), conversation_id: conv.id, sender: "guest", content: msg, meta: { mode: "scripted" }, created_at: nowISO() }); const bb = byId("branches", branch); const knowledge = { branchName: bb?.name_ar, checkInTime: bb?.check_in_time, checkOutTime: bb?.check_out_time, address: bb?.address, phone: bb?.phone, mapUrl: bb?.map_url ?? null, bookingUrl: bb?.booking_platform_url ?? null, policies: T("property_policies").filter((x) => x.branch_id === branch && x.is_public).map((x) => ({ topic: x.topic, title: x.title, content: x.content_ar })), entries: rpcs.fn_public_knowledge({ p_branch: branch }) };
    const note = (r: { intent: string; knowledgeId?: string }) => { if (r.knowledgeId) rpcs.fn_knowledge_usage_bump({ p_entry: r.knowledgeId }); if (r.intent === "unknown") rpcs.fn_record_unanswered({ p_branch: branch, p_question: msg, p_conversation: conv!.id }); };
    if (conv.status === "handed_off") { const r0 = scriptedReply(msg, "فايف اورز", undefined, knowledge); note(r0); const informative = ["policy", "knowledge", "existing_booking", "new_booking", "access_code"].includes(r0.intent); const reply = informative ? r0.text + "\n\nمحادثتك ما زالت محوّلة إلى مشرف الاستقبال وسيرد عليك هنا عند توفره." : "تم تحويل محادثتك إلى مشرف الاستقبال وسيرد عليك هنا قريبًا. أثناء الانتظار يمكنك سؤالي عن مواعيد الوصول والمغادرة أو الإنترنت أو المواقف أو الموقع، أو بدء محادثة جديدة."; T("conversation_messages").push({ id: uid(), conversation_id: conv.id, sender: "assistant", content: reply, meta: { mode: "scripted", reason: "handed_off" }, created_at: nowISO() }); emit("conversation_messages"); return { data: { conversation_id: conv.id, reply, intent: r0.intent, actions: [...(informative ? r0.actions.filter((a) => !a.value) : []), { label: "محادثة جديدة", route: "/reception?new=1" }], mode: "scripted", verified: !!body.guest_token, handed_off: true }, error: null }; }
    const r = scriptedReply(msg, "فايف اورز", undefined, knowledge); note(r); if (/(موظف|مشرف|بشري|human|staff)/.test(msg)) { Object.assign(conv, { status: "handed_off", handed_off_at: nowISO(), handoff_reason: "طلب صريح من النزيل" }); T("human_handoff_tickets").unshift({ id: uid(), organization_id: ORG, branch_id: branch, conversation_id: conv.id, reservation_id: null, kind: "guest_request", external_ref: null, source_name: null, details: "طلب صريح من النزيل", status: "open", resolved_by: null, resolved_at: null, created_at: nowISO() }); emit("human_handoff_tickets"); } T("conversation_messages").push({ id: uid(), conversation_id: conv.id, sender: "assistant", content: r.text, meta: { mode: "scripted" }, created_at: nowISO() }); conv.last_message_at = nowISO(); emit("conversations"); emit("conversation_messages"); return { data: { conversation_id: conv.id, reply: r.text, actions: r.actions, intent: r.intent, mode: "scripted", verified: !!body.guest_token, handed_off: conv.status === "handed_off", ai_status: "demo" }, error: null }; }
  return { data: null, error: { message: "unknown function" } };
}

// ---------------------------------------------------------------------------
// client
// ---------------------------------------------------------------------------
export function createDemoClient() {
  return {
    from: (table: string) => new QB(table),
    rpc: (fn: string, args: any = {}) => rpcCall((f) => rpcs[f], fn, args),
    auth: {
      getSession: async () => ({ data: { session }, error: null }),
      onAuthStateChange: (cb: (e: string, s: Session) => void) => { authListeners.add(cb); return { data: { subscription: { unsubscribe: () => authListeners.delete(cb) } } }; },
      // a fresh sign-in is a new session (0040): it opens after any forced end of the person's sessions, so it is not refused by it
      signInWithPassword: async ({ email }: { email: string; password: string }) => { lastSignInAt = Date.now(); const acc = DEMO_ACCOUNTS.find((a) => a.email.toLowerCase() === String(email).trim().toLowerCase()) ?? DEMO_ACCOUNTS[0]; setSession({ user: { id: acc.auth, email: acc.email }, access_token: "demo", signed_in_at: newSessionAt(acc.auth) }); return { data: { session }, error: null }; },
      signUp: async ({ email }: { email: string; password: string }) => { const acc = DEMO_ACCOUNTS[0]; setSession({ user: { id: acc.auth, email }, access_token: "demo", signed_in_at: newSessionAt(acc.auth) }); return { data: { session }, error: null }; },
      /** a token put back in hand (supabase.auth.setSession): the same session as before, refused if it was ended since */
      setSession: async (s: Session) => { if (!s?.user?.id) return { data: { session: null }, error: { message: "invalid session" } }; setSession({ user: { id: s.user.id, email: s.user.email }, access_token: s.access_token ?? "demo", signed_in_at: s.signed_in_at }); return { data: { session }, error: null }; },
      signOut: async () => { setSession(null); return { error: null }; },
    },
    channel: (_name: string) => { const mine: Listener[] = []; const ch = { on: (_e: string, f: { table: string }, cb: () => void) => { const l = { table: f.table, cb }; mine.push(l); listeners.add(l); return ch; }, subscribe: () => ch, unsubscribe: () => { for (const l of mine) listeners.delete(l); }, _mine: mine }; return ch; },
    removeChannel: async (ch: { _mine?: Listener[] }) => { for (const l of ch?._mine ?? []) listeners.delete(l); return "ok"; },
    functions: { invoke: async (name: string, opts?: any) => invoke(name, opts) },
  };
}
export const DEMO_LOGINS = DEMO_ACCOUNTS.map((a) => ({ email: a.email, name: a.name, role: a.role }));

/** The server's view of the demo store (what edge functions see with the service role) — the WhatsApp simulator
 *  runs the real wa-bridge code (supabase/functions/_shared/wa_bridge.ts) against it. */
export function createDemoServiceClient() {
  return {
    from: (table: string) => new QB(table, true),
    rpc: (fn: string, args: any = {}) => rpcCall((f) => serviceRpcs[f] ?? rpcs[f], fn, args),
  };
}
/** fetch for the demo's edge functions (the WhatsApp flow asks ai-reception over HTTP on the server) */
export const demoFunctionsFetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
  const name = String(input).split("/functions/v1/")[1]?.split("?")[0] ?? "";
  let body: unknown = {}; try { body = JSON.parse(String(init?.body ?? "{}")); } catch { /* empty */ }
  const r = invoke(name, { body }) as { data: unknown; error: { message: string } | null };
  return new Response(JSON.stringify(r.error ? { error: r.error.message } : r.data), { status: r.error ? 400 : 200, headers: { "content-type": "application/json" } });
}) as typeof fetch;
/** the key of a branch linked to the reception computer — the simulator plays that program */
export function demoBridgeKey(branchId: string): string | null {
  return T("branch_whatsapp_channels").find((x) => x.branch_id === branchId && x.mode === "web_bridge")?.bridge_key ?? null;
}
