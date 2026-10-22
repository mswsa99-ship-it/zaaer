import { useReservations } from "../../lib/hooks";
import { ReservationCardRow } from "../../components/ReservationCard";
import { SectionTitle, EmptyState, LoadingScreen } from "../../components/ui";
import { CreditCard } from "lucide-react";

export default function StaffPayments() {
  const { data, loading } = useReservations();
  if (loading) return <LoadingScreen />;
  const pending = data.filter((r) => r.payment_status === "pending" || r.payment_status === "processing" || r.payment_status === "failed");
  return (
    <div>
      <SectionTitle title="المدفوعات" subtitle={`${pending.length} بانتظار المراجعة`} />
      {pending.length === 0 ? (
        <EmptyState icon={<CreditCard className="h-10 w-10" />} title="لا توجد مدفوعات معلّقة" />
      ) : (
        <div className="space-y-3">{pending.map((r) => <ReservationCardRow key={r.id} r={r} />)}</div>
      )}
    </div>
  );
}
