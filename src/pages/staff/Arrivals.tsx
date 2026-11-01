import { useReservations } from "../../lib/hooks";
import { ReservationCardRow } from "../../components/ReservationCard";
import { SectionTitle, EmptyState, LoadingScreen, LoadErrorCard } from "../../components/ui";
import { CalendarClock, AlertTriangle } from "lucide-react";
import { todayISO, COUNT } from "../../lib/utils";

/**
 * «وصول اليوم» (FRONT-06): today's arrivals, and above them the late ones — a confirmed or pending booking whose
 * arrival date has passed without an arrival or a no-show. They stay here until the desk handles them.
 */
export default function Arrivals() {
  const { data, loading, error, reload } = useReservations({ status: ["confirmed", "pending_verification"] });
  if (loading) return <LoadingScreen />;
  if (error && data.length === 0) return <LoadErrorCard message={error} onRetry={reload} />;
  const today = todayISO();
  const late = data.filter((r) => r.check_in < today).sort((a, b) => a.check_in.localeCompare(b.check_in));
  const todays = data.filter((r) => r.check_in === today);
  return (
    <div>
      {late.length > 0 && (
        <section className="mb-6" data-testid="late-arrivals">
          <SectionTitle level={2} title="متأخر" subtitle={`${COUNT.booking(late.length)} — موعد وصولها مضى ولم يُسجَّل وصول ولا عدم حضور`} />
          <p className="mb-3 flex items-center gap-2 rounded-xl bg-warning-500/10 p-3 text-sm text-warning-700"><AlertTriangle className="h-4 w-4 shrink-0" /> سجّل الوصول إن وصل النزيل، أو أعلن عدم الحضور من صفحة الحجز حتى تتحرر الوحدة.</p>
          <div className="space-y-3">{late.map((r) => <ReservationCardRow key={r.id} r={r} />)}</div>
        </section>
      )}
      <SectionTitle title="وصول اليوم" subtitle={COUNT.booking(todays.length)} />
      {todays.length === 0 ? (
        <EmptyState icon={<CalendarClock className="h-10 w-10" />} title="لا توجد وصولات اليوم" description="ستظهر الحجوزات الجديدة هنا تلقائيًا." />
      ) : (
        <div className="space-y-3">{todays.map((r) => <ReservationCardRow key={r.id} r={r} />)}</div>
      )}
    </div>
  );
}
