import { supabase } from "../../lib/supabase";
import { SectionTitle, LoadingScreen, Card, EmptyState, ErrorBanner, LoadErrorCard } from "../../components/ui";
import { BranchPicker } from "../../components/BranchPicker";
import { DoorClosed, BedDouble, TrendingUp, BookCheck, Users, Wallet, LifeBuoy, SearchX, KeyRound, Store, Info } from "lucide-react";
import { Link } from "react-router-dom";
import { useBranchQuery } from "../../lib/useBranchQuery";
import { opsApi, type ReportsFinance, type DailySummary } from "../../lib/api";
import { BarChart, Bar, XAxis, YAxis, ResponsiveContainer, Tooltip } from "recharts";
import { addDaysISO, formatCurrency, todayISO, UI_LOCALE, COUNT } from "../../lib/utils";
import { ReviewBanner } from "../../components/ReviewBanner";
import { OwnerOverview } from "../../components/OwnerOverview";
import { HBars } from "../../components/HBars";
import { useAuth } from "../../lib/auth";
import { useReviewSummary } from "../../lib/reviewAlerts";

/**
 * The selected branch's figures (review of 31 October, Phase 4a). Every figure names what it counts:
 *  - OWNER-02: money taken at the property and money the platforms hold are two tiles, never one;
 *  - OWNER-03: both occupancy figures, each with its definition; one decimal everywhere;
 *  - OWNER-05: only this branch's tickets; what is the whole organisation's (the assistant's usage) is in the owner's view;
 *  - OWNER-06: pending payments of live bookings only, the cancelled and no-show ones said apart;
 *  - OWNER-14/15: the source mix of the same 7 days as the chart beside it, and one definition of today's arrivals.
 */
interface Stats {
  summary: DailySummary | null;
  /** the last 7 days from the voucher ledger (fn_reports_finance); null if the report is unavailable */
  finance: ReportsFinance | null;
  totalRooms: number;
  pendingPayments: number;
  pendingPaymentsDead: number;
  openHandoffs: number;
  unmatched: number;
  deliveryFailures: number;
  weekly: { day: string; bookings: number; net: number; platform: number }[];
}

// Operational columns only — money is never read from the reservations table (GAP05); it comes from the ledger RPC.
type ResRow = { id: string; status: string; check_in: string; payment_status: string };
const LIVE = ["confirmed", "pending_verification", "checked_in"];

/** Everything on the dashboard for one branch; any failed read is an error on screen, never a zero (U04). */
async function loadStats(branchId: string): Promise<Stats> {
  const today = todayISO();
  const hourAgo = new Date(Date.now() - 3600_000).toISOString();
  const [rooms, reservations, handoffs, unmatched, failures, summary, finance] = await Promise.all([
    supabase.from("rooms").select("id", { count: "exact", head: true }).eq("branch_id", branchId).is("archived_at", null),
    supabase.from("reservations").select("id, status, check_in, payment_status").eq("branch_id", branchId),
    supabase.from("human_handoff_tickets").select("id", { count: "exact", head: true }).eq("status", "open").eq("branch_id", branchId),
    supabase.from("human_handoff_tickets").select("id", { count: "exact", head: true }).eq("status", "open").eq("kind", "unmatched_reservation").eq("branch_id", branchId),
    supabase.from("access_delivery_events").select("id, reservation_id").eq("acknowledged", false).lt("created_at", hourAgo),
    opsApi.dailySummary(branchId).catch((): DailySummary | null => null),
    opsApi.reportsFinance(branchId, addDaysISO(today, -6), today).catch((): ReportsFinance | null => null),
  ]);
  for (const r of [rooms, reservations, handoffs, unmatched, failures]) if (r.error) throw new Error(r.error.message);
  const resList = ((reservations.data as unknown as ResRow[]) ?? []);
  const byDay = new Map((finance?.by_day ?? []).map((d) => [d.day, d]));
  const weekly: Stats["weekly"] = [];
  for (let i = 6; i >= 0; i--) {
    const ds = addDaysISO(today, -i);
    const d = byDay.get(ds);
    weekly.push({
      // OWNER-14: the weekday with its date («السبت 31»)
      day: `${new Date(ds + "T12:00:00Z").toLocaleDateString(UI_LOCALE, { weekday: "short", timeZone: "UTC" })} ${Number(ds.slice(8))}`,
      bookings: resList.filter((r) => r.check_in === ds).length,
      net: d ? (d.receipts - d.refunds) / 100 : 0,
      platform: d ? (d.platform ?? 0) / 100 : 0,
    });
  }
  const pending = resList.filter((r) => r.payment_status === "pending");
  const mine = new Set(resList.map((r) => r.id));   // OWNER-05: this branch's code deliveries only
  return {
    summary, finance,
    totalRooms: rooms.count ?? 0,
    pendingPayments: pending.filter((r) => LIVE.includes(r.status)).length,
    pendingPaymentsDead: pending.filter((r) => ["cancelled", "no_show", "rejected"].includes(r.status)).length,
    openHandoffs: handoffs.count ?? 0,
    unmatched: unmatched.count ?? 0,
    deliveryFailures: ((failures.data as { reservation_id: string }[]) ?? []).filter((e) => mine.has(e.reservation_id)).length,
    weekly,
  };
}

const pct1 = (n: number | null | undefined) => (n == null ? "—" : `${Number(n).toFixed(1)}%`);

export default function AdminDashboard() {
  // G24 (decision 40): the active branch's figures only — a slow answer for the previous branch is dropped
  const q = useBranchQuery<Stats | null>(loadStats, [], null);
  const stats = q.data;
  const review = useReviewSummary(true);
  const { profile } = useAuth();   // the owner: what waits for review, and the monitors when due (decision 54)

  const header = <SectionTitle title="لوحة الإدارة" subtitle="مؤشرات الأداء التشغيلي" action={<BranchPicker />} />;
  if (q.loading) return <LoadingScreen />;
  if (!stats) return (
    <div>
      {header}
      {q.error
        ? <LoadErrorCard message={q.error} onRetry={q.reload} />
        : <EmptyState icon={<DoorClosed className="h-10 w-10" />} title="لا يوجد فرع مصرّح لك" description="لوحة التحكم تعرض بيانات فرع واحد؛ اطلب من المالك إضافتك إلى فرع." />}
    </div>
  );

  const s = stats.summary, L = stats.finance?.ledger;
  const money = (h: number | null | undefined) => (h == null ? "—" : formatCurrency(h / 100));
  const kpis: Array<{ label: string; value: string | number; icon: typeof DoorClosed; color: string; note?: string; to?: string; testId?: string }> = [
    { label: "الوحدات", value: stats.totalRooms, icon: DoorClosed, color: "bg-brand-50 text-brand-600", note: s ? `${s.units.active} عاملة · ${s.units.occupied} مشغولة · ${s.units.ready} جاهزة` : undefined },
    // OWNER-03: both figures, each with its definition
    { label: "الإشغال (الوحدات العاملة)", value: pct1(s?.occupancy_pct), icon: TrendingUp, color: "bg-accent-500/10 text-accent-600", note: "المشغولة ÷ الوحدات العاملة (بلا الموقوفة)", testId: "kpi-occupancy" },
    { label: "الإشغال (كل الوحدات)", value: pct1(s?.occupancy_all_pct), icon: BedDouble, color: "bg-ink-100 text-ink-600", note: "المشغولة ÷ كل الوحدات غير المؤرشفة", testId: "kpi-occupancy-all" },
    // OWNER-15: the same definition as the owner's table — still to arrive today
    { label: "متبقٍ وصولًا اليوم", value: s ? s.arrivals.expected : "—", icon: BookCheck, color: "bg-brand-50 text-brand-600", note: s ? `وصل ${s.arrivals.arrived} · متأخر ${s.arrivals.overdue}` : undefined, to: "/staff/arrivals" },
    // OWNER-02: what was taken at the property and what the platforms hold, apart
    { label: "المحصّل في المنشأة (7 أيام)", value: money(L?.net_collected), icon: Wallet, color: "bg-success-500/10 text-success-600", note: "نقد وشبكة وتحويل − الاستردادات، بتاريخ السند", testId: "kpi-collected" },
    { label: "آجل عند المنصات (7 أيام)", value: money(L?.platform_net), icon: Store, color: "bg-warning-500/10 text-warning-700", note: "سُجّل «آجل عبر المنصة»؛ يُطابق عند التحويل", to: "/admin/platform-payouts", testId: "kpi-platform" },
    // OWNER-06: live bookings only; the cancelled and no-show ones said apart
    { label: "طلبات دفع معلّقة", value: stats.pendingPayments, icon: Wallet, color: "bg-warning-500/10 text-warning-700", note: stats.pendingPaymentsDead ? `على حجوزات قائمة؛ و${COUNT.booking(stats.pendingPaymentsDead)} ملغاة أو لم تحضر خارجها` : "على حجوزات قائمة", to: "/admin/reservations", testId: "kpi-pending-payments" },
    { label: "إقامات آخر 7 أيام", value: stats.finance ? stats.finance.reservations.count : "—", icon: Users, color: "bg-ink-100 text-ink-600", note: stats.finance ? COUNT.night(stats.finance.reservations.nights) : undefined },
    { label: "تذاكر تحويل لمشرف (مفتوحة)", value: stats.openHandoffs, icon: LifeBuoy, color: stats.openHandoffs > 0 ? "bg-danger-500/10 text-danger-600" : "bg-ink-100 text-ink-600", to: "/staff/tickets" },
    { label: "حجوزات غير مطابقة", value: stats.unmatched, icon: SearchX, color: stats.unmatched > 0 ? "bg-warning-500/10 text-warning-700" : "bg-ink-100 text-ink-600" },
    { label: "تسليم رمز بلا تأكيد (> ساعة)", value: stats.deliveryFailures, icon: KeyRound, color: stats.deliveryFailures > 0 ? "bg-warning-500/10 text-warning-700" : "bg-ink-100 text-ink-600" },
  ];
  const sources = (stats.finance?.reservations.by_source ?? []).map((x) => ({ key: x.source_id ?? x.source, label: x.source, value: x.count, display: COUNT.booking(x.count) }));
  const anyPlatform = stats.weekly.some((d) => d.platform);

  return (
    <div>
      {header}
      <ReviewBanner summary={review} />
      {q.error && <div className="mb-4"><ErrorBanner message={q.error} /></div>}
      {/* U3: the owner's view across the branches, then the active branch's figures below */}
      {profile?.role === "owner" && <OwnerOverview />}
      <h2 className="mb-3 text-base font-semibold text-ink-800">مؤشرات الفرع المختار</h2>
      <div className="mb-8 grid grid-cols-2 gap-3 lg:grid-cols-4">
        {kpis.map((k) => {
          const body = <>
            <div className={`flex h-9 w-9 items-center justify-center rounded-lg ${k.color}`}><k.icon className="h-5 w-5" /></div>
            <p className="min-w-0 break-words text-xl font-bold tabular-nums text-ink-800" dir={typeof k.value === "string" && /\d/.test(k.value) ? "ltr" : undefined}>{k.value}</p>
            <p className="text-xs text-ink-500">{k.label}</p>
            {k.note && <p className="flex items-start gap-1 text-[11px] leading-relaxed text-ink-400"><Info className="mt-0.5 h-3 w-3 shrink-0" aria-hidden="true" /> {k.note}</p>}
          </>;
          return k.to
            ? <Link key={k.label} to={k.to} className="card flex min-w-0 flex-col gap-1.5 p-4 transition hover:border-brand-200" data-testid={k.testId}>{body}</Link>
            : <Card key={k.label} className="flex min-w-0 flex-col gap-1.5" data-testid={k.testId}>{body}</Card>;
        })}
      </div>

      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <h3 className="mb-1 text-sm font-semibold text-ink-700">آخر 7 أيام</h3>
          <p className="mb-3 text-[11px] text-ink-400">الحجوزات حسب يوم الوصول، والمحصّل في المنشأة (قبض − استرداد) حسب تاريخ السند{anyPlatform ? "، وما سُجّل آجلًا عبر المنصات" : ""}.</p>
          <p className="mb-1 text-xs font-medium text-ink-500">حجوزات (عدد)</p>
          <ResponsiveContainer width="100%" height={120}>
            <BarChart data={stats.weekly}>
              <XAxis dataKey="day" tick={{ fontSize: 11, fill: "#6f83a3" }} interval="preserveStartEnd" minTickGap={6} />
              <YAxis tick={{ fontSize: 11, fill: "#6f83a3" }} allowDecimals={false} orientation="right" tickMargin={6} width={36} />
              <Tooltip contentStyle={{ borderRadius: 12, border: "1px solid #e9edf3", fontSize: 12 }} />
              <Bar dataKey="bookings" fill="#1f5f74" radius={[4, 4, 0, 0]} name="حجوزات" />
            </BarChart>
          </ResponsiveContainer>
          <p className="mb-1 mt-3 text-xs font-medium text-ink-500">المحصّل في المنشأة (ر.س)</p>
          {!stats.finance ? <p className="py-6 text-center text-sm text-ink-400">تقرير التحصيل غير متاح.</p> : (
            <ResponsiveContainer width="100%" height={120}>
              <BarChart data={stats.weekly}>
                <XAxis dataKey="day" tick={{ fontSize: 11, fill: "#6f83a3" }} interval="preserveStartEnd" minTickGap={6} />
                <YAxis tick={{ fontSize: 11, fill: "#6f83a3" }} orientation="right" tickMargin={6} width={56} />
                <Tooltip contentStyle={{ borderRadius: 12, border: "1px solid #e9edf3", fontSize: 12 }} />
                <Bar dataKey="net" fill="#2bb3a3" radius={[4, 4, 0, 0]} name="في المنشأة (ر.س)" />
                {anyPlatform && <Bar dataKey="platform" fill="#d98a1b" radius={[4, 4, 0, 0]} name="عند المنصات (ر.س)" />}
              </BarChart>
            </ResponsiveContainer>
          )}
        </Card>
        <Card>
          <h3 className="mb-1 text-sm font-semibold text-ink-700">الحجوزات حسب المصدر</h3>
          <p className="mb-3 text-[11px] text-ink-400">إقامات آخر 7 أيام (المتقاطعة مع الفترة)، بأي حالة.</p>
          <HBars rows={sources} empty="لا حجوزات في آخر 7 أيام." testId="dashboard-sources" />
        </Card>
      </div>
    </div>
  );
}
