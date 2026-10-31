/**
 * U3 (approved 31 Oct 2026): the owner's view across every branch they hold — the branches side by side today, what
 * the platforms still owe net of their commission, and the operations alerts. It reads only the existing RPCs
 * (fn_ops_daily_summary, fn_platform_unsettled), branch by branch, so a branch added in the settings shows up here by
 * itself. A branch whose read fails says so in its row; it is never a zero.
 */
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { opsApi, moneyApi, toArabicError, type DailySummary, type PlatformPayment } from "../lib/api";
import { useBranch } from "../lib/branch";
import { bpToPercent } from "../lib/money";
import { Card, Badge, Spinner } from "./ui";
import { formatCurrency } from "../lib/utils";

interface Row { id: string; name: string; summary: DailySummary | null; payouts: PlatformPayment[] | null; error?: string }

/** Net due from a platform for one payment: the gross less its commission, rounded per payment like the confirmation. */
export function netOfCommission(p: Pick<PlatformPayment, "signed_halalas" | "commission_bp">): number {
  const bp = p.commission_bp ?? 0;
  const sign = p.signed_halalas < 0 ? -1 : 1;
  const gross = Math.abs(p.signed_halalas);
  return sign * (gross - Math.round((gross * bp) / 10000));
}

export function OwnerOverview() {
  const { branches } = useBranch();
  const [rows, setRows] = useState<Row[] | null>(null);
  const key = branches.map((b) => b.id).join(",");

  useEffect(() => {
    let live = true;
    if (branches.length === 0) { setRows([]); return; }
    Promise.all(branches.map(async (b): Promise<Row> => {
      try {
        const [summary, payouts] = await Promise.all([opsApi.dailySummary(b.id), moneyApi.platformUnsettled(b.id).catch(() => null)]);
        return { id: b.id, name: b.name_ar, summary, payouts };
      } catch (e) { return { id: b.id, name: b.name_ar, summary: null, payouts: null, error: toArabicError(e) }; }
    })).then((r) => { if (live) setRows(r); });
    return () => { live = false; };
  }, [key]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!rows) return <div className="mb-6 flex justify-center py-6"><Spinner className="h-6 w-6" /></div>;
  if (rows.length < 1) return null;

  const ok = rows.filter((r) => r.summary);
  const sum = (f: (s: DailySummary) => number) => ok.reduce((a, r) => a + f(r.summary!), 0);
  const active = sum((s) => s.units.active);
  const occupied = sum((s) => s.units.occupied);

  // the platforms: one line per source across the branches, net of commission
  const bySource = new Map<string, { name: string; bp: number; net: number }>();
  for (const r of rows) for (const p of r.payouts ?? []) {
    const k = p.source_id;
    const cur = bySource.get(k) ?? { name: p.source_name ?? "—", bp: p.commission_bp ?? 0, net: 0 };
    cur.net += netOfCommission(p);
    bySource.set(k, cur);
  }
  const platforms = [...bySource.values()].sort((a, b) => b.net - a.net);

  // the operations alerts, the urgent first
  const alerts: Array<{ level: "danger" | "warn" | "ok"; text: string }> = [];
  for (const r of rows) {
    if (!r.summary) { alerts.push({ level: "danger", text: `${r.name}: تعذّر قراءة ملخص اليوم` }); continue; }
    const s = r.summary;
    if (s.departures.overstay > 0) alerts.push({ level: "danger", text: `${r.name}: ${s.departures.overstay} تجاوز موعد المغادرة` });
    if (s.arrivals.overdue > 0) alerts.push({ level: "danger", text: `${r.name}: ${s.arrivals.overdue} وصول متأخر لم يُسجَّل` });
    if (s.arrivals.pending_identity > 0) alerts.push({ level: "warn", text: `${r.name}: ${s.arrivals.pending_identity} وصول بانتظار مطابقة الهوية` });
    if (s.units.dirty > 0) alerts.push({ level: "warn", text: `${r.name}: ${s.units.dirty} وحدة تحتاج تنظيفًا` });
    if (s.tickets_open > 0) alerts.push({ level: "warn", text: `${r.name}: ${s.tickets_open} بلاغ مفتوح` });
    if (s.departures.overstay + s.arrivals.overdue + s.arrivals.pending_identity + s.units.dirty + s.tickets_open === 0) alerts.push({ level: "ok", text: `${r.name}: لا شيء ينتظر` });
  }
  const order = { danger: 0, warn: 1, ok: 2 } as const;
  alerts.sort((a, b) => order[a.level] - order[b.level]);
  const badge = { danger: ["bg-danger-500/10 text-danger-600", "عاجل"], warn: ["bg-warning-500/10 text-warning-700", "تنبيه"], ok: ["bg-success-500/10 text-success-600", "تم"] } as const;

  return (
    <div className="mb-6 space-y-4" data-testid="owner-overview">
      <Card>
        <h2 className="mb-3 text-base font-semibold text-ink-800">{rows.length === 1 ? "الفرع اليوم" : "الفروع اليوم"}</h2>
        <div className="overflow-x-auto">
          <table className="w-full min-w-[34rem] text-sm" data-testid="branches-today">
            <thead><tr className="border-b border-ink-100 bg-ink-50 text-xs text-ink-600">
              <th className="px-3 py-2 text-right font-semibold">الفرع</th>
              <th className="px-3 py-2 text-left font-semibold">الإشغال</th>
              <th className="px-3 py-2 text-left font-semibold">وصول / مغادرة</th>
              <th className="px-3 py-2 text-left font-semibold">المحصّل اليوم</th>
              <th className="px-3 py-2 text-left font-semibold">متبقٍ على المقيمين</th>
            </tr></thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id} className="border-b border-ink-50" data-testid="branch-row" data-branch={r.name}>
                  <td className="px-3 py-2">{r.name}</td>
                  {r.summary ? <>
                    <td className="px-3 py-2 text-left tabular-nums">{r.summary.occupancy_pct}%</td>
                    <td className="px-3 py-2 text-left tabular-nums">{r.summary.arrivals.expected} / {r.summary.departures.expected}</td>
                    <td className="px-3 py-2 text-left tabular-nums">{formatCurrency((r.summary.finance.received_today - r.summary.finance.refunded_today) / 100)}</td>
                    <td className="px-3 py-2 text-left tabular-nums">{formatCurrency(r.summary.finance.outstanding_in_house / 100)}</td>
                  </> : <td colSpan={4} className="px-3 py-2 text-danger-600">{r.error ?? "تعذّر القراءة"}</td>}
                </tr>
              ))}
              {rows.length > 1 && (
                <tr className="bg-ink-50 font-semibold" data-testid="branches-total">
                  <td className="px-3 py-2">المجموع</td>
                  <td className="px-3 py-2 text-left tabular-nums">{active > 0 ? Math.round((occupied / active) * 100) : 0}%</td>
                  <td className="px-3 py-2 text-left tabular-nums">{sum((s) => s.arrivals.expected)} / {sum((s) => s.departures.expected)}</td>
                  <td className="px-3 py-2 text-left tabular-nums">{formatCurrency(sum((s) => s.finance.received_today - s.finance.refunded_today) / 100)}</td>
                  <td className="px-3 py-2 text-left tabular-nums">{formatCurrency(sum((s) => s.finance.outstanding_in_house) / 100)}</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </Card>
      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <h2 className="mb-2 text-base font-semibold text-ink-800">آجل عند المنصات (صافٍ بعد العمولة)</h2>
          {platforms.length === 0 ? <p className="text-sm text-ink-500">لا مبالغ آجلة عند المنصات.</p> : (
            <ul className="space-y-1.5 text-sm" data-testid="platforms-net">
              {platforms.map((p) => (
                <li key={p.name} className="flex justify-between gap-3">
                  <span>{p.name}{p.bp > 0 ? ` · ${bpToPercent(p.bp)}%` : ""}</span>
                  <span className="tabular-nums">{formatCurrency(p.net / 100)}</span>
                </li>
              ))}
            </ul>
          )}
          <Link to="/admin/platform-payouts" className="btn-outline mt-3 inline-flex text-sm">مطابقة المنصات</Link>
        </Card>
        <Card>
          <h2 className="mb-2 text-base font-semibold text-ink-800">تنبيهات التشغيل</h2>
          <ul className="space-y-1.5 text-sm" data-testid="ops-alerts">
            {alerts.map((a, i) => (
              <li key={i} className="flex items-start gap-2"><Badge className={badge[a.level][0]}>{badge[a.level][1]}</Badge><span>{a.text}</span></li>
            ))}
          </ul>
        </Card>
      </div>
    </div>
  );
}
