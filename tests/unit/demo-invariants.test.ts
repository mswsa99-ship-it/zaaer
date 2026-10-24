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
