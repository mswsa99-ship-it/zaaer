import { useReservations } from "../../lib/hooks";
import { ReservationCardRow } from "../../components/ReservationCard";
import { SectionTitle, EmptyState, LoadingScreen, LoadErrorCard } from "../../components/ui";
import { UserCheck } from "lucide-react";

export default function IdentityVerification() {
  const { data, loading, error, reload } = useReservations();
  if (loading) return <LoadingScreen />;
  if (error && data.length === 0) return <LoadErrorCard message={error} onRetry={reload} />;
  const pending = data.filter((r) => r.identity_status === "data_submitted" || r.identity_status === "pending_supervisor");
  return (
    <div>
      <SectionTitle title="مطابقة الهويات" subtitle={`${pending.length} بانتظار المراجعة`} />
      {pending.length === 0 ? (
        <EmptyState icon={<UserCheck className="h-10 w-10" />} title="لا توجد هويات بانتظار المطابقة" />
      ) : (
        <div className="space-y-3">{pending.map((r) => <ReservationCardRow key={r.id} r={r} />)}</div>
      )}
    </div>
  );
}
