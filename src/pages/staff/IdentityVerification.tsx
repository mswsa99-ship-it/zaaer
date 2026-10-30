import { useEffect, useState } from "react";
import { useReservations } from "../../lib/hooks";
import { supabase } from "../../lib/supabase";
import { ReservationCardRow } from "../../components/ReservationCard";
import { SectionTitle, EmptyState, LoadingScreen, LoadErrorCard } from "../../components/ui";
import { ListFilterBar, pick, sinceHours, useListFilter } from "../../components/WindowedList";
import { UserCheck } from "lucide-react";

const WINDOW_HOURS = 24;
const ACTIVE = ["pending_verification", "confirmed", "checked_in"];

/** «مطابقة الهويات» (B8, the owner's note 9): what waits for matching, always; what was matched in the last 24 hours on demand. */
export default function IdentityVerification() {
  const { data, loading, error, reload } = useReservations();
  const [filter, setFilter] = useListFilter();
  const [recent, setRecent] = useState<Set<string>>(new Set());
  const [windowError, setWindowError] = useState(false);
  useEffect(() => {
    let live = true;
    supabase.from("reservation_guests").select("reservation_id, verified_at").gte("verified_at", sinceHours(WINDOW_HOURS))
      .then(({ data: rows, error: e }) => { if (!live) return; setWindowError(!!e); setRecent(new Set(((rows ?? []) as Array<{ reservation_id: string }>).map((x) => x.reservation_id)));
      });
    return () => { live = false; };
  }, [data]);
  if (loading) return <LoadingScreen />;
  if (error && data.length === 0) return <LoadErrorCard message={error} onRetry={reload} />;
  const open = data.filter((r) => ACTIVE.includes(r.status) && (r.identity_status === "data_submitted" || r.identity_status === "pending_supervisor"));
  const done = data.filter((r) => r.identity_status === "verified" && recent.has(r.id));
  const shown = pick(filter, open, done);
  return (
    <div>
      <SectionTitle title="مطابقة الهويات" subtitle={`بانتظار المطابقة: ${open.length}`} />
      <ListFilterBar value={filter} onChange={setFilter} openLabel="غير المطابَق" doneLabel="طُوبق" openCount={open.length} doneCount={done.length} windowHours={WINDOW_HOURS} />
      {windowError && filter !== "open" && <p className="mb-3 text-sm text-warning-700">تعذّر تحميل ما طُوبق في آخر 24 ساعة؛ أعد تحميل الصفحة.</p>}
      {shown.length === 0 ? (
        <EmptyState icon={<UserCheck className="h-10 w-10" />} title={filter === "done" ? "لم تُطابَق هوية في آخر 24 ساعة" : "لا توجد هويات بانتظار المطابقة"} />
      ) : (
        <div className="space-y-3">{shown.map((r) => <ReservationCardRow key={r.id} r={r} />)}</div>
      )}
    </div>
  );
}
