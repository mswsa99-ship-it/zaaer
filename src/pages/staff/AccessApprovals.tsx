import { useReservations } from "../../lib/hooks";
import { ReservationCardRow } from "../../components/ReservationCard";
import { SectionTitle, EmptyState, LoadingScreen } from "../../components/ui";
import { KeyRound } from "lucide-react";

export default function AccessApprovals() {
  const { data, loading } = useReservations();
  if (loading) return <LoadingScreen />;
  const ready = data.filter((r) =>
    r.identity_status === "verified" &&
    (r.payment_status === "paid" || r.payment_status === "partially_paid") &&
    (r.access_status === "locked" || r.access_status === "approved" || r.access_status === "delivery_pending" || r.access_status === "delivered")
  );
  return (
    <div>
      <SectionTitle title="اعتماد الدخول وتسليم الرمز" subtitle={`${ready.length} حجز`} />
      {ready.length === 0 ? (
        <EmptyState icon={<KeyRound className="h-10 w-10" />} title="لا توجد طلبات اعتماد حالية" />
      ) : (
        <div className="space-y-3">{ready.map((r) => <ReservationCardRow key={r.id} r={r} />)}</div>
      )}
    </div>
  );
}
