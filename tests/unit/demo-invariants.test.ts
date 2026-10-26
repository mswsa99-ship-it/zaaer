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
    const nb = await rpc<any>("fn_admin_upsert_branch", { p: { name_ar: "فرع اختبار المال", name_en: "Money test branch" } });
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
    const nb = await rpc<any>("fn_admin_upsert_branch", { p: { name_ar: "فرع جديد للضريبة", name_en: "Tax test branch" } });
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

describe("G01/G03 — who may change the booking platforms (0029 §16, 0038: decision 22)", () => {
  it("T30 every staff member reads the platforms; nobody writes the table; only the owner or a manager switches one on or off, with an audit row", async () => {
    const src = ((await client.from("booking_sources").select("id, code, is_active").eq("code", "agoda").maybeSingle()).data as any);
    for (const email of ["housekeeping@demo.sa", "reception@demo.sa", "finance@demo.sa", "manager@demo.sa", "owner@demo.sa"]) {
      await login(email);
      expect(((await client.from("booking_sources").select("id")).data as any[]).length, email).toBe(12);
      const upd = await client.from("booking_sources").update({ is_active: false }).eq("id", src.id).select("id");
      expect((upd.data as any[]).length, email).toBe(0);                       // 0038 revoked the table's writes for everyone
      const ins = await client.from("booking_sources").insert({ name: "منصة دخيلة" });
      expect(ins.error?.code, email).toBe("42501");
    }
    for (const email of ["housekeeping@demo.sa", "reception@demo.sa", "finance@demo.sa"]) {
      await login(email);
      const { error } = await client.rpc("fn_admin_set_source_active", { p: { id: src.id, is_active: false, reason: "اختبار" } });
      expect(error?.message, email).toMatch(/^FORBIDDEN/);
    }
    await login("manager@demo.sa");
    expect(await rpc<any>("fn_admin_set_source_active", { p: { id: src.id, is_active: false, reason: "لا نعمل مع هذه المنصة" } })).toMatchObject({ ok: true, changed: true });
    expect(((await client.from("booking_sources").select("is_active").eq("id", src.id).maybeSingle()).data as any).is_active).toBe(false);
    expect(await rpc<any>("fn_admin_set_source_active", { p: { id: src.id, is_active: false } })).toMatchObject({ ok: true, changed: false });   // already off: nothing to record
    const trail = (await client.from("audit_events").select("action, details").eq("entity_id", src.id)).data as any[];
    expect(trail.filter((a) => a.action === "source.disabled")).toHaveLength(1);
    expect(trail[0].details).toMatchObject({ before: { code: "agoda", is_active: true }, after: { code: "agoda", is_active: false }, reason: "لا نعمل مع هذه المنصة" });
    await login("owner@demo.sa");
    expect(await rpc<any>("fn_admin_set_source_active", { p: { id: src.id, is_active: true } })).toMatchObject({ ok: true, changed: true });
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
    const ack = (await rpc<any>("fn_guest_stay_summary", { p_token: token })).hash;
    await rpc("fn_guest_submit", { p_token: token, p_guest_id: g.id, p_payload: { full_name: "ضيف اختبار الإقامة", identity_type: "national_id", identity_number: "1012345678", nationality: "سعودي", birth_date: "1990-01-01", consent: "true", ack_hash: ack } });
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
    const ack = (await rpc<any>("fn_guest_stay_summary", { p_token: token })).hash;
    await rpc("fn_guest_submit", { p_token: token, p_guest_id: g.id, p_payload: { full_name: "ضيف اختبار الفواتير", identity_type: "national_id", identity_number: "1012345678", nationality: "سعودي", birth_date: "1990-01-01", consent: "true", ack_hash: ack } });
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

// The demo facet of tests/sql/guests_platforms_tests.sql (0038): the same rules, the same refusals.
describe("G01/G02/G03/G19/G22 — guests, platforms and the website in the demo (0038: decisions 2, 4, 19, 21, 22, 23, 31, 69)", () => {
  const A = "00000000-0000-0000-0000-000000000010";   // the seeded Riyadh branch (its supervisor works there)
  const riyadh = () => new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Riyadh" });
  const day = (n: number) => { const d = new Date(riyadh() + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  let CAT: string; let OTA: string; let DIRECT: string;
  const fails = async (p: Promise<unknown>) => { try { await p; return ""; } catch (e) { return (e as Error).message; } };
  const get = async (table: string, id: string) => (await client.from(table).select("*").eq("id", id).maybeSingle()).data as any;
  const fin = (id: string) => rpc<any>("fn_reservation_finance", { p_reservation: id });
  const detail = (id: string) => rpc<any>("fn_reservation_detail", { p_reservation: id });
  const guestsOf = async (id: string) => ((await client.from("reservation_guests").select("*").eq("reservation_id", id)).data as any[]).sort((a, b) => Number(b.is_primary) - Number(a.is_primary));
  const trail = async (entityId: string, action: string) => ((await client.from("audit_events").select("action, details").eq("entity_id", entityId)).data as any[]).filter((a) => a.action === action);
  const review = async (kind: string) => ((await rpc<any>("fn_review_list", { p: { kind, status: "all", limit: 50 } })).items ?? []) as any[];
  /** a booking at the reception (no platform number) */
  const book = (from: number, to: number, extra: Record<string, unknown> = {}) => rpc<any>("fn_staff_create_reservation", { p: { branch_id: A, category_id: CAT, source_id: DIRECT, check_in: day(from), check_out: day(to), guest_name: "ضيف الاختبار الخامس", guest_phone: "0500000000", adults: 1, companions: 0, ...extra } });
  /** a platform's booking: its number, who collects and when it was booked there (decision 4) */
  const ota = (from: number, to: number, ref: string, collects: boolean, extra: Record<string, unknown> = {}) => rpc<any>("fn_staff_create_reservation", { p: { branch_id: A, category_id: CAT, source_id: OTA, check_in: day(from), check_out: day(to), guest_name: "ضيف المنصة", guest_phone: "0500000000", adults: 1, companions: 0, external_ref: ref, platform_collects: collects, platform_booked_on: day(0), ...extra } });
  const doc = (res: string, over: Record<string, unknown> = {}) => ({ reservation_id: res, document_matched: true, full_name: "سعد محمد العتيبي", identity_type: "national_id", identity_number: "1098765432", nationality: "سعودي", birth_date: "1988-05-04", ...over });
  const token = async (ref: string, last4 = "0000") => (await rpc<any>("fn_guest_lookup", { p_external_ref: ref, p_phone_last4: last4 })).token as string;
  const cancel = (id: string, extra: Record<string, unknown> = {}) => rpc<any>("fn_staff_cancel", { p: { reservation_id: id, reason: "ألغاه الضيف على المنصة", ...extra } });

  beforeEach(async () => {
    CAT = (await rpc<any>("fn_admin_upsert_room_category", { p: { branch_id: A, name_ar: "نوع الضيوف", base_capacity: 2, max_capacity: 3, base_price_halalas: 10000 } })).id;
    for (const n of ["GU-1", "GU-2", "GU-3", "GU-4", "GU-5"]) await rpc("fn_admin_upsert_room", { p: { branch_id: A, category_id: CAT, room_number: n } });
    const srcs = (await client.from("booking_sources").select("id, code")).data as any[];
    OTA = srcs.find((s) => s.code === "booking_com").id; DIRECT = srcs.find((s) => s.code === "reception").id;
  });

  it("GU01 the twelve sources of decision 22, each with its kind and whether the platform's number is needed; Booking Engine off", async () => {
    const srcs = (await client.from("booking_sources").select("code, kind, external_reference_required, is_active")).data as any[];
    expect(srcs.map((s) => s.code).sort()).toEqual(["agoda", "airbnb", "airport", "almosafer", "booking_com", "booking_engine", "expedia", "gathern", "hotels_com", "jathr_inn", "reception", "trip_com"]);
    expect(srcs.filter((s) => s.kind === "external")).toHaveLength(10);
    expect(srcs.find((s) => s.code === "airport")).toMatchObject({ kind: "external", external_reference_required: false, is_active: true });
    expect(srcs.find((s) => s.code === "reception")).toMatchObject({ kind: "direct", external_reference_required: false });
    expect(srcs.find((s) => s.code === "booking_engine")).toMatchObject({ kind: "direct", is_active: false });
    expect(srcs.filter((s) => s.kind === "external" && s.code !== "airport").every((s) => s.external_reference_required)).toBe(true);
  });

  it("GU02 the office path (decision 2): «طابقتُ الوثيقة الأصلية» is required; the guest is verified at once with who and when, a profile is linked and the trail is masked", async () => {
    await login("reception@demo.sa");
    const r = await book(10, 12);
    const [pg] = await guestsOf(r.id);
    expect(await fails(rpc("fn_staff_enter_guest", { p: doc(r.id, { guest_id: pg.id, document_matched: false }) }))).toBe("VALIDATION: document_matched");
    expect(await fails(rpc("fn_staff_enter_guest", { p: doc(r.id, { guest_id: pg.id, full_name: "سعد العتيبي" }) }))).toBe("VALIDATION: full_name_three_parts");
    expect(await fails(rpc("fn_staff_enter_guest", { p: doc(r.id, { guest_id: pg.id, identity_number: "3098765432" }) }))).toBe("VALIDATION: identity_number_format");
    const out = await rpc<any>("fn_staff_enter_guest", { p: doc(r.id, { guest_id: pg.id }) });
    expect(out).toMatchObject({ ok: true, guest_id: pg.id, identity_status: "verified" });
    const g = await get("reservation_guests", pg.id);
    expect(g).toMatchObject({ verification_status: "verified", entry_path: "office", identity_number_last4: "5432", full_name: "سعد محمد العتيبي" });
    expect(g.entered_by).toBeTruthy(); expect(g.entered_at).toBeTruthy(); expect(g.verified_by).toBe(g.entered_by); expect(g.verified_at).toBeTruthy();
    expect(g.identity_fingerprint).toMatch(/^fp_sa_/); expect(JSON.stringify(g)).not.toContain("1098765432");   // the number itself is never stored
    expect((await get("guest_profiles", g.guest_profile_id))).toMatchObject({ identity_last4: "5432", identity_type: "national_id" });
    const [a] = await trail(r.id, "guest.entered_from_document");
    expect(a.details.after).toMatchObject({ identity_number: "••••5432", birth_year: 1988, entry_path: "office" });
    expect(JSON.stringify(a.details)).not.toContain("1098765432"); expect(JSON.stringify(a.details)).not.toContain("1988-05-04");
    // the same document twice in one stay is refused; a companion beyond the booking's count too
    expect(await fails(rpc("fn_staff_enter_guest", { p: doc(r.id, { full_name: "مرافق سعد العتيبي" }) }))).toBe("DUPLICATE_GUEST");
    expect(await fails(rpc("fn_staff_enter_guest", { p: doc(r.id, { full_name: "مرافق سعد العتيبي", identity_number: "1011111111" }) }))).toBe("GUEST_LIMIT_REACHED");
    for (const email of ["housekeeping@demo.sa", "finance@demo.sa"]) { await login(email); expect(await fails(rpc("fn_staff_enter_guest", { p: doc(r.id, { guest_id: pg.id }) })), email).toMatch(/^FORBIDDEN/); }
  });

  it("GU03 a correction needs a reason; before and after are masked; it goes to the owner's review list; an empty number keeps the one on file", async () => {
    await login("reception@demo.sa");
    const r = await book(10, 12); const [pg] = await guestsOf(r.id);
    await rpc("fn_staff_enter_guest", { p: doc(r.id, { guest_id: pg.id }) });
    expect(await fails(rpc("fn_staff_enter_guest", { p: doc(r.id, { guest_id: pg.id, birth_date: "1989-05-04" }) }))).toBe("VALIDATION: reason");
    await rpc("fn_staff_enter_guest", { p: doc(r.id, { guest_id: pg.id, birth_date: "1989-05-04", identity_number: "", reason: "خطأ في سنة الميلاد" }) });
    const g = await get("reservation_guests", pg.id);
    expect(g).toMatchObject({ birth_date: "1989-05-04", identity_number_last4: "5432", verification_status: "verified" });
    const [a] = await trail(r.id, "guest.corrected");
    expect(a.details).toMatchObject({ before: { birth_year: 1988, identity_number: "••••5432" }, after: { birth_year: 1989, identity_number: "••••5432" }, reason: "خطأ في سنة الميلاد" });
    expect(await fails(rpc("fn_staff_enter_guest", { p: doc(r.id, { guest_id: pg.id, identity_type: "passport", identity_number: "", reason: "جواز" }) }))).toBe("VALIDATION: identity_number_format");
    await login("owner@demo.sa");
    const items = (await review("guest_corrected")).filter((i) => i.entity_id === pg.id);
    expect(items).toHaveLength(1); expect(items[0].reason).toBe("خطأ في سنة الميلاد"); expect(JSON.stringify(items[0])).not.toContain("1098765432");
  });

  it("GU04 the guest's own entry is the guest path and waits for the supervisor; a second profile with the same document is flagged, never merged; search by name, phone, document and last four", async () => {
    await login("reception@demo.sa");
    const r = await book(10, 12); const [pg] = await guestsOf(r.id);
    const tok = await token(r.internal_ref);
    const ack = (await rpc<any>("fn_guest_stay_summary", { p_token: tok })).hash;
    await rpc("fn_guest_submit", { p_token: tok, p_guest_id: pg.id, p_payload: { full_name: "سعد محمد العتيبي", identity_type: "national_id", identity_number: "1098765432", nationality: "سعودي", birth_date: "1988-05-04", consent: "true", ack_hash: ack } });
    let g = await get("reservation_guests", pg.id);
    expect(g).toMatchObject({ entry_path: "guest", verification_status: "data_submitted", data_submitted: true, identity_number_last4: "5432" });
    expect((await get("reservations", r.id)).identity_status).toBe("pending_supervisor");
    expect(g.identity_fingerprint).toMatch(/^fp_sa_/); expect(JSON.stringify(g)).not.toContain("1098765432");
    await rpc("fn_staff_approve_identity", { p_guest_id: pg.id, p_approve: true });
    g = await get("reservation_guests", pg.id); expect(g.verification_status).toBe("verified"); expect(g.verified_by).toBeTruthy();
    // another booking with another phone and the same document: its own profile, flagged as a duplicate, never merged
    const r2 = await book(20, 22, { guest_phone: "0509999999", guest_name: "سعد م العتيبي" }); const [pg2] = await guestsOf(r2.id);
    await rpc("fn_staff_enter_guest", { p: doc(r2.id, { guest_id: pg2.id }) });
    const g2 = await get("reservation_guests", pg2.id);
    expect(g2.guest_profile_id).not.toBe(g.guest_profile_id);
    const prof = await rpc<any>("fn_guest_profile", { p_id: g2.guest_profile_id });
    expect(prof.duplicates.map((d: any) => d.id)).toContain(g.guest_profile_id); expect(prof.duplicates[0].match).toBe("identity");
    for (const q of ["سعد", "0509999999", "1098765432", "5432"]) expect((await rpc<any>("fn_guest_profiles", { p: { q } })).rows.map((x: any) => x.id), q).toContain(g2.guest_profile_id);
    expect((await rpc<any>("fn_guest_profiles", { p: { filter: "duplicates" } })).rows.map((x: any) => x.id)).toContain(g2.guest_profile_id);
    expect(JSON.stringify(await rpc<any>("fn_guest_profiles", { p: { q: "سعد" } }))).not.toContain("0509999999");   // phones are masked in the list
    // the owner's report of identities approved at the office
    await login("owner@demo.sa");
    const rep = await rpc<any>("fn_reports_identities", { p_branch: A, p_from: day(-1), p_to: day(1), p_path: "office" });
    expect(rep.rows.map((x: any) => x.guest_id)).toContain(pg2.id); expect(rep.rows.map((x: any) => x.guest_id)).not.toContain(pg.id);
    await login("manager@demo.sa");
    expect(await fails(rpc("fn_reports_identities", { p_branch: A, p_from: day(-1), p_to: day(1) }))).toMatch(/^FORBIDDEN/);
  });

  it("GU05 a ban (decision 21): a manager with a reason; the guest's other booking shows the alert and cannot arrive; a new profile with the phone and a companion with the document match; the guest's page says only «يرجى مراجعة الاستقبال»; the owner lifts it with a reason", async () => {
    await login("reception@demo.sa");
    const r = await book(0, 2, { guest_phone: "0507777777" }); const [pg] = await guestsOf(r.id);
    await rpc("fn_staff_enter_guest", { p: doc(r.id, { guest_id: pg.id }) });
    const profile = (await get("reservation_guests", pg.id)).guest_profile_id as string;
    expect(await fails(rpc("fn_guest_ban", { p: { profile_id: profile, ban: true, reason: "إتلاف" } }))).toMatch(/^FORBIDDEN/);
    await login("manager@demo.sa");
    expect(await fails(rpc("fn_guest_ban", { p: { profile_id: profile, ban: true } }))).toBe("VALIDATION: reason");
    const b = await rpc<any>("fn_guest_ban", { p: { profile_id: profile, ban: true, reason: "إتلاف الوحدة في إقامة سابقة" } });
    expect(b).toMatchObject({ ok: true, duplicate: false });
    expect(await rpc<any>("fn_guest_ban", { p: { profile_id: profile, ban: true, reason: "مرة أخرى" } })).toMatchObject({ duplicate: true });
    const d = await detail(r.id);
    expect(d.bans).toHaveLength(1); expect(d.bans[0].matched_by).toEqual(["identity", "phone", "profile"]);
    expect((await rpc<any>("fn_reservation_flags", { p_branch: A }))[r.id]).toMatchObject({ ban: true });
    const arrive = await rpc<any>("fn_staff_check_in", { p: { reservation_id: r.id } });
    expect(arrive.ok).toBe(false); expect(arrive.reasons).toContain("الضيف محظور من الإدارة");
    // the guest's own page masks the reason
    const tok = await token(r.internal_ref, "7777");
    const s = await rpc<any>("fn_guest_session", { p_token: tok });
    expect(s.access.reasons).toContain("يرجى مراجعة الاستقبال"); expect(JSON.stringify(s)).not.toContain("محظور");
    // a new profile with the same phone, and a companion entered with the banned document
    await login("reception@demo.sa");
    const r2 = await book(30, 32, { guest_phone: "0507777777", new_profile: true, companions: 1 });
    expect((await detail(r2.id)).bans[0].matched_by).toEqual(["phone"]);   // a fresh profile: nothing else to match
    const r3 = await book(40, 42, { guest_phone: "0501234567", new_profile: true, companions: 1 });
    expect((await detail(r3.id)).bans).toEqual([]);
    await rpc("fn_staff_enter_guest", { p: doc(r3.id, { full_name: "مرافق سعد العتيبي", relationship: "brother" }) });
    expect((await detail(r3.id)).bans[0].matched_by).toContain("identity");
    // lifting: the owner with a reason; the alert and the block go, the history stays
    await login("owner@demo.sa");
    expect(await fails(rpc("fn_guest_ban", { p: { profile_id: profile, ban: false } }))).toBe("VALIDATION: reason");
    await rpc("fn_guest_ban", { p: { profile_id: profile, ban: false, reason: "سدّد قيمة الأضرار" } });
    expect((await detail(r.id)).bans).toEqual([]); expect((await detail(r3.id)).bans).toEqual([]);
    const p = await rpc<any>("fn_guest_profile", { p_id: profile });
    expect(p.ban).toBeNull(); expect(p.ban_history).toHaveLength(1); expect(p.ban_history[0]).toMatchObject({ lift_reason: "سدّد قيمة الأضرار", reason: "إتلاف الوحدة في إقامة سابقة" });
    expect((await review("guest_banned")).some((i) => i.entity_id === profile)).toBe(true); expect((await review("guest_unbanned")).some((i) => i.entity_id === profile)).toBe(true);
  });

  it("GU06 a rating 1–5 with an internal note by a supervisor, seen on the next booking; housekeeping cannot rate; a hold on one booking blocks the arrival and only a manager lifts it", async () => {
    await login("reception@demo.sa");
    const r = await book(0, 2, { guest_phone: "0506666666" }); const [pg] = await guestsOf(r.id);
    const profile = pg.guest_profile_id as string;
    expect(await fails(rpc("fn_guest_rate", { p: { profile_id: profile, rating: 6 } }))).toBe("VALIDATION: rating");
    expect(await fails(rpc("fn_guest_rate", { p: { profile_id: profile, rating: 0 } }))).toBe("VALIDATION: rating");
    await rpc("fn_guest_rate", { p: { profile_id: profile, rating: 2, note: "يترك الوحدة غير مرتبة" } });
    const r2 = await book(10, 12, { guest_phone: "0506666666" });
    expect((await detail(r2.id)).guest_profile).toMatchObject({ id: profile, rating: 2, rating_note: "يترك الوحدة غير مرتبة" });
    expect((await rpc<any>("fn_reservation_flags", { p_branch: A }))[r2.id]).toMatchObject({ rating: 2 });
    await login("housekeeping@demo.sa");
    expect(await fails(rpc("fn_guest_rate", { p: { profile_id: profile, rating: 5 } }))).toMatch(/^FORBIDDEN/);
    // the hold
    await login("reception@demo.sa");
    expect(await fails(rpc("fn_staff_set_hold", { p: { reservation_id: r.id, hold: true } }))).toBe("VALIDATION: reason");
    await rpc("fn_staff_set_hold", { p: { reservation_id: r.id, hold: true, reason: "بلاغ من الأمن" } });
    expect((await rpc<any>("fn_staff_check_in", { p: { reservation_id: r.id } })).reasons).toContain("يوجد حظر أمني على الحجز");
    expect((await detail(r.id)).hold).toMatchObject({ reason: "بلاغ من الأمن" });
    expect(await fails(rpc("fn_staff_set_hold", { p: { reservation_id: r.id, hold: false, reason: "انتهى" } }))).toMatch(/^FORBIDDEN/);
    await login("manager@demo.sa");
    await rpc("fn_staff_set_hold", { p: { reservation_id: r.id, hold: false, reason: "اتضح أنه بلاغ خاطئ" } });
    expect((await detail(r.id)).hold).toBeNull();
    expect((await trail(r.id, "reservation.hold_lifted"))[0].details.reason).toBe("اتضح أنه بلاغ خاطئ");
    await login("owner@demo.sa");
    expect((await review("security_hold")).some((i) => i.reservation_id === r.id)).toBe(true);
  });

  it("GU07 a platform's booking (decision 4) says who collects and when it was booked there; the platform collecting makes its receipt «آجل عبر المنصات» once; the property collecting makes none", async () => {
    await login("reception@demo.sa");
    expect(await fails(ota(80, 82, "PF-0", true, { platform_collects: undefined }))).toBe("VALIDATION: platform_collects");
    expect(await fails(ota(80, 82, "PF-0", false, { platform_booked_on: undefined }))).toBe("VALIDATION: platform_booked_on");
    expect(await fails(ota(80, 82, "PF-0", false, { platform_booked_on: day(1) }))).toBe("VALIDATION: platform_booked_on");
    expect(await fails(rpc("fn_staff_create_reservation", { p: { branch_id: A, category_id: CAT, source_id: OTA, check_in: day(80), check_out: day(82), guest_name: "بلا رقم", guest_phone: "0500000000", adults: 1, companions: 0, platform_collects: true, platform_booked_on: day(0) } }))).toBe("VALIDATION: external_ref_required");
    const r = await ota(80, 82, "PF-1", true);
    expect(r.platform_voucher).toBeTruthy();
    const f = await fin(r.id); expect(f.total).toBeGreaterThan(0); expect(f.net_collected).toBe(f.total);
    const vs = (await client.from("financial_vouchers").select("*").eq("reservation_id", r.id)).data as any[];
    expect(vs).toHaveLength(1); expect(vs[0]).toMatchObject({ kind: "receipt", method: "ota_deferred", reference: "PF-1", status: "approved" });
    expect(await get("reservations", r.id)).toMatchObject({ payment_status: "paid", platform_collects: true, platform_booked_on: day(0) });
    expect((await detail(r.id)).platform).toMatchObject({ collects: true, booked_on: day(0), verified_at: null });
    const r2 = await ota(83, 85, "PF-2", false);
    expect(r2.platform_voucher ?? null).toBeNull(); expect((await fin(r2.id)).net_collected).toBe(0);
    // a reception booking carries none of it
    const r3 = await book(86, 87);
    expect((await detail(r3.id)).platform).toBeNull();
    expect(await get("reservations", r3.id)).toMatchObject({ platform_collects: null, platform_booked_on: null });
  });

  it("GU08 cancelling by the platform's number, once; nothing is refunded; found by that number; an internal mistake needs only a reason; undoing frees the number for the right booking", async () => {
    await login("reception@demo.sa");
    const r = await ota(80, 82, "PF-1", true);
    expect(await fails(cancel(r.id))).toBe("VALIDATION: cancel_number");
    const c1 = await cancel(r.id, { cancel_number: "CXL-1" });
    expect(c1).toMatchObject({ ok: true, cancelled: 1, platform_collected: true, refund_required_separately: true });
    expect(await cancel(r.id, { cancel_number: "CXL-1" })).toMatchObject({ duplicate: true, cancelled: 0 });
    expect(await get("reservations", r.id)).toMatchObject({ status: "cancelled", cancel_reference: "CXL-1", cancel_source: "platform" });
    expect(((await client.from("financial_vouchers").select("kind").eq("reservation_id", r.id)).data as any[]).filter((v) => v.kind === "refund")).toHaveLength(0);
    expect(await trail(r.id, "reservation.cancelled")).toHaveLength(1);
    expect((await rpc<any>("fn_reservation_list", { p_branch: A, p_filters: { q: "CXL-1" } })).total).toBe(1);
    expect((await client.from("integration_events").select("*").eq("external_event_id", "CXL-1")).data).toEqual([]);   // the platform's events are the owner's and the manager's
    await login("manager@demo.sa");
    const ev = (await client.from("integration_events").select("*").eq("external_event_id", "CXL-1")).data as any[];
    expect(ev).toHaveLength(1); expect(ev[0]).toMatchObject({ source: "platform:booking_com", state: "processed", kind: "reservation.cancelled" });
    await login("reception@demo.sa");
    // entered here by mistake: no platform number, a reason only
    const r2 = await ota(83, 85, "PF-2", false);
    await rpc("fn_staff_cancel", { p: { reservation_id: r2.id, reason: "أُدخل بالخطأ", by_platform: false } });
    expect(await get("reservations", r2.id)).toMatchObject({ status: "cancelled", cancel_source: "staff", cancel_reference: null });
    // undo within the hour frees the number
    const r3 = await ota(86, 87, "PF-3", false);
    await cancel(r3.id, { cancel_number: "CXL-2" });
    await login("manager@demo.sa");
    await rpc("fn_staff_undo_cancel", { p: { reservation_id: r3.id, reason: "ألغيت الحجز الخطأ" } });
    expect(await get("reservations", r3.id)).toMatchObject({ status: "confirmed", cancel_reference: null });
    expect(((await client.from("integration_events").select("state").eq("external_event_id", "CXL-2")).data as any[]).map((e) => e.state)).toEqual(["reverted"]);
    await login("reception@demo.sa");
    const r4 = await ota(88, 89, "PF-4", false);
    expect(await cancel(r4.id, { cancel_number: "CXL-2" })).toMatchObject({ cancelled: 1 });
    expect((await get("reservations", r4.id)).status).toBe("cancelled");
  });

  it("GU09 the daily matching list holds the platforms' arrivals of today and tomorrow; «طابقتُ» keeps who and when; the late-entry report counts the days between the platform's booking and the entry", async () => {
    await login("reception@demo.sa");
    const t0 = await ota(0, 2, "PF-T0", false), t1 = await ota(1, 3, "PF-T1", true), t2 = await ota(2, 4, "PF-T2", false);
    const d0 = await book(0, 2);
    const lst = await rpc<any>("fn_platform_check_list", { p_branch: A, p_date: day(0) });
    const ids = lst.rows.map((x: any) => x.id);
    expect(ids).toContain(t0.id); expect(ids).toContain(t1.id); expect(ids).not.toContain(t2.id); expect(ids).not.toContain(d0.id);
    await rpc("fn_platform_mark_checked", { p: { reservation_id: t0.id } });
    const row = (await rpc<any>("fn_platform_check_list", { p_branch: A, p_date: day(0) })).rows.find((x: any) => x.id === t0.id);
    expect(row.verified_at).toBeTruthy(); expect(row.verified_by).toBe("فهد الاستقبال");
    expect(await fails(rpc("fn_platform_mark_checked", { p: { reservation_id: d0.id } }))).toBe("VALIDATION: not_platform");
    await login("housekeeping@demo.sa");
    expect(await fails(rpc("fn_platform_check_list", { p_branch: A }))).toMatch(/^FORBIDDEN/);
    // late entries: booked on the platform three days ago, entered today
    await login("reception@demo.sa");
    const late = await ota(5, 6, "PF-LATE", false, { platform_booked_on: day(-3) });
    await login("manager@demo.sa");
    const rep = await rpc<any>("fn_reports_late_entries", { p_branch: A, p_from: day(-1), p_to: day(1), p_min_days: 1 });
    expect(rep.rows.find((x: any) => x.id === late.id)).toMatchObject({ lag_days: 3, external_ref: "PF-LATE" });
    expect(rep.rows.every((x: any) => x.lag_days >= 1)).toBe(true);
    expect(rep.platform_bookings).toBeGreaterThanOrEqual(4);
    await login("reception@demo.sa");
    expect(await fails(rpc("fn_reports_late_entries", { p_branch: A, p_from: day(-1), p_to: day(1) }))).toMatch(/^FORBIDDEN/);
  });

  it("GU10 one platform number for a group (decision 69): created whole, every unit carries it; the number on another booking or group is refused; one unit failing creates none; the group's page adds up", async () => {
    await login("reception@demo.sa");
    const g = await ota(100, 102, "GR-1", false, { units: [{ category_id: CAT }, { category_id: CAT }, { category_id: CAT }] });
    expect(g.units).toBe(3); expect(g.group_ref).toBeTruthy();
    const units = (await client.from("reservations").select("id, group_ref, external_ref").eq("external_ref", "GR-1")).data as any[];
    expect(units).toHaveLength(3); expect(new Set(units.map((u) => u.group_ref)).size).toBe(1);
    expect(await fails(ota(110, 111, "GR-1", false))).toBe("DUPLICATE_EXTERNAL_REF");
    expect(await fails(ota(110, 111, "GR-1", false, { units: [{ category_id: CAT }, { category_id: CAT }] }))).toBe("DUPLICATE_EXTERNAL_REF");
    expect(await fails(ota(120, 121, "GR-2", false, { units: [{ category_id: CAT }, { category_id: CAT }, { category_id: CAT, adults: 9 }] }))).toBe("CAPACITY_EXCEEDED");
    expect(((await client.from("reservations").select("id").eq("external_ref", "GR-2")).data as any[])).toHaveLength(0);
    const s = await rpc<any>("fn_reservation_group_summary", { p_reservation: g.id });
    expect(s.units).toHaveLength(3); expect(s.external_ref).toBe("GR-1");
    expect(s.totals.total_halalas).toBe(s.units.reduce((a: number, u: any) => a + u.total_halalas, 0)); expect(s.totals.units).toBe(3);
    // the whole group is cancelled with one platform cancellation number
    const c = await cancel(g.id, { cancel_number: "CXL-GR", whole_group: true });
    expect(c.cancelled).toBe(3);
    expect(((await client.from("reservations").select("status, cancel_reference").eq("external_ref", "GR-1")).data as any[]).every((u) => u.status === "cancelled" && u.cancel_reference === "CXL-GR")).toBe(true);
    expect(await rpc<any>("fn_reservation_group_summary", { p_reservation: (await book(5, 6)).id })).toBeNull();
  });

  it("GU11 «ملخص الإقامة» (decision 19): the stay, its money, the deposit and the public policies in the branch's language; a paper signature with the exact text, once; a printed copy no longer current is refused", async () => {
    await login("owner@demo.sa");
    const org = (await get("branches", A)).organization_id;
    await client.from("property_policies").insert([{ organization_id: org, branch_id: A, topic: "stay", title: "الهدوء", content_ar: "يمنع الإزعاج بعد منتصف الليل", content_en: "No noise after midnight", is_public: true, sort_order: 0 },
      { organization_id: org, branch_id: A, topic: "other", title: "سياسة داخلية للموظفين", content_ar: "لا تُعرض على الضيف", content_en: null, is_public: false, sort_order: 9 }]);
    await login("reception@demo.sa");
    const r = await book(10, 12);
    const s = await rpc<any>("fn_stay_summary", { p_reservation: r.id });
    expect(s.language).toBe("ar"); expect(s.text).toContain(r.internal_ref); expect(s.text).toContain("عدد الليالي: 2"); expect(s.text).toContain("الإجمالي"); expect(s.text).toContain("التأمين: 50.00 ر.س");
    expect(s.text).toContain("الهدوء: يمنع الإزعاج بعد منتصف الليل"); expect(s.text).not.toContain("سياسة داخلية");
    expect(await fails(rpc("fn_staff_record_paper_ack", { p: { reservation_id: r.id, text_hash: "old" } }))).toMatch(/^SUMMARY_CHANGED/);
    expect(await rpc<any>("fn_staff_record_paper_ack", { p: { reservation_id: r.id, text_hash: s.hash } })).toMatchObject({ duplicate: false });
    expect(await rpc<any>("fn_staff_record_paper_ack", { p: { reservation_id: r.id, text_hash: s.hash } })).toMatchObject({ duplicate: true });
    const acks = (await client.from("stay_acknowledgements").select("*").eq("reservation_id", r.id)).data as any[];
    expect(acks).toHaveLength(1); expect(acks[0]).toMatchObject({ method: "paper", text_hash: s.hash }); expect(acks[0].text_snapshot).toContain("الهدوء");
    expect((await rpc<any>("fn_stay_summary", { p_reservation: r.id })).acknowledgements).toHaveLength(1);
    // the branch in English
    await login("owner@demo.sa");
    const b = await get("branches", A);
    await rpc("fn_admin_upsert_branch", { p: { id: A, version: b.version, name_ar: b.name_ar, default_language: "en" } });
    const en = await rpc<any>("fn_stay_summary", { p_reservation: r.id });
    expect(en.language).toBe("en"); expect(en.text).toMatch(/^Stay summary/); expect(en.text).toContain("Deposit: SAR 50.00"); expect(en.text).toContain("No noise after midnight");
    await login("housekeeping@demo.sa");
    expect(await fails(rpc("fn_stay_summary", { p_reservation: r.id }))).toMatch(/^FORBIDDEN/);
  });

  it("GU12 the guest accepts the summary on their page; a payment changes it and the earlier acceptance stays with its own text; the first registration needs the acceptance and keeps the text the guest read", async () => {
    await login("reception@demo.sa");
    const r = await book(10, 12); const [pg] = await guestsOf(r.id);
    const tok = await token(r.internal_ref);
    const s1 = await rpc<any>("fn_guest_stay_summary", { p_token: tok });
    expect(s1.accepted_at).toBeNull(); expect(s1.current).toBe(false);
    expect(await fails(rpc("fn_guest_acknowledge", { p_token: tok, p_hash: "stale" }))).toMatch(/^SUMMARY_CHANGED/);
    // registering without the acceptance is refused; with the hash the acceptance is recorded first, with the text the guest read
    const payload = { full_name: "سعد محمد العتيبي", identity_type: "national_id", identity_number: "1098765432", nationality: "سعودي", birth_date: "1988-05-04", consent: "true" };
    expect(await fails(rpc("fn_guest_submit", { p_token: tok, p_guest_id: pg.id, p_payload: payload }))).toBe("VALIDATION: acknowledgement_required");
    await rpc("fn_guest_submit", { p_token: tok, p_guest_id: pg.id, p_payload: { ...payload, ack_hash: s1.hash } });
    const s2 = await rpc<any>("fn_guest_stay_summary", { p_token: tok });
    expect(s2.accepted_at).toBeTruthy(); expect(s2.method).toBe("electronic");
    expect(s2.hash).not.toBe(s1.hash);   // the name changed the text → the page says the current text is not yet accepted
    expect(s2.current).toBe(false);
    const acks = (await client.from("stay_acknowledgements").select("*").eq("reservation_id", r.id)).data as any[];
    expect(acks).toHaveLength(1); expect(acks[0].text_hash).toBe(s1.hash); expect(acks[0].text_snapshot).toBe(s1.text);
    await rpc("fn_guest_acknowledge", { p_token: tok, p_hash: s2.hash });
    expect((await rpc<any>("fn_guest_stay_summary", { p_token: tok })).current).toBe(true);
    expect(await rpc<any>("fn_guest_acknowledge", { p_token: tok, p_hash: s2.hash })).toMatchObject({ duplicate: true });
    // a payment changes the summary
    await rpc("fn_create_voucher", { p: { reservation_id: r.id, kind: "receipt", amount_halalas: 1000, method: "cash", idempotency_key: uid() } });
    const s3 = await rpc<any>("fn_guest_stay_summary", { p_token: tok });
    expect(s3.current).toBe(false); expect(s3.hash).not.toBe(s2.hash); expect(s3.accepted_at).toBeTruthy();
    expect(((await client.from("stay_acknowledgements").select("id").eq("reservation_id", r.id)).data as any[])).toHaveLength(2);
    expect((await rpc<any>("fn_guest_session", { p_token: tok })).reservation.summary_accepted).toBe(true);
  });

  it("GU13 the branch's fields (decision 31): the English name is required, the map link is a Google Maps https link, the platform link is https; the logo by its real type and size; a guest page reads the public card", async () => {
    await login("manager@demo.sa");
    const b = await get("branches", A);
    const up = (p: Record<string, unknown>) => rpc<any>("fn_admin_upsert_branch", { p: { id: A, version: b.version, name_ar: b.name_ar, ...p } });
    expect(await fails(up({ name_en: "  " }))).toBe("VALIDATION: name_en");
    expect(await fails(rpc("fn_admin_upsert_branch", { p: { name_ar: "فرع بلا اسم إنجليزي" } }))).toBe("VALIDATION: name_en");
    expect(await fails(up({ map_url: "http://maps.google.com/?q=1" }))).toBe("VALIDATION: map_url");
    expect(await fails(up({ map_url: "https://evil.example/maps" }))).toBe("VALIDATION: map_url");
    expect(await fails(up({ booking_platform_url: "javascript:alert(1)" }))).toBe("VALIDATION: booking_url");
    expect(await fails(up({ default_language: "fr" }))).toBe("VALIDATION: language");
    expect((await up({ map_url: "https://maps.app.goo.gl/AbCd123", booking_platform_url: "https://www.booking.com/hotel/sa/example.html", default_language: "ar", country_code: "SA" })).ok).toBe(true);
    expect(await get("branches", A)).toMatchObject({ name_en: b.name_en, map_url: "https://maps.app.goo.gl/AbCd123", booking_platform_url: "https://www.booking.com/hotel/sa/example.html" });
    // media: a PNG by its first bytes; an SVG refused; too large refused; the trail keeps the fingerprint, not the file; a supervisor cannot set it
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";   // a 1×1 PNG
    const pngBytes = Buffer.from(png, "base64").length;
    const svg = btoa('<svg xmlns="http://www.w3.org/2000/svg"></svg>');
    expect(await fails(rpc("fn_admin_set_branch_media", { p: { branch_id: A, kind: "logo", data_base64: svg } }))).toBe("VALIDATION: image_type");
    expect(await fails(rpc("fn_admin_set_branch_media", { p: { branch_id: A, kind: "logo", data_base64: btoa("x".repeat(204801)) } }))).toBe("VALIDATION: image_too_large");
    expect(await fails(rpc("fn_admin_set_branch_media", { p: { branch_id: A, kind: "banner", data_base64: png } }))).toBe("VALIDATION: kind");
    const m = await rpc<any>("fn_admin_set_branch_media", { p: { branch_id: A, kind: "logo", data_base64: png } });
    expect(m).toMatchObject({ ok: true, changed: true, media: { mime: "image/png", size_bytes: pngBytes } });
    const [a] = await trail(A, "branch.logo_changed");
    expect(a.details.after).toMatchObject({ mime: "image/png", size_bytes: pngBytes }); expect(JSON.stringify(a.details)).not.toContain(png.slice(0, 20));
    expect((await rpc<any>("fn_admin_branch_media_info", { p_branch: A })).logo).toMatchObject({ mime: "image/png", updated_by: "سلطان مدير الفرع" });
    await login("reception@demo.sa");
    expect(await fails(rpc("fn_admin_set_branch_media", { p: { branch_id: A, kind: "logo", data_base64: png } }))).toMatch(/^FORBIDDEN/);
    // the public card and the logo, as the guest's page reads them (no session)
    await client.auth.signOut();
    const card = await rpc<any>("fn_public_branch", { p_branch: A });
    expect(card).toMatchObject({ id: A, name_en: b.name_en, map_url: "https://maps.app.goo.gl/AbCd123", booking_platform_url: "https://www.booking.com/hotel/sa/example.html", default_language: "ar", country_code: "SA" });
    expect(card.logo_version).toBeTruthy(); expect(card.image_version).toBeNull();
    expect(await rpc<any>("fn_branch_media", { p_branch: A, p_kind: "logo" })).toBe(`data:image/png;base64,${png}`);
    expect(JSON.stringify(card)).not.toContain("tax_rate");
  });

  it("GU14 no direct booking on the website (decision 23): a visitor cannot ask for availability; the platform link and the map come from the branch's card", async () => {
    await client.auth.signOut();
    expect(await fails(rpc("fn_get_public_availability", { p_branch: A, p_date: day(1) }))).toMatch(/permission denied/);
    const card = await rpc<any>("fn_public_branch", { p_branch: A });
    expect(typeof card.booking_platform_url === "string" || card.booking_platform_url === null).toBe(true);
    await login("reception@demo.sa");
    expect(Array.isArray(await rpc<any>("fn_get_public_availability", { p_branch: A, p_date: day(1) }))).toBe(true);   // the staff still read it inside
  });
});

describe("Phase 6 — lists, log, ledger, staff and usage in the demo (0040)", () => {
  const A = "00000000-0000-0000-0000-000000000010", B = "00000000-0000-0000-0000-000000000012";   // the seeded branches (the supervisor works in A only; the manager in both)
  const OWNER = "00000000-0000-0000-0000-000000000001", MANAGER = "00000000-0000-0000-0000-000000000008", SUP = "00000000-0000-0000-0000-000000000002", FIN = "00000000-0000-0000-0000-000000000004", HK = "00000000-0000-0000-0000-000000000003";
  const CAT_B = "00000000-0000-0000-0000-000000000039", RECEPTION = "00000000-0000-0000-0000-000000000021", BOOKING_COM = "00000000-0000-0000-0000-000000000020", STUDIO = "00000000-0000-0000-0000-000000000030";
  const CASH_A = "00000000-0000-0000-0000-000000000700", TT_CLEAN = "00000000-0000-0000-0000-000000000420";
  const riyadh = () => new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Riyadh" });
  const day = (n: number) => { const d = new Date(riyadh() + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  const dayOf = (iso: string) => new Date(iso).toLocaleDateString("en-CA", { timeZone: "Asia/Riyadh" });
  const fails = async (p: Promise<unknown>) => { try { await p; return ""; } catch (e) { return (e as Error).message; } };
  const all = async (table: string) => (await client.from(table).select("*")).data as any[];
  const get = async (table: string, id: string) => (await client.from(table).select("*").eq("id", id).maybeSingle()).data as any;
  const ilike = (v: unknown, q: string) => String(v ?? "").toLowerCase().includes(q.toLowerCase());
  const ids = (rows: any[]) => rows.map((r) => r.id).sort();
  const sum = (rows: any[], f: (r: any) => boolean) => rows.filter(f).reduce((s, r) => s + Number(r.amount_halalas), 0);
  /** a booking at the reception, in A unless said otherwise */
  const book = (from: number, to: number, extra: Record<string, unknown> = {}) => rpc<any>("fn_staff_create_reservation", { p: { branch_id: A, category_id: STUDIO, source_id: RECEPTION, check_in: day(from), check_out: day(to), guest_name: "ضيف المرحلة السادسة", guest_phone: "0500000000", adults: 1, companions: 0, ...extra } });
  /** every page of a list, as an export reads it (X09) */
  const pages = async (fn: string, args: Record<string, unknown>, size: number) => { const got: any[] = []; let total = -1; for (let off = 0; ; off += size) { const r = await rpc<any>(fn, fn === "fn_reservation_list" ? { ...args, p_limit: size, p_offset: off } : { p: { ...(args.p as object), limit: size, offset: off } }); total = r.total; got.push(...r.rows); if (r.rows.length < size) break; } return { rows: got, total }; };

  it("DS01 the reservations list: every filter of the reference equals an independent filter over the store, read in pages of 3 without overlap and with the exact total; a limit above 1000 is capped, not refused", async () => {
    await rpc("fn_staff_create_reservation", { p: { branch_id: A, category_id: STUDIO, source_id: RECEPTION, check_in: day(50), check_out: day(52), guest_name: "ضيف بخصم", guest_phone: "0500000777", adults: 1, companions: 0, discount_halalas: 1000, discount_reason: "ضيف دائم" } });
    const res = (await client.from("reservations").select("*").eq("branch_id", A)).data as any[]; const guests = await all("reservation_guests"); const rooms = await all("rooms"); const today = riyadh();
    expect(res.length).toBeGreaterThan(20);
    const qMatch = (r: any, q: string) => ilike(r.internal_ref, q) || ilike(r.external_ref, q) || ilike(r.cancel_reference, q) || ilike(r.company_name, q) || guests.some((g) => g.reservation_id === r.id && (ilike(g.full_name, q) || String(g.phone ?? "").includes(q)));
    const cases: Array<[string, Record<string, unknown>, (r: any) => boolean]> = [
      ["status", { status: "confirmed,checked_in" }, (r) => ["confirmed", "checked_in"].includes(r.status)],
      ["open_only", { open_only: true }, (r) => ["pending_verification", "confirmed", "checked_in"].includes(r.status)],
      ["check_in window", { check_in_from: day(-3), check_in_to: day(3) }, (r) => r.check_in >= day(-3) && r.check_in <= day(3)],
      ["check_out window", { check_out_from: today, check_out_to: day(7) }, (r) => r.check_out >= today && r.check_out <= day(7)],
      ["created today (branch day)", { created_from: today, created_to: today }, (r) => dayOf(r.created_at) === today],
      ["stay_on", { stay_on: today }, (r) => r.check_in <= today && r.check_out > today],
      ["source", { source_id: BOOKING_COM }, (r) => r.source_id === BOOKING_COM],
      ["category", { category_id: STUDIO }, (r) => r.room_category_id === STUDIO],
      ["room number", { room_number: "101" }, (r) => rooms.find((x) => x.id === r.room_id)?.room_number === "101"],
      ["booking_type", { booking_type: "individual" }, (r) => r.booking_type === "individual"],
      ["price_basis", { price_basis: "daily" }, (r) => r.price_basis === "daily"],
      ["payment_status", { payment_status: "paid" }, (r) => r.payment_status === "paid"],
      ["identity_status", { identity_status: "verified" }, (r) => r.identity_status === "verified"],
      ["has_discount", { has_discount: "true" }, (r) => r.discount_halalas > 0],
      ["has_balance (money role)", { has_balance: true }, (r) => r.balance_due_halalas > 0],
      ["platform_collects", { platform_collects: "true" }, (r) => r.platform_collects === true],
      ["q by number", { q: res[0].internal_ref }, (r) => qMatch(r, res[0].internal_ref)],
      ["q by guest phone", { q: "0501110001" }, (r) => qMatch(r, "0501110001")],
      ["cancelled with cancel_reference", { status: "cancelled", q: "CXL" }, (r) => r.status === "cancelled" && qMatch(r, "CXL")],
    ];
    const nonEmpty: string[] = [];
    for (const [name, filters, pred] of cases) {
      const want = ids(res.filter(pred)); const got = await pages("fn_reservation_list", { p_branch: A, p_filters: filters }, 3);
      expect(got.rows.length, name).toBe(new Set(got.rows.map((r) => r.id)).size);
      expect(ids(got.rows), name).toEqual(want); expect(got.total, name).toBe(want.length);
      if (want.length) nonEmpty.push(name);
    }
    expect(nonEmpty.length).toBeGreaterThan(14);   // the seed exercises the filters, not only their empty answers
    const capped = await rpc<any>("fn_reservation_list", { p_branch: A, p_filters: {}, p_limit: 5000, p_offset: 0 });
    expect(capped.total).toBe(res.length); expect(capped.rows.length).toBe(Math.min(res.length, 1000));
  });

  it("DS02 sort: arrival ascending, departure, creation, number, and the default (arrival descending then creation descending); branch B's booking is the owner's to see and not the supervisor's; the row carries every column the column picker offers", async () => {
    const inB = await rpc<any>("fn_staff_create_reservation", { p: { branch_id: B, category_id: CAT_B, source_id: RECEPTION, check_in: day(40), check_out: day(42), guest_name: "ضيف الفرع ب", guest_phone: "0500009901", adults: 1, companions: 0 } });
    const list = (sort?: string) => rpc<any>("fn_reservation_list", { p_branch: A, p_filters: sort ? { sort } : {}, p_limit: 1000, p_offset: 0 }).then((r) => r.rows as any[]);
    const nonDecreasing = (xs: string[]) => xs.every((x, i) => i === 0 || xs[i - 1] <= x);
    expect(nonDecreasing((await list("check_in_asc")).map((r) => r.check_in))).toBe(true);
    expect(nonDecreasing((await list("ref")).map((r) => r.internal_ref))).toBe(true);
    expect(nonDecreasing((await list("check_out")).map((r) => r.check_out).reverse())).toBe(true);
    expect(nonDecreasing((await list("created")).map((r) => Date.parse(r.created_at)).reverse().map(String).map((x) => x.padStart(20, "0")))).toBe(true);
    const dflt = await list();
    expect(dflt.every((r, i) => i === 0 || dflt[i - 1].check_in > r.check_in || (dflt[i - 1].check_in === r.check_in && Date.parse(dflt[i - 1].created_at) >= Date.parse(r.created_at)))).toBe(true);
    // the columns of the picker (decision 14): every key present on every row, the money columns filled for the owner
    const keys = ["id", "internal_ref", "external_ref", "status", "check_in", "check_out", "nights", "guest_name", "room_number", "source_name", "category_name", "booking_type", "company_name", "price_basis", "adults", "companions", "platform_booked_on", "platform_collects", "created_by_name", "actual_check_in", "actual_check_out", "cancelled_at", "cancel_reference", "total_halalas", "paid_halalas", "discount_halalas", "nightly_rate_halalas", "balance_due_halalas", "deposit_balance_halalas", "payment_status", "identity_status", "access_status", "created_at", "group_ref", "hold", "ban", "rating"];
    for (const r of dflt) for (const k of keys) expect(k in r, `${k} on ${r.internal_ref}`).toBe(true);
    const seeded = dflt.find((r) => r.created_by_name === "فهد الاستقبال" && r.status === "checked_in")!;
    expect(seeded).toMatchObject({ booking_type: "individual", price_basis: "daily", adults: 2, companions: 0, hold: false, ban: false });
    expect(seeded.nights).toBe(Math.round((Date.parse(seeded.check_out) - Date.parse(seeded.check_in)) / 86400000));
    expect(typeof seeded.total_halalas).toBe("number"); expect(typeof seeded.nightly_rate_halalas).toBe("number");
    // branch scoping: the owner sees B's booking in B; the supervisor of A gets nothing of B (no throw) and nothing of B's in A
    expect((await rpc<any>("fn_reservation_list", { p_branch: B, p_filters: {}, p_limit: 50, p_offset: 0 })).rows.map((r: any) => r.id)).toContain(inB.id);
    await login("reception@demo.sa");
    expect(await rpc<any>("fn_reservation_list", { p_branch: B, p_filters: {}, p_limit: 50, p_offset: 0 })).toEqual({ total: 0, rows: [] });
    const mine = await rpc<any>("fn_reservation_list", { p_branch: A, p_filters: {}, p_limit: 1000, p_offset: 0 });
    expect(mine.total).toBeGreaterThan(0); expect(mine.rows.some((r: any) => r.id === inB.id)).toBe(false);
  });

  it("DS03 housekeeping reads the list without money, bans or ratings, and the balance filter yields nothing for them (no inference from counts); the supervisor sees the money and the rating, finance the money and the ban but no rating", async () => {
    await login("housekeeping@demo.sa");
    const hk = await rpc<any>("fn_reservation_list", { p_branch: A, p_filters: {}, p_limit: 1000, p_offset: 0 });
    expect(hk.total).toBeGreaterThan(0);
    for (const r of hk.rows) for (const k of ["total_halalas", "paid_halalas", "discount_halalas", "nightly_rate_halalas", "balance_due_halalas", "deposit_balance_halalas", "ban", "rating"]) expect(r[k], k).toBeNull();
    expect(hk.rows[0].guest_name).toBeTruthy(); expect(hk.rows[0].payment_status).toBeTruthy();
    expect(await rpc<any>("fn_reservation_list", { p_branch: A, p_filters: { has_balance: true }, p_limit: 50, p_offset: 0 })).toEqual({ total: 0, rows: [] });
    await login("reception@demo.sa");
    const sup = (await rpc<any>("fn_reservation_list", { p_branch: A, p_filters: { has_balance: true }, p_limit: 50, p_offset: 0 })).rows as any[];
    expect(sup.length).toBeGreaterThan(0); expect(sup.every((r) => r.balance_due_halalas > 0)).toBe(true);
    const rated = (await rpc<any>("fn_reservation_list", { p_branch: A, p_filters: { q: "0501110004" }, p_limit: 50, p_offset: 0 })).rows[0];
    expect(rated.rating).toBe(2); expect(typeof rated.ban).toBe("boolean");
    await login("finance@demo.sa");
    const fin = (await rpc<any>("fn_reservation_list", { p_branch: A, p_filters: { q: "0501110004" }, p_limit: 50, p_offset: 0 })).rows[0];
    expect(fin.rating).toBeNull(); expect(typeof fin.ban).toBe("boolean"); expect(typeof fin.total_halalas).toBe("number");
  });

  it("DS04 saved views: own rows only (function and table), the second default replaces the first and the list is ordered default first, saving by id renames without a new row, a wrong screen or an empty name is refused, at most 20 live per screen, removing archives (the row stays, no default left), no direct write", async () => {
    await login("reception@demo.sa");
    const v1 = await rpc<any>("fn_saved_view_save", { p: { screen: "reservations", name: " الوصول اليوم ", filters: { check_in_from: day(0) }, columns: ["internal_ref", "guest_name"], is_default: true } });
    const v2 = await rpc<any>("fn_saved_view_save", { p: { screen: "reservations", name: "بلا رصيد", filters: { has_balance: true }, is_default: true } });
    let l = await rpc<any[]>("fn_saved_views_list", { p_screen: "reservations" });
    expect(l.map((x) => [x.name, x.is_default])).toEqual([["بلا رصيد", true], ["الوصول اليوم", false]]);
    expect(l[1]).toMatchObject({ id: v1.id, filters: { check_in_from: day(0) }, columns: ["internal_ref", "guest_name"] }); expect(l[0].columns).toBeNull();
    expect(await rpc<any>("fn_saved_view_save", { p: { id: v1.id, screen: "reservations", name: "الوصول اليوم (معدّل)", filters: { check_in_from: "2026-02-01" } } })).toEqual({ ok: true, id: v1.id });
    l = await rpc<any[]>("fn_saved_views_list", { p_screen: "reservations" });
    expect(l).toHaveLength(2); expect(l.find((x) => x.id === v1.id)).toMatchObject({ name: "الوصول اليوم (معدّل)", filters: { check_in_from: "2026-02-01" }, columns: ["internal_ref", "guest_name"], is_default: false });
    expect(await rpc<any[]>("fn_saved_views_list", { p_screen: "vouchers" })).toEqual([]);
    expect(await fails(rpc("fn_saved_view_save", { p: { screen: "rooms", name: "x" } }))).toBe("VALIDATION: screen");
    expect(await fails(rpc("fn_saved_view_save", { p: { screen: "audit", name: "   " } }))).toBe("VALIDATION: name");
    expect(await fails(rpc("fn_saved_view_save", { p: { screen: "audit", name: "x".repeat(61) } }))).toBe("VALIDATION: name");
    // another person sees none of them, through the function or the table, and cannot touch them
    await login("manager@demo.sa");
    expect(await rpc<any[]>("fn_saved_views_list", { p_screen: "reservations" })).toEqual([]);
    expect(await all("staff_saved_views")).toEqual([]);
    expect(await fails(rpc("fn_saved_view_remove", { p_id: v1.id }))).toBe("NOT_FOUND: view");
    expect(await fails(rpc("fn_saved_view_save", { p: { id: v2.id, screen: "reservations", name: "مسروق" } }))).toBe("NOT_FOUND: view");
    const direct = await client.from("staff_saved_views").insert({ organization_id: "00000000-0000-0000-0000-000000000001", staff_id: MANAGER, screen: "reservations", name: "مباشر" });
    expect(direct.error?.code).toBe("42501");
    // at most 20 live per screen; removal archives and frees a place
    await login("reception@demo.sa");
    for (let i = 3; i <= 20; i++) await rpc("fn_saved_view_save", { p: { screen: "reservations", name: `عرض ${i}` } });
    expect(await fails(rpc("fn_saved_view_save", { p: { screen: "reservations", name: "الواحد والعشرون" } }))).toBe("LIMIT: saved_views");
    expect(await rpc<any>("fn_saved_view_remove", { p_id: v2.id })).toEqual({ ok: true });
    expect(await fails(rpc("fn_saved_view_remove", { p_id: v2.id }))).toBe("NOT_FOUND: view");
    const gone = await get("staff_saved_views", v2.id);
    expect(gone.archived_at).toBeTruthy(); expect(gone.is_default).toBe(false);
    l = await rpc<any[]>("fn_saved_views_list", { p_screen: "reservations" });
    expect(l).toHaveLength(19); expect(l.some((x) => x.is_default)).toBe(false);
    expect((await rpc<any>("fn_saved_view_save", { p: { screen: "reservations", name: "الواحد والعشرون" } })).ok).toBe(true);
    expect((await all("staff_saved_views")).length).toBe(21);   // the archived row stays
    await client.auth.signOut();
    expect(await fails(rpc("fn_saved_view_save", { p: { screen: "reservations", name: "زائر" } }))).toMatch(/^FORBIDDEN/);
  });

  it("DS05 the calendar: the window is at most 62 days and never reversed, another branch is refused; every live unit of the branch and exactly the allocations that touch the window, clipped to it with the before/after flags, nothing cancelled; housekeeping sees it without payment states or balances", async () => {
    expect(await fails(rpc("fn_reservation_calendar", { p_branch: A, p_from: day(1), p_to: day(0) }))).toBe("VALIDATION: range");
    expect(await fails(rpc("fn_reservation_calendar", { p_branch: A, p_from: day(0), p_to: day(63) }))).toBe("VALIDATION: range");
    expect((await rpc<any>("fn_reservation_calendar", { p_branch: A, p_from: day(0), p_to: day(62) })).units.length).toBeGreaterThan(0);
    const from = day(-2), to = day(5), end = day(6);
    const c = await rpc<any>("fn_reservation_calendar", { p_branch: A, p_from: from, p_to: to });
    expect(c).toMatchObject({ from, to, today: riyadh() });
    const rooms = (await all("rooms")).filter((r) => r.branch_id === A && !r.archived_at);
    expect(ids(c.units.map((u: any) => ({ id: u.room_id })))).toEqual(ids(rooms));
    expect(c.units[0]).toMatchObject({ room_number: expect.any(String), category: expect.any(String), floor: expect.any(String), block: expect.any(String), status: expect.any(String), cleanliness: expect.any(String) });
    expect(c.units.some((u: any) => u.is_active === false)).toBe(true);   // U-4 is out of service, not archived: still on the board
    const res = await all("reservations"); const allocs = (await all("reservation_allocations")).filter((a) => a.branch_id === A && ["active", "closed"].includes(a.status) && a.from_date <= to && a.to_date > from && !["cancelled", "rejected", "no_show"].includes(res.find((r) => r.id === a.reservation_id)?.status));
    expect(allocs.length).toBeGreaterThan(3);
    expect(c.segments.map((s: any) => `${s.room_id}|${s.reservation_id}`).sort()).toEqual(allocs.map((a) => `${a.room_id}|${a.reservation_id}`).sort());
    for (const s of c.segments) {
      const a = allocs.find((x) => x.room_id === s.room_id && x.reservation_id === s.reservation_id)!;
      expect(s.from_date).toBe(a.from_date > from ? a.from_date : from); expect(s.to_date).toBe(a.to_date < end ? a.to_date : end);
      expect(s.starts_before).toBe(a.from_date < from); expect(s.ends_after).toBe(a.to_date > end);
      expect(s.from_date >= from && s.to_date <= end && s.from_date < s.to_date).toBe(true);
      expect(typeof s.guest).toBe("string"); expect(typeof s.source).toBe("string"); expect(typeof s.payment_status).toBe("string"); expect(typeof s.balance_due_halalas).toBe("number");
    }
    expect(c.segments.some((s: any) => s.starts_before)).toBe(true);
    await login("housekeeping@demo.sa");
    const h = await rpc<any>("fn_reservation_calendar", { p_branch: A, p_from: from, p_to: to });
    expect(h.segments.length).toBe(c.segments.length); expect(h.segments.every((s: any) => s.payment_status === null && s.balance_due_halalas === null && s.guest)).toBe(true); expect(h.units[0]).toHaveProperty("cleanliness");
    await login("reception@demo.sa");
    expect(await fails(rpc("fn_reservation_calendar", { p_branch: B, p_from: from, p_to: to }))).toBe("FORBIDDEN: branch not permitted");
  });

  it("DS06 the log: the owner reads the whole log with the security rows, the manager and the supervisor never a security row even when asked, the supervisor only their branches and the branch-less rows and no details; every filter equals an independent filter, read in pages; the rows read in Arabic with the booking's number, the person's name and the branch; housekeeping and finance are refused", async () => {
    // a security row (branch-less), a business row of branch B, and a branch-less business row
    await rpc("fn_admin_force_logout", { p_staff: FIN, p_reason: "جهاز مفقود" });
    const inB = await rpc<any>("fn_staff_create_reservation", { p: { branch_id: B, category_id: CAT_B, source_id: RECEPTION, check_in: day(40), check_out: day(42), guest_name: "ضيف الفرع ب", guest_phone: "0500009901", adults: 1, companions: 0 } });
    await rpc("fn_admin_set_source_active", { p: { id: "00000000-0000-0000-0000-000000000529", is_active: true, reason: "تجربة" } });
    const events = await all("audit_events"); const { auditActionLabel } = await import("../../src/lib/auditLabels");
    const seeded = events.find((e) => e.action === "reservation.created" && e.actor_id === SUP)!; const seededRes = await get("reservations", seeded.entity_id);
    const owner = await rpc<any>("fn_audit_list", { p: {} });
    expect(owner).toMatchObject({ total: events.length, limit: 50, offset: 0, tz: "Asia/Riyadh" }); expect(owner.rows.length).toBe(Math.min(50, events.length));
    expect((await rpc<any>("fn_audit_list", { p: { limit: 9999 } })).limit).toBe(500);
    const sec = await rpc<any>("fn_audit_list", { p: { category: "security" } });
    expect(sec.total).toBeGreaterThan(0); expect(sec.rows[0]).toMatchObject({ action: "staff.signed_out", action_label: "تسجيل خروج إجباري", entity_label: "موظف", entity_ref: "نورة المالية", actor_name: "عبدالله المالك", category: "security", branch_id: null, branch_name: null, reason: "جهاز مفقود" });
    const cases: Array<[string, Record<string, unknown>, (e: any) => boolean]> = [
      ["branch", { branch_id: A }, (e) => e.branch_id === A],
      ["action", { action: "reservation.created" }, (e) => e.action === "reservation.created"],
      ["prefix", { action: "reservation.", action_prefix: true }, (e) => String(e.action).startsWith("reservation.")],
      ["entity", { entity_type: "reservation" }, (e) => e.entity_type === "reservation"],
      ["entity id", { entity_id: inB.id }, (e) => e.entity_id === inB.id],
      ["correlation", { correlation_id: seeded.correlation_id }, (e) => e.correlation_id === seeded.correlation_id],
      ["actor", { actor_id: SUP }, (e) => e.actor_id === SUP],
      ["category", { category: "business" }, (e) => e.category === "business"],
      ["result", { result: "success" }, (e) => e.result === "success"],
      ["source", { source: "screen" }, (e) => e.source === "screen"],
      ["day", { from: riyadh(), to: riyadh() }, (e) => dayOf(e.created_at) === riyadh()],
      ["name search", { q: "إنشاء حجز" }, (e) => ilike(e.action, "إنشاء حجز") || ilike(e.entity_type, "إنشاء حجز") || auditActionLabel(e.action).includes("إنشاء حجز")],
      ["code search", { q: "voucher" }, (e) => ilike(e.action, "voucher") || ilike(e.entity_type, "voucher") || ilike(auditActionLabel(e.action), "voucher")],
    ];
    for (const [name, filters, pred] of cases) {
      const want = ids(events.filter(pred)); const got = await pages("fn_audit_list", { p: filters }, 7);
      expect(ids(got.rows), name).toEqual(want); expect(got.total, name).toBe(want.length); expect(want.length, name).toBeGreaterThan(0);
    }
    expect(await fails(rpc("fn_audit_list", { p: { from: day(1), to: day(0) } }))).toBe("VALIDATION: period");
    const row = (await rpc<any>("fn_audit_list", { p: { entity_id: seededRes.id, action: "reservation.created" } })).rows[0];
    expect(row).toMatchObject({ action_label: "إنشاء حجز", entity_label: "حجز", entity_ref: seededRes.internal_ref, actor_name: "فهد الاستقبال", actor_type: "staff", branch_id: A, branch_name: "فرع الرياض — طريق الملك فهد", result: "success", category: "business", reason: null });
    expect(row.details).toBeTruthy(); expect(row.created_at).toBe(seeded.created_at);
    // the manager: details, no security row even when asked; the supervisor: their branch and the branch-less rows, no details
    await login("manager@demo.sa");
    const mgr = await rpc<any>("fn_audit_list", { p: { limit: 500 } });
    expect(mgr.rows.some((r: any) => r.category === "security")).toBe(false); expect(mgr.rows.some((r: any) => r.details)).toBe(true);
    expect((await rpc<any>("fn_audit_list", { p: { category: "security" } })).total).toBe(0);
    expect(mgr.total).toBe(events.filter((e) => e.category !== "security").length);
    await login("reception@demo.sa");
    const sup = await rpc<any>("fn_audit_list", { p: { limit: 500 } });
    expect(sup.total).toBe(events.filter((e) => e.category !== "security" && (e.branch_id == null || e.branch_id === A)).length);
    expect(sup.rows.some((r: any) => r.branch_id === B || r.category === "security")).toBe(false);
    expect(sup.rows.some((r: any) => r.branch_id === null && r.action === "source.enabled")).toBe(true);
    expect(sup.rows.every((r: any) => r.details === null)).toBe(true); expect(sup.rows.some((r: any) => r.reason)).toBe(true);
    expect(await fails(rpc("fn_audit_list", { p: { branch_id: B } }))).toBe("FORBIDDEN: branch not permitted");
    await login("housekeeping@demo.sa"); expect(await fails(rpc("fn_audit_list", { p: {} }))).toMatch(/^FORBIDDEN/);
    await login("finance@demo.sa"); expect(await fails(rpc("fn_audit_list", { p: {} }))).toMatch(/^FORBIDDEN/);
  });

  it("DS07 the ledger: approved by default with the exact total; every filter (kind, method, account, «none», status, staff, booking, day, number) equals an independent filter read in pages of 4; the totals are over the whole set even when the page holds one row; a branch, a sane period and a known status are required; housekeeping is refused, branch B's supervisor is refused branch A, finance reads it", async () => {
    const r = await book(60, 61); const key = uid();
    const v = await rpc<any>("fn_create_voucher", { p: { reservation_id: r.id, kind: "receipt", amount_halalas: 7000, method: "cash", idempotency_key: key } });
    await rpc("fn_cancel_voucher", { p_voucher: v.voucher_id, p_reason: "خطأ إدخال" });
    await rpc("fn_create_voucher", { p: { reservation_id: r.id, kind: "receipt", amount_halalas: 5000, method: "cash", idempotency_key: uid() } });
    const vouchers = (await all("financial_vouchers")).filter((x) => x.branch_id === A); const res = await all("reservations");
    const cancelledNumber = vouchers.find((x) => x.id === v.voucher_id)!.number;
    const base = await rpc<any>("fn_voucher_list", { p: { branch_id: A } });
    expect(base).toMatchObject({ total: vouchers.filter((x) => x.status === "approved").length, limit: 100, offset: 0, tz: "Asia/Riyadh" });
    expect(base.rows.every((x: any) => x.status === "approved")).toBe(true);
    const refOf = (x: any) => res.find((y) => y.id === x.reservation_id)?.internal_ref ?? "";
    const cases: Array<[string, Record<string, unknown>, (x: any) => boolean]> = [
      ["kind", { kind: "deposit" }, (x) => x.status === "approved" && x.kind === "deposit"],
      ["method", { method: "pos" }, (x) => x.status === "approved" && x.method === "pos"],
      ["account", { account_id: CASH_A }, (x) => x.status === "approved" && x.account_id === CASH_A],
      ["no account", { account_id: "none" }, (x) => x.status === "approved" && x.account_id == null],
      ["cancelled", { status: "cancelled" }, (x) => x.status === "cancelled"],
      ["all", { status: "all" }, () => true],
      ["staff", { staff_id: OWNER, status: "all" }, (x) => x.created_by === OWNER],
      ["booking", { reservation_id: r.id, status: "all" }, (x) => x.reservation_id === r.id],
      ["day", { from: riyadh(), to: riyadh() }, (x) => x.status === "approved" && dayOf(x.occurred_at) === riyadh()],
      ["number", { q: cancelledNumber, status: "all" }, (x) => ilike(x.number, cancelledNumber) || ilike(x.reference, cancelledNumber) || ilike(refOf(x), cancelledNumber)],
      ["booking number", { q: r.internal_ref, status: "all" }, (x) => ilike(x.number, r.internal_ref) || ilike(x.reference, r.internal_ref) || ilike(refOf(x), r.internal_ref)],
    ];
    for (const [name, filters, pred] of cases) {
      const want = ids(vouchers.filter(pred)); const got = await pages("fn_voucher_list", { p: { branch_id: A, ...filters } }, 4);
      expect(ids(got.rows), name).toEqual(want); expect(got.total, name).toBe(want.length); expect(want.length, name).toBeGreaterThan(0);
    }
    const one = await rpc<any>("fn_voucher_list", { p: { branch_id: A, limit: 1 } }); const ok = vouchers.filter((x) => x.status === "approved");
    expect(one.rows).toHaveLength(1); expect(one.total).toBe(ok.length);
    expect(one.totals).toMatchObject({ receipts: sum(ok, (x) => x.kind === "receipt"), refunds: sum(ok, (x) => x.kind === "refund"), deposits: sum(ok, (x) => x.kind === "deposit"), deposit_refunds: sum(ok, (x) => x.kind === "deposit_refund"), deposit_applied: 0, approved: ok.length, cancelled: 0 });   // the set is the approved rows: no cancelled one in it
    expect((await rpc<any>("fn_voucher_list", { p: { branch_id: A, status: "all", limit: 1 } })).totals).toMatchObject({ approved: ok.length, cancelled: vouchers.filter((x) => x.status === "cancelled").length, receipts: sum(ok, (x) => x.kind === "receipt") });   // a cancelled voucher never adds to the money
    for (const m of one.totals.by_method) expect(m.amount_halalas).toBe(sum(ok, (x) => x.kind === "receipt" && x.method === m.method));
    expect(one.totals.by_method.map((m: any) => m.method).sort()).toEqual([...new Set(ok.filter((x) => x.kind === "receipt").map((x) => x.method))].sort());
    expect(one.totals.by_method.every((m: any, i: number) => i === 0 || one.totals.by_method[i - 1].amount_halalas >= m.amount_halalas)).toBe(true);
    const cash = one.totals.by_account.find((a: any) => a.account_id === CASH_A);
    expect(cash).toMatchObject({ account_name: "صندوق الاستقبال", in_halalas: sum(ok, (x) => x.account_id === CASH_A && ["receipt", "deposit"].includes(x.kind)), out_halalas: sum(ok, (x) => x.account_id === CASH_A && ["refund", "deposit_refund"].includes(x.kind)) });
    const row = (await rpc<any>("fn_voucher_list", { p: { branch_id: A, reservation_id: r.id, status: "all", kind: "receipt" } })).rows.find((x: any) => x.number === cancelledNumber);
    expect(row).toMatchObject({ status: "cancelled", cancel_reason: "خطأ إدخال", creator_name: "عبدالله المالك", account_name: "صندوق الاستقبال", reservation: { id: r.id, internal_ref: r.internal_ref }, original_number: null });
    expect(row.cancelled_at).toBeTruthy();
    expect(await fails(rpc("fn_voucher_list", { p: {} }))).toBe("VALIDATION: branch_id");
    expect(await fails(rpc("fn_voucher_list", { p: { branch_id: A, from: day(1), to: day(0) } }))).toBe("VALIDATION: period");
    expect(await fails(rpc("fn_voucher_list", { p: { branch_id: A, status: "pending" } }))).toBe("VALIDATION: status");
    await login("housekeeping@demo.sa"); expect(await fails(rpc("fn_voucher_list", { p: { branch_id: A } }))).toMatch(/^FORBIDDEN/);
    await login("reception@demo.sa"); expect(await fails(rpc("fn_voucher_list", { p: { branch_id: B } }))).toBe("FORBIDDEN: branch not permitted");
    await login("finance@demo.sa"); expect((await rpc<any>("fn_voucher_list", { p: { branch_id: A } })).total).toBe(ok.length);
  });

  it("DS08 report filters (decision 36): by staff member, payment method, box or account and «بلا صندوق», source and unit type — each total equals an independent sum, by_staff holds that person only, the collection rate is not claimed under a staff, method or account filter; the discounts, late-entries and identities reports echo their filters; the filter options of a branch", async () => {
    const r = await book(60, 61, { discount_halalas: 500, discount_reason: "تجربة" });
    await rpc("fn_create_voucher", { p: { reservation_id: r.id, kind: "receipt", amount_halalas: 9000, method: "cash", idempotency_key: uid() } });
    const from = day(-30), to = riyadh(); const inPeriod = (x: any) => dayOf(x.occurred_at) >= from && dayOf(x.occurred_at) <= to;
    const res = await all("reservations"); const vs = (await all("financial_vouchers")).filter((x) => x.branch_id === A && x.status === "approved" && inPeriod(x));
    const resOf = (x: any) => res.find((y) => y.id === x.reservation_id);
    const fin = (filters: Record<string, unknown>) => rpc<any>("fn_reports_finance", { p_branch: A, p_from: from, p_to: to, p_filters: filters });
    const plain = await fin({});
    expect(plain.filtered).toBe(false); expect(plain.filters).toEqual({}); expect(plain.collection_rate_pct).not.toBeNull(); expect(plain.ledger.receipts).toBe(sum(vs, (x) => x.kind === "receipt"));
    expect(plain.definitions.collection_rate.endsWith("؛ لا تُحسب مع مرشح الموظف أو الطريقة أو الحساب.")).toBe(true);
    expect(plain.by_staff.length).toBe(2); expect(plain.by_account.length).toBe(2);
    const byStaff = await fin({ staff_id: SUP });
    expect(byStaff).toMatchObject({ filtered: true, filters: { staff_id: SUP }, collection_rate_pct: null });
    expect(byStaff.ledger.receipts).toBe(sum(vs, (x) => x.kind === "receipt" && x.created_by === SUP)); expect(byStaff.ledger.receipts).toBeGreaterThan(0);
    expect(byStaff.by_staff).toEqual([{ staff_id: SUP, staff: "فهد الاستقبال", receipts: byStaff.ledger.receipts, refunds: sum(vs, (x) => x.kind === "refund" && x.created_by === SUP), count: vs.filter((x) => ["receipt", "refund"].includes(x.kind) && x.created_by === SUP).length }]);
    const byMethod = await fin({ method: "cash" });
    expect(byMethod.collection_rate_pct).toBeNull(); expect(byMethod.ledger.receipts).toBe(sum(vs, (x) => x.kind === "receipt" && x.method === "cash")); expect(byMethod.by_method).toEqual([{ method: "cash", amount_halalas: byMethod.ledger.receipts }]);
    const byAccount = await fin({ account_id: CASH_A });
    expect(byAccount.ledger.receipts).toBe(sum(vs, (x) => x.kind === "receipt" && x.account_id === CASH_A)); expect(byAccount.by_account).toEqual([{ account_id: CASH_A, account: "صندوق الاستقبال", in_halalas: sum(vs, (x) => x.account_id === CASH_A && ["receipt", "deposit"].includes(x.kind)), out_halalas: sum(vs, (x) => x.account_id === CASH_A && ["refund", "deposit_refund"].includes(x.kind)) }]);
    const none = await fin({ account_id: "none" });
    expect(none.ledger.receipts).toBe(sum(vs, (x) => x.kind === "receipt" && x.account_id == null)); expect(none.ledger.receipts).toBeGreaterThan(0); expect(none.by_account).toEqual([]); expect(none.collection_rate_pct).toBeNull();
    const bySource = await fin({ source_id: BOOKING_COM });
    expect(bySource.ledger.receipts).toBe(sum(vs, (x) => x.kind === "receipt" && resOf(x)?.source_id === BOOKING_COM)); expect(bySource.ledger.receipts).toBeGreaterThan(0);
    const inWin = res.filter((y) => y.branch_id === A && y.check_in <= to && y.check_out > from);
    expect(bySource.reservations.count).toBe(inWin.filter((y) => y.source_id === BOOKING_COM).length); expect(bySource.collection_rate_pct).not.toBeNull(); expect(bySource.filters).toEqual({ source_id: BOOKING_COM });
    const byCat = await fin({ category_id: STUDIO });
    expect(byCat.ledger.receipts).toBe(sum(vs, (x) => x.kind === "receipt" && resOf(x)?.room_category_id === STUDIO)); expect(byCat.reservations.count).toBe(inWin.filter((y) => y.room_category_id === STUDIO).length);
    expect(byCat.charges.rent).toBe((await all("reservation_charges")).filter((c) => c.branch_id === A && c.kind === "rent" && inWin.some((y) => y.id === c.reservation_id && y.room_category_id === STUDIO && !["cancelled", "rejected", "no_show"].includes(y.status))).reduce((s, c) => s + c.total_halalas, 0));
    expect(await fails(rpc("fn_reports_finance", { p_branch: A, p_from: day(1), p_to: day(0), p_filters: {} }))).toBe("VALIDATION: period");
    // the discounts report: by staff member and «بعد الوصول»
    const disc = (filters: Record<string, unknown>) => rpc<any>("fn_reports_discounts", { p_branch: A, p_from: from, p_to: to, p_filters: filters });
    const dAll = await disc({}); const dMine = await disc({ staff_id: OWNER }); const dBefore = await disc({ after_arrival: false });
    expect(dAll.filters).toEqual({}); expect(dMine.filters).toEqual({ staff_id: OWNER }); expect(dMine.count).toBe(1); expect(dMine.rows[0]).toMatchObject({ internal_ref: r.internal_ref, amount_halalas: 500, staff: "عبدالله المالك", after_arrival: false });
    expect(dBefore.filters).toEqual({ after_arrival: false }); expect(dBefore.count).toBe(dAll.rows.filter((x: any) => !x.after_arrival).length); expect((await disc({ after_arrival: true })).count).toBe(dAll.rows.filter((x: any) => x.after_arrival).length);
    expect(dAll.by_staff.some((s: any) => s.staff === "عبدالله المالك")).toBe(true); expect(dMine.by_staff).toHaveLength(1);
    // the late-entries and identities reports echo their filters and follow them
    const late = (filters: Record<string, unknown>) => rpc<any>("fn_reports_late_entries", { p_branch: A, p_from: from, p_to: to, p_min_days: 1, p_filters: filters });
    expect((await late({})).late).toBeGreaterThan(0); expect((await late({ staff_id: SUP })).late).toBe((await late({})).late); expect(await late({ staff_id: OWNER })).toMatchObject({ filters: { staff_id: OWNER }, late: 0, platform_bookings: 0 });
    expect((await late({ source_id: BOOKING_COM })).platform_bookings).toBe(res.filter((y) => y.branch_id === A && y.source_id === BOOKING_COM && y.platform_booked_on && dayOf(y.created_at) >= from && dayOf(y.created_at) <= to).length);
    const idn = (filters: Record<string, unknown>) => rpc<any>("fn_reports_identities", { p_branch: A, p_from: from, p_to: to, p_path: "all", p_filters: filters });
    const guests = await all("reservation_guests");
    expect(await idn({ staff_id: SUP })).toMatchObject({ filters: { staff_id: SUP, path: "all" }, count: guests.filter((g) => res.find((y) => y.id === g.reservation_id)?.branch_id === A && g.verification_status === "verified" && g.verified_by === SUP && dayOf(g.verified_at) >= from && dayOf(g.verified_at) <= to).length });
    expect(await idn({ staff_id: OWNER })).toMatchObject({ filters: { staff_id: OWNER, path: "all" }, count: 0 });
    // the options of a branch
    const opt = await rpc<any>("fn_report_filter_options", { p_branch: A });
    expect(opt.staff.map((s: any) => s.id).sort()).toEqual([OWNER, MANAGER, SUP, FIN, HK].sort()); expect(opt.staff.find((s: any) => s.id === SUP)).toMatchObject({ name: "فهد الاستقبال", role: "supervisor", is_active: true });
    expect(opt.accounts.map((a: any) => a.kind).sort()).toEqual(["bank_account", "cash_box"]); expect(opt.sources).toHaveLength(12); expect(opt.categories.map((c: any) => c.name)).toEqual(["استوديو مريح", "شقة بغرفة نوم", "شقة بغرفتين"]);
    expect(opt.floors).toHaveLength(3); expect(opt.floors[0].block).toBeTruthy();
    await login("reception@demo.sa");
    expect(await rpc<any>("fn_report_filter_options", { p_branch: B })).toEqual({}); expect(await fails(rpc("fn_reports_finance", { p_branch: B, p_from: from, p_to: to, p_filters: {} }))).toMatch(/^FORBIDDEN/);
  });

  it("DS09 «تعديل موظف»: a reason, the email, the guest role and an unknown staff member are refused; no one changes their own role or branches (so the only owner is never demoted); name, phone and branches change in one call with one audit row (before, after, what changed, the reason, the phone masked); the branch taken away is retired, not erased, and gone from the person's branches at once; giving it back re-opens the same row; a role change is its own action; the manager reads the list without phones and edits nothing; no direct write", async () => {
    const up = (p: Record<string, unknown>) => rpc<any>("fn_admin_update_staff", { p: { reason: "اختبار", ...p } });
    expect(await fails(rpc("fn_admin_update_staff", { p: { staff_id: SUP, full_name: "x" } }))).toBe("VALIDATION: reason");
    expect(await fails(up({ staff_id: SUP, email: "other@demo.sa" }))).toBe("EMAIL_NOT_EDITABLE");
    expect(await up({ staff_id: SUP, email: " Reception@demo.sa " })).toEqual({ ok: true, unchanged: true });
    expect(await fails(up({ staff_id: SUP, role: "guest" }))).toBe("INVALID_ROLE");
    expect(await fails(up({ staff_id: SUP, full_name: "  " }))).toBe("VALIDATION: full_name");
    expect(await fails(up({ staff_id: uid() }))).toBe("NOT_FOUND: staff");
    expect(await fails(up({ staff_id: OWNER, role: "manager" }))).toBe("SELF_ROLE_OR_BRANCHES");
    expect(await fails(up({ staff_id: OWNER, branch_ids: [A] }))).toBe("SELF_ROLE_OR_BRANCHES");
    expect(await up({ staff_id: OWNER, full_name: "عبدالله المالك" })).toEqual({ ok: true, unchanged: true });
    expect((await all("staff_profiles")).filter((s) => s.role === "owner" && s.is_active)).toHaveLength(1);   // the only owner stays an owner
    // name, phone and branches in one call
    const r = await up({ staff_id: SUP, full_name: "فهد الاستقبال الجديد", phone: "+966 50-123-4567", branch_ids: [A, B], reason: "نقل جزئي إلى جدة" });
    expect(r).toEqual({ ok: true, changed: ["full_name", "phone", "branches"] });
    expect(await get("staff_profiles", SUP)).toMatchObject({ full_name: "فهد الاستقبال الجديد", phone: "+966501234567", role: "supervisor" });
    const trail = async (action: string) => (await rpc<any>("fn_audit_list", { p: { entity_id: SUP, action } })).rows as any[];
    const [a1] = await trail("staff.updated");
    expect(a1).toMatchObject({ category: "security", branch_id: null, entity_ref: "فهد الاستقبال الجديد", actor_name: "عبدالله المالك", reason: "نقل جزئي إلى جدة" });
    expect(a1.details).toEqual({ changed: ["full_name", "phone", "branches"], before: { full_name: "فهد الاستقبال", phone: null, role: "supervisor", branch_ids: [A] }, after: { full_name: "فهد الاستقبال الجديد", phone: "••••4567", role: "supervisor", branch_ids: [A, B] }, reason: "نقل جزئي إلى جدة" });
    expect(JSON.stringify(a1.details)).not.toContain("+966501234567");
    // the branch taken away is retired (the row stays) and gone from the person's branches at their next request
    const memberships = async () => ((await client.from("branch_memberships").select("*").eq("staff_id", SUP)).data as any[]).sort((x, y) => String(x.branch_id).localeCompare(String(y.branch_id)));
    const before = await memberships(); expect(before.map((m) => [m.branch_id, m.removed_at])).toEqual([[A, null], [B, null]]);
    expect(await up({ staff_id: SUP, branch_ids: [B] })).toEqual({ ok: true, changed: ["branches"] });
    const retired = await memberships(); expect(retired).toHaveLength(2); expect(retired[0]).toMatchObject({ id: before[0].id, branch_id: A, removed_by: OWNER }); expect(retired[0].removed_at).toBeTruthy(); expect(retired[1].removed_at).toBeNull();
    await login("reception@demo.sa");
    expect(await rpc<string[]>("fn_user_branch_ids", {})).toEqual([B]);
    expect(await fails(rpc("fn_reservation_calendar", { p_branch: A, p_from: day(0), p_to: day(7) }))).toBe("FORBIDDEN: branch not permitted");
    expect(await rpc<any>("fn_reservation_list", { p_branch: A, p_filters: {}, p_limit: 5, p_offset: 0 })).toEqual({ total: 0, rows: [] });
    expect((await rpc<any>("fn_reservation_list", { p_branch: B, p_filters: {}, p_limit: 5, p_offset: 0 })).total).toBe(0);
    await login("owner@demo.sa");
    expect(await up({ staff_id: SUP, branch_ids: [B, A] })).toEqual({ ok: true, changed: ["branches"] });
    const back = await memberships(); expect(back).toHaveLength(2); expect(back[0]).toMatchObject({ id: before[0].id, branch_id: A, removed_at: null, removed_by: null });
    expect(await up({ staff_id: SUP, branch_ids: [A, B] })).toEqual({ ok: true, unchanged: true });
    await login("reception@demo.sa"); expect((await rpc<string[]>("fn_user_branch_ids", {})).sort()).toEqual([A, B].sort());
    // a role change is its own action with before and after; an unknown branch is refused
    await login("owner@demo.sa");
    expect(await up({ staff_id: FIN, role: "supervisor", phone: "0555555555" })).toEqual({ ok: true, changed: ["phone", "role"] });
    const [rc] = (await rpc<any>("fn_audit_list", { p: { entity_id: FIN, action: "staff.role_changed" } })).rows;
    expect(rc.details).toMatchObject({ changed: ["phone", "role"], before: { role: "finance", phone: null }, after: { role: "supervisor", phone: "••••5555" } });
    expect(await fails(up({ staff_id: SUP, branch_ids: [A, uid()] }))).toBe("FORBIDDEN: branch not permitted");
    const list = await rpc<any[]>("fn_admin_staff_list", {});
    expect(list.find((s) => s.id === OWNER)).toMatchObject({ is_me: true, linked: true, role: "owner", branch_ids: [] });
    expect(list.find((s) => s.id === SUP)).toMatchObject({ is_me: false, phone: "+966501234567", branch_ids: [A, B], sessions_ended_at: null }); expect(list.find((s) => s.id === SUP).updated_at).toBeTruthy();
    expect(list.map((s) => s.is_active)).toEqual([...list.map((s) => s.is_active)].sort((x, y) => Number(y) - Number(x)));
    // the manager reads without phones and edits nothing; the supervisor gets nothing; the table is closed to direct writes
    await login("manager@demo.sa");
    const mgr = await rpc<any[]>("fn_admin_staff_list", {}); expect(mgr.length).toBe(list.length); expect(mgr.every((s) => s.phone === null)).toBe(true);
    expect(await fails(up({ staff_id: SUP, full_name: "x" }))).toMatch(/^FORBIDDEN/);
    expect(await fails(rpc("fn_admin_set_staff_active", { p_staff: SUP, p_active: false, p_reason: "اختبار" }))).toMatch(/^FORBIDDEN/);
    await login("reception@demo.sa");
    expect(await rpc<any[]>("fn_admin_staff_list", {})).toEqual([]); expect(await fails(rpc("fn_admin_force_logout", { p_staff: HK, p_reason: "اختبار" }))).toMatch(/^FORBIDDEN/);
    await login("owner@demo.sa");
    expect((await client.from("staff_profiles").update({ is_active: false }).eq("id", HK)).data).toEqual([]); expect((await get("staff_profiles", HK)).is_active).toBe(true);
    expect((await client.from("branch_memberships").insert({ staff_id: HK, branch_id: B })).error?.code).toBe("42501");
  });

  it("DS10 «تسجيل خروج إجباري» and deactivation: a reason, never oneself; the manager signs out a supervisor but neither an owner nor a manager; the token still in hand is refused on its next request (no identity, no branches, no rows, no operation) while a fresh sign-in works again; deactivation ends the sessions and records the reason, reactivation does not bring the old session back; all of it security rows for the owner alone", async () => {
    await login("reception@demo.sa");
    const held = (await client.auth.getSession()).data.session!;
    expect(await rpc<string | null>("fn_staff_id", {})).toBe(SUP);
    await login("owner@demo.sa");
    expect(await fails(rpc("fn_admin_force_logout", { p_staff: SUP, p_reason: "  " }))).toBe("VALIDATION: reason");
    expect(await fails(rpc("fn_admin_force_logout", { p_staff: OWNER, p_reason: "اختبار" }))).toBe("SELF_NOT_ALLOWED");
    expect(await fails(rpc("fn_admin_force_logout", { p_staff: uid(), p_reason: "اختبار" }))).toBe("NOT_FOUND: staff");
    expect(await rpc<any>("fn_admin_force_logout", { p_staff: SUP, p_reason: "جهاز مفقود" })).toEqual({ ok: true, sessions_ended: 1 });
    const row = (await rpc<any[]>("fn_admin_staff_list", {})).find((s) => s.id === SUP)!; expect(row.is_active).toBe(true); expect(row.sessions_ended_at).toBeTruthy();
    const [ev] = (await rpc<any>("fn_audit_list", { p: { entity_id: SUP, action: "staff.signed_out" } })).rows;
    expect(ev).toMatchObject({ category: "security", actor_id: OWNER, branch_id: null, reason: "جهاز مفقود", details: { reason: "جهاز مفقود", sessions_ended: 1, role: "supervisor", linked: true } });
    // the token still in hand: refused on its next request, on any device
    await client.auth.setSession(held);
    expect(await rpc<string | null>("fn_staff_id", {})).toBeNull(); expect(await rpc<string[]>("fn_user_branch_ids", {})).toEqual([]);
    expect(await rpc<any>("fn_reservation_list", { p_branch: A, p_filters: {}, p_limit: 5, p_offset: 0 })).toEqual({ total: 0, rows: [] });
    expect(await all("reservations")).toEqual([]);
    expect(await fails(rpc("fn_hk_create_task", { p: { room_id: (await rpc<any[]>("fn_available_rooms", { p_branch: A, p_from: day(70), p_to: day(71), p_category: null, p_exclude_reservation: null }))[0]?.room_id ?? uid(), task_type_id: TT_CLEAN } }))).toMatch(/^FORBIDDEN/);
    expect((await client.from("staff_profiles").select("id").eq("auth_user_id", held.user.id).maybeSingle()).data).toBeNull();
    // a fresh sign-in is a new session
    await login("reception@demo.sa");
    expect(await rpc<string | null>("fn_staff_id", {})).toBe(SUP); expect((await rpc<any>("fn_reservation_list", { p_branch: A, p_filters: {}, p_limit: 5, p_offset: 0 })).total).toBeGreaterThan(0);
    // the manager's limits
    await login("owner@demo.sa"); const other = await rpc<any>("fn_staff_invite", { p_email: "second.manager@demo.sa", p_full_name: "مدير ثانٍ", p_role: "manager", p_branch_ids: [A] });
    await login("manager@demo.sa");
    expect(await rpc<any>("fn_admin_force_logout", { p_staff: SUP, p_reason: "اختبار المدير" })).toEqual({ ok: true, sessions_ended: 1 });
    expect(await fails(rpc("fn_admin_force_logout", { p_staff: OWNER, p_reason: "اختبار" }))).toBe("FORBIDDEN: a manager signs out neither an owner nor a manager");
    expect(await fails(rpc("fn_admin_force_logout", { p_staff: other.staff_id, p_reason: "اختبار" }))).toBe("FORBIDDEN: a manager signs out neither an owner nor a manager");
    expect(await fails(rpc("fn_admin_force_logout", { p_staff: MANAGER, p_reason: "اختبار" }))).toBe("SELF_NOT_ALLOWED");
    expect(await rpc<any>("fn_admin_force_logout", { p_staff: other.staff_id, p_reason: "اختبار" }).catch((e: Error) => e.message)).toMatch(/^FORBIDDEN/);
    // deactivation ends the sessions and records the reason; reactivation does not revive them
    await login("finance@demo.sa"); const finHeld = (await client.auth.getSession()).data.session!;
    await login("owner@demo.sa");
    expect(await fails(rpc("fn_admin_set_staff_active", { p_staff: FIN, p_active: false, p_reason: "" }))).toBe("VALIDATION: reason");
    expect(await fails(rpc("fn_admin_set_staff_active", { p_staff: OWNER, p_active: false, p_reason: "اختبار" }))).toBe("SELF_NOT_ALLOWED");
    expect(await fails(rpc("fn_admin_set_staff_active", { p_staff: uid(), p_active: false, p_reason: "اختبار" }))).toBe("NOT_FOUND: staff");
    expect(await rpc<any>("fn_admin_set_staff_active", { p_staff: FIN, p_active: true, p_reason: "لا تغيير" })).toEqual({ ok: true, unchanged: true });
    expect(await rpc<any>("fn_admin_set_staff_active", { p_staff: FIN, p_active: false, p_reason: "انتهى عقده" })).toEqual({ ok: true, is_active: false, sessions_ended: 1 });
    const [off] = (await rpc<any>("fn_audit_list", { p: { entity_id: FIN, action: "staff.deactivated" } })).rows;
    expect(off).toMatchObject({ category: "security", reason: "انتهى عقده", details: { before: { role: "finance", is_active: true }, after: { role: "finance", is_active: false }, reason: "انتهى عقده" } });
    expect(await rpc<any>("fn_admin_set_staff_active", { p_staff: other.staff_id, p_active: false, p_reason: "لم يُربط بعد" })).toEqual({ ok: true, is_active: false, sessions_ended: 0 });
    await client.auth.setSession(finHeld); expect(await rpc<string | null>("fn_staff_id", {})).toBeNull();
    await login("owner@demo.sa");
    expect(await rpc<any>("fn_admin_set_staff_active", { p_staff: FIN, p_active: true, p_reason: "عاد" })).toEqual({ ok: true, is_active: true, sessions_ended: 0 });
    expect((await rpc<any>("fn_audit_list", { p: { entity_id: FIN, action: "staff.activated" } })).rows[0].details).toMatchObject({ before: { is_active: false }, after: { is_active: true }, reason: "عاد" });
    await client.auth.setSession(finHeld); expect(await rpc<string | null>("fn_staff_id", {})).toBeNull();   // the old session is not revived
    await login("finance@demo.sa"); expect(await rpc<string | null>("fn_staff_id", {})).toBe(FIN);
    await login("manager@demo.sa"); expect((await rpc<any>("fn_audit_list", { p: { category: "security" } })).total).toBe(0);
    await login("owner@demo.sa");
    const sec = (await rpc<any>("fn_audit_list", { p: { category: "security", limit: 500 } })).rows.map((x: any) => x.action);
    for (const a of ["staff.signed_out", "staff.deactivated", "staff.activated", "staff_invited"]) expect(sec).toContain(a);
  });

  it("DS11 a task without a start gets «الآن» and no end, a planned start and end are kept, an end before the start is refused; fn_branch_staff lists the owner and the live members, not a retired membership nor a deactivated person, and a retired member cannot be assigned; the invite needs an email and a name, refuses the guest role, and is logged", async () => {
    const room = (await all("rooms")).find((x) => x.room_number === "102")!;
    const t1 = await rpc<any>("fn_hk_create_task", { p: { room_id: room.id, task_type_id: TT_CLEAN } }); const task1 = await get("housekeeping_tasks", t1.id);
    expect(Math.abs(Date.now() - Date.parse(task1.scheduled_start))).toBeLessThan(60_000); expect(task1.scheduled_end).toBeNull();
    const start = `${day(1)}T09:00:00.000Z`, end = `${day(1)}T11:00:00.000Z`;
    const t2 = await rpc<any>("fn_hk_create_task", { p: { room_id: room.id, task_type_id: TT_CLEAN, scheduled_start: start, scheduled_end: end } });
    expect(await get("housekeeping_tasks", t2.id)).toMatchObject({ scheduled_start: start, scheduled_end: end, status: "pending" });
    expect(await fails(rpc("fn_hk_create_task", { p: { room_id: room.id, task_type_id: TT_CLEAN, scheduled_start: end, scheduled_end: start } }))).toBe("VALIDATION: schedule");
    expect(await fails(rpc("fn_hk_create_task", { p: { room_id: room.id, task_type_id: TT_CLEAN, scheduled_start: "not a time" } }))).toBe("VALIDATION: schedule");
    // the branch's staff: live members only
    const staff = () => rpc<any[]>("fn_branch_staff", { p_branch: A }).then((l) => l.map((s) => s.id).sort());
    expect(await staff()).toEqual([OWNER, MANAGER, SUP, FIN, HK].sort());
    expect((await rpc<any[]>("fn_branch_staff", { p_branch: A }))[0]).toMatchObject({ full_name: expect.any(String), role: expect.any(String) });
    await rpc("fn_admin_update_staff", { p: { staff_id: HK, branch_ids: [], reason: "نُقل" } });
    await rpc("fn_admin_set_staff_active", { p_staff: FIN, p_active: false, p_reason: "إجازة طويلة" });
    expect(await staff()).toEqual([OWNER, MANAGER, SUP].sort());
    expect(await fails(rpc("fn_hk_assign_task", { p_task: t1.id, p_assignee: HK }))).toBe("ASSIGNEE_NOT_IN_BRANCH");
    expect(await fails(rpc("fn_hk_create_task", { p: { room_id: room.id, task_type_id: TT_CLEAN, assignee_id: HK } }))).toBe("ASSIGNEE_NOT_IN_BRANCH");
    expect((await rpc<any>("fn_hk_assign_task", { p_task: t1.id, p_assignee: SUP })).ok).toBe(true);
    // the invite
    expect(await fails(rpc("fn_staff_invite", { p_email: "  ", p_full_name: "بلا بريد", p_role: "supervisor", p_branch_ids: [A] }))).toBe("VALIDATION: email_and_name");
    expect(await fails(rpc("fn_staff_invite", { p_email: "g@demo.sa", p_full_name: "ضيف", p_role: "guest", p_branch_ids: [] }))).toBe("INVALID_ROLE");
    expect(await fails(rpc("fn_staff_invite", { p_email: "x@demo.sa", p_full_name: "فرع مجهول", p_role: "supervisor", p_branch_ids: [uid()] }))).toBe("FORBIDDEN: branch not permitted");
    const inv = await rpc<any>("fn_staff_invite", { p_email: " New.Person@demo.sa ", p_full_name: " موظف جديد ", p_role: "housekeeping", p_branch_ids: [A] });
    expect(await get("staff_profiles", inv.staff_id)).toMatchObject({ email: "new.person@demo.sa", full_name: "موظف جديد", role: "housekeeping", is_active: true, auth_user_id: null });
    expect((await rpc<any>("fn_audit_list", { p: { entity_id: inv.staff_id, action: "staff_invited" } })).rows[0]).toMatchObject({ category: "security", entity_ref: "موظف جديد", details: { role: "housekeeping", branch_ids: [A] } });
    expect(await staff()).toContain(inv.staff_id);
    await login("reception@demo.sa"); expect(await rpc<any[]>("fn_branch_staff", { p_branch: B })).toEqual([]);
  });

  it("DS12 «استعمال القدرات» (the owner alone): a capability used this window is «مستخدم» with the log's own count and last use; read-only screens «غير مقيس»; the seed's log starts 33 days back, so a four-week window is covered — a fully audited capability never used is «غير مستخدم», a partly audited one «غير محسوم» — while a five-week window is not; the assistant's executions count as the assistant; an action outside the catalogue is listed; a purge of the log inside the window breaks the measure; weeks clamp 1..26; nothing is removed", async () => {
    await login("manager@demo.sa"); expect(await fails(rpc("fn_reports_capability_usage", { p: { weeks: 4 } }))).toMatch(/^FORBIDDEN/);
    await login("owner@demo.sa");
    const events = await all("audit_events"); const oldest = events.map((e) => Date.parse(e.created_at)).sort()[0];
    expect((Date.now() - oldest) / 86400000).toBeGreaterThan(32); expect((Date.now() - oldest) / 86400000).toBeLessThan(35);
    const r = await rpc<any>("fn_reports_capability_usage", { p: { weeks: 4 } });
    expect(r).toMatchObject({ weeks: 4, log_covers_window: true, log_since: new Date(oldest).toISOString() }); expect(r.note).toContain("القرار 53"); expect(r.note).toContain("غير محسوم");
    expect(Math.abs(Date.parse(r.generated_at) - Date.parse(r.window_start) - 28 * 86400000)).toBeLessThan(5000);
    const row = (code: string, rep = r) => rep.rows.find((x: any) => x.code === code);
    const created = events.filter((e) => e.action === "reservation.created" && e.result === "success");
    expect(row("reservations.create")).toMatchObject({ status: "used", area: "الحجوزات", core: false, coverage: "full", window_count: created.filter((e) => Date.parse(e.created_at) >= Date.parse(r.window_start)).length, week_count: created.filter((e) => Date.parse(e.created_at) >= Date.now() - 7 * 86400000).length, last_success_at: new Date(Math.max(...created.map((e) => Date.parse(e.created_at)))).toISOString() });
    expect(row("reservations.create").by.human).toBe(row("reservations.create").window_count); expect(row("reservations.create").by.assistant).toBe(0);
    expect(row("screens.reports").status).toBe("unmeasured"); expect(row("admin.facilities")).toMatchObject({ core: true, status: "used" });   // the seed archived a facility 20 days ago
    expect(row("housekeeping.maintenance")).toMatchObject({ status: "idle", last_success_at: null, window_count: 0 }); expect(row("stay.summary")).toMatchObject({ status: "undetermined", coverage: "partial" });
    expect(r.rows.map((x: any) => x.code).sort()).toEqual([...new Set(r.rows.map((x: any) => x.code))].sort()); expect(r.rows.length).toBe(51);   // 50 in 0041, and «مصفوفة الصلاحيات» since 0044
    expect(r.rows.every((x: any, i: number) => i === 0 || r.rows[i - 1].area.localeCompare(x.area) <= 0)).toBe(true);
    const r5 = await rpc<any>("fn_reports_capability_usage", { p: { weeks: 5 } });
    expect(r5.log_covers_window).toBe(false); expect(r5.rows.some((x: any) => x.status === "idle")).toBe(false); expect(row("housekeeping.maintenance", r5).status).toBe("undetermined"); expect(row("reservations.create", r5).status).toBe("used");
    expect((await rpc<any>("fn_reports_capability_usage", { p: { weeks: 0 } })).weeks).toBe(1); expect((await rpc<any>("fn_reports_capability_usage", { p: { weeks: 99 } })).weeks).toBe(26); expect((await rpc<any>("fn_reports_capability_usage", { p: {} })).weeks).toBe(4);
    // the assistant's execution: every row it writes carries source = ops_assistant and counts as the assistant
    const conv = (await client.from("ai_ops_conversations").insert({ organization_id: "00000000-0000-0000-0000-000000000001", branch_id: A, staff_id: OWNER, title: "تجربة", last_message_at: new Date().toISOString() }).select("id").single()).data as any;
    const room = (await all("rooms")).find((x) => x.room_number === "U-1")!;
    const prop = await rpc<any>("fn_ai_ops_propose", { p_conversation: conv.id, p_action: "create_task", p_args: { room_id: room.id, task_type_id: TT_CLEAN, priority: "medium", description: "من المحادثة" }, p_summary: "مهمة تنظيف" });
    expect((await rpc<any>("fn_ai_ops_execute_proposal", { p_id: prop.proposal_id })).ok).toBe(true);
    const written = (await all("audit_events")).filter((e) => ["task.created", "ai_proposal.executed"].includes(e.action));
    expect(written).toHaveLength(2); expect(written.every((e) => e.source === "ops_assistant" && e.actor_id === OWNER)).toBe(true);
    // a human row after it keeps its own source; an action outside the catalogue is listed under «other»
    const res = await book(70, 72); const free = await rpc<any[]>("fn_available_rooms", { p_branch: A, p_from: day(70), p_to: day(72), p_category: STUDIO, p_exclude_reservation: null });
    await rpc("fn_staff_assign_room", { p_reservation: res.id, p_room: free[0].room_id });
    const r2 = await rpc<any>("fn_reports_capability_usage", { p: { weeks: 4 } });
    expect(row("housekeeping.tasks", r2)).toMatchObject({ status: "used", window_count: 1, week_count: 1, by: { human: 0, assistant: 1, automation: 0, guest: 0 } });
    expect(row("assistant.ops", r2)).toMatchObject({ status: "used", by: { assistant: 1 } });
    expect(row("reservations.create", r2).by.human).toBe(row("reservations.create").by.human + 1);
    expect(r2.other_actions.find((o: any) => o.action === "assign_room")).toMatchObject({ label: "تخصيص وحدة للحجز", window_count: 1 });
    expect(r2.other_actions.some((o: any) => o.action === "reservation.created")).toBe(false);
    // a purge of the log inside the window (a real one, over a period that holds nothing) breaks the measure; the report removes nothing
    const pv = await rpc<any>("fn_admin_purge_preview", { p_branch: null, p_from: day(-800), p_to: day(-700), p_categories: ["audit"] });
    expect((await rpc<any>("fn_admin_purge_execute", { p_token: pv.token, p_phrase: "احذف نهائيا" })).ok).toBe(true);
    const n = (await all("audit_events")).length;
    const r3 = await rpc<any>("fn_reports_capability_usage", { p: { weeks: 4 } });
    expect(r3.log_covers_window).toBe(false); expect(r3.rows.some((x: any) => x.status === "idle")).toBe(false); expect(row("housekeeping.maintenance", r3).status).toBe("undetermined"); expect(row("housekeeping.tasks", r3).status).toBe("used");
    expect(row("admin.purge", r3)).toMatchObject({ status: "used", window_count: 1, core: true });
    expect((await all("audit_events")).length).toBe(n);
  });
});
