import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { BookCheck, Plus, Download, Search } from "lucide-react";
import { useBranch } from "../../lib/branch";
import { opsApi, toArabicError, type ReservationRow } from "../../lib/api";
import { SectionTitle, EmptyState, LoadingScreen, ErrorBanner, Badge } from "../../components/ui";
import { BranchPicker } from "../../components/BranchPicker";
import { RESERVATION_STATUS_LABELS, RESERVATION_STATUS_COLORS, PAYMENT_STATUS_LABELS, type ReservationStatus } from "../../lib/types";
import { formatCurrency, todayISO } from "../../lib/utils";
import { supabase } from "../../lib/supabase";

const PAGE = 25;
const sar = (h: number) => formatCurrency(h / 100);

export default function StaffReservations() {
  const { branchId } = useBranch();
  const [filters, setFilters] = useState<Record<string, string | boolean>>({ open_only: true });
  const [q, setQ] = useState("");
  const [page, setPage] = useState(0);
  const [data, setData] = useState<{ total: number; rows: ReservationRow[] }>({ total: 0, rows: [] });
  const [loading, setLoading] = useState(true); const [error, setError] = useState<string | null>(null);
  const [exporting, setExporting] = useState(false);

  const load = useCallback(async () => {
    if (!branchId) return;
    setLoading(true);
    try { setData(await opsApi.list(branchId, { ...filters, q }, PAGE, page * PAGE)); setError(null); } catch (e) { setError(toArabicError(e)); } finally { setLoading(false); }
  }, [branchId, filters, q, page]);
  useEffect(() => { load(); }, [load]);
  useEffect(() => {
    const ch = supabase.channel("res-list").on("postgres_changes", { event: "*", schema: "public", table: "reservations" }, () => load()).subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [load]);

  // Export respects the same filters and branch scope and fetches ALL matching rows (not just the page) — D01/G25
  async function exportCsv() {
    if (!branchId) return;
    setExporting(true);
    try {
      const all = await opsApi.list(branchId, { ...filters, q }, 10000, 0);
      const head = ["المرجع", "المرجع الخارجي", "الضيف", "الوحدة", "الحالة", "الوصول", "المغادرة", "الليالي", "المصدر", "الإجمالي", "المحصل", "المتبقي", "رصيد التأمين", "حالة الدفع"];
      const rows = all.rows.map((r) => [r.internal_ref, r.external_ref ?? "", r.guest_name ?? "", r.room_number ?? "", RESERVATION_STATUS_LABELS[r.status as ReservationStatus] ?? r.status, r.check_in, r.check_out, r.nights, r.source_name ?? "", (r.total_halalas / 100).toFixed(2), (r.paid_halalas / 100).toFixed(2), (r.balance_due_halalas / 100).toFixed(2), (r.deposit_balance_halalas / 100).toFixed(2), PAYMENT_STATUS_LABELS[r.payment_status as keyof typeof PAYMENT_STATUS_LABELS] ?? r.payment_status]);
      const csv = "﻿" + [head, ...rows].map((r) => r.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(",")).join("\n");
      const a = document.createElement("a"); a.href = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" })); a.download = `reservations-${todayISO()}-${all.total}rows.csv`; a.click();
    } catch (e) { setError(toArabicError(e)); } finally { setExporting(false); }
  }

  const set = (k: string, v: string | boolean) => { setPage(0); setFilters((f) => { const n = { ...f, [k]: v }; if (v === "" || v === false) delete n[k]; return n; }); };
  const pages = Math.max(1, Math.ceil(data.total / PAGE));

  return (
    <div>
      <SectionTitle title="الحجوزات" subtitle={`${data.total} حجز مطابق`} action={
        <div className="flex flex-wrap items-center gap-2"><BranchPicker /><button onClick={exportCsv} disabled={exporting || data.total === 0} className="btn-outline text-sm"><Download className="h-4 w-4" /> تصدير ({data.total})</button><Link to="/staff/reservations/new" className="btn-primary text-sm"><Plus className="h-4 w-4" /> حجز جديد</Link></div>} />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      <div className="mb-4 flex flex-wrap items-center gap-2">
        <div className="relative"><Search className="pointer-events-none absolute right-3 top-2.5 h-4 w-4 text-ink-400" /><input className="input w-56 pr-9" placeholder="مرجع / ضيف / جوال" value={q} onChange={(e) => { setQ(e.target.value); setPage(0); }} /></div>
        <select className="input w-auto" value={String(filters.status ?? "")} onChange={(e) => { set("status", e.target.value); if (e.target.value) set("open_only", false); }}><option value="">كل الحالات</option>{Object.entries(RESERVATION_STATUS_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
        <label className="flex items-center gap-1.5 text-sm text-ink-600"><input type="checkbox" checked={!!filters.open_only} onChange={(e) => set("open_only", e.target.checked)} /> المفتوحة فقط</label>
        <label className="flex items-center gap-1.5 text-sm text-ink-600"><input type="checkbox" checked={!!filters.has_balance} onChange={(e) => set("has_balance", e.target.checked)} /> عليها متبقٍ</label>
        <label className="flex items-center gap-1.5 text-sm text-ink-600">وصول من <input type="date" className="input w-auto py-1" dir="ltr" value={String(filters.check_in_from ?? "")} onChange={(e) => set("check_in_from", e.target.value)} /></label>
        <label className="flex items-center gap-1.5 text-sm text-ink-600">إلى <input type="date" className="input w-auto py-1" dir="ltr" value={String(filters.check_in_to ?? "")} onChange={(e) => set("check_in_to", e.target.value)} /></label>
      </div>
      {loading ? <LoadingScreen /> : data.rows.length === 0 ? <EmptyState icon={<BookCheck className="h-10 w-10" />} title="لا توجد حجوزات مطابقة" /> : (
        <div className="card overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="bg-ink-50 text-xs text-ink-500"><tr>{["المرجع", "الضيف", "الوحدة", "الحالة", "الوصول", "المغادرة", "الإجمالي", "المتبقي", "التأمين", ""].map((h) => <th key={h} className="whitespace-nowrap px-3 py-2 text-right font-medium">{h}</th>)}</tr></thead>
            <tbody>
              {data.rows.map((r) => (
                <tr key={r.id} className="border-t border-ink-50 hover:bg-ink-50/60">
                  <td className="px-3 py-2 font-mono text-xs text-ink-700"><Link to={`/staff/reservations/${r.id}`} className="hover:underline">{r.internal_ref}</Link>{r.external_ref && <div className="text-[10px] text-ink-400">{r.source_name} · {r.external_ref}</div>}</td>
                  <td className="px-3 py-2 text-ink-700">{r.guest_name ?? "—"}</td>
                  <td className="px-3 py-2">{r.room_number ?? <span className="text-ink-300">—</span>}<div className="text-[10px] text-ink-400">{r.category_name}</div></td>
                  <td className="px-3 py-2"><Badge className={RESERVATION_STATUS_COLORS[r.status as ReservationStatus] ?? "bg-ink-100 text-ink-600"}>{RESERVATION_STATUS_LABELS[r.status as ReservationStatus] ?? r.status}</Badge></td>
                  <td className="whitespace-nowrap px-3 py-2 text-ink-600" dir="ltr">{r.check_in}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-ink-600" dir="ltr">{r.check_out}<span className="text-[10px] text-ink-400"> ({r.nights})</span></td>
                  <td className="whitespace-nowrap px-3 py-2" dir="ltr">{sar(r.total_halalas)}</td>
                  <td className={`whitespace-nowrap px-3 py-2 ${r.balance_due_halalas > 0 ? "font-medium text-warning-600" : "text-success-600"}`} dir="ltr">{sar(r.balance_due_halalas)}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-ink-600" dir="ltr">{sar(r.deposit_balance_halalas)}</td>
                  <td className="px-3 py-2"><Link to={`/staff/reservations/${r.id}`} className="btn-outline px-2 py-1 text-xs">فتح</Link></td>
                </tr>
              ))}
            </tbody>
          </table>
          <div className="flex items-center justify-between border-t border-ink-50 px-3 py-2 text-xs text-ink-500">
            <span>صفحة {page + 1} من {pages}</span>
            <div className="flex gap-2"><button disabled={page === 0} onClick={() => setPage(page - 1)} className="btn-ghost px-2 py-1 text-xs">السابق</button><button disabled={page + 1 >= pages} onClick={() => setPage(page + 1)} className="btn-ghost px-2 py-1 text-xs">التالي</button></div>
          </div>
        </div>
      )}
    </div>
  );
}
