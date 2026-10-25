/**
 * Reports (GAP05, decision 36): every money figure comes from the voucher ledger through fn_reports_finance (role-gated
 * on the server) — never from reservation totals or a count of "paid" reservations. Deposits are shown as a separate
 * open balance and are explicitly not revenue. Every report takes the filters its data has (staff, payment method,
 * box or account, source, unit type) beside the period and the branch; the export and the printout carry the same
 * filters and say so (decision 43, X09d); every figure is from the same ledger as the screen.
 */
import { useMemo, useState } from "react";
import { supabase } from "../../lib/supabase";
import { SectionTitle, LoadingScreen, Card, EmptyState, ErrorBanner, Badge, Spinner, LoadErrorCard } from "../../components/ui";
import { BranchPicker } from "../../components/BranchPicker";
import { ExportMenu } from "../../components/ExportMenu";
import { BarChart3, Info, Filter, X } from "lucide-react";
import { BarChart, Bar, XAxis, YAxis, ResponsiveContainer, Tooltip, CartesianGrid, Legend } from "recharts";
import { formatCurrency, formatDateTime, todayISO } from "../../lib/utils";
import { useBranchQuery } from "../../lib/useBranchQuery";
import { useBranch } from "../../lib/branch";
import { opsApi, ratesApi, guestReportsApi, listsApi, type ReportsFinance, type DiscountReport, type ReportFilters, type ReportFilterOptions } from "../../lib/api";
import { useAuth } from "../../lib/auth";
import { Link } from "react-router-dom";
import { ROLE_LABELS } from "../../lib/types";
import { PAYMENT_METHOD_LABELS, type PaymentMethod } from "../../lib/types";
import { money, type ExportScope, type ExportStatement, type ExportTable } from "../../lib/exports";

// Operational columns only — money is never read from the reservations table (GAP05).
interface ResRow { status: string; check_in: string }
interface OpsStats { handoffs: number; unmatched: number; aiRequests14: number; aiFallbacks14: number }
interface OpsData { reservations: ResRow[]; ops: OpsStats }

/** Operational stats (no money): status mix of the branch, open hand-offs, AI usage over 14 days. A failed read is an error, never a zero. */
async function loadOps(branchId: string): Promise<OpsData> {
  const since = new Date(); since.setDate(since.getDate() - 13);
  const [res, handoffs, unmatched, ai] = await Promise.all([
    supabase.from("reservations").select("status, check_in").eq("branch_id", branchId),
    supabase.from("human_handoff_tickets").select("id", { count: "exact", head: true }).eq("status", "open").or(`branch_id.eq.${branchId},branch_id.is.null`),
    supabase.from("human_handoff_tickets").select("id", { count: "exact", head: true }).eq("status", "open").eq("kind", "unmatched_reservation"),
    supabase.from("ai_usage_daily").select("requests, fallbacks").gte("day", since.toISOString().slice(0, 10)),
  ]);
  for (const r of [res, handoffs, unmatched, ai]) if (r.error) throw new Error(r.error.message);
  const aiRows = (ai.data as { requests: number; fallbacks: number }[]) ?? [];
  return {
    reservations: (res.data as unknown as ResRow[]) ?? [],
    ops: { handoffs: handoffs.count ?? 0, unmatched: unmatched.count ?? 0, aiRequests14: aiRows.reduce((s, r) => s + r.requests, 0), aiFallbacks14: aiRows.reduce((s, r) => s + r.fallbacks, 0) },
  };
}

const sar = (h: number) => formatCurrency(h / 100);
const isoDay = (d: Date) => d.toISOString().slice(0, 10);
const addDays = (iso: string, n: number) => { const d = new Date(iso + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return isoDay(d); };
const last30 = () => { const to = todayISO(); return { from: addDays(to, -29), to }; };
const thisMonth = () => { const to = todayISO(); return { from: to.slice(0, 8) + "01", to }; };
const shortDay = (iso: string) => iso.slice(5); // MM-DD on the axis

// Categorical order shared with the other admin charts (brand, accent, …).
const C1 = "#1f5f74", C2 = "#2bb3a3";
const AXIS = { fontSize: 11, fill: "#6f83a3" };
const TOOLTIP = { borderRadius: 12, border: "1px solid #e9edf3", fontSize: 12 };

/** The filters in the reader's words, for the headings and the files' statements (decision 43). */
export function reportFilterWords(f: ReportFilters, o: ReportFilterOptions | null): string[] {
  const w: string[] = [];
  if (f.staff_id) w.push(`الموظف: ${o?.staff.find((s) => s.id === f.staff_id)?.name ?? f.staff_id}`);
  if (f.method) w.push(`طريقة الدفع: ${PAYMENT_METHOD_LABELS[f.method as PaymentMethod] ?? f.method}`);
  if (f.account_id) w.push(`الصندوق أو الحساب: ${f.account_id === "none" ? "بلا صندوق" : o?.accounts.find((a) => a.id === f.account_id)?.name ?? f.account_id}`);
  if (f.source_id) w.push(`المصدر: ${o?.sources.find((s) => s.id === f.source_id)?.name ?? f.source_id}`);
  if (f.category_id) w.push(`نوع الوحدة: ${o?.categories.find((c) => c.id === f.category_id)?.name ?? f.category_id}`);
  if (f.after_arrival) w.push("بعد الوصول فقط");
  return w;
}

export default function AdminReports() {
  const [period, setPeriod] = useState(last30);
  const [filters, setFilters] = useState<ReportFilters>({});
  const { profile } = useAuth();
  const { branch } = useBranch();
  const options = useBranchQuery<ReportFilterOptions | null>(async (b) => { const o = await listsApi.filterOptions(b); return o && "staff" in o ? (o as ReportFilterOptions) : null; }, [], null);
  // G24 (decision 40): both loads belong to the active branch; switching branch clears them, a stale answer is dropped.
  // Ledger KPIs for the branch + period + filters (a change refreshes in place; a failed refresh keeps the shown figures).
  const fin = useBranchQuery<ReportsFinance | null>((branchId) => opsApi.reportsFinance(branchId, period.from, period.to, filters), [period.from, period.to, filters], null);
  const opsQ = useBranchQuery<OpsData | null>(loadOps, [], null);
  const branchId = fin.branchId;
  const report = fin.data, reportError = fin.error;
  const reservations = opsQ.data?.reservations ?? [];
  const ops = opsQ.data?.ops;
  const words = useMemo(() => reportFilterWords(filters, options.data), [filters, options.data]);
  const setFilter = (k: keyof ReportFilters, v: string) => setFilters((f) => { const n: Record<string, unknown> = { ...f, [k]: v }; if (!v) delete n[k]; return n as ReportFilters; });
  const statementFor = (title: string, extra: string[] = []) => (scope: ExportScope): ExportStatement => ({ title, branch: branch?.name_ar ?? null, period, filters: [...words, ...extra], scope, generatedAt: formatDateTime(new Date().toISOString()), by: profile?.full_name ?? null });

  const periodPicker = (
    <div className="flex flex-wrap items-center gap-2 text-sm">
      <label className="flex items-center gap-1.5 text-ink-600">من <input type="date" className="input w-auto py-1" dir="ltr" value={period.from} max={period.to} onChange={(e) => e.target.value && setPeriod({ ...period, from: e.target.value })} /></label>
      <label className="flex items-center gap-1.5 text-ink-600">إلى <input type="date" className="input w-auto py-1" dir="ltr" value={period.to} min={period.from} onChange={(e) => e.target.value && setPeriod({ ...period, to: e.target.value })} /></label>
      <button type="button" onClick={() => setPeriod(last30())} className="btn-ghost py-1 text-xs">آخر 30 يومًا</button>
      <button type="button" onClick={() => setPeriod(thisMonth())} className="btn-ghost py-1 text-xs">هذا الشهر</button>
      {fin.refreshing && <Spinner className="h-4 w-4" />}
    </div>
  );
  const o = options.data;
  const filterBar = (
    <div className="flex flex-wrap items-center gap-2 text-xs text-ink-600" data-testid="report-filters">
      <Filter className="h-4 w-4 text-ink-400" />
      <select className="input w-auto py-1 text-xs" value={filters.staff_id ?? ""} onChange={(e) => setFilter("staff_id", e.target.value)} aria-label="الموظف" data-testid="filter-staff"><option value="">كل الموظفين</option>{(o?.staff ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}{s.is_active ? "" : " (موقوف)"}</option>)}</select>
      <select className="input w-auto py-1 text-xs" value={filters.method ?? ""} onChange={(e) => setFilter("method", e.target.value)} aria-label="طريقة الدفع" data-testid="filter-method"><option value="">كل طرق الدفع</option>{Object.entries(PAYMENT_METHOD_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
      <select className="input w-auto py-1 text-xs" value={filters.account_id ?? ""} onChange={(e) => setFilter("account_id", e.target.value)} aria-label="الصندوق أو الحساب" data-testid="filter-account"><option value="">كل الصناديق والحسابات</option>{(o?.accounts ?? []).map((a) => <option key={a.id} value={a.id}>{a.name}{a.is_active ? "" : " (مؤرشف)"}</option>)}<option value="none">بلا صندوق</option></select>
      <select className="input w-auto py-1 text-xs" value={filters.source_id ?? ""} onChange={(e) => setFilter("source_id", e.target.value)} aria-label="مصدر الحجز" data-testid="filter-source"><option value="">كل المصادر</option>{(o?.sources ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select>
      <select className="input w-auto py-1 text-xs" value={filters.category_id ?? ""} onChange={(e) => setFilter("category_id", e.target.value)} aria-label="نوع الوحدة" data-testid="filter-category"><option value="">كل أنواع الوحدات</option>{(o?.categories ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select>
      {words.length > 0 && <button type="button" className="btn-ghost py-1 text-xs text-ink-500" onClick={() => setFilters({})} data-testid="clear-report-filters"><X className="h-3 w-3" /> مسح</button>}
    </div>
  );

  if (!branchId) {
    return (
      <div>
        <SectionTitle title="التقارير" subtitle="مؤشرات مالية من دفتر السندات وإحصاءات تشغيلية" action={<BranchPicker />} />
        <EmptyState icon={<BarChart3 className="h-10 w-10" />} title="لا توجد بيانات للتقارير" />
      </div>
    );
  }
  if (fin.loading || opsQ.loading) return <LoadingScreen />;

  // ---- operational stats (kept from the previous report; counts only) ----
  const total = reservations.length;
  const confirmed = reservations.filter((r) => r.status === "confirmed").length;
  const checkedIn = reservations.filter((r) => r.status === "checked_in").length;
  // «مغلق» (0033) is a departure too: departed and settled
  const checkedOut = reservations.filter((r) => r.status === "checked_out" || r.status === "closed").length;
  const byStatus = [{ name: "مؤكد", value: confirmed }, { name: "دخل", value: checkedIn }, { name: "غادر", value: checkedOut }];
  const pct = (n: number, d: number) => (d > 0 ? Math.round((n / d) * 100) : 0);

  // ---- ledger KPIs ----
  const L = report?.ledger, Ch = report?.charges;
  const defs = { revenue: report?.definitions?.revenue ?? "صافي التحصيل = سندات قبض الإقامة − الاستردادات + التأمين المستخدم لتغطية رسوم، بتاريخ السند.", collection_rate: report?.definitions?.collection_rate ?? "نسبة التحصيل = صافي التحصيل ÷ إجمالي الرسوم للإقامات المتقاطعة مع الفترة." };
  const rateHidden = !!report && report.collection_rate_pct == null && !!(filters.staff_id || filters.method || filters.account_id);
  const moneyTiles = report && L && Ch ? [
    { label: "صافي التحصيل", value: sar(L.net_collected), tone: "text-success-600", note: defs.revenue },
    { label: "قبض الإقامة", value: sar(L.receipts), tone: "text-ink-800", note: "سندات قبض الإقامة المعتمدة بتاريخ السند ضمن الفترة." },
    { label: "الاستردادات", value: sar(L.refunds), tone: "text-ink-800", note: "سندات الاسترداد المعتمدة ضمن الفترة؛ تُخصم من صافي التحصيل." },
    { label: "إجمالي الرسوم", value: sar(Ch.total_charged), tone: "text-ink-800", note: `إيجار ${sar(Ch.rent)} · إضافات ${sar(Ch.addons)} · خصومات ${sar(Ch.discounts)}${Ch.tax ? ` · ضريبة ${sar(Ch.tax)}` : ""} للإقامات المتقاطعة مع الفترة${filters.source_id || filters.category_id ? " بالمصدر أو النوع المختار" : ""}.` },
    { label: "نسبة التحصيل (%)", value: report.collection_rate_pct == null ? "—" : `${report.collection_rate_pct}%`, tone: "text-brand-700", note: rateHidden ? "لا تُحسب مع مرشح الموظف أو طريقة الدفع أو الصندوق: السندات المرشحة لا تقابل رسوم الإقامات كلها." : defs.collection_rate },
    { label: "رصيد التأمين المفتوح", value: sar(L.deposit_balance_open), tone: "text-ink-800", badge: "ليس إيرادًا", note: `رصيد حالي لا يتبع الفترة ولا المرشحات. ضمن الفترة: قبض تأمين ${sar(L.deposits_received)} · رد تأمين ${sar(L.deposits_refunded)} · تأمين مستخدم لتغطية رسوم ${sar(L.deposits_applied)}.` },
  ] : [];

  const byDay = (report?.by_day ?? []).map((d) => ({ day: shortDay(d.day), قبض: d.receipts / 100, استرداد: d.refunds / 100 }));
  const byMethod = (report?.by_method ?? []).map((m) => ({ name: PAYMENT_METHOD_LABELS[m.method as PaymentMethod] ?? m.method, amount: m.amount_halalas / 100 })).sort((a, b) => b.amount - a.amount);
  const periodRes = report?.reservations;
  const bySource = (periodRes?.by_source ?? []).map((s) => ({ name: s.source, count: s.count })).sort((a, b) => b.count - a.count);
  const byStaff = report?.by_staff ?? [];
  const byAccount = report?.by_account ?? [];

  /** The finance report's file: the KPIs, then the days; breakdowns on their own sheets (the same figures as the screen). */
  const financeTable = async (): Promise<ExportTable> => {
    if (!report) return { columns: [], rows: [] };
    const r = report;
    const kpi: ExportTable["rows"] = [
      ["صافي التحصيل", money(r.ledger.net_collected), ""], ["قبض الإقامة", money(r.ledger.receipts), ""], ["الاستردادات", money(r.ledger.refunds), ""],
      ["إجمالي الرسوم", money(r.charges.total_charged), `إيجار ${sar(r.charges.rent)} · إضافات ${sar(r.charges.addons)} · خصومات ${sar(r.charges.discounts)} · ضريبة ${sar(r.charges.tax)}`],
      ["نسبة التحصيل %", r.collection_rate_pct == null ? "—" : r.collection_rate_pct, rateHidden ? "لا تُحسب مع مرشح الموظف أو الطريقة أو الحساب" : ""],
      ["رصيد التأمين المفتوح (ليس إيرادًا)", money(r.ledger.deposit_balance_open), "رصيد حالي لا يتبع الفترة"],
      ["قبض تأمين / رد تأمين / تأمين مستخدم", `${sar(r.ledger.deposits_received)} / ${sar(r.ledger.deposits_refunded)} / ${sar(r.ledger.deposits_applied)}`, ""],
      ["حجوزات الفترة", r.reservations.count, `${r.reservations.nights} ليلة · ملغاة ${r.reservations.cancelled} · عدم حضور ${r.reservations.no_show}`],
      [], ["اليوم", "قبض", "استرداد", "صافي"],
      ...r.by_day.map((d) => [d.day, money(d.receipts), money(d.refunds), money(d.receipts - d.refunds)]),
    ];
    return {
      columns: ["البند", "القيمة", "ملاحظة", ""], rows: kpi, widths: [34, 16, 40, 14],
      sheets: [
        { name: "حسب الطريقة", rows: [["الطريقة", "قبض الإقامة"], ...r.by_method.map((m) => [PAYMENT_METHOD_LABELS[m.method as PaymentMethod] ?? m.method, money(m.amount_halalas)])], headerRow: 0, widths: [24, 16] },
        { name: "حسب الموظف", rows: [["الموظف", "قبض", "استرداد", "عدد السندات"], ...byStaff.map((s) => [s.staff, money(s.receipts), money(s.refunds), s.count])], headerRow: 0, widths: [24, 14, 14, 12] },
        { name: "حسب الصندوق والحساب", rows: [["الصندوق أو الحساب", "قبض", "صرف"], ...byAccount.map((a) => [a.account, money(a.in_halalas), money(a.out_halalas)])], headerRow: 0, widths: [28, 14, 14] },
        { name: "حسب المصدر", rows: [["المصدر", "عدد الحجوزات", "إجمالي الحجوزات"], ...r.reservations.by_source.map((s) => [s.source, s.count, money(s.total_halalas)])], headerRow: 0, widths: [24, 14, 18] },
      ],
    };
  };

  return (
    <div>
      <SectionTitle title="التقارير" subtitle="مؤشرات مالية من دفتر السندات وإحصاءات تشغيلية" action={
        <div className="flex items-center gap-2">
          <BranchPicker />
          <ExportMenu allOnly source={{ statement: statementFor("التقرير المالي"), table: financeTable, pageCount: report?.by_day.length ?? 0, total: report ? Math.max(1, report.by_day.length) : 0 }} disabled={!report} />
        </div>
      } />

      <Card className="mb-4 flex flex-col gap-3 p-3">
        <div className="flex flex-wrap items-center justify-between gap-3"><p className="text-sm font-semibold text-ink-700">فترة التقرير</p>{periodPicker}</div>
        <div className="flex flex-wrap items-center justify-between gap-3 border-t border-ink-50 pt-3"><p className="text-sm font-semibold text-ink-700">المرشحات <span className="text-xs font-normal text-ink-400">تسري على كل تقرير بحسب ما في بياناته</span></p>{filterBar}</div>
        {words.length > 0 && <p className="text-[11px] text-ink-500" data-testid="report-filter-words">المرشحات: {words.join(" · ")}</p>}
      </Card>

      {reportError && <div className="mb-4"><ErrorBanner message={`تعذّر تحميل المؤشرات المالية: ${reportError}`} /></div>}

      {report && (
        <>
          <h3 className="mb-2 text-sm font-semibold text-ink-700">المؤشرات المالية — من دفتر السندات ({report.period.from} → {report.period.to}){report.filtered && <Badge className="mr-2 bg-brand-50 text-brand-700">مرشّح</Badge>}</h3>
          <div className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-3">
            {moneyTiles.map((t) => (
              <Card key={t.label} className="flex flex-col gap-1">
                <div className="flex items-center justify-between gap-2">
                  <p className="text-xs text-ink-400">{t.label}</p>
                  {t.badge && <Badge className="bg-warning-500/10 text-warning-600">{t.badge}</Badge>}
                </div>
                <p className={`text-xl font-bold ${t.tone}`} dir="ltr">{t.value}</p>
                <p className="flex items-start gap-1 text-[11px] leading-relaxed text-ink-400"><Info className="mt-0.5 h-3 w-3 shrink-0" /> <span>{t.note}</span></p>
              </Card>
            ))}
          </div>
        </>
      )}

      <h3 className="mb-2 text-sm font-semibold text-ink-700">إحصاءات تشغيلية</h3>
      {!ops ? <div className="mb-6"><LoadErrorCard message={opsQ.error ?? "تعذّر تحميل الإحصاءات التشغيلية."} onRetry={opsQ.reload} /></div> : <div className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Card><p className="text-xs text-ink-400">إجمالي الحجوزات</p><p className="mt-1 text-xl font-bold text-ink-800">{total}</p></Card>
        <Card><p className="text-xs text-ink-400">معدل الدخول</p><p className="mt-1 text-xl font-bold text-accent-600">{pct(checkedIn, total)}%</p></Card>
        {report && <Card><p className="text-xs text-ink-400">حجوزات الفترة</p><p className="mt-1 text-xl font-bold text-ink-800">{report.reservations.count}</p><p className="text-[11px] text-ink-400">{report.reservations.nights} ليلة إقامة</p></Card>}
        {report && <Card><p className="text-xs text-ink-400">ملغاة / عدم حضور (الفترة)</p><p className="mt-1 text-xl font-bold text-ink-800">{report.reservations.cancelled} / {report.reservations.no_show}</p></Card>}
        <Card><p className="text-xs text-ink-400">تذاكر تحويل مفتوحة</p><p className="mt-1 text-xl font-bold text-danger-600">{ops.handoffs}</p></Card>
        <Card><p className="text-xs text-ink-400">حجوزات غير مطابقة</p><p className="mt-1 text-xl font-bold text-warning-600">{ops.unmatched}</p></Card>
        <Card><p className="text-xs text-ink-400">طلبات المساعد الذكي (14 يومًا)</p><p className="mt-1 text-xl font-bold text-brand-700">{ops.aiRequests14}</p></Card>
        <Card><p className="text-xs text-ink-400">تحويل لمسار تقليدي (14 يومًا)</p><p className="mt-1 text-xl font-bold text-ink-800">{ops.aiFallbacks14}</p></Card>
      </div>}

      <div className="grid gap-4 lg:grid-cols-2">
        {report && (
          <Card>
            <h3 className="mb-1 text-sm font-semibold text-ink-700">التحصيل اليومي (ر.س)</h3>
            <p className="mb-3 text-[11px] text-ink-400">قبض الإقامة والتأمين المستخدم لتغطية رسوم مقابل الاستردادات، بتاريخ السند.</p>
            {byDay.length === 0 ? <p className="py-10 text-center text-sm text-ink-400">لا سندات في هذه الفترة.</p> : (
              <ResponsiveContainer width="100%" height={240}>
                <BarChart data={byDay}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#e9edf3" vertical={false} />
                  <XAxis dataKey="day" tick={AXIS} />
                  <YAxis tick={AXIS} />
                  <Tooltip contentStyle={TOOLTIP} />
                  <Legend wrapperStyle={{ fontSize: 12 }} />
                  <Bar dataKey="قبض" fill={C1} radius={[4, 4, 0, 0]} />
                  <Bar dataKey="استرداد" fill={C2} radius={[4, 4, 0, 0]} />
                </BarChart>
              </ResponsiveContainer>
            )}
          </Card>
        )}
        {report && (
          <Card>
            <h3 className="mb-1 text-sm font-semibold text-ink-700">قبض الإقامة حسب طريقة الدفع (ر.س)</h3>
            <p className="mb-3 text-[11px] text-ink-400">سندات القبض المعتمدة ضمن الفترة.</p>
            {byMethod.length === 0 ? <p className="py-10 text-center text-sm text-ink-400">لا سندات قبض في هذه الفترة.</p> : (
              <ResponsiveContainer width="100%" height={240}>
                <BarChart data={byMethod} layout="vertical">
                  <CartesianGrid strokeDasharray="3 3" stroke="#e9edf3" horizontal={false} />
                  <XAxis type="number" tick={AXIS} />
                  <YAxis type="category" dataKey="name" tick={AXIS} width={120} />
                  <Tooltip contentStyle={TOOLTIP} />
                  <Bar dataKey="amount" fill={C1} radius={[0, 4, 4, 0]} name="المبلغ" />
                </BarChart>
              </ResponsiveContainer>
            )}
          </Card>
        )}
        {report && (
          <Card data-testid="finance-by-staff">
            <h3 className="mb-1 text-sm font-semibold text-ink-700">التحصيل حسب الموظف</h3>
            <p className="mb-3 text-[11px] text-ink-400">من سجّل سندات القبض والاسترداد في الفترة (يغني عن تقرير منفصل للتحصيل حسب الموظف — القرار 36).</p>
            {byStaff.length === 0 ? <p className="py-6 text-center text-sm text-ink-400">لا سندات في هذه الفترة.</p> : (
              <table className="w-full text-sm"><thead><tr className="border-b border-ink-100 text-xs text-ink-400"><th className="py-1.5 text-right font-medium">الموظف</th><th className="text-right font-medium">قبض</th><th className="text-right font-medium">استرداد</th><th className="text-right font-medium">السندات</th></tr></thead>
                <tbody>{byStaff.map((s) => <tr key={s.staff_id ?? s.staff} className="border-b border-ink-50"><td className="py-1.5">{s.staff}</td><td dir="ltr">{sar(s.receipts)}</td><td dir="ltr">{sar(s.refunds)}</td><td className="text-xs text-ink-500">{s.count}</td></tr>)}</tbody></table>
            )}
          </Card>
        )}
        {report && (
          <Card data-testid="finance-by-account">
            <h3 className="mb-1 text-sm font-semibold text-ink-700">حركة الصناديق والحسابات</h3>
            <p className="mb-3 text-[11px] text-ink-400">قبض الإقامة والتأمين إلى كل صندوق أو حساب، والصرف منه، ضمن الفترة (حركة لا رصيدًا).</p>
            {byAccount.length === 0 ? <p className="py-6 text-center text-sm text-ink-400">لا حركة في هذه الفترة.</p> : (
              <table className="w-full text-sm"><thead><tr className="border-b border-ink-100 text-xs text-ink-400"><th className="py-1.5 text-right font-medium">الصندوق أو الحساب</th><th className="text-right font-medium">قبض</th><th className="text-right font-medium">صرف</th></tr></thead>
                <tbody>{byAccount.map((a) => <tr key={a.account_id} className="border-b border-ink-50"><td className="py-1.5">{a.account}</td><td dir="ltr">{sar(a.in_halalas)}</td><td dir="ltr">{sar(a.out_halalas)}</td></tr>)}</tbody></table>
            )}
          </Card>
        )}
        {ops && (
          <Card>
            <h3 className="mb-4 text-sm font-semibold text-ink-700">الحجوزات حسب الحالة</h3>
            <ResponsiveContainer width="100%" height={240}>
              <BarChart data={byStatus}>
                <XAxis dataKey="name" tick={AXIS} />
                <YAxis tick={AXIS} allowDecimals={false} />
                <Tooltip contentStyle={TOOLTIP} />
                <Bar dataKey="value" fill={C1} radius={[4, 4, 0, 0]} name="عدد" />
              </BarChart>
            </ResponsiveContainer>
          </Card>
        )}
        {report && (
          <Card>
            <h3 className="mb-4 text-sm font-semibold text-ink-700">حجوزات الفترة حسب المصدر</h3>
            {bySource.length === 0 ? <p className="py-10 text-center text-sm text-ink-400">لا حجوزات في هذه الفترة.</p> : (
              <ResponsiveContainer width="100%" height={240}>
                <BarChart data={bySource} layout="vertical">
                  <CartesianGrid strokeDasharray="3 3" stroke="#e9edf3" horizontal={false} />
                  <XAxis type="number" tick={AXIS} allowDecimals={false} />
                  <YAxis type="category" dataKey="name" tick={AXIS} width={120} />
                  <Tooltip contentStyle={TOOLTIP} />
                  <Bar dataKey="count" fill={C1} radius={[0, 4, 4, 0]} name="عدد" />
                </BarChart>
              </ResponsiveContainer>
            )}
          </Card>
        )}
      </div>
      <DiscountsCard from={period.from} to={period.to} filters={filters} statementFor={statementFor} />
      <LateEntriesCard from={period.from} to={period.to} filters={filters} statementFor={statementFor} />
      <IdentitiesCard from={period.from} to={period.to} filters={filters} statementFor={statementFor} />
    </div>
  );
}

type StatementFor = (title: string, extra?: string[]) => (scope: ExportScope) => ExportStatement;

/** «الحجوزات المتأخرة الإدخال» (decision 4): platform bookings entered a day or more after the platform took them (owner, manager). Filters: staff, source. */
function LateEntriesCard({ from, to, filters, statementFor }: { from: string; to: string; filters: ReportFilters; statementFor: StatementFor }) {
  const { profile } = useAuth();
  const allowed = profile?.role === "owner" || profile?.role === "manager";
  const f = useMemo(() => ({ staff_id: filters.staff_id, source_id: filters.source_id }), [filters.staff_id, filters.source_id]);
  const q = useBranchQuery<Awaited<ReturnType<typeof guestReportsApi.lateEntries>> | null>((branchId) => (allowed ? guestReportsApi.lateEntries(branchId, from, to, 1, f) : Promise.resolve(null)), [from, to, allowed, f], null);
  const d = q.data;
  if (!allowed) return null;
  const table = async (): Promise<ExportTable> => ({ columns: ["الحجز", "رقم المنصة", "المنصة", "حُجز في المنصة", "أُدخل", "التأخير (يوم)", "بعد الوصول", "الوصول", "الحالة", "الموظف"], rows: (d?.rows ?? []).map((r) => [r.internal_ref, r.external_ref ?? "", r.source_name ?? "", r.booked_on, r.entered_on, r.lag_days, r.after_arrival ? "نعم" : "", r.check_in, r.status, r.created_by ?? ""]) });
  return (
    <Card className="mt-4" data-testid="late-entries-report">
      <div className="mb-3 flex flex-wrap items-baseline justify-between gap-2">
        <h3 className="text-sm font-semibold text-ink-700">حجوزات المنصات المتأخرة الإدخال ({from} → {to})</h3>
        <div className="flex items-center gap-2">{d && <p className="text-sm text-ink-600">{d.late} من {d.platform_bookings} حجز منصة أُدخل بعد يوم أو أكثر{d.after_arrival ? ` · ${d.after_arrival} بعد موعد الوصول` : ""}</p>}<ExportMenu allOnly source={{ statement: statementFor("حجوزات المنصات المتأخرة الإدخال"), table, pageCount: d?.late ?? 0, total: d?.late ?? 0 }} /></div>
      </div>
      {q.error ? <ErrorBanner message={q.error} /> : !d ? <div className="py-6 text-center"><Spinner /></div> : d.late === 0 ? <p className="text-sm text-ink-400">لا حجوزات متأخرة الإدخال في هذه الفترة.</p> : (
        <div className="grid gap-4 lg:grid-cols-3">
          <div>
            <p className="mb-1 text-xs font-medium text-ink-500">حسب الموظف</p>
            <div className="divide-y divide-ink-50 text-sm">{d.by_staff.map((s) => <div key={s.staff} className="flex justify-between gap-2 py-1.5"><span>{s.staff}</span><span className="text-xs text-ink-500">{s.count} · أقصى تأخير {s.max_lag} يوم</span></div>)}</div>
          </div>
          <div className="overflow-x-auto lg:col-span-2">
            <table className="w-full text-sm">
              <thead><tr className="border-b border-ink-100 text-xs text-ink-400"><th className="py-1.5 text-right font-medium">الحجز</th><th className="text-right font-medium">المنصة</th><th className="text-right font-medium">حُجز في المنصة</th><th className="text-right font-medium">أُدخل</th><th className="text-right font-medium">التأخير</th><th className="text-right font-medium">الموظف</th></tr></thead>
              <tbody>{d.rows.map((r) => (
                <tr key={r.id} className="border-b border-ink-50">
                  <td className="py-1.5 font-mono text-xs"><Link className="hover:underline" to={`/staff/reservations/${r.id}`}>{r.external_ref ?? r.internal_ref}</Link></td>
                  <td className="text-xs">{r.source_name}</td><td className="text-xs" dir="ltr">{r.booked_on}</td><td className="text-xs" dir="ltr">{r.entered_on}</td>
                  <td className="text-xs">{r.lag_days} يوم{r.after_arrival && <Badge className="mr-1 bg-danger-500/10 text-danger-600">بعد الوصول</Badge>}</td>
                  <td className="text-xs text-ink-500">{r.created_by ?? "—"}</td>
                </tr>))}</tbody>
            </table>
          </div>
        </div>
      )}
    </Card>
  );
}

/** «الهويات المعتمدة من المكتب» (decision 2): identities the office entered from the document, with who and when (the owner). Filter: staff (who verified). */
function IdentitiesCard({ from, to, filters, statementFor }: { from: string; to: string; filters: ReportFilters; statementFor: StatementFor }) {
  const { profile } = useAuth();
  const allowed = profile?.role === "owner";
  const [path, setPath] = useState<"office" | "guest" | "all">("office");
  const f = useMemo(() => ({ staff_id: filters.staff_id }), [filters.staff_id]);
  const q = useBranchQuery<Awaited<ReturnType<typeof guestReportsApi.identities>> | null>((branchId) => (allowed ? guestReportsApi.identities(branchId, from, to, path, f) : Promise.resolve(null)), [from, to, path, allowed, f], null);
  const d = q.data;
  if (!allowed) return null;
  const pathWord = path === "office" ? "من المكتب (من الوثيقة)" : path === "guest" ? "أدخلها الضيف وطابقها المشرف" : "كل المسارات";
  const table = async (): Promise<ExportTable> => ({ columns: ["الحجز", "النزيل", "مرافق", "نوع الوثيقة", "آخر أربعة", "المسار", "أدخلها", "وقت الإدخال", "اعتمدها", "وقت الاعتماد"], rows: (d?.rows ?? []).map((r) => [r.internal_ref, r.full_name, r.is_primary ? "" : "نعم", r.identity_type ?? "", r.identity_last4 ? `••••${r.identity_last4}` : "", r.entry_path === "office" ? "من الوثيقة" : "أدخلها الضيف", r.entered_by ?? "", r.entered_at ? formatDateTime(r.entered_at) : "", r.verified_by ?? "", formatDateTime(r.verified_at)]) });
  return (
    <Card className="mt-4" data-testid="identities-report">
      <div className="mb-3 flex flex-wrap items-baseline justify-between gap-2">
        <h3 className="text-sm font-semibold text-ink-700">الهويات المعتمدة ({from} → {to})</h3>
        <div className="flex items-center gap-2">
          <select className="input py-1 text-xs" value={path} onChange={(e) => setPath(e.target.value as typeof path)} aria-label="المسار"><option value="office">من المكتب (من الوثيقة)</option><option value="guest">أدخلها الضيف وطابقها المشرف</option><option value="all">الكل</option></select>
          {d && <p className="text-sm text-ink-600">{d.count}</p>}
          <ExportMenu allOnly source={{ statement: statementFor("الهويات المعتمدة", [`المسار: ${pathWord}`]), table, pageCount: d?.count ?? 0, total: d?.count ?? 0 }} />
        </div>
      </div>
      {q.error ? <ErrorBanner message={q.error} /> : !d ? <div className="py-6 text-center"><Spinner /></div> : d.count === 0 ? <p className="text-sm text-ink-400">لا هويات معتمدة بهذا المسار في الفترة.</p> : (
        <div className="grid gap-4 lg:grid-cols-3">
          <div>
            <p className="mb-1 text-xs font-medium text-ink-500">حسب من اعتمد</p>
            <div className="divide-y divide-ink-50 text-sm">{d.by_staff.map((s) => <div key={s.staff} className="flex justify-between gap-2 py-1.5"><span>{s.staff}</span><span className="text-xs text-ink-500">من المكتب {s.office} · مطابقة {s.guest}</span></div>)}</div>
          </div>
          <div className="overflow-x-auto lg:col-span-2">
            <table className="w-full text-sm">
              <thead><tr className="border-b border-ink-100 text-xs text-ink-400"><th className="py-1.5 text-right font-medium">الحجز</th><th className="text-right font-medium">النزيل</th><th className="text-right font-medium">الوثيقة</th><th className="text-right font-medium">المسار</th><th className="text-right font-medium">اعتمدها</th><th className="text-right font-medium">متى</th></tr></thead>
              <tbody>{d.rows.map((r) => (
                <tr key={r.guest_id} className="border-b border-ink-50">
                  <td className="py-1.5 font-mono text-xs"><Link className="hover:underline" to={`/staff/reservations/${r.reservation_id}`}>{r.internal_ref}</Link></td>
                  <td className="text-xs">{r.full_name}{!r.is_primary && <span className="mr-1 text-[10px] text-ink-400">(مرافق)</span>}</td>
                  <td className="text-xs">{r.identity_type ?? "—"} ••••{r.identity_last4 ?? ""}</td>
                  <td className="text-xs">{r.entry_path === "office" ? "من الوثيقة" : "أدخلها الضيف"}</td>
                  <td className="text-xs text-ink-500">{r.verified_by ?? "—"}</td>
                  <td className="text-xs text-ink-500" dir="ltr">{r.verified_at.slice(0, 16).replace("T", " ")}</td>
                </tr>))}</tbody>
            </table>
          </div>
        </div>
      )}
    </Card>
  );
}

/** «تقرير الخصومات» (decision 9): who gave which discount, how much and why, in the period. Filters: staff, source, unit type, «بعد الوصول». */
function DiscountsCard({ from, to, filters, statementFor }: { from: string; to: string; filters: ReportFilters; statementFor: StatementFor }) {
  const [afterArrival, setAfterArrival] = useState(false);
  const f = useMemo(() => ({ staff_id: filters.staff_id, source_id: filters.source_id, category_id: filters.category_id, after_arrival: afterArrival || undefined }), [filters.staff_id, filters.source_id, filters.category_id, afterArrival]);
  const q = useBranchQuery<DiscountReport | null>((branchId) => ratesApi.discounts(branchId, from, to, f), [from, to, f], null);
  const d = q.data;
  const table = async (): Promise<ExportTable> => ({ columns: ["الحجز", "المبلغ", "السبب", "الموظف", "الدور", "الوقت", "بعد الوصول"], rows: (d?.rows ?? []).map((r) => [r.internal_ref, money(r.amount_halalas), r.reason ?? "", r.staff ?? "", r.role ? ROLE_LABELS[r.role as keyof typeof ROLE_LABELS] ?? r.role : "", formatDateTime(r.created_at), r.after_arrival ? "نعم" : ""]), sheets: [{ name: "حسب الموظف", rows: [["الموظف", "الدور", "عدد", "الإجمالي"], ...(d?.by_staff ?? []).map((s) => [s.staff ?? "—", s.role ? ROLE_LABELS[s.role as keyof typeof ROLE_LABELS] ?? s.role : "", s.count, money(s.total_halalas)])], headerRow: 0, widths: [24, 14, 8, 14] }] });
  return (
    <Card className="mt-4" data-testid="discounts-report">
      <div className="mb-3 flex flex-wrap items-baseline justify-between gap-2">
        <h3 className="text-sm font-semibold text-ink-700">تقرير الخصومات ({from} → {to})</h3>
        <div className="flex items-center gap-2">
          <label className="flex items-center gap-1.5 text-xs text-ink-600"><input type="checkbox" checked={afterArrival} onChange={(e) => setAfterArrival(e.target.checked)} /> بعد الوصول فقط</label>
          {d && <p className="text-sm text-ink-600">{d.count} خصم · <span className="font-semibold" dir="ltr">{sar(d.total_halalas)}</span></p>}
          <ExportMenu allOnly source={{ statement: statementFor("تقرير الخصومات", afterArrival ? ["بعد الوصول فقط"] : []), table, pageCount: d?.rows?.length ?? 0, total: d?.rows?.length ?? 0 }} />
        </div>
      </div>
      {q.error ? <ErrorBanner message={q.error} /> : !d ? <div className="py-6 text-center"><Spinner /></div> : d.count === 0 ? <p className="text-sm text-ink-400">لا خصومات في هذه الفترة.</p> : (
        <div className="grid gap-4 lg:grid-cols-3">
          <div>
            <p className="mb-1 text-xs font-medium text-ink-500">حسب الموظف</p>
            <div className="divide-y divide-ink-50 text-sm">
              {d.by_staff.map((s) => <div key={`${s.staff}|${s.role}`} className="flex justify-between gap-2 py-1.5"><span>{s.staff ?? "—"} <span className="text-xs text-ink-400">{s.role ? ROLE_LABELS[s.role as keyof typeof ROLE_LABELS] ?? s.role : ""}</span></span><span dir="ltr">{s.count} · {sar(s.total_halalas)}</span></div>)}
            </div>
          </div>
          {d.rows && (
            <div className="overflow-x-auto lg:col-span-2">
              <table className="w-full text-sm">
                <thead><tr className="border-b border-ink-100 text-xs text-ink-400"><th className="py-1.5 text-right font-medium">الحجز</th><th className="text-right font-medium">المبلغ</th><th className="text-right font-medium">السبب</th><th className="text-right font-medium">الموظف</th><th className="text-right font-medium">الوقت</th></tr></thead>
                <tbody>
                  {d.rows.map((r) => (
                    <tr key={r.id} className="border-b border-ink-50">
                      <td className="py-1.5 font-mono text-xs"><Link className="hover:underline" to={`/staff/reservations/${r.reservation_id}`}>{r.internal_ref}</Link></td>
                      <td dir="ltr">{sar(r.amount_halalas)}</td>
                      <td className="text-ink-600">{r.reason ?? "—"}{r.after_arrival && <Badge className="mr-1 bg-warning-500/10 text-warning-600">بعد الوصول</Badge>}</td>
                      <td className="text-xs text-ink-500">{r.staff ?? "—"}</td>
                      <td className="text-xs text-ink-400" dir="ltr">{r.created_at.slice(0, 16).replace("T", " ")}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}
    </Card>
  );
}
