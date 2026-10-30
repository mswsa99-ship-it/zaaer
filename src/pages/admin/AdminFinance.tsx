/**
 * «المالية — دفتر السندات» (decision 14, 10.4): the ledger read through fn_voucher_list with every filter its data
 * has (period, kind, method, box or account, status, staff, booking, number), real pages over the whole set, totals
 * computed by the server over the whole filtered set (no silent 2000 limit), and exports that state the branch, the
 * period, the filters and the scope (decision 43, X09a). The deposit is a separate ledger and never revenue.
 */
import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { Wallet } from "lucide-react";
import { SectionTitle, Card, Badge, DataState, Spinner } from "../../components/ui";
import { ExportMenu } from "../../components/ExportMenu";
import { useBranchQuery } from "../../lib/useBranchQuery";
import { BranchPicker } from "../../components/BranchPicker";
import { PAYMENT_METHOD_LABELS, VOUCHER_KIND_LABELS, type PaymentMethod, type VoucherKind } from "../../lib/types";
import { formatCurrency, formatDateTime, todayISO, COUNT } from "../../lib/utils";
import { useCashAccounts } from "../../lib/useCashAccounts";
import { useBranch } from "../../lib/branch";
import { useAuth } from "../../lib/auth";
import { listsApi, fetchAllPages, type VoucherList, type VoucherListFilters, type VoucherRow, type ReportFilterOptions } from "../../lib/api";
import { money, type ExportScope, type ExportStatement } from "../../lib/exports";

const sar = (h: number) => formatCurrency(h / 100);
const monthStart = () => todayISO().slice(0, 8) + "01";
const PAGE = 100;
const EMPTY: VoucherList = { total: 0, rows: [], totals: { receipts: 0, refunds: 0, deposits: 0, deposit_refunds: 0, deposit_applied: 0, approved: 0, cancelled: 0, by_method: [], by_account: [] }, limit: PAGE, offset: 0, tz: "Asia/Riyadh" };
type F = Omit<VoucherListFilters, "branch_id" | "limit" | "offset">;

export default function AdminFinance() {
  const [f, setF] = useState<F>({ from: monthStart(), to: todayISO(), status: "approved" });
  const [page, setPage] = useState(0);
  const { branchId, branch } = useBranch();
  const { profile } = useAuth();
  const accounts = useCashAccounts(branchId);
  const options = useBranchQuery<ReportFilterOptions | null>(async (b) => { const o = await listsApi.filterOptions(b); return o && "staff" in o ? (o as ReportFilterOptions) : null; }, [], null);
  const accountText = (r: VoucherRow) => r.account_name ?? accounts.nameOf(r.account_id) ?? (r.method === "ota_deferred" ? (r.payout_id ? "المنصة · مطابق" : "المنصة · بانتظار الإيداع") : "—");

  // G24: the ledger of the active branch only; a late answer for another branch is dropped
  const ledger = useBranchQuery<VoucherList>((b) => listsApi.vouchers({ ...f, branch_id: b, limit: PAGE, offset: page * PAGE }), [f, page], EMPTY);
  const { rows, totals, total } = ledger.data;
  const set = (k: keyof F, v: string | undefined) => { setPage(0); setF((x) => { const n: Record<string, unknown> = { ...x, [k]: v }; if (v === "" || v === undefined) delete n[k]; return n as F; }); };
  const pages = Math.max(1, Math.ceil(total / PAGE));

  const words = useMemo(() => {
    const w: string[] = [];
    if (f.kind) w.push(`النوع: ${VOUCHER_KIND_LABELS[f.kind as VoucherKind] ?? f.kind}`);
    if (f.method) w.push(`الطريقة: ${PAYMENT_METHOD_LABELS[f.method as PaymentMethod] ?? f.method}`);
    if (f.account_id) w.push(`الصندوق أو الحساب: ${f.account_id === "none" ? "بلا صندوق" : accounts.nameOf(f.account_id) ?? f.account_id}`);
    w.push(f.status === "all" ? "المعتمدة والملغاة" : f.status === "cancelled" ? "الملغاة فقط" : "المعتمدة فقط");
    if (f.staff_id) w.push(`الموظف: ${options.data?.staff.find((s) => s.id === f.staff_id)?.name ?? f.staff_id}`);
    if (f.q) w.push(`بحث: ${f.q}`);
    return w;
  }, [f, accounts, options.data]);

  const COLS = ["السند", "النوع", "الحجز", "المبلغ", "الطريقة", "الصندوق أو الحساب", "المرجع", "الوقت", "المنشئ", "الحالة", "السبب / الملاحظة"];
  const rowOut = (r: VoucherRow) => [r.number, VOUCHER_KIND_LABELS[r.kind as VoucherKind] ?? r.kind, r.reservation?.internal_ref ?? "", money(r.amount_halalas), PAYMENT_METHOD_LABELS[r.method as PaymentMethod] ?? r.method, accountText(r), r.reference ?? "", formatDateTime(r.occurred_at), r.creator_name ?? "", r.status === "approved" ? "معتمد" : `ملغى${r.cancel_reason ? ` · ${r.cancel_reason}` : ""}`, r.reason ?? r.note ?? ""];
  const statement = (scope: ExportScope): ExportStatement => ({ title: "دفتر السندات", branch: branch?.name_ar ?? null, period: { from: f.from, to: f.to }, filters: words, scope, generatedAt: formatDateTime(new Date().toISOString()), by: profile?.full_name ?? null });
  const table = async (scope: ExportScope) => {
    const all = scope.kind === "page" ? rows : (await fetchAllPages((limit, offset) => listsApi.vouchers({ ...f, branch_id: branchId!, limit, offset }), 500)).rows;
    const body = all.map(rowOut);
    // the totals line of the file is the server's, over the whole filtered set (the same figures as the screen)
    const sumRow = scope.kind === "all" ? [[`الإجمالي (${COUNT.voucher(all.length)}): قبض ${sar(totals.receipts)} · استرداد ${sar(totals.refunds)} · تأمين ${sar(totals.deposits)} · رد تأمين ${sar(totals.deposit_refunds)} · تأمين مستخدم ${sar(totals.deposit_applied)}`]] : [];
    return { columns: COLS, rows: [...body, ...sumRow], count: body.length, widths: [16, 18, 14, 12, 12, 24, 14, 18, 16, 14, 30] };
  };

  return (
    <div>
      <SectionTitle title="المالية — دفتر السندات" subtitle={`السندات المطابقة: ${total} · التأمين دفتر مستقل ولا يُحسب ضمن إيراد الإقامة`} action={<div className="flex flex-wrap items-center gap-2"><BranchPicker /><ExportMenu source={{ statement, table, pageCount: rows.length, total }} disabled={!branchId} /></div>} />
      <div className="mb-4 flex flex-wrap items-center gap-2 text-sm">
        <label className="flex items-center gap-1.5 text-ink-600">من <input type="date" className="input w-auto py-1" dir="ltr" value={f.from ?? ""} onChange={(e) => set("from", e.target.value)} aria-label="من" /></label>
        <label className="flex items-center gap-1.5 text-ink-600">إلى <input type="date" className="input w-auto py-1" dir="ltr" value={f.to ?? ""} onChange={(e) => set("to", e.target.value)} aria-label="إلى" /></label>
        <select className="input w-auto py-1" value={f.kind ?? ""} onChange={(e) => set("kind", e.target.value)} aria-label="النوع"><option value="">كل الأنواع</option>{Object.entries(VOUCHER_KIND_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
        <select className="input w-auto py-1" value={f.method ?? ""} onChange={(e) => set("method", e.target.value)} aria-label="الطريقة"><option value="">كل الطرق</option>{Object.entries(PAYMENT_METHOD_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
        <select className="input w-auto py-1" value={f.account_id ?? ""} onChange={(e) => set("account_id", e.target.value)} aria-label="الصندوق أو الحساب"><option value="">كل الصناديق والحسابات</option>{accounts.all.map((a) => <option key={a.id} value={a.id}>{a.name}{a.archived_at ? " (مؤرشف)" : ""}</option>)}<option value="none">بلا صندوق (آجل المنصات والخصم من التأمين)</option></select>
        <select className="input w-auto py-1" value={f.staff_id ?? ""} onChange={(e) => set("staff_id", e.target.value)} aria-label="الموظف" data-testid="filter-staff"><option value="">كل الموظفين</option>{(options.data?.staff ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}{s.is_active ? "" : " (موقوف)"}</option>)}</select>
        <select className="input w-auto py-1" value={f.status ?? "approved"} onChange={(e) => set("status", e.target.value)} aria-label="الحالة"><option value="approved">المعتمدة</option><option value="cancelled">الملغاة</option><option value="all">المعتمدة والملغاة</option></select>
        <input className="input w-40 py-1" placeholder="رقم السند / المرجع / الحجز" value={f.q ?? ""} onChange={(e) => set("q", e.target.value)} aria-label="بحث" />
      </div>
      <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-5" data-testid="finance-totals">
        {[["قبض إقامة", totals.receipts, "text-success-600"], ["استرداد إقامة", totals.refunds, "text-danger-600"], ["صافي تحصيل الإقامة", totals.receipts - totals.refunds + totals.deposit_applied, "text-ink-800"], ["قبض تأمين", totals.deposits, "text-brand-700"], ["رد تأمين", totals.deposit_refunds, "text-brand-700"]].map(([l, v, c]) => (
          <Card key={String(l)} className="p-3"><p className="text-[11px] text-ink-400">{l}</p><p className={`text-lg font-bold ${c}`} dir="ltr">{sar(Number(v))}</p></Card>
        ))}
      </div>
      <p className="mb-1 text-[11px] text-ink-400">المجاميع على كل السندات المطابقة ({totals.approved} معتمدًا{totals.cancelled ? ` و${totals.cancelled} ملغى` : ""})، لا على الصفحة المعروضة.</p>
      {totals.by_method.length > 0 && <p className="mb-2 text-xs text-ink-500">قبض الإقامة حسب الطريقة: {totals.by_method.map((m) => `${PAYMENT_METHOD_LABELS[m.method as PaymentMethod] ?? m.method}: ${sar(m.amount_halalas)}`).join(" · ")}</p>}
      {totals.by_account.length > 0 && <p className="mb-4 text-xs text-ink-500" data-testid="finance-by-account">حركة الفترة حسب الصندوق والحساب: {totals.by_account.map((a) => `${a.account_name ?? accounts.nameOf(a.account_id) ?? "—"}: قبض ${sar(a.in_halalas)}، صرف ${sar(a.out_halalas)}`).join(" · ")}</p>}
      <DataState loading={ledger.loading} error={ledger.error} empty={rows.length === 0} onRetry={ledger.reload} emptyIcon={<Wallet className="h-10 w-10" />} emptyTitle="لا سندات مطابقة">
        <Card className="overflow-x-auto p-0">
          <table className="w-full text-sm" data-testid="vouchers-table">
            <thead className="bg-ink-50 text-xs text-ink-500"><tr>{["السند", "النوع", "الحجز", "المبلغ", "الطريقة", "الصندوق أو الحساب", "المرجع", "الوقت", "المنشئ", "الحالة"].map((h) => <th key={h} className="whitespace-nowrap px-3 py-2 text-right font-medium">{h}</th>)}</tr></thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id} className={`border-t border-ink-50 ${r.status === "cancelled" ? "opacity-60" : ""}`} data-testid="voucher-row">
                  <td className="px-3 py-2 font-mono text-xs">{r.number}{r.original_number && <div className="text-[10px] text-ink-400">بدل {r.original_number}</div>}</td>
                  <td className="px-3 py-2">{VOUCHER_KIND_LABELS[r.kind as VoucherKind] ?? r.kind}</td>
                  <td className="px-3 py-2 font-mono text-xs">{r.reservation ? <Link className="hover:underline" to={`/staff/reservations/${r.reservation.id}`}>{r.reservation.internal_ref}</Link> : "—"}</td>
                  <td className={`whitespace-nowrap px-3 py-2 ${r.status === "cancelled" ? "line-through" : ""}`} dir="ltr">{sar(r.amount_halalas)}</td>
                  <td className="px-3 py-2 text-ink-600">{PAYMENT_METHOD_LABELS[r.method as PaymentMethod] ?? r.method}</td>
                  <td className="px-3 py-2 text-xs text-ink-500">{accountText(r)}</td>
                  <td className="px-3 py-2 font-mono text-xs text-ink-400" dir="ltr">{r.reference ?? "—"}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-xs text-ink-400">{formatDateTime(r.occurred_at)}</td>
                  <td className="px-3 py-2 text-xs text-ink-500">{r.creator_name ?? "—"}</td>
                  <td className="px-3 py-2">{r.status === "approved" ? <Badge className="bg-success-500/10 text-success-600">معتمد</Badge> : <Badge className="bg-danger-500/10 text-danger-600">ملغى{r.cancel_reason ? ` · ${r.cancel_reason}` : ""}</Badge>}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <div className="flex items-center justify-between border-t border-ink-50 px-3 py-2 text-xs text-ink-500">
            <span>صفحة {page + 1} من {pages} · {COUNT.voucher(total)}{ledger.refreshing && <Spinner className="mr-2 inline h-3 w-3" />}</span>
            <div className="flex gap-2"><button disabled={page === 0} onClick={() => setPage(page - 1)} className="btn-ghost px-2 py-1 text-xs">السابق</button><button disabled={page + 1 >= pages} onClick={() => setPage(page + 1)} className="btn-ghost px-2 py-1 text-xs">التالي</button></div>
          </div>
        </Card>
      </DataState>
    </div>
  );
}
