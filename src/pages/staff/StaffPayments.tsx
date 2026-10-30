import { useEffect, useState } from "react";
import { useReservations } from "../../lib/hooks";
import { supabase } from "../../lib/supabase";
import { ReservationCardRow } from "../../components/ReservationCard";
import { SectionTitle, EmptyState, LoadingScreen, LoadErrorCard } from "../../components/ui";
import { ListFilterBar, pick, sinceHours, useListFilter } from "../../components/WindowedList";
import { CreditCard } from "lucide-react";

const WINDOW_HOURS = 48;
const LIVE = ["pending_verification", "confirmed", "checked_in", "checked_out"];
const OWING = ["pending", "processing", "failed", "partially_paid"];

/**
 * «المدفوعات» (B9, the owner's note 10): a stay not paid or paid in part stays listed however old it is; a stay paid
 * in full shows under «سُدِّد» for 48 hours after the receipt that settled it (not after any later change to the stay).
 */
export default function StaffPayments() {
  const { data, loading, error, reload } = useReservations();
  const [filter, setFilter] = useListFilter();
  // the stays with an approved receipt in the window (financial_vouchers is readable by the roles that see money)
  const [paidRecently, setPaidRecently] = useState<Set<string>>(new Set());
  const [windowError, setWindowError] = useState(false);
  useEffect(() => {
    let live = true;
    supabase.from("financial_vouchers").select("reservation_id, occurred_at").eq("status", "approved").in("kind", ["receipt", "deposit_apply"]).gte("occurred_at", sinceHours(WINDOW_HOURS))
      .then(({ data: rows, error: e }) => { if (!live) return; setWindowError(!!e); setPaidRecently(new Set(((rows ?? []) as Array<{ reservation_id: string }>).map((x) => x.reservation_id))); });
    return () => { live = false; };
  }, [data]);
  if (loading) return <LoadingScreen />;
  if (error && data.length === 0) return <LoadErrorCard message={error} onRetry={reload} />;
  const open = data.filter((r) => LIVE.includes(r.status) && OWING.includes(r.payment_status));
  const done = data.filter((r) => LIVE.includes(r.status) && r.payment_status === "paid" && paidRecently.has(r.id));
  const shown = pick(filter, open, done);
  return (
    <div>
      <SectionTitle title="المدفوعات" subtitle={`${open.length} غير مسدَّد أو مسدَّد جزئيًا`} />
      <ListFilterBar value={filter} onChange={setFilter} openLabel="غير المسدَّد" doneLabel="سُدِّد" openCount={open.length} doneCount={done.length} windowHours={WINDOW_HOURS} />
      {windowError && filter !== "open" && <p className="mb-3 text-sm text-warning-600">تعذّر تحميل ما سُدِّد في آخر 48 ساعة؛ أعد تحميل الصفحة.</p>}
      {shown.length === 0 ? (
        <EmptyState icon={<CreditCard className="h-10 w-10" />} title={filter === "done" ? "لم يُسدَّد حجز في آخر 48 ساعة" : "لا توجد مدفوعات معلّقة"} />
      ) : (
        <div className="space-y-3">{shown.map((r) => <ReservationCardRow key={r.id} r={r} />)}</div>
      )}
    </div>
  );
}
