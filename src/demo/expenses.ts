/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * Demo parity for migration 0064 (the accounting stage, A4): the expense categories, the expense voucher with its receipt,
 * its cancellation, the opening balance of an account, and the ledger with its running balance. The same rules,
 * argument names, errors and return shapes as the SQL functions.
 */
import { uid, nowISO, ORG, type Row } from "./data";

export interface ExpensesCtx {
  T: (t: string) => Row[];
  byId: (t: string, id: string | null | undefined) => Row | undefined;
  can: (code: string) => boolean;
  requireCap: (code: string) => void;
  requireBranch: (b: string | null | undefined) => void;
  staffId: () => string | null;
  staffName: (id: string | null | undefined) => string | null;
  audit: (branch: string | null, action: string, entity: string, entityId: string, details: Row) => void;
  addReview: (branch: string, kind: string, entityType: string, entityId: string, resId: string | null, summary: string, reason: string | null, details: Row) => void;
  emit: (table: string) => void;
  dayOf: (iso: string) => string;
  today: (branch: string) => string;
  nextNumber: (prefix: string) => string;
  role: () => string | null;
}

/** the file's kind from its first bytes, as the SQL reads them */
function sniff(bin: Uint8Array): string | null {
  const at = (i: number, ...b: number[]) => b.every((x, k) => bin[i + k] === x);
  if (at(0, 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)) return "image/png";
  if (at(0, 0xff, 0xd8, 0xff)) return "image/jpeg";
  if (at(0, 0x52, 0x49, 0x46, 0x46) && at(8, 0x57, 0x45, 0x42, 0x50)) return "image/webp";
  if (at(0, 0x25, 0x50, 0x44, 0x46)) return "application/pdf";
  return null;
}
function decode(b64: string): Uint8Array | null {
  try { const raw = atob(b64.replace(/^data:[^,]*,/, "").replace(/\s/g, "")); const out = new Uint8Array(raw.length); for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i); return out; }
  catch { return null; }
}
const addDays = (d: string, n: number) => { const t = new Date(d + "T00:00:00Z"); t.setUTCDate(t.getUTCDate() + n); return t.toISOString().slice(0, 10); };

export function expensesRpcs(c: ExpensesCtx): Record<string, (a: any) => any> {
  const { T, byId, can, requireCap, requireBranch, staffId, staffName, audit, addReview, emit, dayOf, today, nextNumber } = c;
  const readable = () => { if (!(can("expense.create") || can("expense.cancel") || can("ledger.view"))) throw new Error("FORBIDDEN: expense"); };
  const range = (from: string, to: string) => { if (!from || !to || from > to || (Date.parse(to) - Date.parse(from)) / 86400000 > 366) throw new Error("VALIDATION: range"); };

  /** fn_account_movements */
  const movements = (account: string) => [
    ...T("financial_vouchers").filter((v) => v.account_id === account && v.status === "approved" && ["receipt", "deposit", "refund", "deposit_refund"].includes(v.kind))
      .map((v) => ({ at: v.occurred_at, kind: v.kind, number: v.number, description: v.reference ?? "", in_halalas: ["receipt", "deposit"].includes(v.kind) ? v.amount_halalas : 0, out_halalas: ["refund", "deposit_refund"].includes(v.kind) ? v.amount_halalas : 0, ref_id: v.id })),
    ...T("platform_payouts").filter((p) => p.account_id === account && p.status === "confirmed")
      .map((p) => ({ at: new Date(p.received_on + "T09:00:00Z").toISOString(), kind: "platform_payout", number: p.reference, description: "دفعة منصة", in_halalas: p.received_halalas, out_halalas: 0, ref_id: p.id })),
    ...T("expense_vouchers").filter((e) => e.account_id === account && e.status === "approved")
      .map((e) => ({ at: e.occurred_at, kind: "expense", number: e.number, description: e.description, in_halalas: 0, out_halalas: e.amount_halalas, ref_id: e.id })),
  ];

  return {
    fn_admin_upsert_expense_category: ({ p }) => {
      requireCap("definitions"); const q: Row = p ?? {}; const name = String(q.name ?? "").trim();
      if (!name || name.length > 60) throw new Error("VALIDATION: name");
      if ("sort_order" in q && !/^[0-9]{1,4}$/.test(String(q.sort_order ?? ""))) throw new Error("VALIDATION: sort_order");
      const mine = T("expense_categories").filter((x) => x.organization_id === ORG);
      if (!q.id) {
        if (mine.some((x) => x.name.toLowerCase() === name.toLowerCase())) throw new Error("DUPLICATE_NAME");
        const x = { id: uid(), organization_id: ORG, name, sort_order: q.sort_order != null ? Number(q.sort_order) : Math.max(0, ...mine.map((m) => m.sort_order)) + 10, is_active: true, version: 1, created_by: staffId(), created_at: nowISO(), updated_at: nowISO() };
        T("expense_categories").push(x); emit("expense_categories"); audit(null, "expense_category.created", "expense_category", x.id, { after: x });
        return { ok: true, id: x.id, version: 1 };
      }
      const x = mine.find((m) => m.id === q.id); if (!x) throw new Error("NOT_FOUND");
      if (x.version !== Number(q.version)) throw new Error("VERSION_CONFLICT: record changed by another user");
      if (mine.some((m) => m.id !== x.id && m.name.toLowerCase() === name.toLowerCase())) throw new Error("DUPLICATE_NAME");
      const before = { ...x };
      Object.assign(x, { name, sort_order: q.sort_order != null ? Number(q.sort_order) : x.sort_order, is_active: q.is_active ?? x.is_active, version: x.version + 1, updated_at: nowISO() });
      emit("expense_categories"); audit(null, "expense_category.updated", "expense_category", x.id, { before, after: { ...x } });
      return { ok: true, id: x.id, version: x.version };
    },
    fn_expense_create: ({ p }) => {
      requireCap("expense.create"); const q: Row = p ?? {}; requireBranch(q.branch_id);
      const key = String(q.idempotency_key ?? "").trim() || null;
      if (key) { const e = T("expense_vouchers").find((x) => x.organization_id === ORG && x.idempotency_key === key); if (e) { if (e.branch_id !== q.branch_id) throw new Error("IDEMPOTENCY_CONFLICT"); return { ok: true, id: e.id, number: e.number, replayed: true }; } }
      const a = byId("cash_accounts", q.account_id); if (!a) throw new Error("VALIDATION: account_required");
      if (a.branch_id !== q.branch_id) throw new Error("BRANCH_MISMATCH: account");
      if (a.archived_at || a.is_active === false) throw new Error("VALIDATION: account_archived");
      const cat = byId("expense_categories", q.category_id); if (!cat || cat.organization_id !== ORG || !cat.is_active) throw new Error("VALIDATION: category");
      if (!/^[0-9]{1,12}$/.test(String(q.amount_halalas ?? ""))) throw new Error("VALIDATION: amount");
      const amount = Number(q.amount_halalas); if (amount <= 0 || amount > 100000000000) throw new Error("VALIDATION: amount");
      const desc = String(q.description ?? "").trim(); if (!desc || desc.length > 500) throw new Error("VALIDATION: description");
      const payee = String(q.payee ?? "").trim() || null; if (payee && payee.length > 120) throw new Error("VALIDATION: payee");
      const ref = String(q.reference ?? "").trim().toUpperCase() || null; if (ref && (ref.length > 60 || !/^[A-Z0-9/_.-]+$/.test(ref))) throw new Error("VALIDATION: reference");
      const t = today(q.branch_id); const day = String(q.occurred_on ?? "") || t;
      if (!/^\d{4}-\d{2}-\d{2}$/.test(day) || day > t || day < addDays(t, -31)) throw new Error("VALIDATION: occurred_on");
      const sentDay = T("day_closings").some((x) => x.branch_id === q.branch_id && x.business_date === day && x.status === "submitted");
      if (a.kind === "cash_box" && sentDay && !can("day.close.approve")) throw new Error("CLOSING_SENT_DAY");
      const files = Array.isArray(q.attachments) ? q.attachments : null;
      if (!files || files.length === 0) throw new Error("VALIDATION: attachment_required");
      if (files.length > 5) throw new Error("VALIDATION: attachments_count");
      const decoded = files.map((f: Row) => {
        const bin = decode(String(f.data_base64 ?? "")); if (!bin || bin.length === 0) throw new Error("VALIDATION: attachment");
        if (bin.length > 2097152) throw new Error("VALIDATION: attachment_too_large");
        const mime = sniff(bin); if (!mime) throw new Error("VALIDATION: attachment_type");
        return { mime, size: bin.length, data: String(f.data_base64).replace(/^data:[^,]*,/, "").replace(/\s/g, ""), name: String(f.file_name ?? "").trim().slice(0, 120) || null };
      });
      const e = { id: uid(), organization_id: ORG, branch_id: q.branch_id, number: nextNumber("EXP"), account_id: a.id, category_id: cat.id, amount_halalas: amount,
                  occurred_at: day === t ? nowISO() : new Date(day + "T09:00:00Z").toISOString(), payee, description: desc, reference: ref, status: "approved",
                  cancel_reason: null, cancelled_at: null, cancelled_by: null, idempotency_key: key, created_by: staffId(), created_at: nowISO() };
      T("expense_vouchers").push(e);
      for (const f of decoded) T("expense_attachments").push({ id: uid(), expense_id: e.id, branch_id: e.branch_id, mime: f.mime, data_base64: f.data, size_bytes: f.size, sha256: uid(), file_name: f.name, created_by: staffId(), created_at: nowISO() });
      emit("expense_vouchers");
      audit(e.branch_id, "expense.created", "expense_voucher", e.id, { after: { number: e.number, amount_halalas: amount, account_id: a.id, category: cat.name, occurred_at: e.occurred_at, attachments: decoded.length } });
      if (a.kind === "cash_box" && sentDay) addReview(e.branch_id, "expense_after_closing", "expense_voucher", e.id, null, `سند صرف ${e.number} على يوم أُرسل إقفاله`, desc, { business_date: day, amount_halalas: amount });
      return { ok: true, id: e.id, number: e.number };
    },
    fn_expense_cancel: ({ p_id, p_reason }) => {
      requireCap("expense.cancel"); const e = byId("expense_vouchers", p_id); if (!e) throw new Error("NOT_FOUND"); requireBranch(e.branch_id);
      const reason = String(p_reason ?? "").trim(); if (!reason || reason.length > 500) throw new Error("VALIDATION: reason");
      if (e.status === "cancelled") return { ok: true, unchanged: true };
      Object.assign(e, { status: "cancelled", cancel_reason: reason, cancelled_at: nowISO(), cancelled_by: staffId() }); emit("expense_vouchers");
      audit(e.branch_id, "expense.cancelled", "expense_voucher", e.id, { before: { status: "approved" }, after: { status: "cancelled", number: e.number, amount_halalas: e.amount_halalas }, reason });
      addReview(e.branch_id, "expense_cancelled", "expense_voucher", e.id, null, `إلغاء سند صرف ${e.number}`, reason, { number: e.number, amount_halalas: e.amount_halalas });
      return { ok: true };
    },
    fn_expense_list: ({ p_branch, p_from, p_to }) => {
      readable(); requireBranch(p_branch); range(p_from, p_to);
      return T("expense_vouchers").filter((e) => e.branch_id === p_branch && dayOf(e.occurred_at) >= p_from && dayOf(e.occurred_at) <= p_to)
        .sort((a, b) => (a.occurred_at < b.occurred_at ? 1 : a.occurred_at > b.occurred_at ? -1 : a.number < b.number ? 1 : -1))
        .map((e) => ({ id: e.id, number: e.number, occurred_at: e.occurred_at, amount_halalas: e.amount_halalas, account_id: e.account_id, account: byId("cash_accounts", e.account_id)?.name ?? null,
                       account_kind: byId("cash_accounts", e.account_id)?.kind ?? null, category_id: e.category_id, category: byId("expense_categories", e.category_id)?.name ?? null,
                       payee: e.payee, description: e.description, reference: e.reference, status: e.status, cancel_reason: e.cancel_reason, created_by: staffName(e.created_by),
                       attachments: T("expense_attachments").filter((x) => x.expense_id === e.id).map((x) => ({ id: x.id, mime: x.mime, size_bytes: x.size_bytes, file_name: x.file_name })) }));
    },
    fn_expense_attachment: ({ p_id }) => {
      readable(); const x = byId("expense_attachments", p_id); if (!x) throw new Error("NOT_FOUND"); requireBranch(x.branch_id);
      return { id: x.id, mime: x.mime, file_name: x.file_name, size_bytes: x.size_bytes, data_base64: x.data_base64 };
    },
    fn_admin_set_account_opening: ({ p_account, p_halalas, p_on, p_reason }) => {
      requireCap("cash_accounts"); if (c.role() !== "owner") throw new Error("FORBIDDEN: owner_only");
      const a = byId("cash_accounts", p_account); if (!a) throw new Error("NOT_FOUND"); requireBranch(a.branch_id);
      if (p_halalas == null || !Number.isInteger(Number(p_halalas)) || Math.abs(Number(p_halalas)) > 100000000000) throw new Error("VALIDATION: amount");
      if (!p_on || p_on > today(a.branch_id)) throw new Error("VALIDATION: opening_on");
      const reason = String(p_reason ?? "").trim(); if (!reason || reason.length > 500) throw new Error("VALIDATION: reason");
      const before = { opening_balance_halalas: a.opening_balance_halalas ?? 0, opening_on: a.opening_on ?? null };
      Object.assign(a, { opening_balance_halalas: Number(p_halalas), opening_on: p_on, version: a.version + 1, updated_at: nowISO() }); emit("cash_accounts");
      audit(a.branch_id, "cash_account.opening_set", "cash_account", a.id, { before, after: { opening_balance_halalas: Number(p_halalas), opening_on: p_on }, reason });
      addReview(a.branch_id, "account_opening_set", "cash_account", a.id, null, `تحديد الرصيد الافتتاحي لـ${a.name}`, reason, { before: before.opening_balance_halalas, after: Number(p_halalas), opening_on: p_on });
      return { ok: true };
    },
    fn_account_ledger: ({ p_account, p_from, p_to }) => {
      requireCap("ledger.view"); const a = byId("cash_accounts", p_account); if (!a) throw new Error("NOT_FOUND"); requireBranch(a.branch_id); range(p_from, p_to);
      if (a.opening_on && p_to < a.opening_on) throw new Error("VALIDATION: before_opening");
      const start = a.opening_on && a.opening_on > p_from ? a.opening_on : p_from;
      const all = movements(a.id).filter((m) => !a.opening_on || dayOf(m.at) >= a.opening_on);
      const opening = (a.opening_balance_halalas ?? 0) + all.filter((m) => dayOf(m.at) < start).reduce((s, m) => s + m.in_halalas - m.out_halalas, 0);
      const inRange = all.filter((m) => dayOf(m.at) >= start && dayOf(m.at) <= p_to).sort((x, y) => (x.at < y.at ? -1 : x.at > y.at ? 1 : x.number < y.number ? -1 : x.number > y.number ? 1 : x.ref_id < y.ref_id ? -1 : 1));
      if (inRange.length > 3000) throw new Error("VALIDATION: range_too_large");
      let bal = opening; const lines = inRange.map((m) => { bal += m.in_halalas - m.out_halalas; return { ...m, balance_halalas: bal }; });
      const tin = inRange.reduce((s, m) => s + m.in_halalas, 0), tout = inRange.reduce((s, m) => s + m.out_halalas, 0);
      return { account: { id: a.id, name: a.name, kind: a.kind, branch_id: a.branch_id, opening_balance_halalas: a.opening_balance_halalas ?? 0, opening_on: a.opening_on ?? null },
               from: p_from, to: p_to, opening_halalas: opening, in_halalas: tin, out_halalas: tout, closing_halalas: opening + tin - tout, lines };
    },
  };
}
