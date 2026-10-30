import { useEffect, useState } from "react";
import { useReservations } from "../../lib/hooks";
import { supabase } from "../../lib/supabase";
import { ReservationCardRow } from "../../components/ReservationCard";
import { SectionTitle, EmptyState, LoadingScreen, LoadErrorCard } from "../../components/ui";
import { ListFilterBar, sinceHours, useListFilter } from "../../components/WindowedList";
import { KeyRound, LogIn, CheckCircle2 } from "lucide-react";
import { todayISO } from "../../lib/utils";

/**
 * «الوصول وتسليم الرمز» (0033): the stays that can arrive today — identity matched — and the guests in house whose
 * key-box code is still to be delivered. The arrival and the code are two steps, both on the stay's page.
 * B10 (the owner's note 11): it opens on what is not done; the arrivals handled in the last 24 hours (in, with the code
 * or the key handed) show under «تمت معالجته».
 */
const WINDOW_HOURS = 24;
export default function AccessApprovals() {
  const { data, loading, error, reload } = useReservations();
  const [filter, setFilter] = useListFilter();
  // the codes delivered in the window, by the box's own delivery time (a guest may be in for a day before the code)
  const [delivered, setDelivered] = useState<Set<string>>(new Set());
  useEffect(() => {
    let live = true;
    supabase.from("keyboxes").select("last_reservation_id, last_delivered_at").gte("last_delivered_at", sinceHours(WINDOW_HOURS))
      .then(({ data: rows }) => { if (live) setDelivered(new Set(((rows ?? []) as Array<{ last_reservation_id: string | null }>).map((x) => x.last_reservation_id).filter((x): x is string => !!x))); });
    return () => { live = false; };
  }, [data]);
  if (loading) return <LoadingScreen />;
  if (error && data.length === 0) return <LoadErrorCard message={error} onRetry={reload} />;
  const today = todayISO();
  const arriving = data.filter((r) => ["confirmed", "pending_verification"].includes(r.status) && r.check_in <= today && r.check_out > today && r.identity_status === "verified");
  const awaitingCode = data.filter((r) => r.status === "checked_in" && (r.access_status === "approved" || r.access_status === "delivery_pending"));
  const since = sinceHours(WINDOW_HOURS);
  const recent = (iso: string | null | undefined) => !!iso && Date.parse(iso) >= Date.parse(since);
  // handled: in with the code delivered (by the box's delivery time) or the key handed at reception (by the arrival);
  // a guest who has since left still counts within the window
  const handled = data.filter((r) => ["checked_in", "checked_out", "closed"].includes(r.status) && ["delivered", "acknowledged", "key_handed"].includes(r.access_status)
    && (delivered.has(r.id) || recent(r.actual_check_in)));
  const showOpen = filter !== "done"; const showDone = filter !== "open";
  return (
    <div>
      <SectionTitle title="الوصول وتسليم الرمز" subtitle={`${arriving.length} بانتظار تسجيل الوصول · ${awaitingCode.length} بانتظار تسليم الرمز`} />
      <ListFilterBar value={filter} onChange={setFilter} openLabel="غير المعالَج" doneLabel="تمت معالجته" openCount={arriving.length + awaitingCode.length} doneCount={handled.length} windowHours={WINDOW_HOURS} />
      {showOpen && <>
      <h2 className="mb-2 flex items-center gap-2 text-sm font-semibold text-ink-700"><LogIn className="h-4 w-4 text-brand-600" /> بانتظار تسجيل الوصول</h2>
      {arriving.length === 0 ? <EmptyState icon={<LogIn className="h-10 w-10" />} title="لا وصول ينتظر التسجيل" description="تظهر هنا حجوزات اليوم بعد مطابقة الهوية؛ يُسجَّل الوصول من صفحة الحجز." />
        : <div className="space-y-3">{arriving.map((r) => <ReservationCardRow key={r.id} r={r} />)}</div>}
      <h2 className="mb-2 mt-8 flex items-center gap-2 text-sm font-semibold text-ink-700"><KeyRound className="h-4 w-4 text-brand-600" /> مقيمون بانتظار تسليم الرمز</h2>
      {awaitingCode.length === 0 ? <EmptyState icon={<KeyRound className="h-10 w-10" />} title="لا رموز تنتظر التسليم" />
        : <div className="space-y-3">{awaitingCode.map((r) => <ReservationCardRow key={r.id} r={r} />)}</div>}
      </>}
      {showDone && <>
      <h2 className={`mb-2 flex items-center gap-2 text-sm font-semibold text-ink-700 ${showOpen ? "mt-8" : ""}`}><CheckCircle2 className="h-4 w-4 text-success-600" /> تمت معالجته في آخر 24 ساعة</h2>
      {handled.length === 0 ? <EmptyState icon={<CheckCircle2 className="h-10 w-10" />} title="لم يُعالَج وصول في آخر 24 ساعة" />
        : <div className="space-y-3">{handled.map((r) => <ReservationCardRow key={r.id} r={r} />)}</div>}
      </>}
    </div>
  );
}
