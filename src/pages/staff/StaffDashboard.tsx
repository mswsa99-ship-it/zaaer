import { COUNT } from "../../lib/utils";
import { useReservations } from "../../lib/hooks";
import { ReservationCardRow } from "../../components/ReservationCard";
import { SectionTitle, LoadingScreen, EmptyState, LoadErrorCard, ErrorBanner } from "../../components/ui";
import { CalendarClock, UserCheck, CreditCard, KeyRound, BookCheck, LogIn, BellRing } from "lucide-react";
import { Link } from "react-router-dom";
import { DailyBriefing } from "../../components/DailyBriefing";
import { BranchPicker } from "../../components/BranchPicker";
import { useBranchQuery } from "../../lib/useBranchQuery";
import { opsApi, stayApi, type DailySummary, type StayFollowups } from "../../lib/api";
import { formatCurrency, todayISO } from "../../lib/utils";
import { useAuth } from "../../lib/auth";
import { ReviewBanner } from "../../components/ReviewBanner";
import { useReviewSummary } from "../../lib/reviewAlerts";

export default function StaffDashboard() {
  const { data: arrivals, loading: l1, error: e1, reload: r1 } = useReservations({ todayOnly: true });
  const { data: all, loading: l2, error: e2, reload: r2 } = useReservations();
  // G24 (decision 40): the active branch's summary only; it refreshes when the reservation count changes
  const sumQ = useBranchQuery<DailySummary | null>((branchId) => opsApi.dailySummary(branchId), [all.length], null);
  const sum = sumQ.data;
  // 0033: what waits for a decision today (the money roles; the server refuses the others)
  const { permissions } = useAuth();
  const followRole = permissions.seesMoney;
  const fuQ = useBranchQuery<StayFollowups | null>((branchId) => (followRole ? stayApi.followups(branchId) : Promise.resolve(null)), [all.length, followRole], null);
  const fu = fuQ.data;
  const review = useReviewSummary(true);   // the owner: what waits for review, and the monitors when due (decision 54)

  if (l1 || l2) return <LoadingScreen />;
  const listError = e1 ?? e2;
  if (listError && all.length === 0 && arrivals.length === 0) {
    return (
      <div>
        <SectionTitle title="مركز عمليات الاستقبال" subtitle="نظرة سريعة على حالات اليوم" action={<BranchPicker />} />
        <LoadErrorCard message={listError} onRetry={() => { r1(); r2(); sumQ.reload(); }} />
      </div>
    );
  }

  const pendingIdentity = all.filter((r) => r.identity_status === "data_submitted" || r.identity_status === "pending_supervisor");
  const pendingPayment = all.filter((r) => r.payment_status === "pending");
  // ready to arrive: today's stay, identity matched, Shomoos accepted — the money and the unit are checked at the arrival itself
  const today = todayISO();
  const readyForApproval = all.filter((r) => ["confirmed", "pending_verification"].includes(r.status) && r.check_in <= today && r.check_out > today && r.identity_status === "verified" && !!r.shomoos_accepted_at);
  const delivered = all.filter((r) => r.status === "checked_in" && (r.access_status === "delivered" || r.access_status === "acknowledged" || r.access_status === "key_handed"));

  const stats = [
    { label: "وصول اليوم", value: arrivals.length, icon: CalendarClock, to: "/staff/arrivals", color: "bg-brand-50 text-brand-600" },
    { label: "بانتظار المطابقة", value: pendingIdentity.length, icon: UserCheck, to: "/staff/identity-verification", color: "bg-warning-500/10 text-warning-700" },
    { label: "بانتظار الدفع", value: pendingPayment.length, icon: CreditCard, to: "/staff/payments", color: "bg-danger-500/10 text-danger-600" },
    { label: "جاهز لتسجيل الوصول", value: readyForApproval.length, icon: LogIn, to: "/staff/access-approvals", color: "bg-accent-500/10 text-accent-600" },
    { label: "استلموا الرمز أو المفتاح", value: delivered.length, icon: KeyRound, to: "/staff/access-approvals", color: "bg-success-500/10 text-success-600" },
    { label: "إجمالي الحجوزات", value: all.length, icon: BookCheck, to: "/staff/reservations", color: "bg-ink-100 text-ink-600" },
  ];

  return (
    <div>
      <SectionTitle title="مركز عمليات الاستقبال" subtitle="نظرة سريعة على حالات اليوم" action={<BranchPicker />} />
      <ReviewBanner summary={review} />
      {listError && <div className="mb-4"><ErrorBanner message={listError} /></div>}
      {fu && fu.overdue.length + fu.departed_open.length + fu.late_departures.length > 0 && (
        <Link to="/staff/followups" className="mb-4 flex flex-wrap items-center gap-x-4 gap-y-1 rounded-xl border border-warning-500/30 bg-warning-500/10 px-4 py-3 text-sm text-warning-700 hover:shadow-sm" data-testid="followups-banner">
          <span className="flex items-center gap-2 font-medium"><BellRing className="h-4 w-4" /> متابعة الإقامات</span>
          {fu.overdue.length > 0 && <span>{fu.overdue.length} بليلة غير مدفوعة بعد موعدها</span>}
          {fu.departed_open.length > 0 && <span>{fu.departed_open.length} غادر ولم يُغلق</span>}
          {fu.late_departures.length > 0 && <span>{fu.late_departures.length} تجاوز موعد المغادرة</span>}
        </Link>
      )}

      <div className="mb-6 grid gap-4 lg:grid-cols-3">
        <div className="lg:col-span-2"><DailyBriefing /></div>
        <div className="grid grid-cols-2 gap-3 content-start">
          {!sum && sumQ.error && <div className="col-span-2"><LoadErrorCard message={sumQ.error} onRetry={sumQ.reload} /></div>}
          {sum && [
            { l: "الإشغال", v: `${sum.occupancy_pct}%`, to: "/staff/rooms" },
            { l: "جاهزة للدخول", v: sum.units.ready, to: "/staff/rooms" },
            { l: "تحتاج تنظيفًا", v: sum.units.dirty, to: "/staff/housekeeping" },
            { l: "مغادرة اليوم", v: `${sum.departures.done}/${sum.departures.expected}`, to: "/staff/reservations" },
            { l: "متبقٍ على المقيمين", v: formatCurrency(sum.finance.outstanding_in_house / 100), to: "/staff/reservations" },
            { l: "تأمينات محتجزة", v: formatCurrency(sum.finance.deposits_held / 100), to: "/admin/finance" },
          ].map((t) => <Link key={t.l} to={t.to} className="card p-3 hover:shadow-md"><p className="text-lg font-bold text-ink-800" dir="ltr">{t.v}</p><p className="text-[11px] text-ink-400">{t.l}</p></Link>)}
        </div>
      </div>

      <div className="mb-8 grid grid-cols-2 gap-3 lg:grid-cols-6">
        {stats.map((s) => (
          <Link key={s.label} to={s.to} className="card flex flex-col gap-2 p-4 transition-all hover:shadow-md">
            <div className={`flex h-9 w-9 items-center justify-center rounded-lg ${s.color}`}>
              <s.icon className="h-5 w-5" />
            </div>
            <p className="text-2xl font-bold text-ink-800">{s.value}</p>
            <p className="text-xs text-ink-400">{s.label}</p>
          </Link>
        ))}
      </div>

      <SectionTitle level={2} title="وصول اليوم" subtitle={COUNT.booking(arrivals.length)} />
      {arrivals.length === 0 ? (
        <EmptyState icon={<CalendarClock className="h-10 w-10" />} title="لا توجد وصولات اليوم" />
      ) : (
        <div className="space-y-3">
          {arrivals.map((r) => <ReservationCardRow key={r.id} r={r} />)}
        </div>
      )}

      {readyForApproval.length > 0 && (
        <>
          <div className="mt-8" />
          <SectionTitle level={2} title="جاهز لتسجيل الوصول" subtitle={`اكتملت هويته وشموس: ${readyForApproval.length}`} action={<Link to="/staff/access-approvals" className="text-sm text-brand-600">عرض الكل</Link>} />
          <div className="space-y-3">
            {readyForApproval.slice(0, 5).map((r) => <ReservationCardRow key={r.id} r={r} />)}
          </div>
        </>
      )}
    </div>
  );
}
