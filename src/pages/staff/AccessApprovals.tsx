import { useReservations } from "../../lib/hooks";
import { ReservationCardRow } from "../../components/ReservationCard";
import { SectionTitle, EmptyState, LoadingScreen, LoadErrorCard } from "../../components/ui";
import { KeyRound, LogIn } from "lucide-react";
import { todayISO } from "../../lib/utils";

/**
 * «الوصول وتسليم الرمز» (0033): the stays that can arrive today — identity matched — and the guests in house whose
 * key-box code is still to be delivered. The arrival and the code are two steps, both on the stay's page.
 */
export default function AccessApprovals() {
  const { data, loading, error, reload } = useReservations();
  if (loading) return <LoadingScreen />;
  if (error && data.length === 0) return <LoadErrorCard message={error} onRetry={reload} />;
  const today = todayISO();
  const arriving = data.filter((r) => ["confirmed", "pending_verification"].includes(r.status) && r.check_in <= today && r.check_out > today && r.identity_status === "verified");
  const awaitingCode = data.filter((r) => r.status === "checked_in" && (r.access_status === "approved" || r.access_status === "delivery_pending"));
  return (
    <div>
      <SectionTitle title="الوصول وتسليم الرمز" subtitle={`${arriving.length} بانتظار تسجيل الوصول · ${awaitingCode.length} بانتظار تسليم الرمز`} />
      <h2 className="mb-2 flex items-center gap-2 text-sm font-semibold text-ink-700"><LogIn className="h-4 w-4 text-brand-600" /> بانتظار تسجيل الوصول</h2>
      {arriving.length === 0 ? <EmptyState icon={<LogIn className="h-10 w-10" />} title="لا وصول ينتظر التسجيل" description="تظهر هنا حجوزات اليوم بعد مطابقة الهوية؛ يُسجَّل الوصول من صفحة الحجز." />
        : <div className="space-y-3">{arriving.map((r) => <ReservationCardRow key={r.id} r={r} />)}</div>}
      <h2 className="mb-2 mt-8 flex items-center gap-2 text-sm font-semibold text-ink-700"><KeyRound className="h-4 w-4 text-brand-600" /> مقيمون بانتظار تسليم الرمز</h2>
      {awaitingCode.length === 0 ? <EmptyState icon={<KeyRound className="h-10 w-10" />} title="لا رموز تنتظر التسليم" />
        : <div className="space-y-3">{awaitingCode.map((r) => <ReservationCardRow key={r.id} r={r} />)}</div>}
    </div>
  );
}
