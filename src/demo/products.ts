/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * Demo parity for migration 0068 (W1): the products catalogue (categories and products with a price, no stock), what
 * each branch offers, and the orders of a guest in their room — from WhatsApp (the guest's verified token, server
 * side) or by the reception — then the payment, the voucher and the delivery task in one step. Same rules, errors and
 * shapes as the SQL (fn_product_order_add, fn_staff_pay_product_order, fn_staff_cancel_product_order and the guards
 * of fn_trg_product_voucher and fn_trg_product_task). The catalogue seeded here is an example: the owner's real items
 * are added from «المنتجات».
 */
import { uid, nowISO, ORG, type Row } from "./data";

export interface ProductsCtx {
  T: (t: string) => Row[];
  byId: (t: string, id: string | null | undefined) => Row | undefined;
  can: (code: string) => boolean;
  requireCap: (code: string) => void;
  requireBranch: (b: string | null | undefined) => void;
  myBranches: () => string[];
  staffId: () => string | null;
  audit: (branch: string | null, action: string, entity: string, entityId: string, details: Row) => void;
  emit: (table: string) => void;
  nextNumber: (prefix: string) => string;
  checkVersion: (cur: number, exp?: number | null) => void;
  atomically: <V>(fn: () => V) => V;
  /** fn_add_charge_in('products', …, 'addon'): the line and its tax line, with the products' tax; returns the line's id */
  addProductCharge: (resId: string, description: string, qty: number, unit: number, taxable: boolean, reason: string | null) => string;
  /** fn_charge_tax(…, 'products', …): the products' tax of the policy the stay was made under (0069) */
  productTax: (resId: string, amount: number, taxable: boolean) => { net: number; tax: number };
  recompute: (resId: string) => unknown;
  /** fn_create_voucher (receipt) */
  createVoucher: (p: Row) => Row;
  /** fn_voucher_settled, and whether the voucher's day (in its branch) is before today */
  voucherSettled: (v: Row) => boolean;
  voucherBeforeToday: (v: Row) => boolean;
  /** fn_cancel_voucher (its own capability check) */
  cancelVoucher: (id: string, reason: string) => unknown;
}

const UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const chars = (s: string) => [...s].length;
const byOrder = (a: Row, b: Row) => (a.sort_order - b.sort_order) || String(a.name).localeCompare(String(b.name), "ar");
const DELIVERY = "تسليم طلب منتجات";

/** the example catalogue of the demo (3 categories, 12 items), offered in the first branch; the second offers some */
export function seedProducts(T: (t: string) => Row[], branches: string[]) {
  const at = nowISO();
  const cats: Array<[string, Array<[string, number, string | null]>]> = [
    ["مشروبات", [["ماء صغير", 200, null], ["مشروب غازي", 400, null], ["عصير برتقال", 600, "علبة 250 مل"], ["قهوة سريعة التحضير", 500, "ظرفان مع كوب"]]],
    ["وجبات خفيفة", [["رقائق البطاطس", 400, null], ["بسكويت", 300, null], ["شوكولاتة", 500, null], ["نودلز سريعة التحضير", 700, "كوب جاهز بالماء الحار"]]],
    ["مستلزمات شخصية", [["فرشاة ومعجون أسنان", 800, null], ["شفرة حلاقة", 600, null], ["شاحن جوال", 2500, "منفذ USB-C"], ["مناديل مبللة", 500, null]]],
  ];
  cats.forEach(([name, items], i) => {
    const c = { id: uid(), organization_id: ORG, name, sort_order: (i + 1) * 10, is_active: true, version: 1, created_by: null, created_at: at, updated_at: at };
    T("product_categories").push(c);
    items.forEach(([pname, price, description], j) => {
      const x = { id: uid(), organization_id: ORG, category_id: c.id, name: pname, description, price_halalas: price, taxable: true, is_active: true, sort_order: (i * 4 + j + 1) * 10, version: 1, created_by: null, created_at: at, updated_at: at };
      T("products").push(x);
      branches.forEach((b, k) => { if (k === 0 || j < 2) T("product_branches").push({ product_id: x.id, branch_id: b, organization_id: ORG, available: true, updated_by: null, updated_at: at }); });
    });
  });
}

export function productRpcs(ctx: ProductsCtx) {
  const { T, byId, requireCap, requireBranch, myBranches, staffId, audit, emit } = ctx;
  /** fivehours.order_cancel: the order whose voucher and task are being cancelled with it */
  let cancelling: string | null = null;

  /** fn_branch_products */
  const branchProducts = (branch: string) => T("product_categories").filter((c) => c.is_active).sort(byOrder).map((c) => ({
    id: c.id, name: c.name,
    products: T("products").filter((x) => x.category_id === c.id && x.is_active && T("product_branches").some((pb) => pb.product_id === x.id && pb.branch_id === branch && pb.available))
      .sort(byOrder).map((x) => ({ id: x.id, name: x.name, description: x.description ?? null, price_halalas: x.price_halalas })),
  })).filter((c) => c.products.length > 0);

  /** fn_product_order_json */
  const orderJson = (o: Row) => {
    const r = byId("reservations", o.reservation_id);
    return {
      id: o.id, number: o.number, status: o.status, source: o.source, total_halalas: o.total_halalas,
      tax_halalas: T("product_order_lines").filter((l) => l.order_id === o.id).reduce((x, l) => x + Number(l.tax_halalas ?? 0), 0), tax_included: !!r?.prices_include_tax,
      reservation_id: o.reservation_id, internal_ref: r?.internal_ref ?? null, room_number: byId("rooms", r?.room_id)?.room_number ?? null, branch_id: o.branch_id,
      created_at: o.created_at, paid_at: o.paid_at, delivered_at: o.delivered_at, cancelled_at: o.cancelled_at, cancel_reason: o.cancel_reason,
      voucher_number: byId("financial_vouchers", o.voucher_id)?.number ?? null, task_status: byId("housekeeping_tasks", o.task_id)?.status ?? null, version: o.version,
      lines: T("product_order_lines").filter((l) => l.order_id === o.id).sort((a, b) => (a.created_at < b.created_at ? -1 : a.created_at > b.created_at ? 1 : String(a.name).localeCompare(String(b.name), "ar")))
        .map((l) => ({ product_id: l.product_id, name: l.name, quantity: l.quantity, unit_price_halalas: l.unit_price_halalas, total_halalas: l.total_halalas })),
    };
  };

  const notify = (branch: string, title: string, body: string, link: string) => {
    T("notifications").unshift({ id: uid(), branch_id: branch, audience: "supervisor", title, body, link, created_at: nowISO(), read_at: null });
    emit("notifications");
  };

  /** fn_product_order_add: the stay's open order of this channel, or a new one */
  const orderAdd = (resId: string, items: unknown, source: "whatsapp" | "staff", conversation: string | null) => ctx.atomically(() => {
    const r = byId("reservations", resId); if (!r) throw new Error("RESERVATION_NOT_FOUND");
    if (r.status !== "checked_in" || !r.room_id) throw new Error("VALIDATION: not_in_stay");
    if (!Array.isArray(items) || items.length < 1 || items.length > 20) throw new Error("VALIDATION: items");
    for (const e of items) {
      if (!e || typeof e !== "object" || Array.isArray(e) || !UUID.test(String((e as Row).product_id ?? "")) || !/^[0-9]{1,2}$/.test(String((e as Row).quantity ?? ""))
        || Number((e as Row).quantity) < 1 || Number((e as Row).quantity) > 50) throw new Error("VALIDATION: items");
    }
    let o = T("product_orders").filter((x) => x.reservation_id === r.id && x.status === "pending_payment" && x.source === source).sort((a, b) => (a.created_at < b.created_at ? 1 : -1))[0];
    const fresh = !o; const at = nowISO();
    if (!o) {
      o = { id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: r.id, number: ctx.nextNumber("ORD"), status: "pending_payment", source, conversation_id: conversation,
        total_halalas: 0, voucher_id: null, task_id: null, created_by: staffId(), created_at: at, updated_at: at, paid_at: null, paid_by: null, delivered_at: null,
        cancelled_at: null, cancelled_by: null, cancel_reason: null, version: 1 };
      T("product_orders").push(o);
    }
    const qty = new Map<string, number>();
    for (const e of items as Row[]) qty.set(String(e.product_id).toLowerCase(), (qty.get(String(e.product_id).toLowerCase()) ?? 0) + Number(e.quantity));
    for (const pid of [...qty.keys()].sort()) {
      const x = T("products").find((p) => p.id.toLowerCase() === pid);
      if (!x || !x.is_active || !byId("product_categories", x.category_id)?.is_active || !T("product_branches").some((pb) => pb.product_id === x.id && pb.branch_id === r.branch_id && pb.available)) throw new Error("VALIDATION: product_unavailable");
      const line = T("product_order_lines").find((l) => l.order_id === o.id && l.product_id === x.id);
      const q = (line?.quantity ?? 0) + qty.get(pid)!;
      if (q > 50) throw new Error("VALIDATION: order_quantity");
      const { net, tax } = ctx.productTax(r.id, x.price_halalas * q, !!x.taxable);
      if (line) Object.assign(line, { quantity: q, total_halalas: net + tax, tax_halalas: tax, unit_price_halalas: x.price_halalas, name: x.name, taxable: !!x.taxable });
      else T("product_order_lines").push({ id: uid(), organization_id: ORG, order_id: o.id, product_id: x.id, name: x.name, unit_price_halalas: x.price_halalas, quantity: q, taxable: !!x.taxable, total_halalas: net + tax, tax_halalas: tax, created_at: nowISO() });
    }
    Object.assign(o, { total_halalas: T("product_order_lines").filter((l) => l.order_id === o.id).reduce((s, l) => s + l.total_halalas, 0), conversation_id: o.conversation_id ?? conversation, version: o.version + 1, updated_at: nowISO() });
    audit(r.branch_id, fresh ? "product_order.created" : "product_order.added", "product_order", o.id, { after: { number: o.number, items, source } });
    if (fresh) notify(r.branch_id, "طلب منتجات بانتظار الدفع", `${o.number} — غرفة ${byId("rooms", r.room_id)?.room_number ?? ""}`, "/staff/orders");
    emit("product_orders"); emit("product_order_lines");
    return orderJson(o);
  });

  const tokenReservation = (token: unknown) => {
    const s = T("registration_sessions").find((x) => x.token === token);
    if (!s) throw new Error("TOKEN_INVALID");
    return s.reservation_id as string;
  };

  /** fn_product_delivery_type */
  const deliveryType = (branch: string) => {
    let t = T("task_types").find((x) => x.branch_id === branch && x.code === "product_delivery") ?? T("task_types").find((x) => x.branch_id === branch && x.name === DELIVERY);
    if (t) t.code = "product_delivery";
    else { t = { id: uid(), organization_id: ORG, branch_id: branch, code: "product_delivery", name: DELIVERY, description: "يُنشأ تلقائيًا بعد دفع الطلب", is_active: true, archived_at: null, version: 1, created_at: nowISO(), updated_at: nowISO() }; T("task_types").push(t); emit("task_types"); }
    return t;
  };

  const staff: Record<string, (a: any) => any> = {
    // ---- the catalogue (settings: «المنتجات») ----
    fn_admin_upsert_product_category: ({ p }) => {
      requireCap("definitions"); const name = String(p?.name ?? "").trim();
      if (!name || chars(name) > 40) throw new Error("VALIDATION: category_name");
      if (p.sort_order !== undefined && !/^[0-9]{1,4}$/.test(String(p.sort_order ?? ""))) throw new Error("VALIDATION: sort_order");
      const taken = (id?: string) => T("product_categories").some((c) => c.name.toLowerCase() === name.toLowerCase() && c.id !== id);
      if (p.id == null) {
        if (taken()) throw new Error("DUPLICATE_NAME");
        const at = nowISO(); const max = Math.max(0, ...T("product_categories").map((c) => c.sort_order));
        const c = { id: uid(), organization_id: ORG, name, sort_order: p.sort_order !== undefined ? Number(p.sort_order) : max + 10, is_active: true, version: 1, created_by: staffId(), created_at: at, updated_at: at };
        T("product_categories").push(c); emit("product_categories"); audit(null, "product_category.created", "product_category", c.id, { after: c });
        return { ok: true, id: c.id, version: c.version };
      }
      const c = byId("product_categories", p.id); if (!c) throw new Error("NOT_FOUND");
      ctx.checkVersion(c.version, p.version == null ? null : Number(p.version));
      if (T("product_branches").some((pb) => T("products").some((x) => x.id === pb.product_id && x.category_id === c.id) && pb.available && !myBranches().includes(pb.branch_id))) throw new Error("FORBIDDEN: product_other_branch");
      if (taken(c.id)) throw new Error("DUPLICATE_NAME");
      const before = { ...c };
      Object.assign(c, { name, sort_order: p.sort_order !== undefined ? Number(p.sort_order) : c.sort_order, is_active: p.is_active == null ? c.is_active : !!p.is_active, version: c.version + 1, updated_at: nowISO() });
      emit("product_categories"); audit(null, "product_category.updated", "product_category", c.id, { before, after: c });
      return { ok: true, id: c.id, version: c.version };
    },
    fn_admin_upsert_product: ({ p }) => {
      requireCap("definitions"); const name = String(p?.name ?? "").trim(); const description = String(p?.description ?? "").trim() || null;
      if (!name || chars(name) > 40) throw new Error("VALIDATION: product_name");
      if (description && chars(description) > 200) throw new Error("VALIDATION: product_description");
      if (!/^[0-9]{1,9}$/.test(String(p.price_halalas ?? ""))) throw new Error("VALIDATION: product_price");
      const price = Number(p.price_halalas); if (price < 1 || price > 10_000_000) throw new Error("VALIDATION: product_price");
      if (p.sort_order !== undefined && !/^[0-9]{1,4}$/.test(String(p.sort_order ?? ""))) throw new Error("VALIDATION: sort_order");
      if (!UUID.test(String(p.category_id ?? ""))) throw new Error("VALIDATION: product_category");
      const cat = T("product_categories").find((c) => c.id.toLowerCase() === String(p.category_id).toLowerCase()); if (!cat) throw new Error("VALIDATION: product_category");
      const taken = (id?: string) => T("products").some((x) => x.name.toLowerCase() === name.toLowerCase() && x.id !== id);
      if (p.id == null) {
        if (taken()) throw new Error("DUPLICATE_NAME");
        const at = nowISO(); const max = Math.max(0, ...T("products").map((x) => x.sort_order));
        const x = { id: uid(), organization_id: ORG, category_id: cat.id, name, description, price_halalas: price, taxable: p.taxable == null ? true : !!p.taxable, is_active: true,
          sort_order: p.sort_order !== undefined ? Number(p.sort_order) : max + 10, version: 1, created_by: staffId(), created_at: at, updated_at: at };
        T("products").push(x); emit("products"); audit(null, "product.created", "product", x.id, { after: x });
        return { ok: true, id: x.id, version: x.version };
      }
      const x = byId("products", p.id); if (!x) throw new Error("NOT_FOUND");
      ctx.checkVersion(x.version, p.version == null ? null : Number(p.version));
      if (T("product_branches").some((pb) => pb.product_id === x.id && pb.available && !myBranches().includes(pb.branch_id))) throw new Error("FORBIDDEN: product_other_branch");
      if (taken(x.id)) throw new Error("DUPLICATE_NAME");
      const before = { ...x };
      // an order already placed keeps the name and the price it was placed with
      Object.assign(x, { category_id: cat.id, name, description, price_halalas: price, taxable: p.taxable == null ? x.taxable : !!p.taxable, is_active: p.is_active == null ? x.is_active : !!p.is_active,
        sort_order: p.sort_order !== undefined ? Number(p.sort_order) : x.sort_order, version: x.version + 1, updated_at: nowISO() });
      emit("products"); audit(null, "product.updated", "product", x.id, { before, after: x });
      return { ok: true, id: x.id, version: x.version };
    },
    fn_admin_set_product_branch: ({ p_product, p_branch, p_available }) => {
      requireCap("definitions");
      const x = byId("products", p_product); if (!x) throw new Error("NOT_FOUND");
      const b = byId("branches", p_branch); if (!b) throw new Error("VALIDATION: product_branch");
      requireBranch(b.id);
      if (p_available == null) throw new Error("VALIDATION: available");
      let pb = T("product_branches").find((y) => y.product_id === x.id && y.branch_id === b.id); const was = pb ? !!pb.available : null;
      if (!pb) { pb = { product_id: x.id, branch_id: b.id, organization_id: ORG, available: !!p_available, updated_by: staffId(), updated_at: nowISO() }; T("product_branches").push(pb); }
      else Object.assign(pb, { available: !!p_available, updated_by: staffId(), updated_at: nowISO() });
      if (was !== !!p_available) audit(b.id, "product.availability_changed", "product", x.id, { before: { available: was ?? false }, after: { available: !!p_available, branch: b.name_ar, product: x.name } });
      emit("product_branches"); return { ok: true };
    },
    fn_admin_products: () => {
      requireCap("definitions"); const mine = myBranches();
      return {
        categories: T("product_categories").slice().sort(byOrder).map((c) => ({ id: c.id, name: c.name, sort_order: c.sort_order, is_active: c.is_active, version: c.version, products: T("products").filter((x) => x.category_id === c.id).length })),
        products: T("products").slice().sort(byOrder).map((x) => ({ id: x.id, category_id: x.category_id, name: x.name, description: x.description ?? null, price_halalas: x.price_halalas, taxable: x.taxable, is_active: x.is_active, sort_order: x.sort_order, version: x.version,
          branches: T("product_branches").filter((pb) => pb.product_id === x.id && pb.available).map((pb) => pb.branch_id).sort() })),
        branches: T("branches").slice().sort((a, b) => String(a.name_ar).localeCompare(String(b.name_ar), "ar")).map((b) => ({ id: b.id, name: b.name_ar, mine: mine.includes(b.id) })),
      };
    },

    // ---- the reception ----
    fn_staff_product_orders: ({ p_branch, p_status = null, p_days = 7 }) => {
      requireCap("voucher.receipt"); requireBranch(p_branch);
      if (p_status != null && !["pending_payment", "paid", "delivered", "cancelled"].includes(p_status)) throw new Error("VALIDATION: status");
      if (p_days == null || !(Number(p_days) >= 1 && Number(p_days) <= 90)) throw new Error("VALIDATION: days");
      const since = Date.now() - Number(p_days) * 86_400_000;
      return T("product_orders").filter((o) => o.branch_id === p_branch && (p_status == null || o.status === p_status) && (["pending_payment", "paid"].includes(o.status) || Date.parse(o.created_at) > since)
        && !!byId("reservations", o.reservation_id))   // not one whose stay the trial-data purge removed
        .sort((a, b) => (a.created_at < b.created_at ? 1 : -1)).map(orderJson);
    },
    fn_staff_product_menu: ({ p_branch }) => {
      requireCap("voucher.receipt"); requireBranch(p_branch);
      return { categories: branchProducts(p_branch),
        stays: T("reservations").filter((r) => r.branch_id === p_branch && r.status === "checked_in" && r.room_id).map((r) => ({ id: r.id, internal_ref: r.internal_ref, room_number: byId("rooms", r.room_id)?.room_number ?? null, tax_rate_bp: r.tax_products_rate_bp ?? r.tax_rate_bp ?? 0, tax_included: !!r.prices_include_tax }))
          .sort((a, b) => String(a.room_number).localeCompare(String(b.room_number))) };
    },
    fn_staff_create_product_order: ({ p_reservation, p_items }) => {
      requireCap("voucher.receipt"); const r = byId("reservations", p_reservation); if (!r) throw new Error("RESERVATION_NOT_FOUND");
      requireBranch(r.branch_id); return orderAdd(r.id, p_items, "staff", null);
    },
    fn_staff_pay_product_order: ({ p }) => {
      requireCap("voucher.receipt");
      if (!UUID.test(String(p?.order_id ?? ""))) throw new Error("NOT_FOUND");
      const key = String(p.idempotency_key ?? "").trim(); if (!key) throw new Error("VALIDATION: idempotency_key");
      if (!["cash", "pos", "bank_transfer"].includes(String(p.method ?? ""))) throw new Error("VALIDATION: order_method");
      const o = byId("product_orders", p.order_id); if (!o) throw new Error("NOT_FOUND");
      requireBranch(o.branch_id); const r = byId("reservations", o.reservation_id)!;
      if (o.status !== "pending_payment") {
        // the same request again: its result
        if (o.voucher_id && byId("financial_vouchers", o.voucher_id)?.idempotency_key === key) return { ok: true, duplicate: true, order: orderJson(o) };
        throw new Error("VALIDATION: order_status");
      }
      // what is paid is what the cashier was shown
      ctx.checkVersion(o.version, p.expected_version == null || p.expected_version === "" ? null : Number(p.expected_version));
      const lines = T("product_order_lines").filter((l) => l.order_id === o.id);
      if (!lines.length) throw new Error("VALIDATION: items");
      if (r.status !== "checked_in" || !r.room_id) throw new Error("VALIDATION: not_in_stay");
      return ctx.atomically(() => {
        // the lines join the stay's account as products, with the products' tax
        for (const l of lines.slice().sort((a, b) => (a.created_at < b.created_at ? -1 : a.created_at > b.created_at ? 1 : String(a.name).localeCompare(String(b.name), "ar")))) {
          const cid = ctx.addProductCharge(r.id, `${l.name} × ${l.quantity}`, l.quantity, l.unit_price_halalas, !!l.taxable, "طلب " + o.number);
          for (const c of T("reservation_charges")) if (c.id === cid || c.base_charge_id === cid) c.product_order_id = o.id;
        }
        const amt = T("reservation_charges").filter((c) => c.product_order_id === o.id).reduce((s, c) => s + Number(c.total_halalas), 0);
        // and they are exactly what the order showed
        if (amt !== Number(o.total_halalas)) throw new Error("VALIDATION: order_total");
        // the receipt of exactly that amount, marked as this order's (its entry goes to product revenue)
        const v = ctx.createVoucher({ reservation_id: r.id, kind: "receipt", amount_halalas: amt, method: p.method, reference: p.reference ?? null, account_id: p.account_id ?? null,
          idempotency_key: key, duplicate_reference_ok: !!p.duplicate_reference_ok, note: "طلب منتجات " + o.number });
        const vr = byId("financial_vouchers", v.voucher_id);
        if (vr && !v.duplicate && vr.kind === "receipt" && !vr.product_order_id) vr.product_order_id = o.id;
        if (!vr || vr.product_order_id !== o.id || vr.status !== "approved") throw new Error("VALIDATION: order_voucher");
        // the delivery task for the guest's room
        const items = lines.map((l) => `${l.quantity} × ${l.name}`).join("، "); const tt = deliveryType(r.branch_id); const at = nowISO();
        const task = { id: uid(), organization_id: ORG, branch_id: r.branch_id, room_id: r.room_id, facility_id: null, task_type_id: tt.id, task_type_name_snapshot: DELIVERY, reservation_id: null, priority: "high", status: "pending",
          assignee_id: null, scheduled_start: at, scheduled_end: null, started_at: null, completed_at: null, completed_by: null, cancelled_at: null, cancel_reason: null, description: `تسليم ${o.number}: ${items}`,
          result_note: null, images: [], version: 1, created_by: staffId(), created_at: at, updated_at: at };
        T("housekeeping_tasks").push(task);
        Object.assign(o, { status: "paid", voucher_id: vr.id, task_id: task.id, paid_at: at, paid_by: staffId(), version: o.version + 1, updated_at: at });
        notify(r.branch_id, DELIVERY, `${o.number} — غرفة ${byId("rooms", r.room_id)?.room_number ?? ""}`, "/staff/housekeeping");
        audit(r.branch_id, "product_order.paid", "product_order", o.id, { before: { status: "pending_payment" }, after: { status: "paid", number: o.number, amount_halalas: amt, voucher: vr.number, method: p.method } });
        emit("housekeeping_tasks"); emit("product_orders"); emit("financial_vouchers"); emit("reservation_charges"); ctx.recompute(r.id);
        return { ok: true, duplicate: false, voucher_number: vr.number, order: orderJson(o) };
      });
    },
    fn_staff_cancel_product_order: ({ p_order, p_reason }) => {
      requireCap("voucher.receipt"); const reason = String(p_reason ?? "").trim();
      if (!reason || chars(reason) > 300) throw new Error("VALIDATION: reason");
      const o = byId("product_orders", p_order); if (!o) throw new Error("NOT_FOUND");
      requireBranch(o.branch_id);
      if (o.status === "delivered") throw new Error("VALIDATION: order_delivered");
      if (o.status === "cancelled") throw new Error("VALIDATION: order_status");
      const was = o.status;
      return ctx.atomically(() => {
        if (o.status === "paid") {
          requireCap("voucher.cancel");
          const v = byId("financial_vouchers", o.voucher_id)!;
          if (ctx.voucherBeforeToday(v) || ctx.voucherSettled(v)) throw new Error("VALIDATION: order_cancel_day");
          if (T("reservation_charges").some((x) => x.product_order_id === o.id && x.invoice_id)) throw new Error("VALIDATION: order_invoiced");
          cancelling = o.id;
          try {
            ctx.cancelVoucher(o.voucher_id, `إلغاء الطلب ${o.number}: ${reason}`);
            // each of the order's rows gets its exact opposite, of the same kind (the line and its tax)
            for (const c of T("reservation_charges").filter((x) => x.product_order_id === o.id && x.kind === "addon" && Number(x.total_halalas) > 0).sort((a, b) => (a.created_at < b.created_at ? -1 : 1))) {
              const neg = (x: Row, base: string | null) => ({ ...x, id: uid(), description: "إلغاء: " + x.description, unit_price_halalas: -x.unit_price_halalas, total_halalas: -x.total_halalas,
                invoice_id: null, reason: "إلغاء الطلب " + o.number, created_by: staffId(), created_at: nowISO(), base_charge_id: base, product_order_id: o.id });
              const n = neg(c, null); T("reservation_charges").push(n);
              for (const t of T("reservation_charges").filter((x) => x.base_charge_id === c.id && x.kind === "tax")) T("reservation_charges").push(neg(t, n.id));
            }
            if (T("reservation_charges").filter((x) => x.product_order_id === o.id).reduce((s, x) => s + Number(x.total_halalas), 0) !== 0) throw new Error("VALIDATION: order_status");
            const t = byId("housekeeping_tasks", o.task_id);
            if (t && ["pending", "in_progress"].includes(t.status)) Object.assign(t, { status: "cancelled", cancelled_at: nowISO(), cancel_reason: "أُلغي الطلب " + o.number, version: t.version + 1, updated_at: nowISO() });
          } finally { cancelling = null; }
          emit("reservation_charges"); emit("housekeeping_tasks"); ctx.recompute(o.reservation_id);
        }
        Object.assign(o, { status: "cancelled", cancelled_at: nowISO(), cancelled_by: staffId(), cancel_reason: reason, version: o.version + 1, updated_at: nowISO() });
        audit(o.branch_id, "product_order.cancelled", "product_order", o.id, { before: { status: was }, after: { status: "cancelled", number: o.number, amount_halalas: o.total_halalas }, reason });
        emit("product_orders"); return orderJson(o);
      });
    },
  };

  /** server only (service role): the WhatsApp ports call these with the guest's verified token */
  const service: Record<string, (a: any) => any> = {
    fn_guest_products: ({ p_token }) => {
      const r = byId("reservations", tokenReservation(p_token))!;
      const open = T("product_orders").filter((o) => o.reservation_id === r.id && o.status === "pending_payment" && o.source === "whatsapp").sort((a, b) => (a.created_at < b.created_at ? 1 : -1))[0];
      return { can_order: r.status === "checked_in" && !!r.room_id, categories: branchProducts(r.branch_id),
        tax: { rate_bp: r.tax_products_rate_bp ?? r.tax_rate_bp ?? 0, included: !!r.prices_include_tax }, open_order: open ? orderJson(open) : null };
    },
    fn_guest_order_products: ({ p_token, p_items, p_conversation = null }) => {
      const rid = tokenReservation(p_token);
      const conv = T("conversations").find((c) => c.id === p_conversation && c.guest_token === p_token)?.id ?? null;
      return orderAdd(rid, p_items, "whatsapp", conv);
    },
    fn_guest_cancel_product_order: ({ p_token, p_number }) => {
      const rid = tokenReservation(p_token);
      const o = T("product_orders").find((x) => x.reservation_id === rid && x.number === p_number); if (!o) throw new Error("NOT_FOUND");
      if (o.status !== "pending_payment" || o.source !== "whatsapp") throw new Error("VALIDATION: order_status");
      Object.assign(o, { status: "cancelled", cancelled_at: nowISO(), cancel_reason: "ألغاه النزيل", version: o.version + 1, updated_at: nowISO() });
      audit(o.branch_id, "product_order.cancelled", "product_order", o.id, { before: { status: "pending_payment" }, after: { status: "cancelled", by: "guest" }, reason: "ألغاه النزيل" });
      emit("product_orders"); return orderJson(o);
    },
    fn_guest_product_orders: ({ p_token }) => {
      const rid = tokenReservation(p_token);
      return T("product_orders").filter((o) => o.reservation_id === rid).sort((a, b) => (a.created_at < b.created_at ? 1 : -1)).map(orderJson);
    },
    fn_public_products: ({ p_branch }) => branchProducts(p_branch),
  };

  return {
    staff, service,
    /** fn_trg_product_voucher: an order's voucher is not cancelled or corrected on its own */
    voucherGuard: (v: Row | undefined) => { if (v?.product_order_id && cancelling !== v.product_order_id) throw new Error("VALIDATION: order_voucher"); },
    /** fn_trg_product_task (before): the delivery task of a paid order is not cancelled on its own */
    taskGuard: (t: Row | undefined) => { const o = t ? T("product_orders").find((x) => x.task_id === t.id) : undefined; if (o && o.status === "paid" && cancelling !== o.id) throw new Error("VALIDATION: order_task"); },
    /** fn_trg_product_task (after): the order is delivered when its task is done */
    sync: () => {
      // fn_trg_product_stay: the delivery follows the guest to a new room; at the departure a waiting order is cancelled
      // and a paid one not delivered says on its task that the guest has left
      for (const o of T("product_orders").filter((x) => x.status === "pending_payment" || x.status === "paid")) {
        const r = byId("reservations", o.reservation_id); if (!r) continue;
        const left = ["checked_out", "closed"].includes(r.status);
        if (o.status === "pending_payment") {
          if (left) { Object.assign(o, { status: "cancelled", cancelled_at: nowISO(), cancel_reason: "غادر النزيل قبل الدفع", version: o.version + 1, updated_at: nowISO() }); emit("product_orders"); }
          continue;
        }
        const t = byId("housekeeping_tasks", o.task_id);
        if (!t || !["pending", "in_progress"].includes(t.status)) continue;
        if (r.room_id && t.room_id !== r.room_id && !left) { t.room_id = r.room_id; emit("housekeeping_tasks"); }
        if (left && !String(t.description).startsWith("غادر النزيل")) { t.description = "غادر النزيل — راجع الاستقبال قبل التسليم. " + t.description; emit("housekeeping_tasks"); }
      }
      for (const o of T("product_orders").filter((x) => x.status === "paid" && x.task_id)) {
        const t = byId("housekeeping_tasks", o.task_id);
        if (t?.status !== "completed") continue;
        Object.assign(o, { status: "delivered", delivered_at: t.completed_at ?? nowISO(), version: o.version + 1, updated_at: nowISO() });
        audit(o.branch_id, "product_order.delivered", "product_order", o.id, { before: { status: "paid" }, after: { status: "delivered", number: o.number, task: t.id } });
        emit("product_orders");
      }
    },
  };
}
