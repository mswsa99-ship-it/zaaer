/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * Demo parity for migration 0065 (the accounting stage, A5): the numbered chart of accounts, the journal that every
 * voucher, expense, platform payout, closing difference and opening balance makes, the trial balance, the account
 * statement, the income statement, the balance sheet and the month lock. The demo derives the journal from what is
 * stored (the SQL keeps it in its own tables) with the same postings, the same numbers and the same errors; a write
 * that would date an entry in a locked month is undone with PERIOD_LOCKED, as the database's trigger does.
 */
import { nowISO, ORG, type Row } from "./data";

export interface GlCtx {
  T: (t: string) => Row[];
  byId: (t: string, id: string | null | undefined) => Row | undefined;
  can: (code: string) => boolean;
  requireCap: (code: string) => void;
  requireBranch: (b: string | null | undefined) => void;
  myBranches: () => string[];
  staffId: () => string | null;
  audit: (branch: string | null, action: string, entity: string, entityId: string, details: Row) => void;
  emit: (table: string) => void;
  dayOf: (iso: string, branch?: string | null) => string;
  today: (branch?: string | null) => string;
}

type Acc = { id: string; code: string; name: string; type: "asset" | "liability" | "equity" | "revenue" | "expense"; parent_id: string | null; is_postable: boolean; key?: string };
type Line = { account_id: string; debit: number; credit: number };
export type Entry = { key: string; number?: string; branch_id: string | null; entry_date: string; description: string; at: string; lines: Line[] };

const SYSTEM: [string, string, Acc["type"], string | null, boolean, string][] = [
  ["1", "الأصول", "asset", null, false, "assets"], ["11", "النقد وما في حكمه", "asset", "1", false, "cash_group"],
  ["111", "صناديق الفروع", "asset", "11", false, "cash_parent"], ["112", "الحسابات البنكية", "asset", "11", false, "bank_parent"],
  ["12", "الذمم المدينة", "asset", "1", false, "receivables"], ["121", "مستحقات المنصات", "asset", "12", false, "platform_parent"],
  ["129", "حساب معلّق", "asset", "12", true, "suspense"], ["2", "الالتزامات", "liability", null, false, "liabilities"],
  ["21", "تأمينات الضيوف", "liability", "2", true, "deposits"], ["3", "حقوق الملكية", "equity", null, false, "equity"],
  ["31", "الأرصدة الافتتاحية", "equity", "3", true, "opening"], ["4", "الإيرادات", "revenue", null, false, "revenue"],
  ["41", "إيراد الإيجار", "revenue", "4", true, "rent_revenue"], ["42", "مردودات الإيجار", "revenue", "4", true, "rent_returns"],
  ["49", "إيرادات أخرى وزيادات", "revenue", "4", true, "other_income"], ["5", "المصروفات", "expense", null, false, "expenses"],
  ["51", "المصروفات التشغيلية", "expense", "5", false, "expense_parent"], ["57", "رسوم بنكية ونقاط البيع", "expense", "5", true, "bank_fees"], ["58", "عمولات المنصات", "expense", "5", true, "platform_commission"],
  ["59", "عجز الصندوق", "expense", "5", true, "cash_shortage"],
];

export function glRpcs(c: GlCtx): { rpcs: Record<string, (a: any) => any>; journal: () => Entry[]; lockedMonths: () => string[] } {
  const { T, byId, can, requireCap, requireBranch, myBranches, staffId, audit, emit, dayOf, today } = c;

  /** the chart: the fixed accounts, then a child under its parent for each box, bank account, platform and category in the order they were made */
  const chart = (): Acc[] => {
    const out: Acc[] = SYSTEM.map(([code, name, type, parent, postable, key]) => ({ id: "gl-" + key, code, name, type, parent_id: parent ? "gl-" + SYSTEM.find((s) => s[0] === parent)![5] : null, is_postable: postable, key }));
    const kids = (parentKey: string, rows: Row[], name: (r: Row) => string, type: Acc["type"], prefix: string) => {
      const p = out.find((a) => a.key === parentKey)!;
      [...rows].sort((a, b) => String(a.created_at ?? "").localeCompare(String(b.created_at ?? "")) || String(a.id).localeCompare(String(b.id)))
        .forEach((r, i) => out.push({ id: prefix + r.id, code: p.code + String(i + 1).padStart(2, "0"), name: name(r), type, parent_id: p.id, is_postable: true }));
    };
    const branchName = (b: string) => byId("branches", b)?.name_ar ?? "";
    kids("cash_parent", T("cash_accounts").filter((a) => a.kind === "cash_box"), (a) => `${a.name} — ${branchName(a.branch_id)}`, "asset", "gl-cash-");
    kids("bank_parent", T("cash_accounts").filter((a) => a.kind === "bank_account"), (a) => `${a.name} — ${branchName(a.branch_id)}`, "asset", "gl-cash-");
    kids("platform_parent", T("booking_sources"), (s) => "مستحقات " + s.name, "asset", "gl-src-");
    kids("expense_parent", T("expense_categories").filter((x) => x.organization_id === ORG), (x) => x.name, "expense", "gl-cat-");
    return out.sort((a, b) => a.code.localeCompare(b.code));
  };
  const sys = (k: string) => "gl-" + k;
  const cashAcc = (id: string | null | undefined) => (id ? "gl-cash-" + id : sys("suspense"));
  const srcAcc = (id: string | null | undefined) => (id ? "gl-src-" + id : sys("suspense"));
  const two = (dr: string, cr: string, amount: number): Line[] => [{ account_id: dr, debit: amount, credit: 0 }, { account_id: cr, debit: 0, credit: amount }];
  const flip = (ls: Line[]): Line[] => ls.map((l) => ({ account_id: l.account_id, debit: l.credit, credit: l.debit }));

  /** fn_gl_post_voucher and the other postings, in the order they happened (the reversal dated the day of the cancellation) */
  const journal = (): Entry[] => {
    const e: Entry[] = [];
    const push = (key: string, branch: string | null, date: string, at: string, description: string, lines: Line[]) => {
      const ls = lines.filter((l) => l.debit !== 0 || l.credit !== 0).map((l) => (l.debit < 0 || l.credit < 0 ? { account_id: l.account_id, debit: Math.max(0, -l.credit) + Math.max(0, l.debit), credit: Math.max(0, -l.debit) + Math.max(0, l.credit) } : l));
      if (ls.length) e.push({ key, branch_id: branch, entry_date: date, at, description, lines: ls });
    };
    for (const v of T("financial_vouchers").filter((x) => x.status === "approved" || x.status === "cancelled")) {
      const res = byId("reservations", v.reservation_id);
      const money = v.account_id ? cashAcc(v.account_id) : ["ota_deferred", "booking_platform"].includes(v.method) ? srcAcc(res?.source_id) : sys("suspense");
      const label = `${v.number} — ` + (({ receipt: "قبض إيجار", refund: "رد مبلغ", deposit: "قبض تأمين", deposit_refund: "رد تأمين" } as Record<string, string>)[v.kind] ?? "خصم من التأمين");
      const lines = v.kind === "receipt" ? two(money, sys("rent_revenue"), v.amount_halalas) : v.kind === "refund" ? two(sys("rent_returns"), money, v.amount_halalas)
        : v.kind === "deposit" ? two(money, sys("deposits"), v.amount_halalas) : v.kind === "deposit_refund" ? two(sys("deposits"), money, v.amount_halalas)
        : two(sys("deposits"), sys("rent_revenue"), v.amount_halalas);
      push("voucher:" + v.id, v.branch_id, dayOf(v.occurred_at, v.branch_id), v.occurred_at, label, lines);
      if (v.status === "cancelled") push("voucher:" + v.id + ":reverse", v.branch_id, dayOf(v.cancelled_at ?? nowISO(), v.branch_id), v.cancelled_at ?? nowISO(), "عكس " + label, flip(lines));
    }
    for (const x of T("expense_vouchers")) {
      const lines = two("gl-cat-" + x.category_id, cashAcc(x.account_id), x.amount_halalas);
      push("expense:" + x.id, x.branch_id, dayOf(x.occurred_at, x.branch_id), x.occurred_at, `${x.number} — ${x.description}`, lines);
      if (x.status === "cancelled") push("expense:" + x.id + ":reverse", x.branch_id, dayOf(x.cancelled_at ?? nowISO(), x.branch_id), x.cancelled_at ?? nowISO(), `عكس ${x.number}`, flip(lines));
    }
    for (const p of T("platform_payouts")) {
      const commission = p.commission_halalas ?? 0; const gap = p.expected_halalas - commission - p.received_halalas;
      const lines: Line[] = [{ account_id: cashAcc(p.account_id), debit: p.received_halalas, credit: 0 },
        { account_id: sys("platform_commission"), debit: commission, credit: 0 },
        { account_id: sys(gap >= 0 ? "cash_shortage" : "other_income"), debit: gap, credit: 0 },
        { account_id: srcAcc(p.source_id), debit: 0, credit: p.expected_halalas }];
      const at = new Date(p.received_on + "T09:00:00Z").toISOString();
      push("payout:" + p.id, p.branch_id, p.received_on, at, "دفعة منصة " + p.reference, lines);
      if (p.status === "cancelled") push("payout:" + p.id + ":reverse", p.branch_id, dayOf(p.cancelled_at ?? nowISO(), p.branch_id), p.cancelled_at ?? nowISO(), "إلغاء دفعة المنصة " + p.reference, flip(lines));
    }
    for (const d of T("day_closings").filter((x) => x.status === "submitted")) {
      const l = T("day_closing_lines").find((x) => x.closing_id === d.id && x.line_key === "cash");
      const diff = l?.difference_halalas ?? 0;
      if (!l || !diff || !l.account_id) continue;
      push("day_closing:" + d.id, d.branch_id, d.business_date, d.submitted_at ?? d.updated_at ?? nowISO(), `فرق الصندوق في إقفال يوم ${d.business_date}` + (l.reason ? ": " + l.reason : ""),
           diff < 0 ? two(sys("cash_shortage"), cashAcc(l.account_id), -diff) : two(cashAcc(l.account_id), sys("other_income"), diff));
    }
    // the opening is what was counted on its day: the gap between it and what the books held the day before (fn_gl_post_opening)
    for (const a of T("cash_accounts").filter((x) => (x.opening_balance_halalas ?? 0) !== 0 || x.opening_on)) {
      const on = a.opening_on ?? today(a.branch_id);
      const before = a.opening_on ? e.filter((x) => x.entry_date < a.opening_on).flatMap((x) => x.lines).filter((l) => l.account_id === cashAcc(a.id)).reduce((t, l) => t + l.debit - l.credit, 0) : 0;
      push("opening:" + a.id, a.branch_id, on, on + "T00:00:00Z", "الرصيد الافتتاحي لـ" + a.name + (before ? " (الفرق عن الدفاتر قبله)" : ""), two(cashAcc(a.id), sys("opening"), (a.opening_balance_halalas ?? 0) - before));
    }
    // 0067: a waiting movement is a reconciliation item, not an entry; a match's difference goes to fees or other income;
    // money in turned into income is bank against other income (money out turned into an expense is the expense above).
    // Dated on the movement's day while its month is open, otherwise the day of the match. (The SQL keeps a released
    // match's entry and its reversal; the demo drops both, which nets the same.)
    for (const v of T("bank_movements").filter((x) => x.cash_account_id)) {
      const acc = cashAcc(v.cash_account_id);
      const m = T("bank_matches").find((x) => x.movement_id === v.id && x.active);
      const d0 = dayOf(v.occurred_at, v.branch_id); const day = m && lockedMonths().includes(d0.slice(0, 7)) ? dayOf(m.created_at, v.branch_id) : d0;
      if (m && m.difference_halalas) { const d = Math.abs(m.difference_halalas); const gain = (v.direction === "in") === (m.difference_halalas > 0);
        push("bank:" + v.id + ":diff", v.branch_id, day, v.occurred_at, "فرق مطابقة: " + (m.reason ?? ""), gain ? two(acc, sys("other_income"), d) : two(sys("bank_fees"), acc, d)); }
      if (m && m.target_type === "journal") push("bank:" + v.id + ":convert", v.branch_id, day, v.occurred_at, "إيراد من حركة بنكية: " + (m.reason ?? ""), two(acc, sys("other_income"), v.amount_halalas));
    }
    e.sort((a, b) => a.at.localeCompare(b.at) || a.key.localeCompare(b.key));
    e.forEach((x, i) => { x.number = "JE-" + String(i + 1).padStart(6, "0"); });
    return e;
  };

  const lockedMonths = () => T("accounting_periods").filter((p) => p.locked).map((p) => String(p.month).slice(0, 7)).sort();
  const check = (branch: string | null | undefined) => { if (!can("accounts.view")) throw new Error("FORBIDDEN: accounts.view"); if (branch) requireBranch(branch); };
  const visible = (branch: string | null | undefined) => { const mine = myBranches(); return (x: Entry) => (branch ? x.branch_id === branch : x.branch_id == null || mine.includes(x.branch_id)); };
  /** fn_gl_balances: per account, the debits and credits dated in [from, to] */
  const balances = (from: string | null, to: string, branch: string | null | undefined) => {
    const m = new Map<string, { debit: number; credit: number }>();
    for (const x of journal().filter(visible(branch)).filter((x) => (!from || x.entry_date >= from) && x.entry_date <= to)) for (const l of x.lines) {
      const b = m.get(l.account_id) ?? { debit: 0, credit: 0 }; b.debit += l.debit; b.credit += l.credit; m.set(l.account_id, b);
    }
    return m;
  };
  const dayBefore = (d: string) => { const t = new Date(d + "T00:00:00Z"); t.setUTCDate(t.getUTCDate() - 1); return t.toISOString().slice(0, 10); };
  const range = (from: string, to: string) => { if (!from || !to || from > to) throw new Error("VALIDATION: range"); };
  const orgToday = () => myBranches().map((b) => today(b)).sort().pop() ?? today(null);

  const rpcs: Record<string, (a: any) => any> = {
    fn_trial_balance: ({ p_from, p_to, p_branch }) => {
      check(p_branch); range(p_from, p_to);
      const open = balances(null, dayBefore(p_from), p_branch); const per = balances(p_from, p_to, p_branch);
      let td = 0, tc = 0; const rows: Row[] = [];
      for (const a of chart().filter((x) => x.is_postable)) {
        const o = open.get(a.id); const p = per.get(a.id);
        const opening = (o?.debit ?? 0) - (o?.credit ?? 0); const d = p?.debit ?? 0; const cr = p?.credit ?? 0;
        td += d; tc += cr;
        if (opening || d || cr) rows.push({ account_id: a.id, code: a.code, name: a.name, type: a.type, opening_halalas: opening, debit_halalas: d, credit_halalas: cr, closing_halalas: opening + d - cr });
      }
      return { from: p_from, to: p_to, branch_id: p_branch ?? null, rows, total_debit_halalas: td, total_credit_halalas: tc, difference_halalas: td - tc, locked_months: lockedMonths() };
    },
    fn_account_statement: ({ p_account, p_from, p_to, p_branch }) => {
      check(p_branch); const a = chart().find((x) => x.id === p_account); if (!a) throw new Error("NOT_FOUND");
      if (!p_from || !p_to || p_from > p_to || (Date.parse(p_to) - Date.parse(p_from)) / 86400000 > 366) throw new Error("VALIDATION: range");
      const o = balances(null, dayBefore(p_from), p_branch).get(a.id); const opening = (o?.debit ?? 0) - (o?.credit ?? 0);
      let bal = opening; const lines: Row[] = [];
      const inRange = journal().filter(visible(p_branch)).filter((x) => x.entry_date >= p_from && x.entry_date <= p_to)
        .sort((p, q) => p.entry_date.localeCompare(q.entry_date) || p.at.localeCompare(q.at) || String(p.number).localeCompare(String(q.number)));
      for (const x of inRange) for (const l of x.lines.filter((l) => l.account_id === a.id)) {
        bal += l.debit - l.credit;
        lines.push({ entry_id: x.key, number: x.number, entry_date: x.entry_date, description: x.description, debit_halalas: l.debit, credit_halalas: l.credit, balance_halalas: bal });
      }
      return { account: { id: a.id, code: a.code, name: a.name, type: a.type }, from: p_from, to: p_to, opening_halalas: opening, lines };
    },
    fn_income_statement: ({ p_from, p_to, p_branch }) => {
      check(p_branch); range(p_from, p_to);
      const b = balances(p_from, p_to, p_branch); let rev = 0, exp = 0; const rows: Row[] = [];
      for (const a of chart().filter((x) => x.type === "revenue" || x.type === "expense")) {
        const v = b.get(a.id); if (!v) continue;
        const amount = a.type === "revenue" ? v.credit - v.debit : v.debit - v.credit;
        if (a.type === "revenue") rev += amount; else exp += amount;
        rows.push({ code: a.code, name: a.name, type: a.type, amount_halalas: amount });
      }
      return { from: p_from, to: p_to, rows, revenue_halalas: rev, expenses_halalas: exp, net_income_halalas: rev - exp };
    },
    fn_balance_sheet: ({ p_as_of, p_branch }) => {
      check(p_branch); if (!p_as_of) throw new Error("VALIDATION: range");
      const b = balances(null, p_as_of, p_branch); let assets = 0, liab = 0, eq = 0, income = 0; const rows: Row[] = [];
      for (const a of chart()) {
        const v = b.get(a.id); if (!v) continue; const net = v.debit - v.credit;
        if (a.type === "asset") assets += net; else if (a.type === "liability") liab -= net; else if (a.type === "equity") eq -= net; else income -= net;
        if (["asset", "liability", "equity"].includes(a.type) && net !== 0) rows.push({ code: a.code, name: a.name, type: a.type, amount_halalas: a.type === "asset" ? net : -net });
      }
      return { as_of: p_as_of, rows, assets_halalas: assets, liabilities_halalas: liab, equity_halalas: eq, retained_income_halalas: income, difference_halalas: assets - liab - eq - income };
    },
    fn_gl_chart: ({ p_as_of, p_branch }) => {
      check(p_branch); const b = balances(null, p_as_of ?? orgToday(), p_branch); const mine = myBranches();
      return chart().filter((a) => !a.id.startsWith("gl-cash-") || mine.includes(byId("cash_accounts", a.id.slice(8))?.branch_id)).map((a) => { const v = b.get(a.id); const net = v ? v.debit - v.credit : 0;
        return { id: a.id, code: a.code, name: a.name, type: a.type, parent_id: a.parent_id, is_postable: a.is_postable, balance_halalas: a.type === "asset" || a.type === "expense" ? net : -net }; });
    },
    fn_accounting_months: () => {
      if (!(can("accounts.view") || can("accounts.close_month"))) throw new Error("FORBIDDEN: accounts");
      return { locked_months: lockedMonths(), today: orgToday() };
    },
    fn_accounting_lock_month: ({ p_month, p_lock, p_reason }) => {
      requireCap("accounts.close_month"); const reason = String(p_reason ?? "").trim();
      if (!p_month) throw new Error("VALIDATION: month");
      const m = String(p_month).slice(0, 7) + "-01";
      if (m > orgToday().slice(0, 7) + "-01") throw new Error("VALIDATION: month");
      if (!reason || reason.length > 500) throw new Error("VALIDATION: reason");
      const row = T("accounting_periods").find((p) => p.month === m);
      if ((row && row.locked === !!p_lock) || (!p_lock && !row)) return { ok: true, unchanged: true, month: m.slice(0, 7), locked: !!p_lock };
      if (row) Object.assign(row, { locked: !!p_lock, changed_at: nowISO(), changed_by: staffId(), reason });
      else T("accounting_periods").push({ organization_id: ORG, month: m, locked: !!p_lock, changed_at: nowISO(), changed_by: staffId(), reason });
      emit("accounting_periods");
      audit(null, p_lock ? "accounting.month_locked" : "accounting.month_opened", "accounting_period", m, { after: { month: m.slice(0, 7) }, reason });
      return { ok: true, month: m.slice(0, 7), locked: !!p_lock };
    },
  };
  return { rpcs, journal, lockedMonths };
}

/** the month lock as the trigger does it: a write that adds an entry dated in a locked month is refused */
export function lockedEntryAdded(before: Entry[], after: Entry[], locked: string[]): string | null {
  if (!locked.length) return null;
  const seen = new Set(before.map((e) => e.key + "|" + e.entry_date + "|" + JSON.stringify(e.lines)));
  const added = after.find((e) => !seen.has(e.key + "|" + e.entry_date + "|" + JSON.stringify(e.lines)) && locked.includes(e.entry_date.slice(0, 7)));
  return added ? "PERIOD_LOCKED: " + added.entry_date.slice(0, 7) : null;
}
