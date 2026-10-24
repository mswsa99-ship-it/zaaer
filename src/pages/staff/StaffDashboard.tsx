import { useReservations } from "../../lib/hooks";
import { ReservationCardRow } from "../../components/ReservationCard";
import { SectionTitle, LoadingScreen, EmptyState, LoadErrorCard, ErrorBanner } from "../../components/ui";
import { CalendarClock, UserCheck, CreditCard, KeyRound, BookCheck } from "lucide-react";
import { Link } from "react-router-dom";
import { DailyBriefing } from "../../components/DailyBriefing";
import { BranchPicker } from "../../components/BranchPicker";
import { useBranchQuery } from "../../lib/useBranchQuery";
import { opsApi, type DailySummary } from "../../lib/api";
import { formatCurrency } from "../../lib/utils";

export default function StaffDashboard() {
  const { data: arrivals, loading: l1, error: e1, reload: r1 } = useReservations({ todayOnly: true });
  const { data: all, loading: l2, error: e2, reload: r2 } = useReservations();
  // G24 (decision 40): the active branch's summary only; it refreshes when the reservation count changes
  const sumQ = useBranchQuery<DailySummary | null>((branchId) => opsApi.dailySummary(branchId), [all.length], null);
  const sum = sumQ.data;

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
  const readyForApproval = all.filter((r) => r.identity_status === "verified" && r.payment_status === "paid" && r.access_status === "locked");
  const delivered = all.filter((r) => r.access_status === "delivered" || r.access_status === "acknowledged");

  const stats = [
    { label: "وصول اليوم", value: arrivals.length, icon: CalendarClock, to: "/staff/arrivals", color: "bg-brand-50 text-brand-600" },
    { label: "بانتظار المطابقة", value: pendingIdentity.length, icon: UserCheck, to: "/staff/identity-verification", color: "bg-warning-500/10 text-warning-600" },
    { label: "بانتظار الدفع", value: pendingPayment.length, icon: CreditCard, to: "/staff/payments", color: "bg-danger-500/10 text-danger-600" },
    { label: "جاهز لاعتماد الدخول", value: readyForApproval.length, icon: KeyRound, to: "/staff/access-approvals", color: "bg-accent-500/10 text-accent-600" },
    { label: "تم تسليم الرمز", value: delivered.length, icon: KeyRound, to: "/staff/access-approvals", color: "bg-success-500/10 text-success-600" },
    { label: "إجمالي الحجوزات", value: all.length, icon: BookCheck, to: "/staff/reservations", color: "bg-ink-100 text-ink-600" },
  ];

  return (
    <div>
      <SectionTitle title="مركز عمليات الاستقبال" subtitle="نظرة سريعة على حالات اليوم" action={<BranchPicker />} />
      {listError && <div className="mb-4"><ErrorBanner message={listError} /></div>}

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

      <SectionTitle title="وصول اليوم" subtitle={`${arrivals.length} حجز`} />
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
          <SectionTitle title="جاهز لاعتماد الدخول" subtitle={`${readyForApproval.length} حجز بانتظار الاعتماد`} action={<Link to="/staff/access-approvals" className="text-sm text-brand-600">عرض الكل</Link>} />
          <div className="space-y-3">
            {readyForApproval.slice(0, 5).map((r) => <ReservationCardRow key={r.id} r={r} />)}
          </div>
        </>
      )}
    </div>
  );
}
