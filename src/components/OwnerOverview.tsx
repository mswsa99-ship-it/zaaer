/**
 * U3 (approved 31 Oct 2026): the owner's view across every branch they hold — the branches side by side today, what
 * the platforms still owe net of their commission, and the operations alerts. It reads only the existing RPCs
 * (fn_ops_daily_summary, fn_platform_unsettled), branch by branch, so a branch added in the settings shows up here by
 * itself. A branch whose read fails says so in its row; it is never a zero.
 *
 * Review of 31 October, Phase 4a: «المحصّل اليوم» is the money taken at the property (cash, POS, transfer) net of
 * refunds, the platforms' money of the day beside it, each defined under the table (OWNER-02/04); on a phone every
 * branch is a card (OWNER-11); every alert opens its list in its branch (OWNER-11); «آخر تحديث» with a refresh; a
 * platform with no commission set says so (OWNER-18); counts agree with their nouns (OWNER-23); the assistant's usage,
 * which belongs to the whole organisation, is here labelled «كل الفروع» (OWNER-05).
 */
import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { RefreshCw, Bot } from "lucide-react";
import { supabase } from "../lib/supabase";
import { opsApi, moneyApi, toArabicError, type DailySummary, type PlatformPayment } from "../lib/api";
import { useBranch } from "../lib/branch";
import { bpToPercent } from "../lib/money";
import { Card, Badge, Spinner } from "./ui";
import { formatCurrency, arabicCount, COUNT } from "../lib/utils";

interface Row { id: string; name: string; summary: DailySummary | null; payouts: PlatformPayment[] | null; error?: string }

/** Net due from a platform for one payment: the gross less its commission, rounded per payment like the confirmation. */
export function netOfCommission(p: Pick<PlatformPayment, "signed_halalas" | "commission_bp">): number {
  const bp = p.commission_bp ?? 0;
  const sign = p.signed_halalas < 0 ? -1 : 1;
  const gross = Math.abs(p.signed_halalas);
  return sign * (gross - Math.round((gross * bp) / 10000));
}

const pct1 = (n: number) => `${Number(n).toFixed(1)}%`;
const collected = (s: DailySummary) => (s.finance?.received_today ?? 0) - (s.finance?.refunded_today ?? 0);
const hhmm = (d: Date) => d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });

export function OwnerOverview() {
  const { branches, setBranchId } = useBranch();
  const navigate = useNavigate();
  const [rows, setRows] = useState<Row[] | null>(null);
  const [ai, setAi] = useState<{ requests: number; fallbacks: number } | null>(null);
  const [at, setAt] = useState<Date | null>(null);
  const [busy, setBusy] = useState(false);
  const key = branches.map((b) => b.id).join(",");

  const load = useCallback(async () => {
    if (branches.length === 0) { setRows([]); return; }
    setBusy(true);
    const r = await Promise.all(branches.map(async (b): Promise<Row> => {
      try {
        const [summary, payouts] = await Promise.all([opsApi.dailySummary(b.id), moneyApi.platformUnsettled(b.id).catch(() => null)]);
        return { id: b.id, name: b.name_ar, summary, payouts };
      } catch (e) { return { id: b.id, name: b.name_ar, summary: null, payouts: null, error: toArabicError(e) }; }
    }));
    const u = await supabase.from("ai_usage_daily").select("requests, fallbacks").eq("day", new Date().toISOString().slice(0, 10));
    setRows(r); setAt(new Date()); setBusy(false);
    setAi(u.error ? null : ((u.data as { requests: number; fallbacks: number }[]) ?? []).reduce((a, x) => ({ requests: a.requests + x.requests, fallbacks: a.fallbacks + x.fallbacks }), { requests: 0, fallbacks: 0 }));
  }, [key]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { void load(); }, [load]);

  if (!rows) return <div className="mb-6 flex justify-center py-6"><Spinner className="h-6 w-6" /></div>;
  if (rows.length < 1) return null;

  const ok = rows.filter((r) => r.summary);
  const sum = (f: (s: DailySummary) => number) => ok.reduce((a, r) => a + f(r.summary!), 0);
  const active = sum((s) => s.units.active);
  const occupied = sum((s) => s.units.occupied);

  // the platforms: one line per source across the branches, net of commission
  const bySource = new Map<string, { name: string; bp: number | null; net: number }>();
  for (const r of rows) for (const p of r.payouts ?? []) {
    const k = p.source_id;
    const cur = bySource.get(k) ?? { name: p.source_name ?? "—", bp: p.commission_bp ?? null, net: 0 };
    cur.net += netOfCommission(p);
    bySource.set(k, cur);
  }
  const platforms = [...bySource.values()].sort((a, b) => b.net - a.net);

  // the operations alerts, the urgent first; each opens its list in its branch
  const open = (branchId: string, to: string) => { setBranchId(branchId); navigate(to); };
  const alerts: Array<{ level: "danger" | "warn" | "ok"; text: string; branch?: string; to?: string }> = [];
  for (const r of rows) {
    if (!r.summary) { alerts.push({ level: "danger", text: `${r.name}: تعذّر قراءة ملخص اليوم` }); continue; }
    const s = r.summary;
    if (s.departures.overstay > 0) alerts.push({ level: "danger", text: `${r.name}: ${arabicCount(s.departures.overstay, ["إقامة واحدة تجاوزت", "إقامتان تجاوزتا", "إقامات تجاوزت", "إقامة تجاوزت"])} موعد المغادرة`, branch: r.id, to: "/staff/followups" });
    if (s.arrivals.overdue > 0) alerts.push({ level: "danger", text: `${r.name}: ${arabicCount(s.arrivals.overdue, ["وصول متأخر واحد", "وصولان متأخران", "وصولات متأخرة", "وصولًا متأخرًا"])} لم يُسجَّل`, branch: r.id, to: "/staff/arrivals" });
    if (s.arrivals.pending_identity > 0) alerts.push({ level: "warn", text: `${r.name}: ${arabicCount(s.arrivals.pending_identity, ["وصول واحد", "وصولان", "وصولات", "وصولًا"])} بانتظار مطابقة الهوية`, branch: r.id, to: "/staff/identity-verification" });
    if (s.units.dirty > 0) alerts.push({ level: "warn", text: `${r.name}: ${COUNT.unit(s.units.dirty)} تحتاج تنظيفًا`, branch: r.id, to: "/staff/housekeeping" });
    if (s.tickets_open > 0) alerts.push({ level: "warn", text: `${r.name}: ${arabicCount(s.tickets_open, ["بلاغ مفتوح", "بلاغان مفتوحان", "بلاغات مفتوحة", "بلاغًا مفتوحًا"])}`, branch: r.id, to: "/staff/tickets" });
    if (s.departures.overstay + s.arrivals.overdue + s.arrivals.pending_identity + s.units.dirty + s.tickets_open === 0) alerts.push({ level: "ok", text: `${r.name}: لا شيء ينتظر` });
  }
  const order = { danger: 0, warn: 1, ok: 2 } as const;
  alerts.sort((a, b) => order[a.level] - order[b.level]);
  const badge = { danger: ["bg-danger-500/10 text-danger-600", "عاجل"], warn: ["bg-warning-500/10 text-warning-700", "تنبيه"], ok: ["bg-success-500/10 text-success-600", "تم"] } as const;
  const urgentOf = (id: string) => alerts.filter((a) => a.branch === id && a.level !== "ok").length;

  return (
    <div className="mb-6 space-y-4" data-testid="owner-overview">
      <Card>
        <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-base font-semibold text-ink-800">{rows.length === 1 ? "الفرع اليوم" : "الفروع اليوم"}</h2>
          <div className="flex items-center gap-2 text-xs text-ink-500">
            {at && <span data-testid="overview-updated">آخر تحديث <span dir="ltr">{hhmm(at)}</span></span>}
            <button type="button" className="btn-ghost min-h-[44px] px-2" onClick={() => void load()} disabled={busy} aria-label="تحديث"><RefreshCw className={`h-4 w-4 ${busy ? "animate-spin" : ""}`} /></button>
          </div>
        </div>
        {/* OWNER-11: on a phone each branch is a card with the day's decision */}
        <ul className="space-y-3 sm:hidden" data-testid="branch-cards">
          {rows.map((r) => (
            <li key={r.id} className="rounded-xl border border-ink-100 p-3" data-testid="branch-card" data-branch={r.name}>
              <p className="mb-2 font-semibold text-ink-800">{r.name}</p>
              {r.summary ? (
                <dl className="grid grid-cols-2 gap-2 text-sm">
                  <div><dt className="text-[11px] text-ink-500">الإشغال</dt><dd className="font-bold tabular-nums">{pct1(r.summary.occupancy_pct)}</dd></div>
                  <div><dt className="text-[11px] text-ink-500">المحصّل اليوم</dt><dd className="font-bold tabular-nums" dir="ltr">{formatCurrency(collected(r.summary) / 100)}</dd></div>
                  <div><dt className="text-[11px] text-ink-500">متبقٍ وصولًا / مغادرةً</dt><dd className="tabular-nums">{r.summary.arrivals.expected} / {r.summary.departures.expected}</dd></div>
                  <div><dt className="text-[11px] text-ink-500">تنبيهات عاجلة</dt><dd className={`tabular-nums ${urgentOf(r.id) ? "font-bold text-danger-600" : ""}`}>{urgentOf(r.id)}</dd></div>
                </dl>
              ) : <p className="text-sm text-danger-600">{r.error ?? "تعذّر القراءة"}</p>}
            </li>
          ))}
        </ul>
        <div className="hidden overflow-x-auto sm:block">
          <table className="w-full min-w-[40rem] text-sm" data-testid="branches-today">
            <thead><tr className="border-b border-ink-100 bg-ink-50 text-xs text-ink-600">
              <th className="px-3 py-2 text-right font-semibold">الفرع</th>
              <th className="px-3 py-2 text-left font-semibold">الإشغال</th>
              <th className="px-3 py-2 text-left font-semibold">متبقٍ وصولًا / مغادرةً</th>
              <th className="px-3 py-2 text-left font-semibold">المحصّل اليوم</th>
              <th className="px-3 py-2 text-left font-semibold">آجل المنصات اليوم</th>
              <th className="px-3 py-2 text-left font-semibold">متبقٍ على المقيمين</th>
            </tr></thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id} className="border-b border-ink-50" data-testid="branch-row" data-branch={r.name}>
                  <td className="px-3 py-2">{r.name}</td>
                  {r.summary ? <>
                    <td className="px-3 py-2 text-left tabular-nums">{pct1(r.summary.occupancy_pct)}</td>
                    <td className="px-3 py-2 text-left tabular-nums">{r.summary.arrivals.expected} / {r.summary.departures.expected}</td>
                    <td className="px-3 py-2 text-left tabular-nums">{formatCurrency(collected(r.summary) / 100)}</td>
                    <td className="px-3 py-2 text-left tabular-nums">{formatCurrency((r.summary.finance?.platform_today ?? 0) / 100)}</td>
                    <td className="px-3 py-2 text-left tabular-nums">{formatCurrency((r.summary.finance?.outstanding_in_house ?? 0) / 100)}</td>
                  </> : <td colSpan={5} className="px-3 py-2 text-danger-600">{r.error ?? "تعذّر القراءة"}</td>}
                </tr>
              ))}
              {rows.length > 1 && (
                <tr className="bg-ink-50 font-semibold" data-testid="branches-total">
                  <td className="px-3 py-2">المجموع</td>
                  <td className="px-3 py-2 text-left tabular-nums">{pct1(active > 0 ? Math.round((occupied / active) * 1000) / 10 : 0)}</td>
                  <td className="px-3 py-2 text-left tabular-nums">{sum((s) => s.arrivals.expected)} / {sum((s) => s.departures.expected)}</td>
                  <td className="px-3 py-2 text-left tabular-nums">{formatCurrency(sum(collected) / 100)}</td>
                  <td className="px-3 py-2 text-left tabular-nums">{formatCurrency(sum((s) => s.finance?.platform_today ?? 0) / 100)}</td>
                  <td className="px-3 py-2 text-left tabular-nums">{formatCurrency(sum((s) => s.finance?.outstanding_in_house ?? 0) / 100)}</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
        {/* OWNER-04: each figure says what it counts */}
        <p className="mt-2 text-[11px] leading-relaxed text-ink-500" data-testid="overview-definitions">
          الإشغال: المشغولة ÷ الوحدات العاملة. متبقٍ: من لم يصل أو لم يغادر بعد من حجوزات اليوم. المحصّل اليوم: قبض الإقامة نقدًا أو شبكة أو تحويلًا − الاستردادات، بتاريخ السند؛ التأمين خارجه.
          آجل المنصات: ما سُجّل اليوم «آجل عبر المنصة».
        </p>
      </Card>
      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <h2 className="mb-2 text-base font-semibold text-ink-800">آجل عند المنصات (صافٍ بعد العمولة)</h2>
          {platforms.length === 0 ? <p className="text-sm text-ink-500">لا مبالغ آجلة عند المنصات.</p> : (
            <ul className="space-y-1.5 text-sm" data-testid="platforms-net">
              {platforms.map((p) => (
                <li key={p.name} className="flex justify-between gap-3">
                  {/* OWNER-18: a zero or missing commission is said, not hidden */}
                  <span>{p.name} · {p.bp ? `${bpToPercent(p.bp)}%` : <span className="text-warning-700">عمولة غير محددة</span>}</span>
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
              <li key={i} className="flex items-start gap-2"><Badge className={badge[a.level][0]}>{badge[a.level][1]}</Badge>
                {a.to && a.branch ? <button type="button" className="text-start text-brand-700 hover:underline" onClick={() => open(a.branch!, a.to!)}>{a.text}</button> : <span>{a.text}</span>}
              </li>
            ))}
          </ul>
        </Card>
      </div>
      {ai && (
        <p className="flex items-center gap-2 text-xs text-ink-500" data-testid="overview-ai">
          <Bot className="h-4 w-4" aria-hidden="true" /> المساعد اليوم (كل الفروع): {arabicCount(ai.requests, ["طلب واحد", "طلبان", "طلبات", "طلبًا"])}، منها بالمسار الثابت {ai.fallbacks}.
        </p>
      )}
    </div>
  );
}
