/**
 * The in-browser demo backend (src/demo) is what reviewers click through. It must enforce the same
 * non-negotiable rules as the SQL functions, otherwise the demo would "prove" behaviour the real
 * system does not have (or hide a rule the real system enforces). These tests drive the demo client
 * exactly as the UI does — through rpc()/from() — with a tiny storage shim instead of a browser.
 */
import { describe, it, expect, beforeAll, beforeEach } from "vitest";

type Client = ReturnType<typeof import("../../src/demo/client")["createDemoClient"]>;
let client: Client;
let resetDemo: () => void;
let BRANCH: string;
let CATEGORY: string;
let SOURCE: string;

const memStorage = () => {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, String(v)), removeItem: (k: string) => void m.delete(k), clear: () => m.clear(), key: () => null, length: 0 };
};

async function login(email: string) { await client.auth.signInWithPassword({ email, password: "demo" }); }
async function rpc<T = any>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await client.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}
const uid = () => `k-${Math.random().toString(36).slice(2)}`;
const fut = (n: number) => { const d = new Date(); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };

async function createRes(opts: { ci: number; co: number; roomId?: string; name?: string }) {
  return rpc<{ ok: boolean; id: string; room_id: string | null }>("fn_staff_create_reservation", { p: { branch_id: BRANCH, category_id: CATEGORY, source_id: SOURCE, check_in: fut(opts.ci), check_out: fut(opts.co), guest_name: opts.name ?? "ضيف اختبار", guest_phone: "0500000000", room_id: opts.roomId, adults: 1, companions: 0 } });
}

beforeAll(async () => {
  (globalThis as any).window = globalThis;
  (globalThis as any).localStorage = memStorage();
  (globalThis as any).sessionStorage = memStorage();
  const mod = await import("../../src/demo/client");
  client = mod.createDemoClient();
  resetDemo = mod.resetDemo;
});

beforeEach(async () => {
  resetDemo();
  await login("owner@demo.sa");
  const b = await client.from("branches").select("id").order("name_ar").limit(1).maybeSingle();
  BRANCH = (b.data as any).id;
  const c = await client.from("room_categories").select("id").eq("branch_id", BRANCH).order("base_price_halalas").limit(1).maybeSingle();
  CATEGORY = (c.data as any).id;
  const s = await client.from("booking_sources").select("id, external_reference_required").eq("is_active", true);
  SOURCE = ((s.data as any[]).find((x) => !x.external_reference_required) ?? (s.data as any[])[0]).id;
});

describe("G05 — no overlapping allocation", () => {
  it("the second reservation for the same room and nights is rejected", async () => {
    const rooms = await rpc<Array<{ room_id: string }>>("fn_available_rooms", { p_branch: BRANCH, p_from: fut(30), p_to: fut(33), p_category: CATEGORY, p_exclude_reservation: null });
    expect(rooms.length).toBeGreaterThan(0);
    const room = rooms[0].room_id;
    const a = await createRes({ ci: 30, co: 33, roomId: room });
    expect(a.ok).toBe(true);
    await expect(createRes({ ci: 31, co: 34, roomId: room, name: "متداخل" })).rejects.toThrow(/ALLOCATION_CONFLICT|ROOM_NOT_AVAILABLE/);
    // a non-overlapping stay in the same room is fine ([) semantics: check-out day == next check-in day)
    const b = await createRes({ ci: 33, co: 35, roomId: room, name: "متتابع" });
    expect(b.ok).toBe(true);
  });
});

describe("G10–G13 — money", () => {
  it("a partial receipt is 'partially_paid', never 'paid'; the deposit lives in its own ledger", async () => {
    const r = await createRes({ ci: 40, co: 42 });
    const f0 = await rpc<any>("fn_reservation_finance", { p_reservation: r.id });
    expect(f0.total).toBeGreaterThan(0);
    await rpc("fn_create_voucher", { p: { reservation_id: r.id, kind: "deposit", amount_halalas: 20000, method: "cash", idempotency_key: uid() } });
    let f = await rpc<any>("fn_reservation_finance", { p_reservation: r.id });
    expect(f.deposit_balance).toBe(20000);
    expect(f.balance_due).toBe(f0.total); // the deposit did not pay the stay
    expect(f.payment_status).toBe("pending");
    const half = Math.floor(f0.total / 2);
    await rpc("fn_create_voucher", { p: { reservation_id: r.id, kind: "receipt", amount_halalas: half, method: "cash", idempotency_key: uid() } });
    f = await rpc<any>("fn_reservation_finance", { p_reservation: r.id });
    expect(f.payment_status).toBe("partially_paid");
    expect(f.balance_due).toBe(f0.total - half);
    await rpc("fn_create_voucher", { p: { reservation_id: r.id, kind: "receipt", amount_halalas: f0.total - half, method: "cash", idempotency_key: uid() } });
    f = await rpc<any>("fn_reservation_finance", { p_reservation: r.id });
    expect(f.payment_status).toBe("paid");
    expect(f.balance_due).toBe(0);
    expect(f.deposit_balance).toBe(20000);
  });

  it("the same idempotency key replays without a second voucher; a different payload with the same key is a conflict", async () => {
    const r = await createRes({ ci: 44, co: 45 });
    const key = uid();
    const first = await rpc<any>("fn_create_voucher", { p: { reservation_id: r.id, kind: "receipt", amount_halalas: 5000, method: "cash", idempotency_key: key } });
    const replay = await rpc<any>("fn_create_voucher", { p: { reservation_id: r.id, kind: "receipt", amount_halalas: 5000, method: "cash", idempotency_key: key } });
    expect(replay.duplicate).toBe(true);
    expect(replay.voucher_id).toBe(first.voucher_id);
    await expect(rpc("fn_create_voucher", { p: { reservation_id: r.id, kind: "receipt", amount_halalas: 9000, method: "cash", idempotency_key: key } })).rejects.toThrow(/IDEMPOTENCY_CONFLICT/);
    const f = await rpc<any>("fn_reservation_finance", { p_reservation: r.id });
    expect(f.received).toBe(5000);
  });

  it("refunds never exceed what was received; cancelling a reservation never refunds by itself", async () => {
    const r = await createRes({ ci: 46, co: 47 });
    await rpc("fn_create_voucher", { p: { reservation_id: r.id, kind: "receipt", amount_halalas: 10000, method: "cash", idempotency_key: uid() } });
    await expect(rpc("fn_refund", { p: { reservation_id: r.id, kind: "refund", amount_halalas: 15000, method: "cash", reason: "اختبار", idempotency_key: uid() } })).rejects.toThrow(/REFUND_EXCEEDS_AVAILABLE/);
    await rpc("fn_refund", { p: { reservation_id: r.id, kind: "refund", amount_halalas: 4000, method: "cash", reason: "اختبار", idempotency_key: uid() } });
    await expect(rpc("fn_refund", { p: { reservation_id: r.id, kind: "refund", amount_halalas: 7000, method: "cash", reason: "اختبار", idempotency_key: uid() } })).rejects.toThrow(/REFUND_EXCEEDS_AVAILABLE/);
    await rpc("fn_staff_cancel_reservation", { p_reservation: r.id, p_reason: "طلب الضيف", p_source: "staff" });
    const f = await rpc<any>("fn_reservation_finance", { p_reservation: r.id });
    expect(f.received).toBe(10000);
    expect(f.refunded).toBe(4000);
    const row = await client.from("reservations").select("status").eq("id", r.id).maybeSingle();
    expect((row.data as any).status).toBe("cancelled");
  });

  it("housekeeping gets no finance and cannot create vouchers", async () => {
    const r = await createRes({ ci: 48, co: 49 });
    await login("housekeeping@demo.sa");
    expect(await rpc("fn_reservation_finance", { p_reservation: r.id })).toBeNull();
    const d = await rpc<any>("fn_reservation_detail", { p_reservation: r.id });
    expect(d.finance).toBeNull();
    await expect(rpc("fn_create_voucher", { p: { reservation_id: r.id, kind: "receipt", amount_halalas: 100, method: "cash", idempotency_key: uid() } })).rejects.toThrow(/FORBIDDEN/);
    const ledger = await client.from("financial_vouchers").select("id");
    expect((ledger.data as any[]).length).toBe(0);
  });
});

describe("G16 — definitions are archived, not deleted, while in use", () => {
  it("a task type with history cannot be hard-deleted; archiving needs a reason and no open commitments; restore works", async () => {
    const types = (await client.from("task_types").select("id, code").eq("branch_id", BRANCH).is("archived_at", null)).data as any[];
    const tasks = (await client.from("housekeeping_tasks").select("task_type_id, status").eq("branch_id", BRANCH)).data as any[];
    const withHistory = types.find((t) => tasks.some((x) => x.task_type_id === t.id));
    expect(withHistory).toBeTruthy();
    const deps = await rpc<Record<string, number>>("fn_definition_dependencies", { p_entity: "task_type", p_id: withHistory.id });
    expect(Object.values(deps).some((n) => n > 0)).toBe(true);
    const del = await rpc<any>("fn_admin_delete_definition", { p_entity: "task_type", p_id: withHistory.id });
    expect(del.ok).toBe(false);
    expect(del.error).toBe("HAS_DEPENDENCIES");
    // archiving requires a reason …
    await expect(rpc("fn_admin_archive_definition", { p_entity: "task_type", p_id: withHistory.id, p_reason: "", p_archive: true })).rejects.toThrow(/VALIDATION/);
    // … and refuses while tasks are still open (they must be finished or cancelled first)
    const open = tasks.filter((x) => x.task_type_id === withHistory.id && ["pending", "in_progress"].includes(x.status));
    if (open.length > 0) {
      await expect(rpc("fn_admin_archive_definition", { p_entity: "task_type", p_id: withHistory.id, p_reason: "لم يعد مستخدمًا", p_archive: true })).rejects.toThrow(/HAS_OPEN_COMMITMENTS/);
    }
    // a brand-new definition with no history: archive → hidden, restore → back, delete → allowed (and audited)
    const created = await rpc<any>("fn_admin_upsert_task_type", { p: { branch_id: BRANCH, name: "نوع اختبار", target: "room", default_priority: "medium", default_duration_minutes: 30, is_active: true } });
    const newId = created.id ?? created.task_type_id ?? (created as any);
    await rpc("fn_admin_archive_definition", { p_entity: "task_type", p_id: newId, p_reason: "تجربة", p_archive: true });
    expect(((await client.from("task_types").select("archived_at").eq("id", newId).maybeSingle()).data as any).archived_at).toBeTruthy();
    await rpc("fn_admin_archive_definition", { p_entity: "task_type", p_id: newId, p_reason: "استعادة", p_archive: false });
    expect(((await client.from("task_types").select("archived_at").eq("id", newId).maybeSingle()).data as any).archived_at).toBeNull();
    const del2 = await rpc<any>("fn_admin_delete_definition", { p_entity: "task_type", p_id: newId });
    expect(del2.ok).toBe(true);
    const audit = (await client.from("audit_events").select("action").eq("entity_id", newId)).data as any[];
    expect(audit.some((a) => a.action === "task_type.deleted")).toBe(true);
  });
});

describe("G09 — cleanliness, occupancy and readiness are separate", () => {
  it("completing a cleaning task makes the room clean but does not change occupancy", async () => {
    const task = await client.from("housekeeping_tasks").select("id, room_id, version").eq("status", "pending").not("room_id", "is", null).limit(1).maybeSingle();
    const t = task.data as any;
    const before = await client.from("rooms").select("status, cleanliness").eq("id", t.room_id).maybeSingle();
    await rpc("fn_hk_start_task", { p_task: t.id });
    const res = await rpc<any>("fn_hk_complete_task", { p_task: t.id, p_note: null, p_expected_version: t.version + 1 });
    const after = await client.from("rooms").select("status, cleanliness").eq("id", t.room_id).maybeSingle();
    expect((after.data as any).cleanliness).toBe("clean");
    const occupiedBefore = (before.data as any).status === "occupied";
    const occupiedAfter = (after.data as any).status === "occupied";
    expect(occupiedAfter).toBe(occupiedBefore);
    expect(res.room_status).toBeDefined();
  });
});

// The demo facet of tests/sql/money_core_tests.sql: same codes, same scenarios, driven as the UI drives them.
describe("G10–G14 — money core (decisions 13, 24, 25, 47, 68, 69)", () => {
  type Acc = { id: string; branch_id: string; kind: string; name: string; is_default: boolean; is_active: boolean; archived_at: string | null; version: number };
  const accountsOf = async (branch: string) => (await client.from("cash_accounts").select("id, branch_id, kind, name, is_default, is_active, archived_at, version").eq("branch_id", branch)).data as Acc[];
  const defaults = async (branch: string) => { const a = await accountsOf(branch); return { cash: a.find((x) => x.kind === "cash_box" && x.is_default && !x.archived_at)!, bank: a.find((x) => x.kind === "bank_account" && x.is_default && !x.archived_at)! }; };
  const voucher = (reservation: string, extra: Record<string, unknown>) => rpc<any>("fn_create_voucher", { p: { reservation_id: reservation, kind: "receipt", amount_halalas: 1000, method: "cash", idempotency_key: uid(), ...extra } });
  const refund = (reservation: string, extra: Record<string, unknown>) => rpc<any>("fn_refund", { p: { reservation_id: reservation, kind: "refund", amount_halalas: 1000, method: "cash", reason: "اختبار", idempotency_key: uid(), ...extra } });
  const vrow = async (id: string) => (await client.from("financial_vouchers").select("id, method, account_id, reference, payout_id, kind").eq("id", id).maybeSingle()).data as any;
  const today = () => new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Riyadh" });
  /** The branch-local day after today (fut() counts UTC days, which is today in Riyadh before 03:00). */
  const tomorrow = () => { const t = new Date(`${today()}T00:00:00Z`); t.setUTCDate(t.getUTCDate() + 1); return t.toISOString().slice(0, 10); };
  const otherBranch = async () => ((await client.from("branches").select("id")).data as any[]).map((b) => b.id).find((id) => id !== BRANCH)!;

  it("MC01 every branch has a default cash box and a default bank account — the seeded ones and a branch created later", async () => {
    for (const b of (await client.from("branches").select("id")).data as any[]) {
      const a = await accountsOf(b.id);
      for (const kind of ["cash_box", "bank_account"]) expect(a.filter((x) => x.kind === kind && x.is_default && !x.archived_at), `${b.id} ${kind}`).toHaveLength(1);
    }
    const nb = await rpc<any>("fn_admin_upsert_branch", { p: { name_ar: "فرع اختبار المال" } });
    const a = await accountsOf(nb.id);
    expect(a.map((x) => x.kind).sort()).toEqual(["bank_account", "cash_box"]);
    expect(a.every((x) => x.is_default)).toBe(true);
  });

  it("MC02 cash goes to the default cash box, the terminal to the default bank account, the platform to none", async () => {
    const r = await createRes({ ci: 50, co: 52 });
    const d = await defaults(BRANCH);
    const cash = await vrow((await voucher(r.id, { method: "cash" })).voucher_id);
    const pos = await vrow((await voucher(r.id, { method: "pos", reference: "TRX-50021" })).voucher_id);
    const ota = await vrow((await voucher(r.id, { method: "ota_deferred" })).voucher_id);
    expect(cash.account_id).toBe(d.cash.id);
    expect(pos).toMatchObject({ account_id: d.bank.id, reference: "TRX-50021" });
    expect(ota.account_id).toBeNull();
  });

  it("MC03 the retired methods are refused for new vouchers; vouchers that already used them keep them", async () => {
    const r = await createRes({ ci: 53, co: 54 });
    for (const method of ["mada", "card", "payment_link", "booking_platform"]) {
      await expect(voucher(r.id, { method, reference: "REF-1234" }), method).rejects.toThrow(/method_retired/);
      await expect(refund(r.id, { method, reference: "REF-1234" }), method).rejects.toThrow(/method_retired|REFUND_EXCEEDS/);
    }
  });

  it("MC04 the terminal and the transfer need their transaction number; a transfer counts at once with it", async () => {
    const r = await createRes({ ci: 55, co: 57 });
    await expect(voucher(r.id, { method: "pos" })).rejects.toThrow(/reference_required/);
    await expect(voucher(r.id, { method: "bank_transfer", reference: "  " })).rejects.toThrow(/reference_required/);
    await expect(voucher(r.id, { method: "bank_transfer", reference: "ab" })).rejects.toThrow(/VALIDATION: reference/);
    await voucher(r.id, { method: "bank_transfer", reference: "TR-778899", amount_halalas: 4321 });
    const f = await rpc<any>("fn_reservation_finance", { p_reservation: r.id });
    expect(f.received).toBe(4321);
  });

  it("MC05 cash never lands in a bank account, an account of another branch is refused, the platform takes no account", async () => {
    const r = await createRes({ ci: 58, co: 59 });
    const d = await defaults(BRANCH);
    const other = await defaults(await otherBranch());
    await expect(voucher(r.id, { method: "cash", account_id: d.bank.id })).rejects.toThrow(/account_kind/);
    await expect(voucher(r.id, { method: "pos", reference: "TRX-1", account_id: d.cash.id })).rejects.toThrow(/account_kind|VALIDATION: reference/);
    await expect(voucher(r.id, { method: "pos", reference: "TRX-1001", account_id: other.bank.id })).rejects.toThrow(/BRANCH_MISMATCH/);
    await expect(voucher(r.id, { method: "ota_deferred", account_id: d.bank.id })).rejects.toThrow(/account_not_allowed/);
  });

  it("MC15 the deposit is taken and returned at the property, never through the platform", async () => {
    const r = await createRes({ ci: 90, co: 91 });
    await expect(voucher(r.id, { kind: "deposit", method: "ota_deferred", amount_halalas: 5000 })).rejects.toThrow(/deposit_method/);
    await voucher(r.id, { kind: "deposit", method: "cash", amount_halalas: 5000 });
    await expect(refund(r.id, { kind: "deposit_refund", method: "ota_deferred", amount_halalas: 5000 })).rejects.toThrow(/deposit_method/);
    expect((await rpc<any>("fn_reservation_finance", { p_reservation: r.id })).deposit_balance).toBe(5000);
  });

  it("MC06 with no default and no account a cash receipt is refused with a clear reason; an archived box is refused; restoring brings it back", async () => {
    const r = await createRes({ ci: 60, co: 61 });
    const d = await defaults(BRANCH);
    const archived = await rpc<any>("fn_admin_archive_cash_account", { p_id: d.cash.id, p_archive: true, p_reason: "إغلاق الصندوق" });
    const others = (await accountsOf(BRANCH)).filter((x) => x.kind === "cash_box" && x.id !== d.cash.id && !x.archived_at);
    for (const o of others) await rpc("fn_admin_archive_cash_account", { p_id: o.id, p_archive: true, p_reason: "اختبار" });
    expect(archived.default_missing).toBe(true);
    await expect(voucher(r.id, { method: "cash" })).rejects.toThrow(/account_required/);
    await expect(voucher(r.id, { method: "cash", account_id: d.cash.id })).rejects.toThrow(/account_archived/);
    await rpc("fn_admin_archive_cash_account", { p_id: d.cash.id, p_archive: false, p_reason: "إعادة الصندوق" });
    const ok = await voucher(r.id, { method: "cash", account_id: d.cash.id });
    expect((await vrow(ok.voucher_id)).account_id).toBe(d.cash.id);
  });

  it("MC07a a supervisor cannot define cash boxes or bank accounts", async () => {
    await login("reception@demo.sa");
    await expect(rpc("fn_admin_upsert_cash_account", { p: { branch_id: BRANCH, kind: "cash_box", name: "صندوق جانبي" } })).rejects.toThrow(/FORBIDDEN/);
  });

  it("MC07b a manager adds an account and makes it the default; the old default steps down; a duplicate name is refused; renaming keeps the voucher on it", async () => {
    await login("manager@demo.sa");
    const before = await defaults(BRANCH);
    const created = await rpc<any>("fn_admin_upsert_cash_account", { p: { branch_id: BRANCH, kind: "bank_account", name: "حساب التحويلات", bank_name: "بنك تجريبي", account_last4: "9876", is_default: true } });
    const now = await defaults(BRANCH);
    expect(now.bank.id).toBe(created.id);
    expect((await accountsOf(BRANCH)).find((x) => x.id === before.bank.id)!.is_default).toBe(false);
    await expect(rpc("fn_admin_upsert_cash_account", { p: { branch_id: BRANCH, kind: "cash_box", name: "حساب التحويلات" } })).rejects.toThrow(/DUPLICATE_NAME/);
    await expect(rpc("fn_admin_upsert_cash_account", { p: { branch_id: BRANCH, kind: "bank_account", name: "حساب آخر", account_last4: "12a4" } })).rejects.toThrow(/account_last4/);
    const r = await createRes({ ci: 62, co: 63 });
    const v = await voucher(r.id, { method: "pos", reference: "TRX-6200" });
    await rpc("fn_admin_upsert_cash_account", { p: { id: created.id, name: "حساب التحويلات الرئيسي", version: created.version } });
    expect((await vrow(v.voucher_id)).account_id).toBe(created.id);
  });

  it("MC09 a refund leaves through an account too (cash box, or bank with its number); applying the deposit to the stay takes none", async () => {
    const r = await createRes({ ci: 64, co: 66 });
    const d = await defaults(BRANCH);
    await voucher(r.id, { method: "cash", amount_halalas: 10000 });
    await voucher(r.id, { kind: "deposit", method: "cash", amount_halalas: 5000 });
    await expect(refund(r.id, { method: "pos", amount_halalas: 2000 })).rejects.toThrow(/reference_required/);
    const back = await vrow((await refund(r.id, { method: "pos", reference: "RF-2001", amount_halalas: 2000 })).voucher_id);
    expect(back).toMatchObject({ account_id: d.bank.id, reference: "RF-2001" });
    const cashBack = await vrow((await refund(r.id, { method: "cash", amount_halalas: 1000 })).voucher_id);
    expect(cashBack.account_id).toBe(d.cash.id);
    const applied = await vrow((await refund(r.id, { kind: "deposit_apply", method: undefined, amount_halalas: 3000 })).voucher_id);
    expect(applied.account_id).toBeNull();
  });

  it("MC10 the supervisor settles the day: the terminal vouchers net (taken in − paid back) against the terminal total; equal is matched", async () => {
    const d = await defaults(BRANCH);
    const base = await rpc<any>("fn_pos_settlement_preview", { p_branch: BRANCH, p_account: d.bank.id, p_date: today() });
    const r = await createRes({ ci: 67, co: 69 });
    await voucher(r.id, { method: "pos", reference: "TRX-6701", amount_halalas: 12000 });
    await refund(r.id, { method: "pos", reference: "RF-6701", amount_halalas: 2000 });
    await voucher(r.id, { method: "cash", amount_halalas: 999 });   // cash is not the terminal's
    await login("reception@demo.sa");
    const day = await rpc<any>("fn_pos_settlement_preview", { p_branch: BRANCH, p_account: d.bank.id, p_date: today() });
    expect(day.system_total_halalas - base.system_total_halalas).toBe(10000);
    expect(day.voucher_count - base.voucher_count).toBe(2);
    const s = await rpc<any>("fn_pos_settle", { p: { branch_id: BRANCH, account_id: d.bank.id, business_date: today(), terminal_total_halalas: day.system_total_halalas, version: day.settlement?.version } });
    expect(s.settlement).toMatchObject({ status: "matched", difference_halalas: 0 });
  });

  it("MC11 a difference must be explained, is kept with its sign for the owner", async () => {
    const d = await defaults(BRANCH);
    await login("reception@demo.sa");
    const day = await rpc<any>("fn_pos_settlement_preview", { p_branch: BRANCH, p_account: d.bank.id, p_date: today() });
    const terminal = day.system_total_halalas - 500;
    await expect(rpc("fn_pos_settle", { p: { branch_id: BRANCH, account_id: d.bank.id, business_date: today(), terminal_total_halalas: terminal, version: day.settlement?.version } })).rejects.toThrow(/note_required/);
    const s = await rpc<any>("fn_pos_settle", { p: { branch_id: BRANCH, account_id: d.bank.id, business_date: today(), terminal_total_halalas: terminal, note: "عملية أُلغيت في الجهاز", version: day.settlement?.version } });
    expect(s.settlement).toMatchObject({ status: "difference", difference_halalas: -500, note: "عملية أُلغيت في الجهاز" });
    const audit = (await client.from("audit_events").select("action").eq("entity_id", s.settlement.id)).data as any[];
    expect(audit.some((a) => a.action === "pos.settled")).toBe(true);
  });

  it("MC11b housekeeping cannot see the settlement; a day that has not come yet cannot be settled", async () => {
    const d = await defaults(BRANCH);
    await expect(rpc("fn_pos_settle", { p: { branch_id: BRANCH, account_id: d.bank.id, business_date: tomorrow(), terminal_total_halalas: 0 } })).rejects.toThrow(/business_date/);
    await expect(rpc("fn_pos_settle", { p: { branch_id: BRANCH, account_id: d.cash.id, business_date: today(), terminal_total_halalas: 0 } })).rejects.toThrow(/BRANCH_MISMATCH/);
    await login("housekeeping@demo.sa");
    await expect(rpc("fn_pos_settlement_preview", { p_branch: BRANCH, p_account: d.bank.id, p_date: today() })).rejects.toThrow(/FORBIDDEN/);
  });

  it("MC12 finance matches the platform's deposit against its deferred payments; a difference needs its reason", async () => {
    const r = await createRes({ ci: 70, co: 73 });
    const v1 = await voucher(r.id, { method: "ota_deferred", amount_halalas: 30000 });
    const v2 = await voucher(r.id, { method: "ota_deferred", amount_halalas: 20000 });
    const v3 = await refund(r.id, { method: "ota_deferred", amount_halalas: 5000 });
    const ids = [v1.voucher_id, v2.voucher_id, v3.voucher_id];
    const source = ((await client.from("reservations").select("source_id").eq("id", r.id).maybeSingle()).data as any).source_id;
    await login("finance@demo.sa");
    const open = await rpc<any[]>("fn_platform_unsettled", { p_branch: BRANCH });
    expect(open.filter((x) => ids.includes(x.id)).reduce((s, x) => s + x.signed_halalas, 0)).toBe(45000);
    const base = { branch_id: BRANCH, source_id: source, voucher_ids: ids, received_on: today(), reference: "PAYOUT-7001" };
    await expect(rpc("fn_platform_payout_confirm", { p: { ...base, received_halalas: 40000 } })).rejects.toThrow(/note_required/);
    await expect(rpc("fn_platform_payout_confirm", { p: { ...base, received_halalas: 45000, reference: "" } })).rejects.toThrow(/reference_required/);
    await expect(rpc("fn_platform_payout_confirm", { p: { ...base, received_halalas: 45000, received_on: tomorrow() } })).rejects.toThrow(/received_on/);
    const ok = await rpc<any>("fn_platform_payout_confirm", { p: { ...base, received_halalas: 40000, note: "عمولة المنصة" } });
    expect(ok.payout).toMatchObject({ expected_halalas: 45000, received_halalas: 40000, difference_halalas: -5000, voucher_count: 3 });
    for (const id of ids) expect((await vrow(id)).payout_id).toBe(ok.payout.id);
    expect((await rpc<any[]>("fn_platform_unsettled", { p_branch: BRANCH })).some((x) => ids.includes(x.id))).toBe(false);
    await expect(rpc("fn_platform_payout_confirm", { p: { ...base, received_halalas: 45000 } })).rejects.toThrow(/payout_vouchers/);   // a payment is matched once
  });

  it("MC12b only the owner or manager cancels a payout; the payments return to the unmatched list and the payout stays as cancelled", async () => {
    const r = await createRes({ ci: 74, co: 75 });
    const v = await voucher(r.id, { method: "ota_deferred", amount_halalas: 15000 });
    const source = ((await client.from("reservations").select("source_id").eq("id", r.id).maybeSingle()).data as any).source_id;
    await login("finance@demo.sa");
    const p = await rpc<any>("fn_platform_payout_confirm", { p: { branch_id: BRANCH, source_id: source, voucher_ids: [v.voucher_id], received_halalas: 15000, received_on: today(), reference: "PAYOUT-7401" } });
    await expect(rpc("fn_platform_payout_cancel", { p_payout: p.payout.id, p_reason: "خطأ" })).rejects.toThrow(/FORBIDDEN/);
    await login("manager@demo.sa");
    await rpc("fn_platform_payout_cancel", { p_payout: p.payout.id, p_reason: "إيداع آخر" });
    expect((await vrow(v.voucher_id)).payout_id).toBeNull();
    expect(((await client.from("platform_payouts").select("status").eq("id", p.payout.id).maybeSingle()).data as any).status).toBe("cancelled");
    expect((await rpc<any[]>("fn_platform_unsettled", { p_branch: BRANCH })).some((x) => x.id === v.voucher_id)).toBe(true);
  });

  it("MC13a the tax policy is the owner's alone; the manager keeps the other settings; the change is audited", async () => {
    const b = (await client.from("branches").select("id, name_ar, version").eq("id", BRANCH).maybeSingle()).data as any;
    await login("manager@demo.sa");
    await expect(rpc("fn_admin_upsert_branch", { p: { id: BRANCH, name_ar: b.name_ar, tax_rate_bp: 1500, version: b.version } })).rejects.toThrow(/FORBIDDEN/);
    const m = await rpc<any>("fn_admin_upsert_branch", { p: { id: BRANCH, name_ar: b.name_ar, default_deposit_halalas: 7500, version: b.version } });
    await login("owner@demo.sa");
    await rpc("fn_admin_upsert_branch", { p: { id: BRANCH, name_ar: b.name_ar, tax_rate_bp: 1500, version: m.version } });
    const after = (await client.from("branches").select("tax_rate_bp, default_deposit_halalas").eq("id", BRANCH).maybeSingle()).data as any;
    expect(after).toMatchObject({ tax_rate_bp: 1500, default_deposit_halalas: 7500 });
    const audit = (await client.from("audit_events").select("action").eq("entity_id", BRANCH)).data as any[];
    expect(audit.some((a) => a.action === "branch.tax_changed")).toBe(true);
    await expect(rpc("fn_admin_upsert_branch", { p: { id: BRANCH, name_ar: b.name_ar, tax_rate_bp: 10001, version: m.version + 1 } })).rejects.toThrow(/tax_rate/);
  });

  it("MC13b a new branch starts at zero tax, a 50.00 deposit, a cash box and a bank account", async () => {
    const nb = await rpc<any>("fn_admin_upsert_branch", { p: { name_ar: "فرع جديد للضريبة" } });
    const row = (await client.from("branches").select("tax_rate_bp, prices_include_tax, default_deposit_halalas").eq("id", nb.id).maybeSingle()).data as any;
    expect(row).toMatchObject({ tax_rate_bp: 0, prices_include_tax: false, default_deposit_halalas: 5000 });
    expect((await accountsOf(nb.id)).length).toBe(2);
  });

  it("X07 money in halalas: 300.05 is 30005; 100.01 then 200.04 leaves exactly zero; a 50.00 deposit does not change the charges", async () => {
    const r = await rpc<any>("fn_staff_create_reservation", { p: { branch_id: BRANCH, category_id: CATEGORY, source_id: SOURCE, check_in: fut(80), check_out: fut(81), guest_name: "ضيف الهللات", guest_phone: "0500000000", adults: 1, companions: 0, nightly_rate_halalas: 30005 } });
    const f0 = await rpc<any>("fn_reservation_finance", { p_reservation: r.id });
    expect(f0).toMatchObject({ total: 30005, tax: 0 });
    await voucher(r.id, { amount_halalas: 10001 });
    await voucher(r.id, { method: "pos", reference: "TRX-8001", amount_halalas: 20004 });
    await voucher(r.id, { kind: "deposit", amount_halalas: 5000 });
    const f = await rpc<any>("fn_reservation_finance", { p_reservation: r.id });
    expect(f).toMatchObject({ total: 30005, balance_due: 0, payment_status: "paid", deposit_balance: 5000 });
  });

  it("X07b a tax set later taxes new reservations only; a reservation keeps the rate it was made with, even for later charges", async () => {
    const svc = ((await client.from("service_definitions").select("id, price_halalas, taxable, billing_unit").eq("branch_id", BRANCH).eq("billing_unit", "once")).data as any[]).find((s) => s.taxable)!;
    const b = (await client.from("branches").select("name_ar, version").eq("id", BRANCH).maybeSingle()).data as any;
    const before = await createRes({ ci: 82, co: 84 });
    const b1 = await rpc<any>("fn_admin_upsert_branch", { p: { id: BRANCH, name_ar: b.name_ar, tax_rate_bp: 1500, prices_include_tax: false, version: b.version } });
    const during = await createRes({ ci: 85, co: 87 });
    const fd = await rpc<any>("fn_reservation_finance", { p_reservation: during.id });
    expect(fd.tax).toBe(Math.round(fd.rent * 0.15));
    expect((await rpc<any>("fn_reservation_finance", { p_reservation: before.id })).tax).toBe(0);
    await rpc("fn_admin_upsert_branch", { p: { id: BRANCH, name_ar: b.name_ar, tax_rate_bp: 0, version: b1.version } });
    await rpc("fn_staff_add_service", { p_reservation: during.id, p_service: svc.id, p_quantity: 1, p_note: null });
    await rpc("fn_staff_add_service", { p_reservation: before.id, p_service: svc.id, p_quantity: 1, p_note: null });
    expect((await rpc<any>("fn_reservation_finance", { p_reservation: during.id })).tax - fd.tax).toBe(Math.round(svc.price_halalas * 0.15));
    expect((await rpc<any>("fn_reservation_finance", { p_reservation: before.id })).tax).toBe(0);
  });

  it("F09 an amount that is zero, negative, a fraction of a halala or not a number is refused", async () => {
    const r = await createRes({ ci: 88, co: 89 });
    for (const amount of [0, -100, 10.5, "12.50", "abc", "", null, 1e16, "1e3"]) {
      await expect(voucher(r.id, { amount_halalas: amount }), String(amount)).rejects.toThrow(/VALIDATION: amount/);
      await expect(refund(r.id, { amount_halalas: amount }), String(amount)).rejects.toThrow(/VALIDATION: amount/);
    }
    const d = await defaults(BRANCH);
    await expect(rpc("fn_pos_settle", { p: { branch_id: BRANCH, account_id: d.bank.id, business_date: today(), terminal_total_halalas: "1.5" } })).rejects.toThrow(/VALIDATION: amount/);
  });
});

describe("G01/G03 — who may change the booking platforms (0029, §16)", () => {
  it("T30 every staff member reads the platforms; only the owner or a manager changes one", async () => {
    const src = ((await client.from("booking_sources").select("id, booking_url").limit(1).maybeSingle()).data as any);
    for (const email of ["housekeeping@demo.sa", "reception@demo.sa", "finance@demo.sa"]) {
      await login(email);
      expect(((await client.from("booking_sources").select("id")).data as any[]).length, email).toBeGreaterThan(0);
      const upd = await client.from("booking_sources").update({ booking_url: "https://elsewhere.test" }).eq("id", src.id).select("id");
      expect((upd.data as any[]).length, email).toBe(0);
      const ins = await client.from("booking_sources").insert({ name: "منصة دخيلة" });
      expect(ins.error?.code, email).toBe("42501");
    }
    await login("manager@demo.sa");
    const ok = await client.from("booking_sources").update({ booking_url: "https://example.test/book" }).eq("id", src.id).select("id, booking_url");
    expect((ok.data as any[])[0]).toMatchObject({ id: src.id, booking_url: "https://example.test/book" });
  });
});

// The demo facet of tests/sql/rates_tests.sql (0030): same codes, same scenarios.
describe("G06/G14/G27 — rates (decisions 9, 15, 32, 33, 47)", () => {
  const D = 200;   // far from the seeded calendar (the next 60 days)
  let CAT: string; let PLATFORM: string;
  const day = (n: number) => fut(n);
  const q = (from: number, to: number, extra: Record<string, unknown> = {}) => rpc<any>("fn_quote_stay", { p: { branch_id: BRANCH, category_id: CAT, check_in: day(from), check_out: day(to), source_id: SOURCE, ...extra } });
  const setRates = (p: Record<string, unknown>) => rpc<any>("fn_rate_calendar_set", { p: { branch_id: BRANCH, ...p } });
  const make = (from: number, to: number, extra: Record<string, unknown> = {}) => rpc<any>("fn_staff_create_reservation", { p: { branch_id: BRANCH, category_id: CAT, check_in: day(from), check_out: day(to), guest_name: "ضيف الأسعار", guest_phone: "0500000001", source_id: SOURCE, adults: 1, companions: 0, ...extra } });
  const nights = async (id: string) => ((await rpc<any[]>("fn_reservation_nights", { p_reservation: id })) ?? []).filter((x) => x.status === "active").map((x) => `${x.price}:${x.basis}`).join(",");
  const version = async (id: string) => ((await client.from("reservations").select("version").eq("id", id).maybeSingle()).data as any).version;
  const total = async (id: string) => ((await client.from("reservations").select("total_halalas").eq("id", id).maybeSingle()).data as any).total_halalas;

  beforeEach(async () => {
    const c = await rpc<any>("fn_admin_upsert_room_category", { p: { branch_id: BRANCH, name_ar: "نوع الأسعار", base_capacity: 2, max_capacity: 3, base_price_halalas: 20000, weekly_price_halalas: 125000, monthly_price_halalas: 455000, min_nightly_halalas: 15000, price_mode: "by_channel" } });
    CAT = c.id;
    await rpc("fn_admin_upsert_room", { p: { branch_id: BRANCH, category_id: CAT, room_number: "PR-1" } });
    await rpc("fn_admin_upsert_room", { p: { branch_id: BRANCH, category_id: CAT, room_number: "PR-2" } });
    PLATFORM = (((await client.from("booking_sources").select("id, kind").eq("is_active", true)).data as any[]).find((s) => s.kind !== "direct")).id;
  });

  it("PR01 a night without a calendar price takes the base price; a calendar price replaces it for that night only", async () => {
    await setRates({ price_halalas: 25000, cells: [{ category_id: CAT, night: day(D + 1) }] });
    const x = await q(D, D + 3);
    expect(x.rent_gross).toBe(65000);
    expect(x.runs.map((r: any) => r.basis)).toEqual(["base", "calendar", "base"]);
    expect(x).toMatchObject({ basis: "daily", channel: "system" });
  });

  it("PR02 a platform booking of a type priced by channel takes the platform row; the reception takes the system row", async () => {
    await setRates({ price_halalas: 25000, cells: [{ category_id: CAT, night: day(D + 1) }] });
    await setRates({ platform_price_halalas: 22000, from: day(D), to: day(D + 2), category_ids: [CAT] });
    expect((await q(D, D + 3, { source_id: PLATFORM })).rent_gross).toBe(66000);
    expect((await q(D, D + 3)).rent_gross).toBe(65000);
  });

  it("PR03 7+ nights take the weekly price and 30+ the monthly, spread with the remainder on the last night; the stay keeps its prices", async () => {
    const w = await q(D + 10, D + 17);
    expect(w).toMatchObject({ basis: "weekly", rent_gross: 125000 });
    expect(w.runs.map((r: any) => [r.nights, r.price])).toEqual([[6, 17857], [1, 17858]]);
    const m = await q(D + 100, D + 130);
    expect(m).toMatchObject({ basis: "monthly", rent_gross: 455000 });
    expect(m.runs.map((r: any) => r.price)).toEqual([15166, 15186]);
    const r = await make(D + 10, D + 17);
    await setRates({ price_halalas: 40000, cells: [{ category_id: CAT, night: day(D + 12) }] });
    expect(await nights(r.id)).toBe("17857:weekly,17857:weekly,17857:weekly,17857:weekly,17857:weekly,17857:weekly,17858:weekly");
    expect(await total(r.id)).toBe(125000);
  });

  it("PR04 no price under the minimum, no past night, only the owner or a manager; each edit is audited with what it replaced", async () => {
    await expect(setRates({ price_halalas: 14000, cells: [{ category_id: CAT, night: day(D + 5) }] })).rejects.toThrow(/below_minimum/);
    await expect(setRates({ price_halalas: 30000, cells: [{ category_id: CAT, night: fut(-2) }] })).rejects.toThrow(/past_night/);
    await setRates({ price_halalas: 30000, cells: [{ category_id: CAT, night: day(D + 5) }] });
    await setRates({ price_halalas: 31000, cells: [{ category_id: CAT, night: day(D + 5) }] });
    const edits = (await client.from("audit_events").select("action, details, created_at").eq("action", "rates.updated")).data as any[];
    const a = edits[0];   // the demo keeps the newest audit row first (both edits may share a millisecond)
    expect(a.details.before.cells[0].price).toBe(30000);
    expect(a.details.after.price_halalas).toBe(31000);
    await login("reception@demo.sa");
    await expect(setRates({ price_halalas: 30000, cells: [{ category_id: CAT, night: day(D + 5) }] })).rejects.toThrow(/FORBIDDEN/);
    await expect(rpc("fn_rate_calendar", { p_branch: BRANCH, p_from: day(D), p_to: day(D + 3) })).rejects.toThrow(/FORBIDDEN/);
  });

  it("PR05 a group edit (from–to × types × weekdays) sets exactly the matching nights; clearing returns them to the base price", async () => {
    const r = await setRates({ price_halalas: 30000, from: day(D + 40), to: day(D + 53), weekdays: [5, 6], category_ids: [CAT] });
    const expected = Array.from({ length: 14 }, (_, i) => new Date(day(D + 40 + i) + "T00:00:00Z").getUTCDay()).filter((d) => d === 5 || d === 6).length;
    expect(r.changed).toBe(expected);
    const cleared = await setRates({ clear: true, from: day(D + 40), to: day(D + 53), category_ids: [CAT] });
    expect(cleared.changed).toBe(expected);
    expect((await q(D + 40, D + 42)).rent_gross).toBe(40000);
  });

  it("PR06 the supervisor discounts with a reason within the percentage and the minimum; the manager goes beyond", async () => {
    await login("reception@demo.sa");
    expect((await q(D + 60, D + 63)).discount_max).toBe(6000);
    const ok = await make(D + 60, D + 63, { discount_halalas: 6000, discount_reason: "ضيف دائم" });
    await expect(make(D + 60, D + 63, { discount_halalas: 6001, discount_reason: "أكثر" })).rejects.toThrow(/discount_percent/);
    await expect(make(D + 60, D + 63, { discount_halalas: 1000 })).rejects.toThrow(/discount_reason/);
    await expect(make(D + 60, D + 63, { nightly_rate_halalas: 19000 })).rejects.toThrow(/FORBIDDEN/);
    await expect(rpc("fn_staff_adjust_price", { p_reservation: ok.id, p_kind: "discount", p_amount_halalas: 100, p_description: "خصم", p_reason: "إضافي", p_expected_version: await version(ok.id) })).rejects.toThrow(/discount_percent/);
    await login("owner@demo.sa");
    const b = (await client.from("branches").select("name_ar, version").eq("id", BRANCH).maybeSingle()).data as any;
    await rpc("fn_admin_upsert_branch", { p: { id: BRANCH, name_ar: b.name_ar, version: b.version, supervisor_max_discount_bp: 5000 } });
    await login("reception@demo.sa");
    expect((await q(D + 64, D + 67)).discount_max).toBe(15000);
    await expect(make(D + 64, D + 67, { discount_halalas: 20000, discount_reason: "كثير" })).rejects.toThrow(/discount_minimum/);
    await login("manager@demo.sa");
    const big = await make(D + 64, D + 67, { discount_halalas: 20000, discount_reason: "تعويض" });
    expect(await total(big.id)).toBe(40000);
  });

  it("PR07 shortening refunds exactly the removed nights' prices; extending keeps the last night's price or takes the calendar's", async () => {
    await setRates({ price_halalas: 25000, cells: [{ category_id: CAT, night: day(D + 71) }] });
    await setRates({ price_halalas: 26000, cells: [{ category_id: CAT, night: day(D + 75) }] });
    await login("reception@demo.sa");
    const r = await make(D + 70, D + 73);
    expect(await total(r.id)).toBe(65000);
    await rpc("fn_staff_amend_stay", { p_reservation: r.id, p_new_check_out: day(D + 72), p_pricing_mode: "keep_rate", p_reason: "خروج مبكر", p_expected_version: await version(r.id) });
    expect(await total(r.id)).toBe(45000);
    await rpc("fn_staff_amend_stay", { p_reservation: r.id, p_new_check_out: day(D + 75), p_pricing_mode: "keep_rate", p_reason: "تمديد", p_expected_version: await version(r.id) });
    expect(await total(r.id)).toBe(120000);
    await rpc("fn_staff_amend_stay", { p_reservation: r.id, p_new_check_out: day(D + 77), p_pricing_mode: "reprice", p_reason: "تمديد بسعر التقويم", p_expected_version: await version(r.id) });
    expect(await total(r.id)).toBe(166000);
    expect(await nights(r.id)).toBe("20000:base,25000:calendar,25000:kept,25000:kept,25000:kept,26000:calendar,20000:base");
  });

  it("PR07b shortening a weekly stay is the manager's; the refund is its removed nights at their weekly prices", async () => {
    const r = await make(D + 10, D + 17);
    await login("reception@demo.sa");
    await expect(rpc("fn_staff_amend_stay", { p_reservation: r.id, p_new_check_out: day(D + 14), p_pricing_mode: "keep_rate", p_reason: "خروج مبكر", p_expected_version: await version(r.id) })).rejects.toThrow(/FORBIDDEN/);
    await login("manager@demo.sa");
    await rpc("fn_staff_amend_stay", { p_reservation: r.id, p_new_check_out: day(D + 14), p_pricing_mode: "keep_rate", p_reason: "خروج مبكر بقرار المدير", p_expected_version: await version(r.id) });
    expect(125000 - (await total(r.id))).toBe(17857 * 2 + 17858);
  });

  it("PR08 the discount report shows who, how much and why; the supervisor gets the totals only", async () => {
    await login("reception@demo.sa");
    const r = await make(D + 60, D + 63, { discount_halalas: 6000, discount_reason: "ضيف دائم" });
    const today = new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Riyadh" });
    const sup = await rpc<any>("fn_reports_discounts", { p_branch: BRANCH, p_from: today, p_to: today });
    expect(sup.rows).toBeNull();
    await login("manager@demo.sa");
    const full = await rpc<any>("fn_reports_discounts", { p_branch: BRANCH, p_from: today, p_to: today });
    expect(full.rows.find((x: any) => x.reservation_id === r.id)).toMatchObject({ amount_halalas: 6000, reason: "ضيف دائم", role: "supervisor" });
    expect(sup.total_halalas).toBe(full.total_halalas);
  });

  it("PR09 lowering a type's capacity lists the upcoming stays that no longer fit; PR10 the calendar shows free units of the total", async () => {
    const rooms = await rpc<Array<{ room_id: string }>>("fn_available_rooms", { p_branch: BRANCH, p_from: day(D + 1), p_to: day(D + 2), p_category: CAT, p_exclude_reservation: null });
    const r = await make(D + 1, D + 2, { adults: 2, companions: 1, room_id: rooms[0].room_id });
    const impact = await rpc<any[]>("fn_category_capacity_impact", { p_category: CAT, p_max_capacity: 2 });
    expect(impact.map((x) => x.id)).toEqual([r.id]);
    const c = (await client.from("room_categories").select("name_ar, version").eq("id", CAT).maybeSingle()).data as any;
    expect((await rpc<any>("fn_admin_upsert_room_category", { p: { id: CAT, name_ar: c.name_ar, version: c.version, max_capacity: 2 } })).stays_over_capacity).toBe(1);
    const cal = await rpc<any>("fn_rate_calendar", { p_branch: BRANCH, p_from: day(D), p_to: day(D + 2) });
    const row = cal.categories.find((x: any) => x.id === CAT);
    expect(row.units).toBe(2);
    expect(row.days.map((x: any) => x.available)).toEqual([2, 1, 2]);
  });

  it("PR12 a unit type with calendar prices is not removed: the answer lists them and the archive is offered", async () => {
    const c = await rpc<any>("fn_admin_upsert_room_category", { p: { branch_id: BRANCH, name_ar: "نوع بلا حجوزات", base_price_halalas: 18000 } });
    await setRates({ price_halalas: 19000, cells: [{ category_id: c.id, night: day(D + 3) }] });
    const res = await rpc<any>("fn_admin_delete_definition", { p_entity: "room_category", p_id: c.id });
    expect(res).toMatchObject({ ok: false, error: "HAS_DEPENDENCIES" });
    expect(res.dependencies.rate_calendar).toBe(1);
  });
});

describe("G08/G10/G17/G19 — the stay cycle in the demo (0033: decisions 1, 3, 5, 6, 7, 8, 10, 12, 49, 59)", () => {
  const A = "00000000-0000-0000-0000-000000000010";   // the seeded Riyadh branch (its supervisor works there)
  const riyadh = () => new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Riyadh" });
  const day = (n: number) => { const d = new Date(riyadh() + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  let CAT: string; let K1: string; let K2: string; let N1: string; let N2: string; let SVC: string;
  const fails = async (p: Promise<unknown>) => { try { await p; return ""; } catch (e) { return (e as Error).message; } };
  const status = (id: string) => rpc<any>("fn_stay_status", { p_reservation: id });
  const fin = (id: string) => rpc<any>("fn_reservation_finance", { p_reservation: id });
  const row = async (id: string) => (await client.from("reservations").select("*").eq("id", id).maybeSingle()).data as any;
  const book = (room: string | null, from: number, to: number) => rpc<any>("fn_staff_create_reservation", { p: { branch_id: A, category_id: CAT, source_id: SOURCE, check_in: day(from), check_out: day(to), guest_name: "ضيف الإقامة", guest_phone: "0500000000", room_id: room ?? undefined, adults: 1, companions: 0 } });
  /** the guest registers on their page and the supervisor matches the identity; then Shomoos with every guest, and its acceptance */
  const prepare = async (id: string, ref: string, shomoos = true) => {
    const { token } = await rpc<any>("fn_guest_lookup", { p_external_ref: ref, p_phone_last4: "0000" });
    const g = (await rpc<any>("fn_guest_session", { p_token: token })).guests[0];
    await rpc("fn_guest_submit", { p_token: token, p_guest_id: g.id, p_payload: { full_name: "ضيف اختبار الإقامة", identity_type: "national_id", identity_number: "1012345678", nationality: "سعودي", birth_date: "1990-01-01", consent: "true" } });
    await rpc("fn_staff_approve_identity", { p_guest_id: g.id, p_approve: true });
    if (shomoos) {
      await rpc("fn_staff_shomoos", { p: { reservation_id: id, action: "register", reference: "SHM-" + ref.slice(-6), all_guests: true } });
      await rpc("fn_staff_shomoos", { p: { reservation_id: id, action: "accept" } });
    }
    return token as string;
  };
  const arrive = (id: string, rent: number | null, deposit: number | null = 5000, extra: Record<string, unknown> = {}) => rpc<any>("fn_staff_check_in", { p: { reservation_id: id,
    ...(rent ? { rent: { amount_halalas: rent, method: "cash", idempotency_key: uid() } } : {}), ...(deposit ? { deposit: { amount_halalas: deposit, method: "cash", idempotency_key: uid() } } : {}), ...extra } });
  const ready = async (room: string | null, from: number, to: number) => { const r = await book(room, from, to); await prepare(r.id, r.internal_ref); return r.id as string; };
  /** in house with the whole stay paid (or `rent`) and the branch's deposit */
  const inHouse = async (room: string | null, from: number, to: number, rent?: number) => { const id = await ready(room, from, to); const x = await arrive(id, rent ?? 10000 * (to - from)); expect(x.ok).toBe(true); return id; };
  const pay = (id: string, amount: number) => rpc("fn_create_voucher", { p: { reservation_id: id, kind: "receipt", amount_halalas: amount, method: "cash", idempotency_key: uid() } });
  /** test-only: moves a moment back (the real table refuses direct writes; the demo's does not) */
  const backdate = (id: string, col: string, minutes: number) => client.from("reservations").update({ [col]: new Date(Date.now() - minutes * 60_000).toISOString() }).eq("id", id);

  beforeEach(async () => {
    CAT = (await rpc<any>("fn_admin_upsert_room_category", { p: { branch_id: A, name_ar: "نوع الإقامة", base_capacity: 2, max_capacity: 3, base_price_halalas: 10000 } })).id;
    const room = async (n: string) => (await rpc<any>("fn_admin_upsert_room", { p: { branch_id: A, category_id: CAT, room_number: n } })).id as string;
    K1 = await room("SD-K1"); K2 = await room("SD-K2"); N1 = await room("SD-N1"); N2 = await room("SD-N2");
    await rpc("fn_staff_rotate_keybox_code", { p_room: K1, p_new_code: "3141", p_field_tested: true });
    await rpc("fn_staff_rotate_keybox_code", { p_room: K2, p_new_code: "2718", p_field_tested: true });
    SVC = (await rpc<any>("fn_admin_upsert_service", { p: { branch_id: A, name_ar: "مياه إضافية", billing_unit: "once", price_halalas: 500, taxable: true } })).id;
  });

  it("SD01 the arrival waits for Shomoos with every guest and its acceptance, then for the whole first night and the deposit; it records both vouchers, once", async () => {
    const r = await book(K1, 0, 2);
    await prepare(r.id, r.internal_ref, false);
    expect((await arrive(r.id, null, null)).reasons).toContain("لم يُسجَّل النزلاء في شموس");
    expect(await fails(rpc("fn_staff_confirm_gov_registration", { p_reservation: r.id, p_reference: "SHM-1" }))).toBe("VALIDATION: shomoos_all_guests");
    expect(await fails(rpc("fn_staff_shomoos", { p: { reservation_id: r.id, action: "register", reference: "SHM-100", all_guests: false } }))).toBe("VALIDATION: shomoos_all_guests");
    await rpc("fn_staff_shomoos", { p: { reservation_id: r.id, action: "register", reference: "SHM-100", all_guests: true } });
    expect((await arrive(r.id, null, null)).reasons).toContain("لم يُؤكَّد قبول شموس للتسجيل");
    await rpc("fn_staff_shomoos", { p: { reservation_id: r.id, action: "accept" } });
    expect((await arrive(r.id, null, null)).reasons).toEqual(["الليلة الأولى غير مدفوعة كاملة: المتبقي 100.00 ر.س", "التأمين لم يُستلم كاملًا: المطلوب 50.00 ر.س"]);
    // part of the first night is not the first night — and a refused arrival records nothing
    expect((await arrive(r.id, 9999, 5000)).reasons).toEqual(["الليلة الأولى غير مدفوعة كاملة: المتبقي 0.01 ر.س"]);
    expect((await fin(r.id)).net_collected).toBe(0);
    expect(await arrive(r.id, 10000, 5000)).toMatchObject({ ok: true, duplicate: false, has_keybox: true });
    expect(await fin(r.id)).toMatchObject({ net_collected: 10000, deposit_balance: 5000, balance_due: 10000 });
    const v = (await client.from("financial_vouchers").select("kind, amount_halalas").eq("reservation_id", r.id)).data as any[];
    expect(v.map((y) => `${y.kind}:${y.amount_halalas}`).sort()).toEqual(["deposit:5000", "receipt:10000"]);
    const res = await row(r.id);
    expect(res).toMatchObject({ status: "checked_in", access_status: "approved", keybox_delivered: false });
    expect(res.checked_in_by).toBeTruthy();
    expect((await arrive(r.id, null, null)).duplicate).toBe(true);
    const s = await status(r.id);
    expect(s.shomoos).toMatchObject({ registered: true, reference: "SHM-100", guest_count: 1, guests_now: 1 });
    expect(s.shomoos.accepted_at).toBeTruthy();
  });

  it("SD02 a deposit not taken needs its reason, kept with who and when; part of it is not the deposit", async () => {
    const id = await ready(N1, 0, 1);
    expect((await arrive(id, 10000, 2000)).reasons).toEqual(["التأمين لم يُستلم كاملًا: المطلوب 50.00 ر.س"]);
    expect((await arrive(id, 10000, null, { deposit_reason: "ضيف معروف للمنشأة" })).ok).toBe(true);
    const s = await status(id);
    expect(s.deposit_waiver).toMatchObject({ reason: "ضيف معروف للمنشأة" });
    expect(s.deposit_waiver.by).toBeTruthy();
    expect(s).toMatchObject({ has_keybox: false, access_status: "key_handed", keybox_state: "none" });
  });

  it("SD03 the code comes after the arrival, once, for a unit with a key box — and is the guest's own on their page; a unit without a box takes its key at reception", async () => {
    const r = await book(K1, 0, 2); const token = await prepare(r.id, r.internal_ref);
    const ev = (await rpc<any[]>("fn_evaluate_access", { p_reservation: r.id }))[0];
    expect(ev.allowed).toBe(false);
    expect(ev.reasons).toContain("يُسجَّل الوصول في الاستقبال ثم يُسلَّم الرمز");
    expect((await rpc<any>("fn_staff_deliver_access_code", { p_reservation: r.id, p_channel: "supervisor" })).reasons).toEqual(["لم يُسجَّل الوصول بعد"]);
    expect((await rpc<any>("fn_guest_access_code", { p_token: token })).allowed).toBe(false);
    expect((await rpc<any>("fn_guest_session", { p_token: token })).reservation).toMatchObject({ has_keybox: true, first_night_paid: false });
    await arrive(r.id, 20000);
    expect(await rpc<any>("fn_staff_deliver_access_code", { p_reservation: r.id, p_channel: "supervisor" })).toEqual({ ok: true, code: "3141" });
    expect((await rpc<any>("fn_staff_deliver_access_code", { p_reservation: r.id, p_channel: "screen" })).reasons).toEqual(["تم تسليم الرمز مسبقًا لهذا الحجز"]);
    expect(await rpc<any>("fn_guest_access_code", { p_token: token })).toMatchObject({ allowed: true, code: "3141" });
    expect((await row(r.id)).access_status).toBe("acknowledged");
    const n = await inHouse(N1, 0, 1);
    expect((await row(n)).access_status).toBe("key_handed");
    expect((await rpc<any>("fn_staff_deliver_access_code", { p_reservation: n, p_channel: "screen" })).reasons).toEqual(["الوحدة بلا صندوق مفتاح؛ يُسلَّم مفتاحها يدويًا"]);
  });

  it("SD04 night by night: a night unpaid past its deadline stops extending and services until it is paid or a reason excuses it", async () => {
    const id = await ready(N1, -2, 1);
    expect((await arrive(id, 10000)).ok).toBe(true);   // the first night only
    let s = await status(id);
    expect(s.due).toMatchObject({ nights: 3, nights_covered: 1, overdue: true });
    expect(s.due.overdue_amount).toBeGreaterThanOrEqual(10000);
    expect(s.overdue_blocked).toBe(true);
    expect(await fails(rpc("fn_staff_amend_stay", { p_reservation: id, p_new_check_out: day(2), p_pricing_mode: "keep_rate", p_reason: "تمديد", p_expected_version: (await row(id)).version }))).toMatch(/^PAYMENT_OVERDUE/);
    expect(await fails(rpc("fn_staff_add_service", { p_reservation: id, p_service: SVC }))).toMatch(/^PAYMENT_OVERDUE/);
    expect((await rpc<any>("fn_stay_followups", { p_branch: A })).overdue.find((x: any) => x.id === id)).toMatchObject({ excused: false });
    expect(await fails(rpc("fn_staff_payment_exception", { p: { reservation_id: id, reason: " " } }))).toBe("VALIDATION: reason");
    await rpc("fn_staff_payment_exception", { p: { reservation_id: id, reason: "وعد بالسداد مساءً" } });
    expect((await rpc<any>("fn_stay_followups", { p_branch: A })).overdue.find((x: any) => x.id === id)).toMatchObject({ excused: true });
    s = await status(id);
    expect(s).toMatchObject({ overdue_blocked: false, payment_exception: { reason: "وعد بالسداد مساءً" } });
    await rpc("fn_staff_add_service", { p_reservation: id, p_service: SVC });
    await pay(id, (await fin(id)).balance_due);
    expect((await status(id)).due.overdue).toBe(false);
    expect((await rpc<any>("fn_staff_amend_stay", { p_reservation: id, p_new_check_out: day(2), p_pricing_mode: "keep_rate", p_reason: "تمديد بعد السداد", p_expected_version: (await row(id)).version })).ok).toBe(true);
  });

  it("SD05 the departure only with nothing owed, for anyone — the override is gone; a held deposit keeps the stay «غادر»", async () => {
    const id = await inHouse(K1, 0, 2, 10000);   // one night of two paid
    const out = await rpc<any>("fn_staff_check_out", { p: { reservation_id: id } });
    expect(out).toMatchObject({ ok: false, balance_due: 10000 });
    expect(out.reasons[0]).toContain("على الحجز مبلغ مستحق 100.00 ر.س");
    expect((await rpc<any>("fn_staff_checkout", { p_reservation: id, p_override_reason: "بقرار المالك" })).ok).toBe(false);
    await pay(id, 10000);
    const ok = await rpc<any>("fn_staff_check_out", { p: { reservation_id: id } });
    expect(ok).toMatchObject({ ok: true, status: "checked_out", deposit_to_settle_halalas: 5000 });
    expect(ok.missing).toContain("تأمين لم يُسوَّ 50.00 ر.س");
    expect((await client.from("rooms").select("status, cleanliness").eq("id", K1).maybeSingle()).data).toMatchObject({ status: "cleaning", cleanliness: "dirty" });
    expect((await rpc<any>("fn_stay_followups", { p_branch: A })).departed_open.some((x: any) => x.id === id)).toBe(true);
    expect((await rpc<any>("fn_staff_check_out", { p: { reservation_id: id } })).duplicate).toBe(true);
  });

  it("SD06 the deposit goes back after the departure and its inspection — the supervisor may return it; the departure invoiced the stay, so the refund closes it, and cancelling its invoice reopens «غادر»", async () => {
    const id = await inHouse(N1, 0, 1);
    const refund = () => rpc("fn_refund", { p: { reservation_id: id, kind: "deposit_refund", amount_halalas: 5000, method: "cash", reason: "إرجاع التأمين", idempotency_key: uid() } });
    await login("reception@demo.sa");
    expect(await fails(refund())).toBe("VALIDATION: deposit_refund_before_checkout");
    await rpc("fn_staff_check_out", { p: { reservation_id: id } });
    expect(await fails(refund())).toMatch(/^INSPECTION_REQUIRED/);
    expect((await status(id)).deposit_refund_blocker).toBe("سجّل فحص المغادرة أولًا");
    expect(await fails(rpc("fn_staff_record_inspection", { p: { reservation_id: id, result: "notes" } }))).toBe("VALIDATION: inspection_notes");
    await login("finance@demo.sa");
    expect(await fails(rpc("fn_staff_record_inspection", { p: { reservation_id: id, result: "ok" } }))).toMatch(/^FORBIDDEN/);
    await login("housekeeping@demo.sa");
    await rpc("fn_staff_record_inspection", { p: { reservation_id: id, result: "ok" } });
    await login("reception@demo.sa");
    await refund();
    // the departure invoiced everything (decision 27), so the deposit back is the last thing: «مغلق» by itself
    const closed = await row(id);
    expect(closed.status).toBe("closed");
    expect(closed.closed_at).toBeTruthy();
    await login("owner@demo.sa");
    const inv = ((await client.from("invoices").select("id, origin").eq("reservation_id", id)).data as any[]);
    expect(inv.map((x) => x.origin)).toEqual(["checkout"]);
    await rpc("fn_cancel_invoice", { p_invoice: inv[0].id, p_reason: "خطأ في الاسم" });
    expect((await row(id)).status).toBe("checked_out");
    expect((await rpc<any>("fn_stay_followups", { p_branch: A })).departed_open.find((x: any) => x.id === id).missing).toEqual(["قيمة لم تُفوتر 100.00 ر.س"]);
    await rpc("fn_create_invoice", { p_reservation: id });
    expect((await row(id)).status).toBe("closed");
    const acts = ((await client.from("audit_events").select("action").eq("entity_id", id)).data as any[]).map((a) => a.action);
    expect(acts).toEqual(expect.arrayContaining(["reservation.checked_in", "reservation.checked_out", "reservation.inspected", "reservation.closed", "reservation.unclosed"]));
  });

  it("SD07 a damage charge carries its reason and comes off the deposit as far as it goes; the same key is one charge", async () => {
    const id = await inHouse(N1, 0, 1);
    await rpc("fn_staff_check_out", { p: { reservation_id: id } });
    await login("reception@demo.sa");
    expect(await fails(rpc("fn_staff_add_damage", { p: { reservation_id: id, amount_halalas: 3000, reason: "", idempotency_key: "dmg" } }))).toBe("VALIDATION: reason");
    const d = await rpc<any>("fn_staff_add_damage", { p: { reservation_id: id, amount_halalas: 3000, description: "كوب مكسور", reason: "كسر أثناء الإقامة", idempotency_key: "dmg" } });
    expect(d).toMatchObject({ ok: true, duplicate: false, from_deposit_halalas: 3000 });
    expect(d.finance).toMatchObject({ deposit_balance: 2000, balance_due: 0, penalties: 3000 });
    expect((await rpc<any>("fn_staff_add_damage", { p: { reservation_id: id, amount_halalas: 3000, reason: "كسر أثناء الإقامة", idempotency_key: "dmg" } })).duplicate).toBe(true);
    const lines = (await client.from("reservation_charges").select("kind, purpose, reason").eq("reservation_id", id)).data as any[];
    expect(lines.filter((c) => c.purpose === "damage")).toEqual([{ kind: "penalty", purpose: "damage", reason: "كسر أثناء الإقامة" }]);
  });

  it("SD08 undoing an arrival is the owner's or a manager's, with a reason, within 30 minutes; a code already shown must change; it waits in the owner's review list", async () => {
    const id = await inHouse(K1, 0, 2);
    await rpc("fn_staff_deliver_access_code", { p_reservation: id, p_channel: "screen" });
    await login("reception@demo.sa");
    expect(await fails(rpc("fn_staff_undo_check_in", { p: { reservation_id: id, reason: "خطأ" } }))).toMatch(/^FORBIDDEN/);
    await login("manager@demo.sa");
    expect(await fails(rpc("fn_staff_undo_check_in", { p: { reservation_id: id, reason: " " } }))).toBe("VALIDATION: reason");
    expect(await rpc<any>("fn_staff_undo_check_in", { p: { reservation_id: id, reason: "سُجّل الوصول للحجز الخطأ" } })).toEqual({ ok: true, code_needs_change: true });
    expect(await row(id)).toMatchObject({ status: "confirmed", access_status: "locked" });
    expect((await arrive(id, null, null)).ok).toBe(true);   // the first arrival's money is still there
    expect((await rpc<any>("fn_staff_deliver_access_code", { p_reservation: id, p_channel: "screen" })).reasons).toEqual(["رمز الصندوق يحتاج إلى تغيير"]);
    await backdate(id, "actual_check_in", 31);
    expect(await fails(rpc("fn_staff_undo_check_in", { p: { reservation_id: id, reason: "متأخر" } }))).toMatch(/^CORRECTION_WINDOW_PASSED/);
    expect((await client.from("review_items").select("id")).data).toEqual([]);   // the owner's list only
    await login("owner@demo.sa");
    expect((await client.from("review_items").select("kind, reason").eq("reservation_id", id)).data).toEqual([{ kind: "check_in_undone", reason: "سُجّل الوصول للحجز الخطأ" }]);
  });

  it("SD09 a departure reopens within 2 hours (its cleaning cancelled, an unchanged code still the guest's); a cancellation comes back within the hour unless its unit was taken", async () => {
    const id = await inHouse(K1, 0, 2);
    await rpc("fn_staff_deliver_access_code", { p_reservation: id, p_channel: "screen" });
    await rpc("fn_staff_check_out", { p: { reservation_id: id } });
    await rpc("fn_staff_record_inspection", { p: { reservation_id: id, result: "ok" } });
    expect(await rpc<any>("fn_staff_reopen_stay", { p: { reservation_id: id, reason: "سُجّلت المغادرة قبل موعدها" } })).toEqual({ ok: true, access_status: "delivered" });
    expect((await row(id)).status).toBe("checked_in");
    expect(((await client.from("housekeeping_tasks").select("status").eq("reservation_id", id)).data as any[]).map((x) => x.status)).toEqual(["cancelled"]);
    expect((await status(id)).inspection).toBeNull();
    const c = await book(K2, 3, 5);
    await rpc("fn_staff_cancel_reservation", { p_reservation: c.id, p_reason: "طلب الضيف" });
    expect(await rpc<any>("fn_staff_undo_cancel", { p: { reservation_id: c.id, reason: "تراجع الضيف" } })).toEqual({ ok: true, status: "confirmed" });
    expect((await client.from("reservation_allocations").select("status").eq("reservation_id", c.id)).data).toEqual([{ status: "active" }]);
    await rpc("fn_staff_cancel_reservation", { p_reservation: c.id, p_reason: "طلب الضيف مرة أخرى" });
    await book(K2, 4, 6);
    expect(await fails(rpc("fn_staff_undo_cancel", { p: { reservation_id: c.id, reason: "تراجع" } }))).toMatch(/^ALLOCATION_CONFLICT/);
    await backdate(c.id, "cancelled_at", 61);
    expect(await fails(rpc("fn_staff_undo_cancel", { p: { reservation_id: c.id, reason: "تراجع" } }))).toMatch(/^CORRECTION_WINDOW_PASSED/);
  });

  it("SD10 late check-out is a priced service that moves the departure to its hour: after the branch's check-out time, billed once", async () => {
    const svc = (p: Record<string, unknown>) => rpc<any>("fn_admin_upsert_service", { p: { branch_id: A, name_ar: "مغادرة متأخرة اختبار", price_halalas: 3000, ...p } });
    expect(await fails(svc({ billing_unit: "once", late_checkout_until: "11:00" }))).toBe("VALIDATION: late_checkout_until");
    expect(await fails(svc({ billing_unit: "night", late_checkout_until: "15:00" }))).toBe("VALIDATION: late_checkout_unit");
    const late = await svc({ billing_unit: "once", late_checkout_until: "15:00" });
    const id = await inHouse(N1, 0, 1);
    expect((await rpc<any>("fn_staff_add_service", { p_reservation: id, p_service: late.id })).late_checkout_until).toBe("15:00");
    expect((await status(id)).departure_time).toBe("15:00");
    const lines = (await client.from("reservation_charges").select("purpose, total_halalas").eq("reservation_id", id)).data as any[];
    expect(lines.filter((c) => c.purpose === "late_checkout")).toEqual([{ purpose: "late_checkout", total_halalas: 3000 }]);
  });

  it("SD11 readiness: a unit without a key box is ready when clean, one with a box also needs a new tested code; a manual cleanliness change is free and recorded", async () => {
    const n = await inHouse(N1, 0, 1); await rpc("fn_staff_check_out", { p: { reservation_id: n } });
    const k = await inHouse(K1, 0, 1); await rpc("fn_staff_check_out", { p: { reservation_id: k } });
    const task = async (room: string) => ((await client.from("housekeeping_tasks").select("id, status, version").eq("room_id", room)).data as any[]).find((t) => t.status === "pending");
    await login("reception@demo.sa");
    expect((await rpc<any>("fn_hk_set_cleanliness", { p_room: N1, p_state: "clean", p_reason: "نُظّفت قبل فتح المهمة" })).room_status).toBe("ready");
    const t = await task(N1);
    expect(t.status).toBe("pending");   // the task keeps its own state
    const a = ((await client.from("audit_events").select("action, entity_id, details").eq("action", "room.cleanliness_changed")).data as any[]).find((e) => e.entity_id === N1);
    expect(a.details.after).toMatchObject({ cleanliness: "clean", open_cleaning_task: true });
    expect((await rpc<any>("fn_hk_complete_task", { p_task: t.id, p_expected_version: t.version })).room_status).toBe("ready");
    const tk = await task(K1);
    expect((await rpc<any>("fn_hk_complete_task", { p_task: tk.id, p_expected_version: tk.version })).room_status).toBe("cleaning");
    await rpc("fn_staff_rotate_keybox_code", { p_room: K1, p_new_code: "5926", p_field_tested: true });
    expect((await client.from("rooms").select("status").eq("id", K1).maybeSingle()).data).toEqual({ status: "ready" });
  });

  it("SD12 a unit with a guest in house is not deactivated or archived; a type with an open stay is not archived, even before a unit; an archived type takes no booking", async () => {
    await inHouse(N1, 0, 1);
    const v = ((await client.from("rooms").select("version").eq("id", N1).maybeSingle()).data as any).version;
    expect(await fails(rpc("fn_admin_upsert_room", { p: { id: N1, version: v, is_active: false } }))).toMatch(/^ROOM_HAS_GUEST/);
    expect(await fails(rpc("fn_admin_archive_definition", { p_entity: "room", p_id: N1, p_reason: "صيانة", p_archive: true }))).toMatch(/^ROOM_HAS_GUEST/);
    const c2 = (await rpc<any>("fn_admin_upsert_room_category", { p: { branch_id: A, name_ar: "نوع بلا وحدات", base_price_halalas: 9000 } })).id;
    const mk = (from: number) => rpc<any>("fn_staff_create_reservation", { p: { branch_id: A, category_id: c2, source_id: SOURCE, check_in: day(from), check_out: day(from + 1), guest_name: "ضيف بلا وحدة", guest_phone: "0500000000", adults: 1, companions: 0 } });
    const r = await mk(3);
    expect(await fails(rpc("fn_admin_archive_definition", { p_entity: "room_category", p_id: c2, p_reason: "إيقاف", p_archive: true }))).toMatch(/^HAS_OPEN_COMMITMENTS/);
    await rpc("fn_staff_cancel_reservation", { p_reservation: r.id, p_reason: "إلغاء" });
    expect((await rpc<any>("fn_admin_archive_definition", { p_entity: "room_category", p_id: c2, p_reason: "إيقاف", p_archive: true })).ok).toBe(true);
    expect(await fails(mk(5))).toMatch(/^CATEGORY_ARCHIVED/);
  });

  it("SD13 moving in house: to a unit without a box its key is handed; to one with a box its code is delivered as its own step", async () => {
    const id = await inHouse(K1, 0, 2);
    await rpc("fn_staff_deliver_access_code", { p_reservation: id, p_channel: "screen" });
    const sw = async (room: string) => rpc<any>("fn_staff_switch_room", { p_reservation: id, p_room: room, p_effective: null, p_reason: "طلب الضيف", p_expected_version: (await row(id)).version });
    expect(await sw(N2)).toMatchObject({ ok: true, code_delivery_required: false });
    expect((await row(id)).access_status).toBe("key_handed");
    expect(await sw(K2)).toMatchObject({ ok: true, code_delivery_required: true });
    expect((await row(id)).access_status).toBe("approved");
    expect(((await client.from("keyboxes").select("last_reservation_id").eq("room_id", K2)).data as any[])[0].last_reservation_id).toBeNull();
    expect((await rpc<any>("fn_staff_deliver_access_code", { p_reservation: id, p_channel: "supervisor" })).code).toBe("2718");
  });

  it("SD14 the seeded stays tell the story: overdue nights, departures not closed, a late departure, the closed history, an arrival waiting for its deposit, the annex's key", async () => {
    const fu = await rpc<any>("fn_stay_followups", { p_branch: A });
    expect(fu.overdue.map((x: any) => x.room_number)).toEqual(expect.arrayContaining(["101", "201"]));
    expect(fu.departed_open.map((x: any) => x.room_number).sort()).toEqual(["103", "202", "206"]);
    expect(fu.late_departures.map((x: any) => x.room_number)).toContain("204");
    const all = (await client.from("reservations").select("id, status, room_id, access_status").eq("branch_id", A)).data as any[];
    expect(all.filter((r) => r.status === "closed")).toHaveLength(6);
    const rooms = (await client.from("rooms").select("id, room_number").eq("branch_id", A)).data as any[];
    const unit = (n: string) => rooms.find((r) => r.room_number === n)!.id;
    const s = await status(all.find((r) => r.room_id === unit("203") && r.status === "confirmed").id);
    expect(s.checkin.blockers).toEqual([]);
    expect(s.checkin.money_blockers).toEqual(["التأمين لم يُستلم كاملًا: المطلوب 50.00 ر.س"]);
    expect(all.find((r) => r.room_id === unit("U-2") && r.status === "checked_in").access_status).toBe("key_handed");
    expect((await client.from("rooms").select("status").eq("id", unit("U-3")).maybeSingle()).data).toEqual({ status: "ready" });
  });

  it("SD15 the day per employee: what each received and paid back, by method; a supervisor sees their own only", async () => {
    const own = await book(N2, 0, 1);
    await pay(own.id, 4000);
    await login("reception@demo.sa");
    const id = await ready(N1, 0, 1);
    await arrive(id, 10000);
    const mine = await rpc<any>("fn_staff_day_summary", { p_branch: A, p_date: day(0) });
    expect(mine.everyone).toBe(false);
    expect(new Set(mine.rows.map((x: any) => x.staff_id))).toEqual(new Set(["00000000-0000-0000-0000-000000000002"]));
    expect(mine.rows).toEqual(expect.arrayContaining([expect.objectContaining({ kind: "receipt", method: "cash", count: 1, total: 10000 }), expect.objectContaining({ kind: "deposit", method: "cash", count: 1, total: 5000 })]));
    await login("owner@demo.sa");
    const all = await rpc<any>("fn_staff_day_summary", { p_branch: A, p_date: day(0) });
    expect(all.everyone).toBe(true);
    expect(all.rows).toEqual(expect.arrayContaining([expect.objectContaining({ staff_id: "00000000-0000-0000-0000-000000000001", kind: "receipt", method: "cash", total: 4000 })]));
    await login("housekeeping@demo.sa");
    expect(await fails(rpc("fn_staff_day_summary", { p_branch: A, p_date: day(0) }))).toMatch(/^FORBIDDEN/);
  });

  it("SD16 finance and housekeeping register no arrival, departure, Shomoos, damage, code, overdue reason or correction", async () => {
    const id = await ready(K1, 0, 2);
    const calls: Array<[string, Record<string, unknown>]> = [
      ["fn_staff_check_in", { p: { reservation_id: id } }], ["fn_staff_check_out", { p: { reservation_id: id } }], ["fn_staff_shomoos", { p: { reservation_id: id, action: "accept" } }],
      ["fn_staff_add_damage", { p: { reservation_id: id, amount_halalas: 100, reason: "x", idempotency_key: uid() } }], ["fn_staff_deliver_access_code", { p_reservation: id, p_channel: "screen" }],
      ["fn_staff_payment_exception", { p: { reservation_id: id, reason: "x" } }], ["fn_staff_undo_check_in", { p: { reservation_id: id, reason: "x" } }], ["fn_staff_reopen_stay", { p: { reservation_id: id, reason: "x" } }],
    ];
    for (const who of ["finance@demo.sa", "housekeeping@demo.sa"]) {
      await login(who);
      for (const [fn, args] of calls) expect(await fails(rpc(fn, args)), `${who} ${fn}`).toMatch(/^FORBIDDEN/);
    }
  });
});

describe("G10/G13/G14/G15/G22 — invoices, voucher correction and the review list in the demo (0036–0037: decisions 11, 26, 27, 54)", () => {
  const A = "00000000-0000-0000-0000-000000000010";   // the seeded Riyadh branch (its supervisor works there)
  const riyadh = () => new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Riyadh" });
  const day = (n: number) => { const d = new Date(riyadh() + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  let CAT: string; let U: string[]; let SVC: string;
  const fails = async (p: Promise<unknown>) => { try { await p; return ""; } catch (e) { return (e as Error).message; } };
  const get = async (table: string, id: string) => (await client.from(table).select("*").eq("id", id).maybeSingle()).data as any;
  const fin = (id: string) => rpc<any>("fn_reservation_finance", { p_reservation: id });
  const detail = (id: string) => rpc<any>("fn_reservation_detail", { p_reservation: id });
  const uninvoiced = async (id: string) => (await detail(id)).invoicing.uninvoiced_halalas as number;
  const share = (inv: any, kind: string) => (inv.snapshot.lines as any[]).filter((l) => l.kind === kind).reduce((a, l) => a + l.amount_halalas, 0);
  const book = (room: string, from: number, to: number, name = "ضيف الفواتير") => rpc<any>("fn_staff_create_reservation", { p: { branch_id: A, category_id: CAT, source_id: SOURCE, check_in: day(from), check_out: day(to), guest_name: name, guest_phone: "0500000000", room_id: room, adults: 1, companions: 0 } });
  const version = async (id: string) => (await get("reservations", id)).version as number;
  const adjust = async (id: string, kind: string, amount: number, reason: string) => rpc("fn_staff_adjust_price", { p_reservation: id, p_kind: kind, p_amount_halalas: amount, p_description: kind === "discount" ? "خصم" : "تسوية", p_reason: reason, p_expected_version: await version(id) });
  const issue = (id: string, from?: number, to?: number, extra: Record<string, unknown> = {}) => rpc<any>("fn_staff_issue_invoice", { p: { reservation_id: id, ...(from != null ? { from: day(from), to: day(to!) } : {}), ...extra } });
  const invoicesOf = async (id: string) => ((await client.from("invoices").select("*").eq("reservation_id", id)).data as any[]).sort((a, b) => (a.issued_at < b.issued_at ? -1 : 1));
  /** in house today with the whole stay paid and the branch's deposit (the guest registered, Shomoos accepted) */
  const inHouse = async (room: string, nights: number) => {
    const r = await book(room, 0, nights, "ضيف المغادرة");
    const { token } = await rpc<any>("fn_guest_lookup", { p_external_ref: r.internal_ref, p_phone_last4: "0000" });
    const g = (await rpc<any>("fn_guest_session", { p_token: token })).guests[0];
    await rpc("fn_guest_submit", { p_token: token, p_guest_id: g.id, p_payload: { full_name: "ضيف اختبار الفواتير", identity_type: "national_id", identity_number: "1012345678", nationality: "سعودي", birth_date: "1990-01-01", consent: "true" } });
    await rpc("fn_staff_approve_identity", { p_guest_id: g.id, p_approve: true });
    await rpc("fn_staff_shomoos", { p: { reservation_id: r.id, action: "register", reference: "SHM-" + r.internal_ref.slice(-6), all_guests: true } });
    await rpc("fn_staff_shomoos", { p: { reservation_id: r.id, action: "accept" } });
    const x = await rpc<any>("fn_staff_check_in", { p: { reservation_id: r.id, rent: { amount_halalas: 10000 * nights, method: "cash", idempotency_key: uid() }, deposit: { amount_halalas: 5000, method: "cash", idempotency_key: uid() } } });
    expect(x.ok).toBe(true);
    return r.id as string;
  };
  const receipt = (id: string, amount: number, extra: Record<string, unknown> = {}) => rpc<any>("fn_create_voucher", { p: { reservation_id: id, kind: "receipt", amount_halalas: amount, method: "cash", idempotency_key: uid(), ...extra } });
  const correct = (voucher: string, p: Record<string, unknown>) => rpc<any>("fn_staff_correct_voucher", { p: { voucher_id: voucher, idempotency_key: uid(), ...p } });

  beforeEach(async () => {
    CAT = (await rpc<any>("fn_admin_upsert_room_category", { p: { branch_id: A, name_ar: "نوع الفواتير", base_capacity: 2, max_capacity: 3, base_price_halalas: 10000 } })).id;
    U = [];
    for (const n of ["IV-1", "IV-2", "IV-3", "IV-4", "IV-5", "IV-6"]) U.push((await rpc<any>("fn_admin_upsert_room", { p: { branch_id: A, category_id: CAT, room_number: n } })).id);
    SVC = (await rpc<any>("fn_admin_upsert_service", { p: { branch_id: A, name_ar: "غسيل ملابس", billing_unit: "once", price_halalas: 1500, taxable: true } })).id;
  });

  it("ID01 a partial invoice carries its period's nights at their saved price and the discount in the same proportion; periods add up to the stay, to the halala", async () => {
    const r = await book(U[0], 20, 24);
    await adjust(r.id, "discount", 4000, "عميل دائم");
    const a = await issue(r.id, 20, 22), b = await issue(r.id, 22, 24);
    const [ia, ib] = [await get("invoices", a.id), await get("invoices", b.id)];
    expect(a).toMatchObject({ ok: true, scope: "period", total_halalas: 18000, period_from: day(20), period_to: day(22) });
    expect([share(ia, "rent"), share(ia, "discount"), b.total_halalas]).toEqual([20000, -2000, 18000]);
    expect(a.total_halalas + b.total_halalas).toBe((await fin(r.id)).total);
    expect(await uninvoiced(r.id)).toBe(0);
    expect(((await client.from("reservation_charges").select("invoice_id").eq("reservation_id", r.id)).data as any[]).every((c) => c.invoice_id === ib.id)).toBe(true);   // completed by the last
    // a 10.00 discount over three nights: -3.33, -3.34, -3.33 — cumulative shares lose no halala
    const t = await book(U[1], 30, 33);
    await adjust(t.id, "discount", 1000, "تقريب");
    const parts = [];
    for (const n of [30, 31, 32]) parts.push(share(await get("invoices", (await issue(t.id, n, n + 1)).id), "discount"));
    expect(parts).toEqual([-333, -334, -333]);
    expect(await uninvoiced(t.id)).toBe(0);
  });

  it("ID02 two period invoices of a stay never overlap; nothing left is NOTHING_TO_INVOICE, never an empty invoice", async () => {
    const r = await book(U[0], 20, 24);
    await issue(r.id, 20, 22);
    expect(await fails(issue(r.id, 21, 23))).toMatch(/^INVOICE_PERIOD_OVERLAP/);
    expect(await fails(issue(r.id, 22, 22))).toBe("VALIDATION: period");
    await issue(r.id, 22, 24);
    expect(await fails(issue(r.id))).toBe("NOTHING_TO_INVOICE");
    expect((await invoicesOf(r.id)).length).toBe(2);
  });

  it("ID03 the preview shows what «إنشاء» would issue and writes nothing; a one-off line goes with its day; no period is the rest of the stay", async () => {
    const r = await book(U[2], 40, 43, "ضيف المعاينة");
    await rpc("fn_staff_add_service", { p_reservation: r.id, p_service: SVC, p_quantity: 1 });
    const before = (await client.from("invoices").select("id")).data!.length;
    const pv = await rpc<any>("fn_invoice_preview", { p: { reservation_id: r.id, from: day(40), to: day(42) } });
    expect(pv).toMatchObject({ ok: true, problems: [], scope: "period", total_halalas: 20000, reservation: { guest: "ضيف المعاينة", internal_ref: r.internal_ref } });
    expect((await client.from("invoices").select("id")).data!.length).toBe(before);
    // the service was added today, outside the period: it waits for the invoice of its day, or the rest of the stay
    const i = await issue(r.id, 40, 42);
    expect([i.total_halalas, share(await get("invoices", i.id), "addon"), await uninvoiced(r.id)]).toEqual([20000, 0, 11500]);
    expect((await rpc<any>("fn_invoice_preview", { p: { reservation_id: r.id, from: day(41), to: day(43) } })).problems).toEqual(["فاتورة أخرى لهذا الحجز تغطي جزءًا من الفترة"]);
    const rest = await issue(r.id);
    expect(rest).toMatchObject({ scope: "remaining", total_halalas: 11500 });
    expect(await uninvoiced(r.id)).toBe(0);
    expect((await rpc<any>("fn_invoice_preview", { p: { reservation_id: r.id } })).problems).toEqual(["لا شيء لم يُفوتر في هذه الفترة"]);
  });

  it("ID04 a discount follows the period's share of the rent, not of the nights; a tax line records its line and goes with it", async () => {
    const r = await book(U[3], 50, 52);
    await client.from("reservation_nights").update({ price_halalas: 30000 }).eq("reservation_id", r.id).eq("night", day(51));   // test-only: a dearer second night
    await adjust(r.id, "discount", 2000, "نسبة");
    expect(share(await get("invoices", (await issue(r.id, 50, 51)).id), "discount")).toBe(-500);   // a quarter of the rent, a quarter of the discount
    const t = await book(U[4], 60, 62);
    await client.from("reservations").update({ tax_rate_bp: 1500, prices_include_tax: false }).eq("id", t.id);   // test-only: 15% on this stay
    await adjust(t.id, "discount", 2000, "ضريبة");
    const tax = ((await client.from("reservation_charges").select("*").eq("reservation_id", t.id)).data as any[]).find((c) => c.kind === "tax");
    expect((await get("reservation_charges", tax.base_charge_id)).kind).toBe("discount");
    const inv = await get("invoices", (await issue(t.id, 60, 61)).id);
    expect([share(inv, "discount"), share(inv, "tax")]).toEqual([-1000, -150]);
  });

  it("ID05 the departure invoices everything not yet invoiced in the same operation; a damage after it is invoiced when the deposit is settled; paid, the stay closes by itself", async () => {
    const id = await inHouse(U[5], 2);
    await rpc("fn_staff_add_service", { p_reservation: id, p_service: SVC, p_quantity: 1 });
    await receipt(id, 1500);
    const out = await rpc<any>("fn_staff_check_out", { p: { reservation_id: id } });
    let inv = await invoicesOf(id);
    expect(out).toMatchObject({ ok: true, status: "checked_out", invoice: inv[0].number });
    expect(inv[0]).toMatchObject({ origin: "checkout", scope: "remaining", total_halalas: 21500 });
    expect(await uninvoiced(id)).toBe(0);
    expect(out.missing).toEqual(["تأمين لم يُسوَّ 50.00 ر.س"]);
    // after the departure: a damage of 70.00 from a 50.00 deposit, 20.00 still owed; the deposit is gone, so it is invoiced at once
    await rpc("fn_staff_record_inspection", { p: { reservation_id: id, result: "notes", notes: "كسر", suggested_deduction_halalas: 7000 } });
    const d = await rpc<any>("fn_staff_add_damage", { p: { reservation_id: id, amount_halalas: 7000, reason: "كسر الطاولة", idempotency_key: uid() } });
    inv = await invoicesOf(id);
    expect(inv.map((x) => [x.origin, x.total_halalas])).toEqual([["checkout", 21500], ["deposit_settled", 7000]]);
    expect(d.invoice).toBe(inv[1].number);
    expect([await uninvoiced(id), (await fin(id)).balance_due]).toEqual([0, 2000]);
    await receipt(id, 2000);
    expect((await get("reservations", id)).status).toBe("closed");
    // the reservation page: each line's invoiced share, each invoice's origin and version, and nothing left
    const dt = await detail(id);
    expect(dt.charges.filter((c: any) => c.total_halalas !== 0).every((c: any) => c.invoiced_halalas === c.total_halalas)).toBe(true);
    expect(dt.invoices.map((x: any) => [x.origin, x.version, x.lines.length > 0])).toEqual([["checkout", 1, true], ["deposit_settled", 1, true]]);
  });

  it("ID06 an edit with its reason changes the bill-to and keeps the version before; it waits in the owner's review list; an edit that changes nothing writes nothing", async () => {
    const r = await book(U[0], 20, 22);
    const i = await issue(r.id, 20, 22);
    await login("reception@demo.sa");
    const e = await rpc<any>("fn_staff_edit_invoice", { p: { invoice_id: i.id, reason: "اسم الشركة على الفاتورة", bill_to: { name: "شركة الاختبار", note: "مرجع 77" } } });
    const inv = await get("invoices", i.id);
    expect(e).toMatchObject({ ok: true, unchanged: false, version: 2 });
    expect(inv.bill_to).toEqual({ name: "شركة الاختبار", note: "مرجع 77" });
    expect(inv.snapshot.bill_to.name).toBe("شركة الاختبار");
    expect(inv.versions).toHaveLength(1);
    expect(inv.versions[0]).toMatchObject({ version: 1, total_halalas: 20000, reason: "اسم الشركة على الفاتورة", bill_to: { name: "ضيف الفواتير" } });
    expect((await rpc<any>("fn_staff_edit_invoice", { p: { invoice_id: i.id, reason: "لا شيء", bill_to: { name: "شركة الاختبار", note: "مرجع 77" } } })).unchanged).toBe(true);
    expect(await fails(rpc("fn_staff_edit_invoice", { p: { invoice_id: i.id, reason: "بلا اسم", bill_to: { name: " " } } }))).toBe("VALIDATION: bill_to_name");
    expect(await fails(rpc("fn_staff_edit_invoice", { p: { invoice_id: i.id } }))).toBe("VALIDATION: reason");
    await login("owner@demo.sa");
    const items = (await rpc<any>("fn_review_list", { p: { kind: "invoice_edited" } })).items.filter((x: any) => x.entity_id === i.id);
    expect(items).toHaveLength(1);
    expect(items[0]).toMatchObject({ summary: `تعديل الفاتورة ${i.number} (الإصدار 2)`, reason: "اسم الشركة على الفاتورة", internal_ref: r.internal_ref });
    expect(((await client.from("audit_events").select("action").eq("entity_id", i.id)).data as any[]).map((x) => x.action)).toContain("invoice.edited");
  });

  it("ID07 a lower stay after its invoice: no credit note — only lines that lower it are INVOICE_NOT_POSITIVE, and the edit brings the invoice to the lines", async () => {
    const r = await book(U[1], 70, 72);
    const i = await issue(r.id, 70, 72);
    await adjust(r.id, "adjustment", -2000, "تعويض عن عطل");
    expect(await uninvoiced(r.id)).toBe(-2000);
    expect(await fails(issue(r.id))).toBe("INVOICE_NOT_POSITIVE");
    const e = await rpc<any>("fn_staff_edit_invoice", { p: { invoice_id: i.id, reason: "تضمين التسوية" } });
    expect(e).toMatchObject({ ok: true, total_halalas: 18000 });
    expect(share(await get("invoices", i.id), "adjustment")).toBe(-2000);
    expect(await uninvoiced(r.id)).toBe(0);
  });

  it("ID08 cancelling an invoice is the owner's or a manager's: its shares are free again and it waits in the review list; a period is moved only onto nights no other invoice carries", async () => {
    const r = await book(U[2], 20, 24);
    await adjust(r.id, "discount", 4000, "عميل دائم");
    const a = await issue(r.id, 20, 22), b = await issue(r.id, 22, 24);
    await login("reception@demo.sa");
    expect(await fails(rpc("fn_cancel_invoice", { p_invoice: a.id, p_reason: "خطأ" }))).toMatch(/^FORBIDDEN/);
    expect(await fails(rpc("fn_staff_edit_invoice", { p: { invoice_id: b.id, reason: "فترة", from: day(21) } }))).toMatch(/^INVOICE_PERIOD_OVERLAP/);
    const e = await rpc<any>("fn_staff_edit_invoice", { p: { invoice_id: b.id, reason: "ليلة واحدة", to: day(23) } });
    expect(e).toMatchObject({ total_halalas: 9000, version: 2 });
    expect(await uninvoiced(r.id)).toBe(9000);
    await login("housekeeping@demo.sa");
    expect(await fails(rpc("fn_staff_edit_invoice", { p: { invoice_id: a.id, reason: "x" } }))).toMatch(/^FORBIDDEN/);
    await login("manager@demo.sa");
    await rpc("fn_cancel_invoice", { p_invoice: a.id, p_reason: "أُصدرت بالخطأ" });
    expect(await uninvoiced(r.id)).toBe(9000 + 18000);
    expect(await fails(rpc("fn_staff_edit_invoice", { p: { invoice_id: a.id, reason: "x" } }))).toBe("INVOICE_STATUS_INVALID");
    expect((await issue(r.id, 20, 22)).total_halalas).toBe(18000);
    await login("owner@demo.sa");
    expect((await rpc<any>("fn_review_list", { p: { kind: "invoice_cancelled" } })).items.map((x: any) => x.entity_id)).toEqual([a.id]);
  });

  it("ID09 «تصحيح سند»: the supervisor corrects their own voucher within 24 hours — the original cancelled with the reason, the replacement linked, the money follows; again, the same answer", async () => {
    const r = await book(U[3], 90, 92);
    await login("reception@demo.sa");
    const v = await receipt(r.id, 15000);
    const key = uid();
    const c = await rpc<any>("fn_staff_correct_voucher", { p: { voucher_id: v.voucher_id, reason: "المبلغ المقبوض 120 لا 150", amount_halalas: 12000, idempotency_key: key } });
    const [o, n] = [await get("financial_vouchers", v.voucher_id), await get("financial_vouchers", c.voucher_id)];
    expect(c).toMatchObject({ ok: true, duplicate: false, original_number: v.number });
    expect(o).toMatchObject({ status: "cancelled", cancel_reason: "تصحيح: المبلغ المقبوض 120 لا 150" });
    expect(n).toMatchObject({ status: "approved", kind: "receipt", amount_halalas: 12000, original_voucher_id: o.id });
    expect((await fin(r.id)).received).toBe(12000);
    const again = await rpc<any>("fn_staff_correct_voucher", { p: { voucher_id: v.voucher_id, reason: "المبلغ المقبوض 120 لا 150", amount_halalas: 12000, idempotency_key: key } });
    expect(again).toMatchObject({ duplicate: true, voucher_id: n.id });
    expect((await client.from("financial_vouchers").select("id").eq("reservation_id", r.id)).data).toHaveLength(2);
    const dv = (await detail(r.id)).vouchers;
    expect(dv.find((x: any) => x.id === o.id)).toMatchObject({ replaced_by_number: n.number, created_by_name: expect.any(String) });
    expect(dv.find((x: any) => x.id === n.id).original_number).toBe(o.number);
    await login("owner@demo.sa");
    expect((await rpc<any>("fn_review_list", { p: { kind: "voucher_corrected" } })).items[0]).toMatchObject({ entity_id: n.id, reason: "المبلغ المقبوض 120 لا 150", details: { original: o.number, replacement: n.number, issued_by_self: true } });
  });

  it("ID10 the supervisor corrects only the vouchers they issued, and only within 24 hours; then a manager; finance does not correct", async () => {
    const r = await book(U[3], 90, 92);
    const dep = await rpc<any>("fn_create_voucher", { p: { reservation_id: r.id, kind: "deposit", amount_halalas: 5000, method: "cash", idempotency_key: uid() } });   // the owner's
    await login("reception@demo.sa");
    expect(await fails(correct(dep.voucher_id, { reason: "x", amount_halalas: 4000 }))).toBe("FORBIDDEN: a supervisor corrects only the vouchers they issued");
    const v = await receipt(r.id, 12000);
    await client.from("financial_vouchers").update({ created_at: new Date(Date.now() - 25 * 3_600_000).toISOString() }).eq("id", v.voucher_id);   // test-only
    expect(await fails(correct(v.voucher_id, { reason: "x", amount_halalas: 11000 }))).toMatch(/^CORRECTION_WINDOW_PASSED/);
    await login("manager@demo.sa");
    const c = await correct(v.voucher_id, { reason: "تصحيح بعد يوم", amount_halalas: 11000 });
    expect((await fin(r.id)).received).toBe(11000);
    await login("finance@demo.sa");
    expect(await fails(correct(c.voucher_id, { reason: "x", amount_halalas: 10000 }))).toMatch(/^FORBIDDEN/);
  });

  it("ID11 a correction needs its reason and a change, passes the checks of a new voucher (all or nothing), and never leaves more refunded than received", async () => {
    const r = await book(U[4], 95, 97);
    await login("manager@demo.sa");
    const v = await receipt(r.id, 11000);
    expect(await fails(correct(v.voucher_id, { amount_halalas: 10000 }))).toBe("VALIDATION: reason");
    expect(await fails(correct(v.voucher_id, { reason: "لا تغيير" }))).toBe("VALIDATION: nothing_changed");
    expect(await fails(correct(v.voucher_id, { reason: "شبكة", method: "pos" }))).toMatch(/^VALIDATION: reference/);
    expect(await fails(correct(v.voucher_id, { reason: "مدى", method: "mada" }))).toBe("VALIDATION: method_retired");
    expect((await get("financial_vouchers", v.voucher_id)).status).toBe("approved");
    expect((await client.from("financial_vouchers").select("id").eq("reservation_id", r.id)).data).toHaveLength(1);
    // to the terminal with its number: its own account (the bank account), not the cash box
    const pos = await correct(v.voucher_id, { reason: "دُفع بالشبكة", method: "pos", reference: "TRX-5521" });
    expect(await get("financial_vouchers", pos.voucher_id)).toMatchObject({ method: "pos", reference: "TRX-5521", amount_halalas: 11000 });
    expect((await get("cash_accounts", (await get("financial_vouchers", pos.voucher_id)).account_id)).kind).toBe("bank_account");
    // 110.00 received, 100.00 refunded: the receipt down to 50.00 would refund more than was received
    const rf = await rpc<any>("fn_refund", { p: { reservation_id: r.id, kind: "refund", amount_halalas: 10000, method: "cash", reason: "إلغاء ليلة", idempotency_key: uid() } });
    expect(await fails(correct(pos.voucher_id, { reason: "x", amount_halalas: 5000 }))).toBe("CANCEL_WOULD_GO_NEGATIVE");
    expect((await get("financial_vouchers", pos.voucher_id)).status).toBe("approved");
    const c = await correct(rf.voucher_id, { reason: "المبلغ المردود 90", amount_halalas: 9000 });
    expect([(await get("financial_vouchers", c.voucher_id)).kind, (await fin(r.id)).refunded]).toEqual(["refund", 9000]);
  });

  it("ID12 cancelling a voucher waits in the review list too; a voucher in a platform payout is neither cancelled nor corrected", async () => {
    const r = await book(U[5], 95, 96);
    const v = await receipt(r.id, 3000);
    await rpc("fn_cancel_voucher", { p_voucher: v.voucher_id, p_reason: "سند مكرر" });
    expect((await rpc<any>("fn_review_list", { p: { kind: "voucher_cancelled" } })).items[0]).toMatchObject({ entity_id: v.voucher_id, reason: "سند مكرر", summary: `إلغاء السند ${v.number}` });
    const w = await receipt(r.id, 3000, { method: "ota_deferred", reference: "OTA-9" });
    await client.from("financial_vouchers").update({ payout_id: "payout-test" }).eq("id", w.voucher_id);   // test-only: in a confirmed payout
    expect(await fails(rpc("fn_cancel_voucher", { p_voucher: w.voucher_id, p_reason: "x" }))).toBe("VOUCHER_IN_PAYOUT");
    expect(await fails(correct(w.voucher_id, { reason: "x", amount_halalas: 2000 }))).toBe("VOUCHER_IN_PAYOUT");
  });

  it("ID13 the review list is the owner's alone: what waits, with who, when and why; marked, it moves to «تمت مراجعتها» with the note; the banner counts by kind", async () => {
    await login("manager@demo.sa");
    expect(await fails(rpc("fn_review_list", { p: {} }))).toMatch(/^FORBIDDEN/);
    expect(await rpc("fn_review_summary", {})).toBeNull();
    const r = await book(U[0], 95, 96);
    const v = await receipt(r.id, 3000);
    await correct(v.voucher_id, { reason: "المبلغ 25", amount_halalas: 2500 });
    await login("reception@demo.sa");
    expect((await client.from("review_items").select("id")).data).toEqual([]);
    await login("owner@demo.sa");
    const l = await rpc<any>("fn_review_list", { p: {} });
    expect(l.open_count).toBe(2);   // the seeded invoice edit, and this correction
    expect(l.items.map((x: any) => x.kind).sort()).toEqual(["invoice_edited", "voucher_corrected"]);
    expect(l.items.find((x: any) => x.kind === "invoice_edited")).toMatchObject({ created_by: "سلطان مدير الفرع", reason: "طلب الضيف إصدارها باسم جهة عمله", branch_name: expect.any(String) });
    expect(await rpc("fn_review_summary", {})).toMatchObject({ open: 2, monitors: 0, by_kind: { invoice_edited: 1, voucher_corrected: 1 } });
    const ids = l.items.filter((x: any) => x.kind === "voucher_corrected").map((x: any) => x.id);
    expect(await rpc("fn_review_mark", { p: { ids, note: "راجعتها" } })).toEqual({ ok: true, marked: 1 });
    expect((await rpc<any>("fn_review_list", { p: {} })).open_count).toBe(1);
    expect((await rpc<any>("fn_review_list", { p: { status: "reviewed" } })).items[0]).toMatchObject({ review_note: "راجعتها", reviewed_by: expect.any(String) });
    expect(await rpc("fn_review_mark", { p: { ids } })).toEqual({ ok: true, marked: 0 });
    expect(await fails(rpc("fn_review_mark", { p: { ids: null } }))).toBe("VALIDATION: ids");
  });

  it("ID14 the monitors (decision 54): the seeded demo has nothing to report; a stored summary that differs from its ledger, or three refusals of one employee, are each raised once, without personal data", async () => {
    const first = await rpc<any>("fn_monitors_if_due", { p_branch: A });
    expect(first).toMatchObject({ ran: true, found: {} });
    expect((await rpc<any>("fn_monitors_if_due", { p_branch: A })).ran).toBe(false);   // at most every 10 minutes
    const stay = ((await client.from("reservations").select("id, internal_ref, total_halalas").eq("branch_id", A).eq("status", "checked_in")).data as any[])[0];
    await client.from("reservations").update({ total_halalas: stay.total_halalas + 100 }).eq("id", stay.id);   // test-only: an inconsistency
    await login("finance@demo.sa");
    for (let i = 0; i < 3; i++) await rpc("fn_log_client_error", { p_trace: "TRACE00" + i, p_code: "FORBIDDEN", p_context: "fn_cancel_invoice" });
    await login("owner@demo.sa");
    const rewind = () => client.from("monitor_runs").update({ last_run_at: new Date(Date.now() - 11 * 60_000).toISOString() }).eq("branch_id", A);   // test-only
    await rewind();
    const run = await rpc<any>("fn_monitors_if_due", { p_branch: A });
    expect(run).toMatchObject({ ran: true, found: { ledger_mismatch: 1, out_of_scope: 1 }, summary: { monitors: 2 } });
    const items = (await rpc<any>("fn_review_list", { p: { kind: "monitor" } })).items;
    expect(items.map((x: any) => x.kind).sort()).toEqual(["monitor:ledger_mismatch", "monitor:out_of_scope"]);
    expect(items.find((x: any) => x.kind === "monitor:ledger_mismatch")).toMatchObject({ internal_ref: stay.internal_ref, summary: `الملخص المالي للحجز ${stay.internal_ref} يختلف عن الدفتر` });
    expect(items.find((x: any) => x.kind === "monitor:out_of_scope").summary).toBe("نورة المالية: 3 محاولات مرفوضة خارج صلاحياته خلال يوم");
    expect(JSON.stringify(items)).not.toMatch(/05\d{8}|1012345678/);
    await rewind();
    expect((await rpc<any>("fn_monitors_if_due", { p_branch: A })).found).toEqual({});   // not again while it is open
    await login("manager@demo.sa");
    expect(await fails(rpc("fn_monitors_if_due", { p_branch: A }))).toMatch(/^FORBIDDEN/);
  });
});
