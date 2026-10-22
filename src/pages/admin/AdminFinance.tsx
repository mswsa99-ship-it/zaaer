import { useCallback, useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { Wallet, Download } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useBranch } from "../../lib/branch";
import { toArabicError } from "../../lib/api";
import { SectionTitle, LoadingScreen, Card, EmptyState, ErrorBanner, Badge } from "../../components/ui";
import { BranchPicker } from "../../components/BranchPicker";
import { PAYMENT_METHOD_LABELS, VOUCHER_KIND_LABELS, type PaymentMethod, type VoucherKind } from "../../lib/types";
import { formatCurrency, formatDateTime } from "../../lib/utils";

interface V { id: string; number: string; kind: VoucherKind; amount_halalas: number; method: PaymentMethod; status: string; reference: string | null; reason: string | null; occurred_at: string; cancel_reason: string | null; created_by: string | null; reservation?: { id: string; internal_ref: string } | null; creator?: { full_name: string } | null }
const sar = (h: number) => formatCurrency(h / 100);
const monthStart = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-01`; };

export default function AdminFinance() {
  const { branchId } = useBranch();
  const [rows, setRows] = useState<V[]>([]); const [loading, setLoading] = useState(true); const [error, setError] = useState<string | null>(null);
  const [f, setF] = useState({ from: monthStart(), to: new Date().toISOString().slice(0, 10), kind: "all", method: "all", includeCancelled: false });

  const load = useCallback(async () => {
    if (!branchId) return;
    setLoading(true);
    let q = supabase.from("financial_vouchers").select("id, number, kind, amount_halalas, method, status, reference, reason, occurred_at, cancel_reason, created_by, reservation:reservations(id, internal_ref), creator:staff_profiles!financial_vouchers_created_by_fkey(full_name)").eq("branch_id", branchId).gte("occurred_at", f.from).lte("occurred_at", f.to + "T23:59:59").order("occurred_at", { ascending: false }).limit(2000);
    if (f.kind !== "all") q = q.eq("kind", f.kind);
    if (f.method !== "all") q = q.eq("method", f.method);
    if (!f.includeCancelled) q = q.eq("status", "approved");
    const { data, error: e } = await q;
    if (e) {
      // creator join may be unavailable if the FK name differs; fall back without it
      const r2 = await supabase.from("financial_vouchers").select("id, number, kind, amount_halalas, method, status, reference, reason, occurred_at, cancel_reason, created_by, reservation:reservations(id, internal_ref)").eq("branch_id", branchId).gte("occurred_at", f.from).lte("occurred_at", f.to + "T23:59:59").order("occurred_at", { ascending: false }).limit(2000);
      if (r2.error) setError(toArabicError(r2.error)); else setRows((r2.data as unknown as V[]) ?? []);
    } else { setRows((data as unknown as V[]) ?? []); setError(null); }
    setLoading(false);
  }, [branchId, f]);
  useEffect(() => { load(); }, [load]);

  const totals = useMemo(() => {
    const ok = rows.filter((r) => r.status === "approved");
    const sum = (k: VoucherKind) => ok.filter((r) => r.kind === k).reduce((s, r) => s + r.amount_halalas, 0);
    const byMethod = new Map<string, number>(); for (const r of ok) if (r.kind === "receipt") byMethod.set(r.method, (byMethod.get(r.method) ?? 0) + r.amount_halalas);
    return { receipts: sum("receipt"), refunds: sum("refund"), deposits: sum("deposit"), depositRefunds: sum("deposit_refund"), depositApplied: sum("deposit_apply"), byMethod };
  }, [rows]);

  function exportCsv() {
    const head = ["رقم السند", "النوع", "الحجز", "المبلغ", "الطريقة", "المرجع", "الحالة", "الوقت", "السبب", "المنشئ"];
    const body = rows.map((r) => [r.number, VOUCHER_KIND_LABELS[r.kind], r.reservation?.internal_ref ?? "", (r.amount_halalas / 100).toFixed(2), PAYMENT_METHOD_LABELS[r.method] ?? r.method, r.reference ?? "", r.status === "approved" ? "معتمد" : "ملغى", r.occurred_at, r.reason ?? r.cancel_reason ?? "", r.creator?.full_name ?? ""]);
    const csv = "﻿" + [head, ...body].map((x) => x.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(",")).join("\n");
    const a = document.createElement("a"); a.href = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" })); a.download = `vouchers-${f.from}-${f.to}-${rows.length}rows.csv`; a.click();
  }

  return (
    <div>
      <SectionTitle title="المالية — دفتر السندات" subtitle="التأمين دفتر مستقل ولا يُحسب ضمن إيراد الإقامة" action={<div className="flex items-center gap-2"><BranchPicker /><button onClick={exportCsv} disabled={rows.length === 0} className="btn-outline text-sm"><Download className="h-4 w-4" /> تصدير ({rows.length})</button></div>} />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      <div className="mb-4 flex flex-wrap items-center gap-2 text-sm">
        <label className="flex items-center gap-1.5 text-ink-600">من <input type="date" className="input w-auto py-1" dir="ltr" value={f.from} onChange={(e) => setF({ ...f, from: e.target.value })} /></label>
        <label className="flex items-center gap-1.5 text-ink-600">إلى <input type="date" className="input w-auto py-1" dir="ltr" value={f.to} onChange={(e) => setF({ ...f, to: e.target.value })} /></label>
        <select className="input w-auto py-1" value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })}><option value="all">كل الأنواع</option>{Object.entries(VOUCHER_KIND_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
        <select className="input w-auto py-1" value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })}><option value="all">كل الطرق</option>{Object.entries(PAYMENT_METHOD_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
        <label className="flex items-center gap-1.5 text-ink-600"><input type="checkbox" checked={f.includeCancelled} onChange={(e) => setF({ ...f, includeCancelled: e.target.checked })} /> إظهار الملغاة</label>
      </div>
      <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-5">
        {[["قبض إقامة", totals.receipts, "text-success-600"], ["استرداد إقامة", totals.refunds, "text-danger-600"], ["صافي تحصيل الإقامة", totals.receipts - totals.refunds + totals.depositApplied, "text-ink-800"], ["قبض تأمين", totals.deposits, "text-brand-700"], ["رد تأمين", totals.depositRefunds, "text-brand-700"]].map(([l, v, c]) => (
          <Card key={String(l)} className="p-3"><p className="text-[11px] text-ink-400">{l}</p><p className={`text-lg font-bold ${c}`} dir="ltr">{sar(Number(v))}</p></Card>
        ))}
      </div>
      {totals.byMethod.size > 0 && <p className="mb-4 text-xs text-ink-500">قبض الإقامة حسب الطريقة: {[...totals.byMethod.entries()].map(([m, v]) => `${PAYMENT_METHOD_LABELS[m as PaymentMethod] ?? m}: ${sar(v)}`).join(" · ")}</p>}
      {loading ? <LoadingScreen /> : rows.length === 0 ? <EmptyState icon={<Wallet className="h-10 w-10" />} title="لا سندات في هذه الفترة" /> : (
        <Card className="overflow-x-auto p-0">
          <table className="w-full text-sm">
            <thead className="bg-ink-50 text-xs text-ink-500"><tr>{["السند", "النوع", "الحجز", "المبلغ", "الطريقة", "المرجع", "الوقت", "المنشئ", "الحالة"].map((h) => <th key={h} className="whitespace-nowrap px-3 py-2 text-right font-medium">{h}</th>)}</tr></thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id} className={`border-t border-ink-50 ${r.status === "cancelled" ? "opacity-60" : ""}`}>
                  <td className="px-3 py-2 font-mono text-xs">{r.number}</td>
                  <td className="px-3 py-2">{VOUCHER_KIND_LABELS[r.kind]}</td>
                  <td className="px-3 py-2 font-mono text-xs">{r.reservation ? <Link className="hover:underline" to={`/staff/reservations/${r.reservation.id}`}>{r.reservation.internal_ref}</Link> : "—"}</td>
                  <td className={`whitespace-nowrap px-3 py-2 ${r.status === "cancelled" ? "line-through" : ""}`} dir="ltr">{sar(r.amount_halalas)}</td>
                  <td className="px-3 py-2 text-ink-600">{PAYMENT_METHOD_LABELS[r.method] ?? r.method}</td>
                  <td className="px-3 py-2 font-mono text-xs text-ink-400" dir="ltr">{r.reference ?? "—"}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-xs text-ink-400">{formatDateTime(r.occurred_at)}</td>
                  <td className="px-3 py-2 text-xs text-ink-500">{r.creator?.full_name ?? "—"}</td>
                  <td className="px-3 py-2">{r.status === "approved" ? <Badge className="bg-success-500/10 text-success-600">معتمد</Badge> : <Badge className="bg-danger-500/10 text-danger-600" >ملغى{r.cancel_reason ? ` · ${r.cancel_reason}` : ""}</Badge>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}
    </div>
  );
}
