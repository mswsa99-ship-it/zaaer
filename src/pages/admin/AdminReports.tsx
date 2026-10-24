/**
 * Reports (GAP05): every money figure comes from the voucher ledger through fn_reports_finance (role-gated on the
 * server) — never from reservation totals or a count of "paid" reservations. Deposits are shown as a separate
 * open balance and are explicitly not revenue. Operational stats (status mix, hand-offs, AI usage) are kept.
 */
import { useState } from "react";
import { supabase } from "../../lib/supabase";
import { SectionTitle, LoadingScreen, Card, EmptyState, ErrorBanner, Badge, Spinner, LoadErrorCard } from "../../components/ui";
import { BranchPicker } from "../../components/BranchPicker";
import { BarChart3, Download, Info } from "lucide-react";
import { BarChart, Bar, XAxis, YAxis, ResponsiveContainer, Tooltip, CartesianGrid, Legend } from "recharts";
import { formatCurrency, todayISO } from "../../lib/utils";
import { useBranchQuery } from "../../lib/useBranchQuery";
import { opsApi, type ReportsFinance } from "../../lib/api";
import { PAYMENT_METHOD_LABELS, type PaymentMethod } from "../../lib/types";

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

export default function AdminReports() {
  const [period, setPeriod] = useState(last30);
  // G24 (decision 40): both loads belong to the active branch; switching branch clears them, a stale answer is dropped.
  // Ledger KPIs for the branch + period (a period change refreshes in place; a failed refresh keeps the shown figures).
  const fin = useBranchQuery<ReportsFinance | null>((branchId) => opsApi.reportsFinance(branchId, period.from, period.to), [period.from, period.to], null);
  const opsQ = useBranchQuery<OpsData | null>(loadOps, [], null);
  const branchId = fin.branchId;
  const report = fin.data, reportError = fin.error;
  const reservations = opsQ.data?.reservations ?? [];
  const ops = opsQ.data?.ops;

  const periodPicker = (
    <div className="flex flex-wrap items-center gap-2 text-sm">
      <label className="flex items-center gap-1.5 text-ink-600">من <input type="date" className="input w-auto py-1" dir="ltr" value={period.from} max={period.to} onChange={(e) => e.target.value && setPeriod({ ...period, from: e.target.value })} /></label>
      <label className="flex items-center gap-1.5 text-ink-600">إلى <input type="date" className="input w-auto py-1" dir="ltr" value={period.to} min={period.from} onChange={(e) => e.target.value && setPeriod({ ...period, to: e.target.value })} /></label>
      <button type="button" onClick={() => setPeriod(last30())} className="btn-ghost py-1 text-xs">آخر 30 يومًا</button>
      <button type="button" onClick={() => setPeriod(thisMonth())} className="btn-ghost py-1 text-xs">هذا الشهر</button>
      {fin.refreshing && <Spinner className="h-4 w-4" />}
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
  const checkedOut = reservations.filter((r) => r.status === "checked_out").length;
  const byStatus = [
    { name: "مؤكد", value: confirmed },
    { name: "دخل", value: checkedIn },
    { name: "غادر", value: checkedOut },
  ];
  const pct = (n: number, d: number) => (d > 0 ? Math.round((n / d) * 100) : 0);

  // ---- ledger KPIs ----
  const L = report?.ledger, Ch = report?.charges;
  const defs = { revenue: report?.definitions?.revenue ?? "صافي التحصيل = سندات قبض الإقامة − الاستردادات + التأمين المستخدم لتغطية رسوم، بتاريخ السند.", collection_rate: report?.definitions?.collection_rate ?? "نسبة التحصيل = صافي التحصيل ÷ إجمالي الرسوم للإقامات المتقاطعة مع الفترة." };
  const moneyTiles = report && L && Ch ? [
    { label: "صافي التحصيل", value: sar(L.net_collected), tone: "text-success-600", note: defs.revenue },
    { label: "قبض الإقامة", value: sar(L.receipts), tone: "text-ink-800", note: "سندات قبض الإقامة المعتمدة بتاريخ السند ضمن الفترة." },
    { label: "الاستردادات", value: sar(L.refunds), tone: "text-ink-800", note: "سندات الاسترداد المعتمدة ضمن الفترة؛ تُخصم من صافي التحصيل." },
    { label: "إجمالي الرسوم", value: sar(Ch.total_charged), tone: "text-ink-800", note: `إيجار ${sar(Ch.rent)} · إضافات ${sar(Ch.addons)} · خصومات ${sar(Ch.discounts)}${Ch.tax ? ` · ضريبة ${sar(Ch.tax)}` : ""} للإقامات المتقاطعة مع الفترة.` },
    { label: "نسبة التحصيل (%)", value: report.collection_rate_pct == null ? "—" : `${report.collection_rate_pct}%`, tone: "text-brand-700", note: defs.collection_rate },
    { label: "رصيد التأمين المفتوح", value: sar(L.deposit_balance_open), tone: "text-ink-800", badge: "ليس إيرادًا", note: `رصيد حالي لا يتبع الفترة. ضمن الفترة: قبض تأمين ${sar(L.deposits_received)} · رد تأمين ${sar(L.deposits_refunded)} · تأمين مستخدم لتغطية رسوم ${sar(L.deposits_applied)}.` },
  ] : [];

  const byDay = (report?.by_day ?? []).map((d) => ({ day: shortDay(d.day), قبض: d.receipts / 100, استرداد: d.refunds / 100 }));
  const byMethod = (report?.by_method ?? []).map((m) => ({ name: PAYMENT_METHOD_LABELS[m.method as PaymentMethod] ?? m.method, amount: m.amount_halalas / 100 })).sort((a, b) => b.amount - a.amount);
  const periodRes = report?.reservations;
  const bySource = (periodRes?.by_source ?? []).map((s) => ({ name: s.source, count: s.count })).sort((a, b) => b.count - a.count);

  return (
    <div>
      <SectionTitle title="التقارير" subtitle="مؤشرات مالية من دفتر السندات وإحصاءات تشغيلية" action={
        <div className="flex items-center gap-2">
          <BranchPicker />
          <button onClick={() => report && exportCsv(report)} disabled={!report} className="btn-outline text-sm"><Download className="h-4 w-4" /> تصدير CSV</button>
        </div>
      } />

      <Card className="mb-4 flex flex-wrap items-center justify-between gap-3 p-3">
        <p className="text-sm font-semibold text-ink-700">فترة التقرير</p>
        {periodPicker}
      </Card>

      {reportError && <div className="mb-4"><ErrorBanner message={`تعذّر تحميل المؤشرات المالية: ${reportError}`} /></div>}

      {report && (
        <>
          <h3 className="mb-2 text-sm font-semibold text-ink-700">المؤشرات المالية — من دفتر السندات ({report.period.from} → {report.period.to})</h3>
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
    </div>
  );
}

/** Ledger figures of the period (SAR), one row per day plus the totals — never reservation totals. */
function exportCsv(r: ReportsFinance) {
  const n = (h: number) => (h / 100).toFixed(2);
  const head = ["اليوم", "قبض", "استرداد", "صافي"];
  const rows = r.by_day.map((d) => [d.day, n(d.receipts), n(d.refunds), n(d.receipts - d.refunds)]);
  const totals = [
    [`الإجمالي ${r.period.from} → ${r.period.to}`, n(r.ledger.receipts), n(r.ledger.refunds), n(r.ledger.net_collected)],
    ["إجمالي الرسوم", n(r.charges.total_charged), "", ""],
    ["نسبة التحصيل %", r.collection_rate_pct == null ? "" : String(r.collection_rate_pct), "", ""],
    ["رصيد التأمين المفتوح (ليس إيرادًا)", n(r.ledger.deposit_balance_open), "", ""],
  ];
  const csv = "﻿" + [head, ...rows, ...totals].map((x) => x.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(",")).join("\n");
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url; a.download = `finance-report-${r.period.from}-${r.period.to}.csv`; a.click();
  URL.revokeObjectURL(url);
}
