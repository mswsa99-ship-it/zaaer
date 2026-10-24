import { useReservations } from "../../lib/hooks";
import { ReservationCardRow } from "../../components/ReservationCard";
import { SectionTitle, EmptyState, LoadingScreen, LoadErrorCard } from "../../components/ui";
import { CalendarClock } from "lucide-react";

export default function Arrivals() {
  const { data, loading, error, reload } = useReservations({ todayOnly: true });
  if (loading) return <LoadingScreen />;
  if (error && data.length === 0) return <LoadErrorCard message={error} onRetry={reload} />;
  return (
    <div>
      <SectionTitle title="وصول اليوم" subtitle={`${data.length} حجز`} />
      {data.length === 0 ? (
        <EmptyState icon={<CalendarClock className="h-10 w-10" />} title="لا توجد وصولات اليوم" description="ستظهر الحجوزات الجديدة هنا تلقائيًا." />
      ) : (
        <div className="space-y-3">{data.map((r) => <ReservationCardRow key={r.id} r={r} />)}</div>
      )}
    </div>
  );
}
