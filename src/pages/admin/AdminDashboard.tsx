import { supabase } from "../../lib/supabase";
import { SectionTitle, LoadingScreen, Card, EmptyState, ErrorBanner, LoadErrorCard } from "../../components/ui";
import { BranchPicker } from "../../components/BranchPicker";
import { DoorClosed, BedDouble, TrendingUp, BookCheck, Users, Wallet, LifeBuoy, SearchX, KeyRound, Bot } from "lucide-react";
import { useBranchQuery } from "../../lib/useBranchQuery";
import { opsApi, type ReportsFinance } from "../../lib/api";
import { BarChart, Bar, XAxis, YAxis, ResponsiveContainer, Tooltip, PieChart, Pie, Cell } from "recharts";
import { addDaysISO, formatCurrency, todayISO, UI_LOCALE } from "../../lib/utils";
import { ReviewBanner } from "../../components/ReviewBanner";
import { useReviewSummary } from "../../lib/reviewAlerts";

interface Stats {
  totalRooms: number;
  occupied: number;
  available: number;
  reserved: number;
  maintenance: number;
  outOfService: number;
  arrivalsToday: number;
  departuresToday: number;
  pendingApprovals: number;
  pendingPayments: number;
  occupancyRate: number;
  /** Net collected over the last 7 days from the voucher ledger (fn_reports_finance); null if the report is unavailable. */
  netCollected7Halalas: number | null;
  openHandoffs: number;
  unmatched: number;
  deliveryFailures: number;
  aiToday: { requests: number; tokens: number; fallbacks: number; blocks: number } | null;
  totalReservations: number;
  bySource: { name: string; count: number }[];
  weekly: { day: string; bookings: number; net: number }[];
}

// Operational columns only — money is never read from the reservations table (GAP05); it comes from the ledger RPC.
type ResRow = { id: string; status: string; check_in: string; check_out: string; payment_status: string; access_status: string; identity_status: string; source?: { name: string } | { name: string }[] | null };

/** Everything on the dashboard for one branch; any failed read is an error on screen, never a zero (U04). */
async function loadStats(branchId: string): Promise<Stats> {
  const today = todayISO();
  const usageDay = new Date().toISOString().slice(0, 10);   // AI usage is counted per UTC day (edge functions)
  const hourAgo = new Date(Date.now() - 3600_000).toISOString();
  const [rooms, reservations, handoffs, unmatched, failures, aiUsage, finance] = await Promise.all([
    supabase.from("rooms").select("status").eq("branch_id", branchId),
    supabase.from("reservations").select("id, status, check_in, check_out, payment_status, access_status, identity_status, source:booking_sources(name)").eq("branch_id", branchId),
    supabase.from("human_handoff_tickets").select("id", { count: "exact", head: true }).eq("status", "open").or(`branch_id.eq.${branchId},branch_id.is.null`),
    supabase.from("human_handoff_tickets").select("id", { count: "exact", head: true }).eq("status", "open").eq("kind", "unmatched_reservation"),
    supabase.from("access_delivery_events").select("id", { count: "exact", head: true }).eq("acknowledged", false).lt("created_at", hourAgo),
    supabase.from("ai_usage_daily").select("requests, tokens_in, tokens_out, fallbacks, guardrail_blocks").eq("day", usageDay).maybeSingle(),
    opsApi.reportsFinance(branchId, addDaysISO(today, -6), today).catch((): ReportsFinance | null => null),
  ]);
  for (const r of [rooms, reservations, handoffs, unmatched, failures, aiUsage]) if (r.error) throw new Error(r.error.message);
  const ai = aiUsage.data as { requests: number; tokens_in: number; tokens_out: number; fallbacks: number; guardrail_blocks: number } | null;

  const roomList = (rooms.data as { status: string }[]) ?? [];
  const resList = ((reservations.data as unknown as ResRow[]) ?? []);
  const resFlat = resList.map((r) => ({ ...r, source: Array.isArray(r.source) ? r.source[0] : r.source }));
  const bySourceMap = new Map<string, number>();
  resFlat.forEach((r) => { const n = r.source?.name ?? "غير محدد"; bySourceMap.set(n, (bySourceMap.get(n) ?? 0) + 1); });

  const netByDay = new Map((finance?.by_day ?? []).map((d) => [d.day, d.receipts - d.refunds]));
  const weekly: { day: string; bookings: number; net: number }[] = [];
  for (let i = 6; i >= 0; i--) {
    const ds = addDaysISO(today, -i);
    weekly.push({
      day: new Date(ds + "T12:00:00Z").toLocaleDateString(UI_LOCALE, { weekday: "short", timeZone: "UTC" }),
      bookings: resFlat.filter((r) => r.check_in === ds).length,
      net: (netByDay.get(ds) ?? 0) / 100,
    });
  }

  return {
    totalRooms: roomList.length,
    occupied: roomList.filter((r) => r.status === "occupied").length,
    available: roomList.filter((r) => r.status === "available" || r.status === "ready").length,
    reserved: roomList.filter((r) => r.status === "reserved").length,
    maintenance: roomList.filter((r) => r.status === "maintenance").length,
    outOfService: roomList.filter((r) => r.status === "out_of_service" || r.status === "blocked").length,
    arrivalsToday: resFlat.filter((r) => r.check_in === today).length,
    departuresToday: resFlat.filter((r) => r.check_out === today).length,
    pendingApprovals: resFlat.filter((r) => r.access_status === "locked" && r.identity_status === "verified").length,
    pendingPayments: resFlat.filter((r) => r.payment_status === "pending").length,
    occupancyRate: roomList.length > 0 ? Math.round((roomList.filter((r) => r.status === "occupied").length / roomList.length) * 100) : 0,
    netCollected7Halalas: finance ? finance.ledger.net_collected : null,
    openHandoffs: handoffs.count ?? 0,
    unmatched: unmatched.count ?? 0,
    deliveryFailures: failures.count ?? 0,
    aiToday: ai ? { requests: ai.requests, tokens: Number(ai.tokens_in) + Number(ai.tokens_out), fallbacks: ai.fallbacks, blocks: ai.guardrail_blocks } : null,
    totalReservations: resFlat.length,
    bySource: Array.from(bySourceMap.entries()).map(([name, count]) => ({ name, count })),
    weekly,
  };
}

export default function AdminDashboard() {
  // G24 (decision 40): the active branch's figures only — a slow answer for the previous branch is dropped
  const q = useBranchQuery<Stats | null>(loadStats, [], null);
  const stats = q.data;
  const review = useReviewSummary(true);   // the owner: what waits for review, and the monitors when due (decision 54)

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

  const kpis = [
    { label: "إجمالي الغرف", value: stats.totalRooms, icon: DoorClosed, color: "bg-brand-50 text-brand-600" },
    { label: "المشغولة", value: stats.occupied, icon: BedDouble, color: "bg-ink-100 text-ink-600" },
    { label: "المتاحة", value: stats.available, icon: DoorClosed, color: "bg-success-500/10 text-success-600" },
    { label: "نسبة الإشغال", value: `${stats.occupancyRate}%`, icon: TrendingUp, color: "bg-accent-500/10 text-accent-600" },
    { label: "وصول اليوم", value: stats.arrivalsToday, icon: BookCheck, color: "bg-brand-50 text-brand-600" },
    { label: "إجمالي الحجوزات", value: stats.totalReservations, icon: Users, color: "bg-ink-100 text-ink-600" },
    { label: "صافي التحصيل (7 أيام، من دفتر السندات)", value: stats.netCollected7Halalas == null ? "—" : formatCurrency(stats.netCollected7Halalas / 100), icon: Wallet, color: "bg-success-500/10 text-success-600" },
    { label: "طلبات دفع معلّقة", value: stats.pendingPayments, icon: Wallet, color: "bg-warning-500/10 text-warning-600" },
    { label: "تذاكر تحويل لمشرف (مفتوحة)", value: stats.openHandoffs, icon: LifeBuoy, color: stats.openHandoffs > 0 ? "bg-danger-500/10 text-danger-600" : "bg-ink-100 text-ink-600" },
    { label: "حجوزات غير مطابقة", value: stats.unmatched, icon: SearchX, color: stats.unmatched > 0 ? "bg-warning-500/10 text-warning-600" : "bg-ink-100 text-ink-600" },
    { label: "تسليم رمز بلا تأكيد (> ساعة)", value: stats.deliveryFailures, icon: KeyRound, color: stats.deliveryFailures > 0 ? "bg-warning-500/10 text-warning-600" : "bg-ink-100 text-ink-600" },
    { label: "طلبات المساعد الذكي اليوم", value: stats.aiToday ? `${stats.aiToday.requests} (${stats.aiToday.tokens.toLocaleString("en")} توكن)` : "0", icon: Bot, color: "bg-brand-50 text-brand-600" },
  ];

  const pieColors = ["#1f5f74", "#2bb3a3", "#d98a1b", "#c0392b", "#33476a"];

  return (
    <div>
      {header}
      <ReviewBanner summary={review} />
      {q.error && <div className="mb-4"><ErrorBanner message={q.error} /></div>}
      <div className="mb-8 grid grid-cols-2 gap-3 lg:grid-cols-4">
        {kpis.map((k) => (
          <Card key={k.label} className="flex flex-col gap-2">
            <div className={`flex h-9 w-9 items-center justify-center rounded-lg ${k.color}`}><k.icon className="h-5 w-5" /></div>
            <p className="text-2xl font-bold text-ink-800">{k.value}</p>
            <p className="text-xs text-ink-400">{k.label}</p>
          </Card>
        ))}
      </div>

      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <h3 className="mb-1 text-sm font-semibold text-ink-700">آخر 7 أيام</h3>
          <p className="mb-3 text-[11px] text-ink-400">الحجوزات حسب يوم الوصول، وصافي التحصيل (قبض − استرداد) حسب تاريخ السند من دفتر السندات.</p>
          <p className="mb-1 text-xs font-medium text-ink-500">حجوزات (عدد)</p>
          <ResponsiveContainer width="100%" height={120}>
            <BarChart data={stats.weekly}>
              <XAxis dataKey="day" tick={{ fontSize: 11, fill: "#6f83a3" }} />
              <YAxis tick={{ fontSize: 11, fill: "#6f83a3" }} allowDecimals={false} />
              <Tooltip contentStyle={{ borderRadius: 12, border: "1px solid #e9edf3", fontSize: 12 }} />
              <Bar dataKey="bookings" fill="#1f5f74" radius={[4, 4, 0, 0]} name="حجوزات" />
            </BarChart>
          </ResponsiveContainer>
          <p className="mb-1 mt-3 text-xs font-medium text-ink-500">صافي التحصيل (ر.س)</p>
          {stats.netCollected7Halalas == null ? <p className="py-6 text-center text-sm text-ink-400">تقرير التحصيل غير متاح.</p> : (
            <ResponsiveContainer width="100%" height={120}>
              <BarChart data={stats.weekly}>
                <XAxis dataKey="day" tick={{ fontSize: 11, fill: "#6f83a3" }} />
                <YAxis tick={{ fontSize: 11, fill: "#6f83a3" }} />
                <Tooltip contentStyle={{ borderRadius: 12, border: "1px solid #e9edf3", fontSize: 12 }} />
                <Bar dataKey="net" fill="#2bb3a3" radius={[4, 4, 0, 0]} name="صافي التحصيل (ر.س)" />
              </BarChart>
            </ResponsiveContainer>
          )}
        </Card>
        <Card>
          <h3 className="mb-4 text-sm font-semibold text-ink-700">الحجوزات حسب المصدر</h3>
          {stats.bySource.length > 0 ? (
            <ResponsiveContainer width="100%" height={260}>
              <PieChart>
                <Pie data={stats.bySource} dataKey="count" nameKey="name" cx="50%" cy="50%" outerRadius={80} label={({ name, value }: { name: string; value: number }) => `${name}: ${value}`} labelLine={false} style={{ fontSize: 11 }}>
                  {stats.bySource.map((_, i) => <Cell key={i} fill={pieColors[i % pieColors.length]} />)}
                </Pie>
                <Tooltip contentStyle={{ borderRadius: 12, fontSize: 12 }} />
              </PieChart>
            </ResponsiveContainer>
          ) : <p className="text-sm text-ink-400">لا توجد بيانات.</p>}
        </Card>
      </div>
    </div>
  );
}
