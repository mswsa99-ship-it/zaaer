import { useCallback, useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { DoorClosed, KeyRound, Wrench, Sparkles, CalendarClock } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useBranch } from "../../lib/branch";
import { opsApi, toArabicError, type UnitCard, type DailySummary } from "../../lib/api";
import { SectionTitle, LoadingScreen, Card, EmptyState, Badge, ErrorBanner } from "../../components/ui";
import { BranchPicker } from "../../components/BranchPicker";
import { ROOM_STATUS_LABELS, ROOM_STATUS_COLORS, CLEANLINESS_LABELS, CLEANLINESS_COLORS, RESERVATION_STATUS_LABELS, type RoomStatus, type ReservationStatus } from "../../lib/types";
import { formatCurrency, formatDateTime } from "../../lib/utils";

/** Units board — one card per unit with the three independent dimensions: occupancy/ops status, cleanliness, entry readiness. */
export default function StaffRooms() {
  const { branchId } = useBranch();
  const [units, setUnits] = useState<UnitCard[]>([]); const [summary, setSummary] = useState<DailySummary | null>(null);
  const [loading, setLoading] = useState(true); const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<"all" | "free" | "occupied" | "dirty" | "arriving" | "departing" | "attention">("all");
  const [q, setQ] = useState("");

  const load = useCallback(async () => {
    if (!branchId) return;
    try { const [u, s] = await Promise.all([opsApi.unitsBoard(branchId), opsApi.dailySummary(branchId)]); setUnits(u); setSummary(s); setError(null); } catch (e) { setError(toArabicError(e)); } finally { setLoading(false); }
  }, [branchId]);
  useEffect(() => { load(); }, [load]);
  useEffect(() => {
    const ch = supabase.channel("units-board").on("postgres_changes", { event: "*", schema: "public", table: "rooms" }, () => load()).on("postgres_changes", { event: "*", schema: "public", table: "reservations" }, () => load()).on("postgres_changes", { event: "*", schema: "public", table: "housekeeping_tasks" }, () => load()).subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [load]);

  const today = new Date().toISOString().slice(0, 10);
  const visible = useMemo(() => units.filter((u) => {
    if (q && !u.room_number.includes(q)) return false;
    switch (filter) {
      case "free": return !u.current && u.is_active && !["maintenance", "out_of_service", "blocked"].includes(u.status);
      case "occupied": return u.status === "occupied";
      case "dirty": return u.cleanliness !== "clean";
      case "arriving": return (u.current?.check_in === today && u.current.status !== "checked_in") || u.next?.check_in === today;
      case "departing": return u.current?.check_out === today && u.current.status === "checked_in";
      case "attention": return u.cleanliness !== "clean" || u.open_maintenance > 0 || (!!u.current && u.current.check_in <= today && u.current.status !== "checked_in") || (!!u.current && u.current.check_out < today);
      default: return true;
    }
  }), [units, filter, q, today]);

  if (loading) return <LoadingScreen />;
  const u = summary?.units;
  return (
    <div>
      <SectionTitle title="لوحة الوحدات" subtitle={summary ? `الإشغال ${summary.occupancy_pct}% — ${u?.occupied} مؤجرة من ${u?.active} فعالة · ${u?.ready} جاهزة · ${u?.dirty} تحتاج تنظيفًا · ${u?.maintenance} صيانة · آخر تحديث ${formatDateTime(summary.generated_at)}` : ""} action={<BranchPicker />} />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      <div className="mb-4 flex flex-wrap items-center gap-2">
        <input className="input w-32" placeholder="رقم الوحدة" value={q} onChange={(e) => setQ(e.target.value)} />
        {([["all", "الكل"], ["free", "خالية"], ["occupied", "مؤجرة"], ["arriving", "وصول اليوم"], ["departing", "مغادرة اليوم"], ["dirty", "تحتاج تنظيفًا"], ["attention", "تحتاج انتباهًا"]] as const).map(([k, v]) => (
          <button key={k} onClick={() => setFilter(k)} className={`rounded-lg px-3 py-1.5 text-xs font-medium ${filter === k ? "bg-brand-600 text-white" : "bg-ink-100 text-ink-600"}`}>{v}</button>
        ))}
      </div>
      {visible.length === 0 ? <EmptyState icon={<DoorClosed className="h-10 w-10" />} title="لا وحدات مطابقة" /> : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
          {visible.map((x) => {
            const late = x.current && x.current.check_in < today && x.current.status !== "checked_in";
            const over = x.current && x.current.check_out < today && x.current.status === "checked_in";
            return (
              <Card key={x.room_id} className={!x.is_active ? "opacity-60" : ""}>
                <div className="flex items-start justify-between">
                  <div><p className="text-lg font-bold text-ink-800">{x.room_number}</p><p className="text-[11px] text-ink-400">{x.category}{x.block ? ` · ${x.block}` : ""}{x.floor ? ` / ${x.floor}` : ""}</p></div>
                  <Badge className={ROOM_STATUS_COLORS[x.status as RoomStatus] ?? "bg-ink-100"}>{ROOM_STATUS_LABELS[x.status as RoomStatus] ?? x.status}</Badge>
                </div>
                <div className="mt-2 flex flex-wrap gap-1.5">
                  <Badge className={CLEANLINESS_COLORS[x.cleanliness]}><Sparkles className="h-3 w-3" /> {CLEANLINESS_LABELS[x.cleanliness]}</Badge>
                  <Badge className={x.keybox_ready ? "bg-success-500/10 text-success-600" : "bg-ink-100 text-ink-500"}><KeyRound className="h-3 w-3" /> {x.keybox_ready ? "الرمز جاهز" : "الرمز يحتاج تدويرًا"}</Badge>
                  {x.open_maintenance > 0 && <Badge className="bg-danger-500/10 text-danger-600"><Wrench className="h-3 w-3" /> صيانة</Badge>}
                  {x.open_tasks > 0 && <Badge className="bg-warning-500/10 text-warning-600">{x.open_tasks} مهمة</Badge>}
                </div>
                {x.current ? (
                  <Link to={`/staff/reservations/${x.current.reservation_id}`} className="mt-3 block rounded-xl bg-ink-50 p-2.5 text-xs hover:bg-brand-50">
                    <div className="flex justify-between"><span className="font-mono font-medium text-ink-700">{x.current.internal_ref}</span><span className="text-ink-500">{RESERVATION_STATUS_LABELS[x.current.status as ReservationStatus] ?? x.current.status}</span></div>
                    <p className="mt-0.5 text-ink-600">{x.current.guest}</p>
                    <p className="text-ink-400" dir="ltr">{x.current.check_in} → {x.current.check_out}</p>
                    {x.current.balance_due > 0 && <p className="mt-0.5 font-medium text-warning-600">متبقٍ {formatCurrency(x.current.balance_due / 100)}</p>}
                    {late && <p className="mt-0.5 font-medium text-danger-600">وصول متأخر لم يُسجَّل</p>}
                    {over && <p className="mt-0.5 font-medium text-danger-600">تجاوز موعد المغادرة</p>}
                  </Link>
                ) : <p className="mt-3 rounded-xl bg-ink-50 p-2.5 text-xs text-ink-400">خالية الآن{x.next ? "" : " · لا وصول قادم"}</p>}
                {x.next && <p className="mt-2 flex items-center gap-1 text-[11px] text-ink-400"><CalendarClock className="h-3 w-3" /> القادم: {x.next.internal_ref} في <span dir="ltr">{x.next.check_in}</span></p>}
              </Card>
            );
          })}
        </div>
      )}
    </div>
  );
}
