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
