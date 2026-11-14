/**
 * W2 (migration 0069) in the demo store — the demo facet of tests/sql/tax_w2_tests.sql (VT01–VT18): the value-added
 * tax is off by default; rent, services and products each have their switch and their rate in the branch's settings,
 * the owner's alone; a reservation keeps the policy it was made under (three rates), so a change reaches new
 * reservations only; a product order says how much of its total is tax and is paid as shown. And what the guest reads
 * on WhatsApp when the products of their stay are taxed.
 */
import { describe, it, expect, beforeAll, beforeEach } from "vitest";

type Demo = typeof import("../../src/demo/client");
type Sim = typeof import("../../src/demo/whatsappSim");
let demo: Demo; let sim: Sim;
let staff: ReturnType<Demo["createDemoClient"]>;
let BRANCH: string; let CAT: string; let SOURCE: string; let SVC: { id: string; price_halalas: number }; let WATER: string; let roomNo = 900;

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
const db = () => demo.createDemoServiceClient();
const fails = async (p: Promise<unknown>) => { try { await p; return "accepted"; } catch (e) { return (e as Error).message; } };
const as = (email: string) => staff.auth.signInWithPassword({ email, password: "demo" });
const day = (n: number) => { const d = new Date(new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Riyadh" }) + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const IN_HOUSE = "966501110001";   // the seed's guest in room 101 (checked in, the first branch): a stay made before any switch
const item = (id: string, quantity: number) => ({ product_id: id, quantity });

const branchRow = async (id = BRANCH) => (await db().from("branches").select("*").eq("id", id).single()).data as Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
/** the owner's (or whoever is signed in) change of the branch's switches, with the version on file */
const set = async (p: Record<string, unknown>, id = BRANCH) => { const b = await branchRow(id); return rpc("fn_admin_upsert_branch", { p: { id, name_ar: b.name_ar, version: b.version, ...p } }); };
/** rent, services, products (on/off and rate), and the rent rate in force */
const switches = async (id = BRANCH) => { const b = await branchRow(id); return `${b.tax_rent_enabled}:${b.tax_rent_rate_bp} ${b.tax_services_enabled}:${b.tax_services_rate_bp} ${b.tax_products_enabled}:${b.tax_products_rate_bp} in force ${b.tax_rate_bp}`; };
/** the policy a stay was made under: rent/services/products */
const policy = async (res: string) => { const r = (await db().from("reservations").select("*").eq("id", res).single()).data as Record<string, any>; return `${r.tax_rate_bp}/${r.tax_services_rate_bp ?? "null"}/${r.tax_products_rate_bp ?? "null"}`; }; // eslint-disable-line @typescript-eslint/no-explicit-any
const fin = (res: string) => rpc<{ total: number; tax: number; rent: number }>("fn_reservation_finance", { p_reservation: res });
/** a stay of two nights from today in a room of its own, its rent paid, in the house (the check-in itself is not what is tried here) */
async function stay(phone: string): Promise<string> {
  const room = await rpc<{ id: string }>("fn_admin_upsert_room", { p: { branch_id: BRANCH, category_id: CAT, room_number: String(roomNo++) } });
  const r = await rpc<{ id: string }>("fn_staff_create_reservation", { p: { branch_id: BRANCH, category_id: CAT, source_id: SOURCE, check_in: day(0), check_out: day(2), guest_name: "نزيل الضريبة", guest_phone: phone, adults: 1, companions: 0, room_id: room.id } });
  await rpc("fn_create_voucher", { p: { reservation_id: r.id, kind: "receipt", amount_halalas: (await fin(r.id)).total, method: "cash", idempotency_key: `vt-rent-${r.id}` } });
  await db().from("reservations").update({ status: "checked_in", room_id: room.id }).eq("id", r.id);
  return r.id;
}
const order = (res: string, items: unknown[]) => rpc<any>("fn_staff_create_product_order", { p_reservation: res, p_items: items }); // eslint-disable-line @typescript-eslint/no-explicit-any
const pay = (o: { id: string; version: number }, key: string) => rpc<any>("fn_staff_pay_product_order", { p: { order_id: o.id, method: "cash", idempotency_key: key, expected_version: o.version } }); // eslint-disable-line @typescript-eslint/no-explicit-any
const orderRows = async (id: string) => ((await db().from("reservation_charges").select("kind, total_halalas").eq("product_order_id", id)).data ?? []) as Array<{ kind: string; total_halalas: number }>;
async function inHouse(): Promise<{ token: string; reservation: string }> {
  const ps = await service<string>("fn_whatsapp_phone_session", { p_phone: IN_HOUSE });
  const list = await service<{ reservations: Array<{ internal_ref: string; status: string }> }>("fn_guest_phone_reservations", { p_token: ps });
  const b = list.reservations.find((r) => r.status === "checked_in")!;
  const { token } = await service<{ token: string }>("fn_guest_phone_open", { p_token: ps, p_internal_ref: b.internal_ref });
  const { data } = await db().from("reservations").select("id").eq("internal_ref", b.internal_ref).single();
  return { token, reservation: (data as { id: string }).id };
}

beforeAll(async () => {
  (globalThis as any).window = globalThis; // eslint-disable-line @typescript-eslint/no-explicit-any
  (globalThis as any).localStorage = memStorage(); // eslint-disable-line @typescript-eslint/no-explicit-any
  (globalThis as any).sessionStorage = memStorage(); // eslint-disable-line @typescript-eslint/no-explicit-any
  (globalThis as any).location = { href: "https://demo.test/index.html#/" }; // eslint-disable-line @typescript-eslint/no-explicit-any
  demo = await import("../../src/demo/client");
  sim = await import("../../src/demo/whatsappSim");
  staff = demo.createDemoClient();
});
beforeEach(async () => {
  demo.resetDemo(); roomNo = 900; await as("owner@demo.sa");
  BRANCH = ((await staff.from("branches").select("id").order("name_ar").limit(1).maybeSingle()).data as { id: string }).id;
  CAT = ((await staff.from("room_categories").select("id").eq("branch_id", BRANCH).order("base_price_halalas").limit(1).maybeSingle()).data as { id: string }).id;
  const s = (await staff.from("booking_sources").select("id, external_reference_required").eq("is_active", true)).data as Array<{ id: string; external_reference_required: boolean }>;
  SOURCE = (s.find((x) => !x.external_reference_required) ?? s[0]).id;
  SVC = ((await staff.from("service_definitions").select("id, price_halalas, taxable, billing_unit, late_checkout_until").eq("branch_id", BRANCH).eq("billing_unit", "once")).data as Array<Record<string, any>>) // eslint-disable-line @typescript-eslint/no-explicit-any
    .find((x) => x.taxable && !x.late_checkout_until) as { id: string; price_halalas: number };
  WATER = (await rpc<{ products: Array<{ id: string; name: string }> }>("fn_admin_products")).products.find((p) => p.name === "ماء صغير")!.id;
});

describe("the tax switches in the demo (W2)", () => {
  it("VT20 the tax is off by default: every branch has its three switches off with a rate ready, a new branch too, and a stay made so carries no tax", async () => {
    expect(await switches()).toBe("false:1500 false:1500 false:1500 in force 0");
    const nb = await rpc<{ id: string }>("fn_admin_upsert_branch", { p: { name_ar: "فرع جديد للضريبة", name_en: "New tax branch" } });
    expect(await switches(nb.id)).toBe("false:1500 false:1500 false:1500 in force 0");
    const res = await stay("0553000001");
    expect(await policy(res)).toBe("0/0/0");
    const o = await order(res, [item(WATER, 2)]);
    expect(o).toMatchObject({ total_halalas: 400, tax_halalas: 0, tax_included: false });
    expect((await fin(res)).tax).toBe(0);
  });

  it("VT21 the products' switch alone: a stay made after it is taxed on its taxable products only, the order says how much is tax and is paid as shown; a stay made before it is not taxed", async () => {
    const cat = (await rpc<{ categories: Array<{ id: string }> }>("fn_admin_products")).categories[0].id;
    const plain = await rpc<{ id: string }>("fn_admin_upsert_product", { p: { category_id: cat, name: "منتج بلا ضريبة", price_halalas: 500, taxable: false } });
    await rpc("fn_admin_set_product_branch", { p_product: plain.id, p_branch: BRANCH, p_available: true });
    const before = await stay("0553000002");
    await set({ tax_products_enabled: true });
    expect(await switches()).toBe("false:1500 false:1500 true:1500 in force 0");
    const res = await stay("0553000003");
    expect(await policy(res)).toBe("0/0/1500");
    await rpc("fn_staff_add_service", { p_reservation: res, p_service: SVC.id, p_quantity: 1, p_note: null });
    const o = await order(res, [item(WATER, 2), item(plain.id, 1)]);
    expect(o).toMatchObject({ total_halalas: 960, tax_halalas: 60, tax_included: false });   // 2 × 2.00 + 15%, and 5.00 untaxed
    expect((await fin(res)).tax).toBe(0);                                                    // nothing on the rent, nothing on the service
    const paid = await pay(o, "vt21");
    expect(paid.order).toMatchObject({ status: "paid", total_halalas: 960, tax_halalas: 60 });
    const rows = await orderRows(o.id);
    expect(rows.reduce((x, r) => x + r.total_halalas, 0)).toBe(960);
    expect(rows.filter((r) => r.kind === "tax").map((r) => r.total_halalas)).toEqual([60]);
    expect((await fin(res)).tax).toBe(60);
    // the stay made before the switch keeps its policy
    expect(await policy(before)).toBe("0/0/0");
    expect(await order(before, [item(WATER, 2)])).toMatchObject({ total_halalas: 400, tax_halalas: 0 });
  });

  it("VT22 three switches, three rates: rent 15%, services 5%, products 10% each tax their own; a stay keeps the policy it was made under when the switches change, and when they are turned off", async () => {
    await set({ tax_products_enabled: true });
    const early = await stay("0553000004");                                  // made while only products were taxed, at 15%
    await set({ tax_rent_enabled: true, tax_rent_rate_bp: 1500, tax_services_enabled: true, tax_services_rate_bp: 500, tax_products_enabled: true, tax_products_rate_bp: 1000 });
    expect(await switches()).toBe("true:1500 true:500 true:1000 in force 1500");
    const q = await rpc<{ rent: number; tax: number; total: number; tax_rate_bp: number }>("fn_quote_stay", { p: { branch_id: BRANCH, category_id: CAT, check_in: day(20), check_out: day(22), source_id: SOURCE } });
    expect(q.tax_rate_bp).toBe(1500);
    expect(q.tax).toBe(Math.round(q.rent * 0.15));
    const res = await stay("0553000005");
    expect(await policy(res)).toBe("1500/500/1000");
    const f0 = await fin(res);
    expect(f0.tax).toBe(Math.round(f0.rent * 0.15));
    await rpc("fn_staff_add_service", { p_reservation: res, p_service: SVC.id, p_quantity: 1, p_note: null });
    expect((await fin(res)).tax - f0.tax).toBe(Math.round(SVC.price_halalas * 0.05));
    expect(await order(res, [item(WATER, 1)])).toMatchObject({ total_halalas: 220, tax_halalas: 20 });
    // the earlier stay: its service is not taxed, its products at its own 15%
    await rpc("fn_staff_add_service", { p_reservation: early, p_service: SVC.id, p_quantity: 1, p_note: null });
    expect((await fin(early)).tax).toBe(0);
    expect(await order(early, [item(WATER, 1)])).toMatchObject({ total_halalas: 230, tax_halalas: 30 });
    // turned off: the rates stay on file, a new stay carries nothing, the stay made under 15/5/10 keeps them
    await set({ tax_rent_enabled: false, tax_services_enabled: false, tax_products_enabled: false });
    expect(await switches()).toBe("false:1500 false:500 false:1000 in force 0");
    const late = await stay("0553000006");
    expect(await policy(late)).toBe("0/0/0");
    expect((await fin(late)).tax).toBe(0);
    const f1 = await fin(res);
    await rpc("fn_staff_add_service", { p_reservation: res, p_service: SVC.id, p_quantity: 1, p_note: "مرة ثانية" });
    expect((await fin(res)).tax - f1.tax).toBe(Math.round(SVC.price_halalas * 0.05));
  });

  it("VT23 the switches are the owner's alone; a switch is true or false and a rate from 0.01% to 100%; the screen before the switches still saves", async () => {
    await as("manager@demo.sa");
    expect(await fails(set({ tax_products_enabled: true }))).toMatch(/^FORBIDDEN/);
    expect(await fails(set({ tax_rent_rate_bp: 1400 }))).toMatch(/^FORBIDDEN/);
    expect(await fails(set({ prices_include_tax: true }))).toMatch(/^FORBIDDEN/);
    // the same switches sent back with another field (the screen sends them all): saved
    await set({ city: "بريدة", tax_rent_enabled: false, tax_rent_rate_bp: 1500, tax_services_enabled: false, tax_services_rate_bp: 1500, tax_products_enabled: false, tax_products_rate_bp: 1500 });
    expect((await branchRow()).city).toBe("بريدة");
    expect(await switches()).toBe("false:1500 false:1500 false:1500 in force 0");
    await as("owner@demo.sa");
    for (const bad of [{ tax_rent_rate_bp: 0 }, { tax_services_rate_bp: 10001 }, { tax_products_rate_bp: "15.5" }, { tax_products_rate_bp: null }, { tax_products_rate_bp: -5 }])
      expect(await fails(set(bad))).toMatch(/^VALIDATION: tax_rate/);
    for (const bad of [{ tax_services_enabled: "yes" }, { tax_products_enabled: null }, { tax_rent_enabled: 1 }, { prices_include_tax: "yes" }])
      expect(await fails(set(bad))).toMatch(/^VALIDATION: tax_switch/);
    expect(await switches()).toBe("false:1500 false:1500 false:1500 in force 0");
    // the earlier screen: the rate in force sent back changes nothing; a rate typed there is one rate on everything; zero turns the three off
    await set({ tax_products_enabled: true, tax_products_rate_bp: 1000 });
    await set({ tax_rate_bp: 0, city: "عنيزة" });
    expect(await switches()).toBe("false:1500 false:1500 true:1000 in force 0");
    await set({ tax_rate_bp: 1200 });
    expect(await switches()).toBe("true:1200 true:1200 true:1200 in force 1200");
    await set({ tax_rate_bp: 0 });
    expect(await switches()).toBe("false:1200 false:1200 false:1200 in force 0");
    // every change on the record, with what it was and what it became
    const log = ((await db().from("audit_events").select("*").eq("action", "branch.tax_changed").eq("entity_id", BRANCH)).data ?? []) as Array<Record<string, any>>; // eslint-disable-line @typescript-eslint/no-explicit-any
    expect(log).toHaveLength(3);
    expect(log.every((e) => e.details.reason === "يسري على الحجوزات الجديدة فقط" && "tax_products_enabled" in e.details.before && "tax_products_enabled" in e.details.after)).toBe(true);
  });

  it("VT24 prices that carry the tax: the guest pays the price shown and the tax is taken out of it, on the order and on the service", async () => {
    await set({ tax_services_enabled: true, tax_products_enabled: true, prices_include_tax: true });
    const res = await stay("0553000007");
    expect(await policy(res)).toBe("0/1500/1500");
    const o = await order(res, [item(WATER, 2)]);
    expect(o).toMatchObject({ total_halalas: 400, tax_halalas: 52, tax_included: true });
    await pay(o, "vt24");
    expect((await orderRows(o.id)).map((r) => `${r.kind}:${r.total_halalas}`).sort()).toEqual(["addon:348", "tax:52"]);
    const f0 = await fin(res);
    await rpc("fn_staff_add_service", { p_reservation: res, p_service: SVC.id, p_quantity: 1, p_note: null });
    const f1 = await fin(res);
    expect(f1.total - f0.total).toBe(SVC.price_halalas);                                       // the price shown, no more
    expect(f1.tax - f0.tax).toBe(SVC.price_halalas - Math.round(SVC.price_halalas * 10000 / 11500));
  });

  it("VT25 on WhatsApp the guest reads how the prices are meant and how much of the order is tax — by the policy of their own stay", async () => {
    const BR = (await rpc<Array<{ branch_id: string; mode: string }>>("fn_admin_whatsapp_channels")).find((x) => x.mode === "web_bridge" && demo.demoBridgeKey(x.branch_id))!.branch_id;
    const g = await inHouse();
    // a stay made before any switch: no word of tax
    const plain = await sim.simSend(BR, IN_HOUSE, "المنتجات");
    expect(plain.replies[0]).not.toMatch(/ضريبة/);
    // its products taxed at 15% on top
    await db().from("reservations").update({ tax_products_rate_bp: 1500, prices_include_tax: false }).eq("id", g.reservation);
    expect((await service("fn_guest_products", { p_token: g.token })).tax).toEqual({ rate_bp: 1500, included: false });
    const a = await sim.simSend(BR, IN_HOUSE, "المنتجات");
    expect(a.replies[0]).toMatch(/اختر الفئة:\nالأسعار قبل ضريبة القيمة المضافة 15%/);
    const b = await sim.simSend(BR, IN_HOUSE, "1");
    expect(b.replies[0]).toMatch(/مشروبات — اختر المنتج:\nالأسعار قبل ضريبة القيمة المضافة 15%/);
    await sim.simSend(BR, IN_HOUSE, "1");
    const d = await sim.simSend(BR, IN_HOUSE, "2");
    expect(d.replies[0]).toMatch(/• 2 × ماء صغير — 4\.60 ر\.س\nالإجمالي: 4\.60 ر\.س\nمنها ضريبة القيمة المضافة: 0\.60 ر\.س/);
    // and when the prices carry it
    await db().from("reservations").update({ prices_include_tax: true }).eq("id", g.reservation);
    const e = await sim.simSend(BR, IN_HOUSE, "المنتجات");
    expect(e.replies[0]).toMatch(/الأسعار شاملة ضريبة القيمة المضافة/);
  });

  it("VT26 what is paid is what the order showed: an order whose lines would now be charged another amount is refused whole, and paid once it adds up again", async () => {
    await set({ tax_products_enabled: true, tax_products_rate_bp: 1000 });
    const res = await stay("0553000008");
    const o = await order(res, [item(WATER, 4)]);
    expect(o.total_halalas).toBe(880);
    await db().from("reservations").update({ tax_products_rate_bp: 0 }).eq("id", res);        // rewritten under the order, as no screen can do
    expect(await fails(pay(o, "vt26"))).toMatch(/^VALIDATION: order_total/);
    expect(await orderRows(o.id)).toHaveLength(0);
    expect(((await db().from("product_orders").select("status, voucher_id, task_id").eq("id", o.id).single()).data)).toMatchObject({ status: "pending_payment", voucher_id: null, task_id: null });
    await db().from("reservations").update({ tax_products_rate_bp: 1000 }).eq("id", res);
    expect((await pay(o, "vt26")).order).toMatchObject({ status: "paid", total_halalas: 880, tax_halalas: 80 });
  });
});
