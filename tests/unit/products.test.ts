/**
 * W1 (migration 0068) in the demo store — the demo facet of tests/sql/products_w1_tests.sql (PD01–PD13): the example
 * catalogue and what each branch offers; a guest's order through the WhatsApp ports (server side, the guest token);
 * the payment at reception (the lines in the stay's account, a receipt marked as the order's, product revenue, the
 * delivery task); the guards on the order's voucher and task; the delivery when the task is done; the owner's
 * cancellation of a paid order. And the conversation itself on the reception computer (the server code of wa-bridge
 * against the demo store): «المنتجات» → a category → a product → how many → the order.
 */
import { describe, it, expect, beforeAll, beforeEach } from "vitest";

type Demo = typeof import("../../src/demo/client");
type Sim = typeof import("../../src/demo/whatsappSim");
let demo: Demo; let sim: Sim;
let staff: ReturnType<Demo["createDemoClient"]>;

const memStorage = () => {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, String(v)), removeItem: (k: string) => void m.delete(k), clear: () => m.clear(), key: () => null, length: 0 };
};
async function rpc<T = any>(fn: string, args: Record<string, unknown> = {}): Promise<T> { // eslint-disable-line @typescript-eslint/no-explicit-any
  const { data, error } = await staff.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}
async function service<T = any>(fn: string, args: Record<string, unknown>): Promise<T> { // eslint-disable-line @typescript-eslint/no-explicit-any
  const { data, error } = await demo.createDemoServiceClient().rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}
const fails = async (p: Promise<unknown>) => { try { await p; return "accepted"; } catch (e) { return (e as Error).message; } };
const as = (email: string) => staff.auth.signInWithPassword({ email, password: "demo" });
const IN_HOUSE = "966501110001";   // the seed's guest in room 101 (checked in, the first branch)

/** a guest token of the in-house stay of room 101, as the WhatsApp flow gets it (the phone session, then the booking) */
async function guestToken(): Promise<{ token: string; reservation: string; branch: string }> {
  const ps = await service<string>("fn_whatsapp_phone_session", { p_phone: IN_HOUSE });
  const list = await service<{ reservations: Array<{ internal_ref: string; status: string }> }>("fn_guest_phone_reservations", { p_token: ps });
  const b = list.reservations.find((r) => r.status === "checked_in")!;
  const { token } = await service<{ token: string }>("fn_guest_phone_open", { p_token: ps, p_internal_ref: b.internal_ref });
  const { data } = await demo.createDemoServiceClient().from("reservations").select("id, branch_id").eq("internal_ref", b.internal_ref).single();
  return { token, reservation: (data as { id: string }).id, branch: (data as { branch_id: string }).branch_id };
}
const item = (id: string, quantity: number) => ({ product_id: id, quantity });
/** the order's version as a cashier who just opened it sees it */
const ver = async (id: string) => ((await demo.createDemoServiceClient().from("product_orders").select("version").eq("id", id).single()).data as { version: number }).version;

beforeAll(async () => {
  (globalThis as any).window = globalThis; // eslint-disable-line @typescript-eslint/no-explicit-any
  (globalThis as any).localStorage = memStorage(); // eslint-disable-line @typescript-eslint/no-explicit-any
  (globalThis as any).sessionStorage = memStorage(); // eslint-disable-line @typescript-eslint/no-explicit-any
  (globalThis as any).location = { href: "https://demo.test/index.html#/" }; // eslint-disable-line @typescript-eslint/no-explicit-any
  demo = await import("../../src/demo/client");
  sim = await import("../../src/demo/whatsappSim");
  staff = demo.createDemoClient();
});
beforeEach(async () => { demo.resetDemo(); await as("owner@demo.sa"); });

describe("products and orders in the demo (W1)", () => {
  it("PD20 the example catalogue: 3 categories and 12 products without stock; the first branch offers all, the second its own; the owner adds and makes available", async () => {
    const a = await rpc("fn_admin_products");
    expect(a.categories).toHaveLength(3);
    expect(a.products).toHaveLength(12);
    const [b1, b2] = a.branches.map((b: { id: string }) => b.id);
    const offered = (b: string) => a.products.filter((p: { branches: string[] }) => p.branches.includes(b)).length;
    expect(offered(b1) + offered(b2)).toBe(18);
    expect(Math.max(offered(b1), offered(b2))).toBe(12);
    const cat = a.categories[0].id;
    expect(await fails(rpc("fn_admin_upsert_product", { p: { category_id: cat, name: " ", price_halalas: 100 } }))).toMatch(/VALIDATION: product_name/);
    expect(await fails(rpc("fn_admin_upsert_product", { p: { category_id: cat, name: "عصير", price_halalas: 0 } }))).toMatch(/VALIDATION: product_price/);
    expect(await fails(rpc("fn_admin_upsert_product", { p: { category_id: cat, name: "ماء صغير", price_halalas: 100 } }))).toMatch(/DUPLICATE_NAME/);
    const r = await rpc("fn_admin_upsert_product", { p: { category_id: cat, name: "حليب", price_halalas: 350 } });
    await rpc("fn_admin_set_product_branch", { p_product: r.id, p_branch: b2, p_available: true });
    const after = await rpc("fn_admin_products");
    expect(after.products.find((p: { id: string }) => p.id === r.id).branches).toEqual([b2]);
    // the supervisor does not change the catalogue
    await as("reception@demo.sa");
    expect(await fails(rpc("fn_admin_upsert_product_category", { p: { name: "فئة" } }))).toMatch(/FORBIDDEN/);
  });

  it("PD21 a guest in the house orders through the WhatsApp ports; the reception takes the payment: the lines join the stay's account, a receipt of the same amount pays them as product revenue, and the delivery task is created", async () => {
    const g = await guestToken();
    const shop = await service("fn_guest_products", { p_token: g.token });
    expect(shop.can_order).toBe(true);
    const water = shop.categories.flatMap((c: { products: Array<{ id: string; name: string }> }) => c.products).find((p: { name: string }) => p.name === "ماء صغير");
    const o = await service("fn_guest_order_products", { p_token: g.token, p_items: [item(water.id, 2)] });
    const o2 = await service("fn_guest_order_products", { p_token: g.token, p_items: [item(water.id, 1)] });
    expect(o2.id).toBe(o.id);
    expect(o2.lines).toEqual([expect.objectContaining({ name: "ماء صغير", quantity: 3 })]);
    expect(o2.status).toBe("pending_payment");
    // the browser never reaches the guest's functions
    expect(await fails(rpc("fn_guest_order_products", { p_token: g.token, p_items: [item(water.id, 1)] }))).toMatch(/NOT_IMPLEMENTED|FORBIDDEN|permission denied/i);

    await as("reception@demo.sa");
    const before = await rpc("fn_reservation_detail", { p_reservation: g.reservation }).catch(() => null);
    const due0 = before?.finance?.balance_due ?? null;
    expect(await fails(rpc("fn_staff_pay_product_order", { p: { order_id: o.id, method: "ota_deferred", idempotency_key: "k0", expected_version: (await ver(o.id)) } }))).toMatch(/VALIDATION: order_method/);
    const paid = await rpc("fn_staff_pay_product_order", { p: { order_id: o.id, method: "cash", idempotency_key: "pd21", expected_version: (await ver(o.id)) } });
    expect(paid.duplicate).toBe(false);
    expect(paid.order.status).toBe("paid");
    expect((await rpc("fn_staff_pay_product_order", { p: { order_id: o.id, method: "cash", idempotency_key: "pd21", expected_version: (await ver(o.id)) } })).duplicate).toBe(true);
    expect(await fails(rpc("fn_staff_pay_product_order", { p: { order_id: o.id, method: "cash", idempotency_key: "other", expected_version: (await ver(o.id)) } }))).toMatch(/VALIDATION: order_status/);
    const db = demo.createDemoServiceClient();
    const { data: v } = await db.from("financial_vouchers").select("*").eq("number", paid.voucher_number).single();
    expect(v).toMatchObject({ kind: "receipt", amount_halalas: paid.order.total_halalas, product_order_id: o.id, status: "approved" });
    const { data: charges } = await db.from("reservation_charges").select("total_halalas, product_order_id").eq("product_order_id", o.id);
    expect((charges as Array<{ total_halalas: number }>).reduce((s, c) => s + c.total_halalas, 0)).toBe(paid.order.total_halalas);
    const { data: task } = await db.from("housekeeping_tasks").select("*").eq("task_type_name_snapshot", "تسليم طلب منتجات").single();
    expect(task).toMatchObject({ status: "pending", priority: "high" });
    expect(String((task as { description: string }).description)).toContain("3 × ماء صغير");
    if (due0 != null) expect((await rpc("fn_reservation_detail", { p_reservation: g.reservation })).finance.balance_due).toBe(due0);
    // the books: product revenue (43), not rent
    await as("owner@demo.sa");
    const today = new Date(Date.now() + 3 * 3600_000).toISOString().slice(0, 10);
    const inc = await rpc("fn_income_statement", { p_from: today, p_to: today, p_branch: g.branch });
    expect(inc.rows.find((r: { code: string }) => r.code === "43")?.amount_halalas).toBe(paid.order.total_halalas);
  });

  it("PD22 an order's voucher and task are not undone on their own; the order is delivered when its task is done; a delivered order is not cancelled", async () => {
    const g = await guestToken();
    const shop = await service("fn_guest_products", { p_token: g.token });
    const pid = shop.categories[0].products[0].id;
    const o = await service("fn_guest_order_products", { p_token: g.token, p_items: [item(pid, 1)] });
    const paid = await rpc("fn_staff_pay_product_order", { p: { order_id: o.id, method: "cash", idempotency_key: "pd22", expected_version: (await ver(o.id)) } });
    const db = demo.createDemoServiceClient();
    const { data: v } = await db.from("financial_vouchers").select("id").eq("number", paid.voucher_number).single();
    const { data: ord } = await db.from("product_orders").select("task_id").eq("id", o.id).single();
    const taskId = (ord as { task_id: string }).task_id;
    expect(await fails(rpc("fn_cancel_voucher", { p_voucher: (v as { id: string }).id, p_reason: "خطأ" }))).toMatch(/VALIDATION: order_voucher/);
    expect(await fails(rpc("fn_staff_correct_voucher", { p: { voucher_id: (v as { id: string }).id, reason: "تصحيح", idempotency_key: "c1", amount_halalas: 100 } }))).toMatch(/VALIDATION: order_voucher/);
    expect(await fails(rpc("fn_hk_cancel_task", { p_task: taskId, p_reason: "لا داعي" }))).toMatch(/VALIDATION: order_task/);
    const { data: t } = await db.from("housekeeping_tasks").select("version").eq("id", taskId).single();
    await rpc("fn_hk_complete_task", { p_task: taskId, p_note: null, p_expected_version: (t as { version: number }).version });
    const list = await rpc("fn_staff_product_orders", { p_branch: g.branch, p_status: "delivered", p_days: 7 });
    expect(list.map((x: { id: string }) => x.id)).toContain(o.id);
    expect(await fails(rpc("fn_staff_cancel_product_order", { p_order: o.id, p_reason: "تأخر" }))).toMatch(/VALIDATION: order_delivered/);
  });

  it("PD23 the owner cancels a paid order not yet delivered: its receipt is cancelled, its lines balanced back, its task cancelled; the supervisor may not; a waiting order is cancelled by the reception or the guest", async () => {
    const g = await guestToken();
    const shop = await service("fn_guest_products", { p_token: g.token });
    const pid = shop.categories[0].products[1].id;
    const o = await service("fn_guest_order_products", { p_token: g.token, p_items: [item(pid, 2)] });
    await as("reception@demo.sa");
    const paid = await rpc("fn_staff_pay_product_order", { p: { order_id: o.id, method: "cash", idempotency_key: "pd23", expected_version: (await ver(o.id)) } });
    expect(await fails(rpc("fn_staff_cancel_product_order", { p_order: o.id, p_reason: "رفضه النزيل" }))).toMatch(/FORBIDDEN/);
    await as("owner@demo.sa");
    expect(await fails(rpc("fn_staff_cancel_product_order", { p_order: o.id, p_reason: " " }))).toMatch(/VALIDATION: reason/);
    const c = await rpc("fn_staff_cancel_product_order", { p_order: o.id, p_reason: "رفضه النزيل" });
    expect(c.status).toBe("cancelled");
    const db = demo.createDemoServiceClient();
    const { data: v } = await db.from("financial_vouchers").select("status").eq("number", paid.voucher_number).single();
    expect((v as { status: string }).status).toBe("cancelled");
    const { data: charges } = await db.from("reservation_charges").select("total_halalas").eq("product_order_id", o.id);
    expect((charges as Array<{ total_halalas: number }>).reduce((s, x) => s + x.total_halalas, 0)).toBe(0);
    expect(c.task_status).toBe("cancelled");
    // a waiting order: the guest cancels it from WhatsApp, only their own and only once
    const w = await service("fn_guest_order_products", { p_token: g.token, p_items: [item(pid, 1)] });
    expect((await service("fn_guest_cancel_product_order", { p_token: g.token, p_number: w.number })).status).toBe("cancelled");
    expect(await fails(service("fn_guest_cancel_product_order", { p_token: g.token, p_number: w.number }))).toMatch(/VALIDATION: order_status/);
  });

  it("PD27 with tax added on top (15%) an order carries its tax; cancelling it reverses the tax with it and the order nets to zero", async () => {
    const g = await guestToken();
    const db = demo.createDemoServiceClient();
    await db.from("reservations").update({ tax_rate_bp: 1500, prices_include_tax: false }).eq("id", g.reservation);
    const shop = await service("fn_guest_products", { p_token: g.token });
    const water = shop.categories[0].products.find((p: { name: string }) => p.name === "ماء صغير");
    const o = await service("fn_guest_order_products", { p_token: g.token, p_items: [item(water.id, 2)] });
    expect(o.total_halalas).toBe(460);                                   // 2 × 2.00 + 15%
    const paid = await rpc("fn_staff_pay_product_order", { p: { order_id: o.id, method: "cash", idempotency_key: "pd27", expected_version: (await ver(o.id)) } });
    expect(paid.order.total_halalas).toBe(460);
    await rpc("fn_staff_cancel_product_order", { p_order: o.id, p_reason: "خطأ في الطلب" });
    const { data } = await db.from("reservation_charges").select("kind, total_halalas").eq("product_order_id", o.id);
    const rows = data as Array<{ kind: string; total_halalas: number }>;
    expect(rows.filter((r) => r.kind === "tax").map((r) => r.total_halalas).sort((a, b) => a - b)).toEqual([-60, 60]);
    expect(rows.reduce((x, r) => x + r.total_halalas, 0)).toBe(0);
  });

  it("PD29 the review's cases: an item added after the cashier opened the payment refuses it; a cancelled paid order leaves the stay's dues as they were; the delivery follows a room move; the departure cancels a waiting order", async () => {
    const g = await guestToken();
    const shop = await service("fn_guest_products", { p_token: g.token });
    const [w1, w2] = shop.categories[0].products;
    const o = await service("fn_guest_order_products", { p_token: g.token, p_items: [item(w1.id, 1)] });
    const seen = await ver(o.id);
    await service("fn_guest_order_products", { p_token: g.token, p_items: [item(w2.id, 1)] });
    expect(await fails(rpc("fn_staff_pay_product_order", { p: { order_id: o.id, method: "cash", idempotency_key: "pd29", expected_version: seen } }))).toMatch(/VERSION_CONFLICT/);
    expect(await fails(rpc("fn_staff_pay_product_order", { p: { order_id: o.id, method: "cash", idempotency_key: "pd29" } }))).toMatch(/VERSION_REQUIRED/);
    const due0 = (await rpc("fn_reservation_detail", { p_reservation: g.reservation })).stay?.due ?? (await rpc("fn_reservation_detail", { p_reservation: g.reservation })).finance;
    await rpc("fn_staff_pay_product_order", { p: { order_id: o.id, method: "cash", idempotency_key: "pd29c", expected_version: await ver(o.id) } });
    await rpc("fn_staff_cancel_product_order", { p_order: o.id, p_reason: "تجربة" });
    const d1 = await rpc("fn_reservation_detail", { p_reservation: g.reservation });
    expect(d1.stay?.due ?? d1.finance).toEqual(due0);
    const db = demo.createDemoServiceClient();
    const { data: rows } = await db.from("reservation_charges").select("kind").eq("product_order_id", o.id);
    expect((rows as Array<{ kind: string }>).every((r) => r.kind !== "adjustment")).toBe(true);
    // a reception order is not the guest's to cancel from WhatsApp
    const s2 = await rpc("fn_staff_create_product_order", { p_reservation: g.reservation, p_items: [item(w1.id, 1)] });
    expect(await fails(service("fn_guest_cancel_product_order", { p_token: g.token, p_number: s2.number }))).toMatch(/VALIDATION: order_status/);
    // the departure: the waiting order is cancelled with its reason
    await db.from("reservations").update({ status: "checked_out" }).eq("id", g.reservation);
    await rpc("fn_admin_products");
    const { data: after } = await db.from("product_orders").select("status, cancel_reason").eq("id", s2.id).single();
    expect(after).toMatchObject({ status: "cancelled", cancel_reason: "غادر النزيل قبل الدفع" });
  });

  it("PD24 the reception orders for a guest in the house only, and a role that does not see money reads no order", async () => {
    await as("reception@demo.sa");
    const branches = (await rpc("fn_admin_products").catch(() => null)) ?? null;
    expect(branches).toBeNull();   // the catalogue settings are the owner's and the manager's
    const g = await guestToken();
    const menu = await rpc("fn_staff_product_menu", { p_branch: g.branch });
    expect(menu.stays.map((s: { id: string }) => s.id)).toContain(g.reservation);
    const o = await rpc("fn_staff_create_product_order", { p_reservation: g.reservation, p_items: [item(menu.categories[0].products[0].id, 1)] });
    expect(o).toMatchObject({ source: "staff", status: "pending_payment" });
    const { data: future } = await demo.createDemoServiceClient().from("reservations").select("id").eq("branch_id", g.branch).eq("status", "confirmed").limit(1).single();
    expect(await fails(rpc("fn_staff_create_product_order", { p_reservation: (future as { id: string }).id, p_items: [item(menu.categories[0].products[0].id, 1)] }))).toMatch(/VALIDATION: not_in_stay/);
    await as("housekeeping@demo.sa");
    const { data: rows } = await staff.from("product_orders").select("id");
    expect(rows ?? []).toHaveLength(0);
    expect(await fails(rpc("fn_staff_product_orders", { p_branch: g.branch }))).toMatch(/FORBIDDEN/);
  });
});

describe("the owner's list, pasted once («استيراد قائمة», W1)", () => {
  it("PD28 each line is a category, a product and a price (Arabic digits and «ر.س» read); a bad line says why; a name already there, or twice in the list, is left", async () => {
    const { parseProductList } = await import("../../src/lib/productImport");
    const lines = parseProductList([
      "مشروبات، ماء صغير، 2",
      "مشروبات، قهوة، ٥٫٥٠ ر.س، ظرفان مع كوب",
      "مستلزمات شخصية\tشاحن جوال\t25",
      "",
      "مشروبات, عصير, 1,250",
      "مشروبات، بلا سعر",
      "مشروبات، ماء صغير، 3",
      "وجبات، بسكويت، 3",
      "مشروبات, حليب, 3.5 ريال, علبة صغيرة",
    ].join("\n"), ["بسكويت"]);
    expect(lines.map((l) => [l.n, l.category, l.name, l.price, l.description, l.problem, l.existing])).toEqual([
      [1, "مشروبات", "ماء صغير", 200, null, null, false],
      [2, "مشروبات", "قهوة", 550, "ظرفان مع كوب", null, false],
      [3, "مستلزمات شخصية", "شاحن جوال", 2500, null, null, false],
      [5, "مشروبات", "عصير", 125000, null, null, false],
      [6, "مشروبات", "بلا سعر", null, null, "السعر غير مقروء (بالريال، مثل 2.50)", false],
      [7, "مشروبات", "ماء صغير", 300, null, null, true],
      [8, "وجبات", "بسكويت", 300, null, null, true],
      [9, "مشروبات", "حليب", 350, "علبة صغيرة", null, false],
    ]);
  });
});

describe("ordering on WhatsApp, end to end on the reception computer (W1)", () => {
  const branchOfBridge = async () => {
    const list = await rpc<Array<{ branch_id: string; mode: string }>>("fn_admin_whatsapp_channels", {});
    return list.find((x) => x.mode === "web_bridge" && demo.demoBridgeKey(x.branch_id))!.branch_id;
  };
  it("PD25 «المنتجات» → a category → a product → how many: the order waits for the payment and the reception sees it; «إلغاء الطلب» cancels it", async () => {
    const BRANCH = await branchOfBridge();
    const a = await sim.simSend(BRANCH, IN_HOUSE, "المنتجات");
    expect(a.replies[0]).toMatch(/اختر الفئة/);
    expect(a.replies[0]).toMatch(/1️⃣ مشروبات/);
    const b = await sim.simSend(BRANCH, IN_HOUSE, "1");
    expect(b.replies[0]).toMatch(/مشروبات — اختر المنتج/);
    expect(b.replies[0]).toMatch(/1️⃣ ماء صغير/);
    const c = await sim.simSend(BRANCH, IN_HOUSE, "1");
    expect(c.replies[0]).toMatch(/ماء صغير — 2\.00 ر\.س/);
    expect(c.replies[0]).toMatch(/اختر الكمية:\n\n1️⃣ قطعة واحدة\n2️⃣ قطعتان\n3️⃣ 3 قطع/);
    const d = await sim.simSend(BRANCH, IN_HOUSE, "2");
    expect(d.replies[0]).toMatch(/أضفت 2 × ماء صغير إلى طلبك\.\nرقم الطلب: ORD-2026-\d{6}\n/);
    expect(d.replies[0]).toMatch(/الإجمالي: /);
    expect(d.replies[0]).toMatch(/يتواصل معك الاستقبال لإتمام الدفع/);
    const orders = await rpc("fn_staff_product_orders", { p_branch: BRANCH });
    const o = orders.find((x: { source: string; status: string }) => x.source === "whatsapp" && x.status === "pending_payment");
    expect(o.lines).toEqual([expect.objectContaining({ name: "ماء صغير", quantity: 2 })]);
    // the guest cancels from the same message (option 2: «إلغاء الطلب»)
    const e = await sim.simSend(BRANCH, IN_HOUSE, "2");
    expect(e.replies[0]).toMatch(new RegExp(`أُلغي طلبك رقم ${o.number}`));
    expect((await rpc("fn_staff_product_orders", { p_branch: BRANCH, p_status: "cancelled" })).map((x: { id: string }) => x.id)).toContain(o.id);
  });

  it("PD26 a guest who is not in the house is told ordering is for guests in their room; nothing is ordered", async () => {
    const BRANCH = await branchOfBridge();
    const r = await sim.simSend(BRANCH, "966501110010", "المنتجات");   // two confirmed stays, none checked in
    expect(r.replies[0]).toMatch(/للنزيل المقيم بعد تسجيل وصوله/);
    expect((await rpc("fn_staff_product_orders", { p_branch: BRANCH })).filter((x: { source: string }) => x.source === "whatsapp")).toHaveLength(0);
  });
});
