import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { Wallet, Download } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { SectionTitle, Card, Badge, DataState } from "../../components/ui";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { BranchPicker } from "../../components/BranchPicker";
import { PAYMENT_METHOD_LABELS, VOUCHER_KIND_LABELS, type PaymentMethod, type VoucherKind } from "../../lib/types";
import { formatCurrency, formatDateTime, todayISO } from "../../lib/utils";
import { useCashAccounts } from "../../lib/useCashAccounts";
import { useBranch } from "../../lib/branch";

interface V { id: string; number: string; kind: VoucherKind; amount_halalas: number; method: PaymentMethod; status: string; reference: string | null; reason: string | null; occurred_at: string; cancel_reason: string | null; created_by: string | null; account_id: string | null; payout_id: string | null; reservation?: { id: string; internal_ref: string } | null; creator?: { full_name: string } | null }
const sar = (h: number) => formatCurrency(h / 100);
const monthStart = () => todayISO().slice(0, 8) + "01";
const NO_ROWS: V[] = [];
const COLS = "id, number, kind, amount_halalas, method, status, reference, reason, occurred_at, cancel_reason, created_by, account_id, payout_id, reservation:reservations(id, internal_ref)";
/** Money moving in or out of a box or account; applying the deposit to charges moves nothing (decision 25). */
const IN_KINDS: VoucherKind[] = ["receipt", "deposit"]; const OUT_KINDS: VoucherKind[] = ["refund", "deposit_refund"];

export default function AdminFinance() {
  const [f, setF] = useState({ from: monthStart(), to: todayISO(), kind: "all", method: "all", account: "all", includeCancelled: false });
  const { branchId } = useBranch();
  const accounts = useCashAccounts(branchId);
  const accountText = (r: V) => accounts.nameOf(r.account_id) ?? (r.method === "ota_deferred" ? (r.payout_id ? "المنصة · مطابق" : "المنصة · بانتظار الإيداع") : "—");

  // G24: the ledger of the active branch only; a late answer for another branch is dropped
  const ledger = useBranchQuery<V[]>(async (branchId) => {
    const run = (cols: string) => {
      let q = supabase.from("financial_vouchers").select(cols).eq("branch_id", branchId).gte("occurred_at", f.from).lte("occurred_at", f.to + "T23:59:59").order("occurred_at", { ascending: false }).limit(2000);
      if (f.kind !== "all") q = q.eq("kind", f.kind);
      if (f.method !== "all") q = q.eq("method", f.method);
      if (f.account === "none") q = q.is("account_id", null); else if (f.account !== "all") q = q.eq("account_id", f.account);
      if (!f.includeCancelled) q = q.eq("status", "approved");
      return q;
    };
    const withCreator = await run(COLS + ", creator:staff_profiles!financial_vouchers_created_by_fkey(full_name)");
    // the creator join may be unavailable if the FK name differs; fall back without it
    return (withCreator.error ? must(await run(COLS)) : must(withCreator)) as unknown as V[];
  }, [f], NO_ROWS);
  const rows = ledger.data;

  const totals = useMemo(() => {
    const ok = rows.filter((r) => r.status === "approved");
    const sum = (k: VoucherKind) => ok.filter((r) => r.kind === k).reduce((s, r) => s + r.amount_halalas, 0);
    const byMethod = new Map<string, number>(); for (const r of ok) if (r.kind === "receipt") byMethod.set(r.method, (byMethod.get(r.method) ?? 0) + r.amount_halalas);
    // the period's entries per box or account — movement, not a running balance (no ledger; decision 25)
    const byAccount = new Map<string, { in: number; out: number }>();
    for (const r of ok) {
      if (!r.account_id) continue;
      const m = byAccount.get(r.account_id) ?? { in: 0, out: 0 };
      if (IN_KINDS.includes(r.kind)) m.in += r.amount_halalas; else if (OUT_KINDS.includes(r.kind)) m.out += r.amount_halalas;
      byAccount.set(r.account_id, m);
    }
    return { receipts: sum("receipt"), refunds: sum("refund"), deposits: sum("deposit"), depositRefunds: sum("deposit_refund"), depositApplied: sum("deposit_apply"), byMethod, byAccount };
  }, [rows]);

  function exportCsv() {
    const head = ["رقم السند", "النوع", "الحجز", "المبلغ", "الطريقة", "الصندوق أو الحساب", "المرجع", "الحالة", "الوقت", "السبب", "المنشئ"];
    const body = rows.map((r) => [r.number, VOUCHER_KIND_LABELS[r.kind], r.reservation?.internal_ref ?? "", (r.amount_halalas / 100).toFixed(2), PAYMENT_METHOD_LABELS[r.method] ?? r.method, accountText(r), r.reference ?? "", r.status === "approved" ? "معتمد" : "ملغى", r.occurred_at, r.reason ?? r.cancel_reason ?? "", r.creator?.full_name ?? ""]);
    const csv = "﻿" + [head, ...body].map((x) => x.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(",")).join("\n");
    const a = document.createElement("a"); a.href = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" })); a.download = `vouchers-${f.from}-${f.to}-${rows.length}rows.csv`; a.click();
  }

  return (
    <div>
      <SectionTitle title="المالية — دفتر السندات" subtitle="التأمين دفتر مستقل ولا يُحسب ضمن إيراد الإقامة" action={<div className="flex items-center gap-2"><BranchPicker /><button onClick={exportCsv} disabled={rows.length === 0} className="btn-outline text-sm"><Download className="h-4 w-4" /> تصدير ({rows.length})</button></div>} />
      <div className="mb-4 flex flex-wrap items-center gap-2 text-sm">
        <label className="flex items-center gap-1.5 text-ink-600">من <input type="date" className="input w-auto py-1" dir="ltr" value={f.from} onChange={(e) => setF({ ...f, from: e.target.value })} /></label>
        <label className="flex items-center gap-1.5 text-ink-600">إلى <input type="date" className="input w-auto py-1" dir="ltr" value={f.to} onChange={(e) => setF({ ...f, to: e.target.value })} /></label>
        <select className="input w-auto py-1" value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })}><option value="all">كل الأنواع</option>{Object.entries(VOUCHER_KIND_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
        <select className="input w-auto py-1" value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })}><option value="all">كل الطرق</option>{Object.entries(PAYMENT_METHOD_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
        <select className="input w-auto py-1" value={f.account} onChange={(e) => setF({ ...f, account: e.target.value })} aria-label="الصندوق أو الحساب"><option value="all">كل الصناديق والحسابات</option>{accounts.all.map((a) => <option key={a.id} value={a.id}>{a.name}{a.archived_at ? " (مؤرشف)" : ""}</option>)}<option value="none">بلا صندوق (آجل المنصات والخصم من التأمين)</option></select>
        <label className="flex items-center gap-1.5 text-ink-600"><input type="checkbox" checked={f.includeCancelled} onChange={(e) => setF({ ...f, includeCancelled: e.target.checked })} /> إظهار الملغاة</label>
      </div>
      <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-5">
        {[["قبض إقامة", totals.receipts, "text-success-600"], ["استرداد إقامة", totals.refunds, "text-danger-600"], ["صافي تحصيل الإقامة", totals.receipts - totals.refunds + totals.depositApplied, "text-ink-800"], ["قبض تأمين", totals.deposits, "text-brand-700"], ["رد تأمين", totals.depositRefunds, "text-brand-700"]].map(([l, v, c]) => (
          <Card key={String(l)} className="p-3"><p className="text-[11px] text-ink-400">{l}</p><p className={`text-lg font-bold ${c}`} dir="ltr">{sar(Number(v))}</p></Card>
        ))}
      </div>
      {totals.byMethod.size > 0 && <p className="mb-4 text-xs text-ink-500">قبض الإقامة حسب الطريقة: {[...totals.byMethod.entries()].map(([m, v]) => `${PAYMENT_METHOD_LABELS[m as PaymentMethod] ?? m}: ${sar(v)}`).join(" · ")}</p>}
      {totals.byAccount.size > 0 && <p className="mb-4 text-xs text-ink-500" data-testid="finance-by-account">حركة الفترة حسب الصندوق والحساب: {[...totals.byAccount.entries()].map(([id, m]) => `${accounts.nameOf(id) ?? "—"}: قبض ${sar(m.in)}، صرف ${sar(m.out)}`).join(" · ")}</p>}
      <DataState loading={ledger.loading} error={ledger.error} empty={rows.length === 0} onRetry={ledger.reload} emptyIcon={<Wallet className="h-10 w-10" />} emptyTitle="لا سندات في هذه الفترة">
        <Card className="overflow-x-auto p-0">
          <table className="w-full text-sm">
            <thead className="bg-ink-50 text-xs text-ink-500"><tr>{["السند", "النوع", "الحجز", "المبلغ", "الطريقة", "الصندوق أو الحساب", "المرجع", "الوقت", "المنشئ", "الحالة"].map((h) => <th key={h} className="whitespace-nowrap px-3 py-2 text-right font-medium">{h}</th>)}</tr></thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id} className={`border-t border-ink-50 ${r.status === "cancelled" ? "opacity-60" : ""}`}>
                  <td className="px-3 py-2 font-mono text-xs">{r.number}</td>
                  <td className="px-3 py-2">{VOUCHER_KIND_LABELS[r.kind]}</td>
                  <td className="px-3 py-2 font-mono text-xs">{r.reservation ? <Link className="hover:underline" to={`/staff/reservations/${r.reservation.id}`}>{r.reservation.internal_ref}</Link> : "—"}</td>
                  <td className={`whitespace-nowrap px-3 py-2 ${r.status === "cancelled" ? "line-through" : ""}`} dir="ltr">{sar(r.amount_halalas)}</td>
                  <td className="px-3 py-2 text-ink-600">{PAYMENT_METHOD_LABELS[r.method] ?? r.method}</td>
                  <td className="px-3 py-2 text-xs text-ink-500">{accountText(r)}</td>
                  <td className="px-3 py-2 font-mono text-xs text-ink-400" dir="ltr">{r.reference ?? "—"}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-xs text-ink-400">{formatDateTime(r.occurred_at)}</td>
                  <td className="px-3 py-2 text-xs text-ink-500">{r.creator?.full_name ?? "—"}</td>
                  <td className="px-3 py-2">{r.status === "approved" ? <Badge className="bg-success-500/10 text-success-600">معتمد</Badge> : <Badge className="bg-danger-500/10 text-danger-600" >ملغى{r.cancel_reason ? ` · ${r.cancel_reason}` : ""}</Badge>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      </DataState>
    </div>
  );
}
