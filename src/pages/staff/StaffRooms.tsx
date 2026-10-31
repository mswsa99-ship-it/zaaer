import { useEffect, useMemo, useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { DoorClosed, KeyRound, Wrench, Sparkles, CalendarClock, CalendarRange, LayoutGrid, ChevronRight, ChevronLeft, BellRing } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { opsApi, listsApi, type UnitCard, type DailySummary, type ReservationCalendar, type CalendarSegment } from "../../lib/api";
import { SectionTitle, LoadingScreen, Card, EmptyState, Badge, LoadErrorCard, ErrorBanner, DataState } from "../../components/ui";
import { useBranchQuery } from "../../lib/useBranchQuery";
import { BranchPicker } from "../../components/BranchPicker";
import { ROOM_STATUS_LABELS, ROOM_STATUS_COLORS, CLEANLINESS_LABELS, CLEANLINESS_COLORS, RESERVATION_STATUS_LABELS, PAYMENT_STATUS_LABELS, type RoomStatus, type ReservationStatus } from "../../lib/types";
import { formatCurrency, formatDateTime, todayISO, addDaysISO, COUNT } from "../../lib/utils";

const NO_BOARD: { units: UnitCard[]; summary: DailySummary | null } = { units: [], summary: null };

/** Units board — one card per unit with the three independent dimensions (occupancy/ops status, cleanliness, entry
 *  readiness), filters by type and floor (decision 14, 10.2), and «تقويم الحجوزات»: the units against the days. */
export default function StaffRooms() {
  const [params, setParams] = useSearchParams();
  const view = params.get("view") === "calendar" ? "calendar" : "board";
  const setView = (v: "board" | "calendar") => { const p = new URLSearchParams(params); if (v === "calendar") p.set("view", "calendar"); else p.delete("view"); setParams(p, { replace: true }); };
  const [filter, setFilter] = useState<"all" | "free" | "occupied" | "ready" | "dirty" | "maintenance" | "arriving" | "departing" | "attention">("all");
  const [q, setQ] = useState("");
  const [category, setCategory] = useState("");
  const [floor, setFloor] = useState("");

  // G24: the board and its summary belong to the active branch only; a late answer for another branch is dropped
  const board = useBranchQuery(async (b) => { const [units, summary] = await Promise.all([opsApi.unitsBoard(b), opsApi.dailySummary(b)]); return { units, summary }; }, [], NO_BOARD);
  const { units, summary } = board.data;
  const { reload } = board;
  useEffect(() => {
    const ch = supabase.channel("units-board").on("postgres_changes", { event: "*", schema: "public", table: "rooms" }, () => reload()).on("postgres_changes", { event: "*", schema: "public", table: "reservations" }, () => reload()).on("postgres_changes", { event: "*", schema: "public", table: "housekeeping_tasks" }, () => reload()).subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [reload]);

  const today = todayISO();
  const categories = useMemo(() => [...new Set(units.map((u) => u.category).filter(Boolean))].sort(), [units]);
  const floors = useMemo(() => [...new Set(units.map((u) => (u.block ? `${u.block} / ${u.floor ?? "—"}` : u.floor ?? "")).filter(Boolean))].sort(), [units]);
  const floorOf = (u: UnitCard) => (u.block ? `${u.block} / ${u.floor ?? "—"}` : u.floor ?? "");
  const visible = useMemo(() => units.filter((u) => {
    if (q && !u.room_number.includes(q)) return false;
    if (category && u.category !== category) return false;
    if (floor && floorOf(u) !== floor) return false;
    switch (filter) {
      case "free": return !u.current && u.is_active && !["maintenance", "out_of_service", "blocked"].includes(u.status);
      case "occupied": return u.status === "occupied";
      case "ready": return u.status === "ready";
      case "maintenance": return u.status === "maintenance";
      case "dirty": return u.is_active && u.cleanliness !== "clean";
      case "arriving": return (u.current?.check_in === today && u.current.status !== "checked_in") || u.next?.check_in === today;
      case "departing": return u.current?.check_out === today && u.current.status === "checked_in";
      case "attention": return u.cleanliness !== "clean" || u.open_maintenance > 0 || (!!u.current && u.current.check_in <= today && u.current.status !== "checked_in") || (!!u.current && u.current.check_out < today);
      default: return true;
    }
  }), [units, filter, q, category, floor, today]);

  // U3 (approved 31 Oct): what needs doing now, first — late arrivals, overstays, a unit to clean or a code to change
  // before today's arrival; the cards then put the units needing attention before the others
  const urgency = (x: UnitCard) => {
    const arrivingToday = (x.current?.check_in === today && x.current.status !== "checked_in") || x.next?.check_in === today;
    if (x.current && x.current.check_in < today && x.current.status !== "checked_in") return 0;
    if (x.current && x.current.check_out < today && x.current.status === "checked_in") return 0;
    if (arrivingToday && x.is_active && (x.cleanliness !== "clean" || !x.keybox_ready)) return 0;
    if (x.is_active && (x.cleanliness !== "clean" || x.open_maintenance > 0)) return 1;
    return 2;
  };
  const ordered = useMemo(() => [...visible].sort((a, b) => urgency(a) - urgency(b) || a.room_number.localeCompare(b.room_number, "en", { numeric: true })),
    [visible, today]); // eslint-disable-line react-hooks/exhaustive-deps
  const now = useMemo(() => {
    const out: Array<{ key: string; text: string; to?: string }> = [];
    for (const x of units) {
      if (!x.is_active) continue;
      if (x.current && x.current.check_in < today && x.current.status !== "checked_in") out.push({ key: `late-${x.room_id}`, text: `${x.room_number}: وصول متأخر لم يُسجَّل`, to: `/staff/reservations/${x.current.reservation_id}` });
      else if (x.current && x.current.check_out < today && x.current.status === "checked_in") out.push({ key: `over-${x.room_id}`, text: `${x.room_number}: تجاوز موعد المغادرة`, to: `/staff/reservations/${x.current.reservation_id}` });
      const arrivingToday = (x.current?.check_in === today && x.current.status !== "checked_in") || x.next?.check_in === today;
      if (arrivingToday && x.cleanliness !== "clean") out.push({ key: `clean-${x.room_id}`, text: `${x.room_number}: تحتاج تنظيفًا قبل وصول اليوم`, to: "/staff/housekeeping" });
      if (arrivingToday && !x.keybox_ready) out.push({ key: `code-${x.room_id}`, text: `${x.room_number}: رمز الصندوق يحتاج تغييرًا قبل الوصول`, to: "/staff/codes" });
    }
    return out;
  }, [units, today]);

  if (board.loading) return <LoadingScreen />;
  if (board.error && units.length === 0) return <div><SectionTitle title="لوحة الوحدات" action={<BranchPicker />} /><LoadErrorCard message={board.error} onRetry={reload} /></div>;
  const u = summary?.units;
  const tabs = (
    <div className="flex gap-1 rounded-xl bg-ink-100 p-1 text-sm" role="tablist">
      <button role="tab" aria-selected={view === "board"} onClick={() => setView("board")} className={`flex items-center gap-1 rounded-lg px-3 py-1.5 ${view === "board" ? "bg-white font-medium text-ink-800 shadow-sm" : "text-ink-500"}`}><LayoutGrid className="h-4 w-4" /> اللوحة</button>
      <button role="tab" aria-selected={view === "calendar"} onClick={() => setView("calendar")} className={`flex items-center gap-1 rounded-lg px-3 py-1.5 ${view === "calendar" ? "bg-white font-medium text-ink-800 shadow-sm" : "text-ink-500"}`} data-testid="tab-calendar"><CalendarRange className="h-4 w-4" /> تقويم الحجوزات</button>
    </div>
  );
  return (
    <div>
      <SectionTitle title={view === "calendar" ? "تقويم الحجوزات" : "لوحة الوحدات"} subtitle={summary ? (view === "calendar" ? `الإشغال ${summary.occupancy_pct}% — مؤجرة ${u?.occupied} من ${u?.active} فعالة · جاهزة ${u?.ready} · تحتاج تنظيفًا ${u?.dirty} · صيانة ${u?.maintenance} · آخر تحديث ${formatDateTime(summary.generated_at)}` : `آخر تحديث ${formatDateTime(summary.generated_at)}`) : ""} action={<div className="flex flex-wrap items-center gap-2">{tabs}<BranchPicker /></div>} />
      {board.error && <div className="mb-4"><ErrorBanner message={board.error} /></div>}
      {view === "board" && now.length > 0 && (
        <section aria-label="ينتظرك الآن" className="mb-4 flex flex-wrap items-start justify-between gap-3 rounded-2xl border border-warning-500/30 bg-warning-50 px-4 py-3" data-testid="units-now">
          <div className="min-w-0">
            <p className="flex items-center gap-1.5 font-semibold text-warning-700"><BellRing className="h-4 w-4" aria-hidden="true" /> ينتظرك الآن</p>
            <ul className="mt-1 space-y-0.5 text-sm text-ink-800">
              {now.slice(0, 4).map((n) => <li key={n.key}>{n.to ? <Link to={n.to} className="hover:underline">{n.text}</Link> : n.text}</li>)}
            </ul>
            {now.length > 4 && <p className="mt-1 text-xs text-ink-500">و{now.length - 4 === 1 ? "أمر آخر" : `${now.length - 4} أمور أخرى`}</p>}
          </div>
          <button type="button" className="btn-primary text-sm" onClick={() => setFilter("attention")}>عرض ما يحتاج انتباهًا</button>
        </section>
      )}
      {view === "board" && summary && u && (
        // B12 (note 13): the occupancy strip — the figures in large type; a figure filters the units it counts
        <div className="mb-4 grid grid-cols-[repeat(auto-fit,minmax(8.5rem,1fr))] gap-3" data-testid="occupancy-strip">
          {([
            ["all", "الإشغال", `${summary.occupancy_pct}%`, `${u.occupied} من ${u.active} فعالة`, "text-ink-900"],
            ["occupied", "مؤجرة", String(u.occupied), "وحدة مشغولة الآن", "text-brand-700"],
            ["ready", "جاهزة", String(u.ready), "للتسليم الآن", "text-success-600"],
            ["dirty", "تحتاج تنظيفًا", String(u.dirty), "متسخة أو قيد التنظيف", "text-warning-700"],
            ["maintenance", "صيانة", String(u.maintenance), "خارج التشغيل مؤقتًا", "text-danger-600"],
          ] as const).map(([k, label, value, hint, tone], i) => (
            <button key={label} type="button" onClick={() => setFilter(k)} aria-pressed={filter === k}
              className={`flex min-h-[44px] flex-col items-start gap-1 rounded-2xl border bg-white p-3 text-right shadow-sm transition hover:border-brand-500 ${filter === k ? "border-brand-500 ring-2 ring-brand-100" : "border-ink-100"}`}
              data-testid={`strip-${i === 0 ? "occupancy" : k}`}>
              <span className="text-[13px] font-medium text-ink-500">{label}</span>
              <span className={`text-3xl font-bold leading-10 tabular-nums ${tone}`} dir="ltr">{value}</span>
              <span className="text-xs text-ink-500">{hint}</span>
            </button>
          ))}
        </div>
      )}
      <div className="mb-4 flex flex-wrap items-center gap-2">
        <input className="input w-32" placeholder="رقم الوحدة" value={q} onChange={(e) => setQ(e.target.value)} aria-label="رقم الوحدة" />
        <select className="input w-auto py-1.5 text-sm" value={category} onChange={(e) => setCategory(e.target.value)} aria-label="نوع الوحدة" data-testid="filter-category"><option value="">كل الأنواع</option>{categories.map((c) => <option key={c} value={c}>{c}</option>)}</select>
        <select className="input w-auto py-1.5 text-sm" value={floor} onChange={(e) => setFloor(e.target.value)} aria-label="الطابق" data-testid="filter-floor"><option value="">كل الطوابق</option>{floors.map((f) => <option key={f} value={f}>{f}</option>)}</select>
        {view === "board" && ([["all", "الكل"], ["free", "خالية"], ["occupied", "مؤجرة"], ["ready", "جاهزة"], ["arriving", "وصول اليوم"], ["departing", "مغادرة اليوم"], ["dirty", "تحتاج تنظيفًا"], ["maintenance", "صيانة"], ["attention", "تحتاج انتباهًا"]] as const).map(([k, v]) => (
          <button key={k} type="button" aria-pressed={filter === k} data-testid={`units-filter-${k}`} onClick={() => setFilter(k)} className={`rounded-lg px-3 py-1.5 text-xs font-medium ${filter === k ? "bg-brand-600 text-white" : "bg-ink-100 text-ink-600"}`}>{v}</button>
        ))}
      </div>
      {view === "calendar" ? <CalendarView roomFilter={(id) => visible.some((x) => x.room_id === id)} /> : visible.length === 0 ? <EmptyState icon={<DoorClosed className="h-10 w-10" />} title="لا وحدات مطابقة" /> : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
          {ordered.map((x) => {
            const late = x.current && x.current.check_in < today && x.current.status !== "checked_in";
            const over = x.current && x.current.check_out < today && x.current.status === "checked_in";
            return (
              <Card key={x.room_id} className={!x.is_active ? "opacity-60" : ""} data-testid="unit-card" data-room={x.room_number} data-urgency={urgency(x)}>
                <div className="flex items-start justify-between">
                  <div><p className="text-lg font-bold text-ink-800">{x.room_number}</p><p className="text-[11px] text-ink-400">{x.category}{x.block ? ` · ${x.block}` : ""}{x.floor ? ` / ${x.floor}` : ""}</p></div>
                  <Badge className={ROOM_STATUS_COLORS[x.status as RoomStatus] ?? "bg-ink-100"}>{ROOM_STATUS_LABELS[x.status as RoomStatus] ?? x.status}</Badge>
                </div>
                <div className="mt-2 flex flex-wrap gap-1.5">
                  <Badge className={CLEANLINESS_COLORS[x.cleanliness]}><Sparkles className="h-3 w-3" /> {CLEANLINESS_LABELS[x.cleanliness]}</Badge>
                  <Badge className={x.keybox_ready ? "bg-success-500/10 text-success-600" : "bg-ink-100 text-ink-500"}><KeyRound className="h-3 w-3" /> {x.keybox_ready ? "الرمز جاهز" : "الرمز يحتاج تدويرًا"}</Badge>
                  {x.open_maintenance > 0 && <Badge className="bg-danger-500/10 text-danger-600"><Wrench className="h-3 w-3" /> صيانة</Badge>}
                  {x.open_tasks > 0 && <Badge className="bg-warning-500/10 text-warning-700">{COUNT.task(x.open_tasks)}</Badge>}
                </div>
                {x.current ? (
                  <Link to={`/staff/reservations/${x.current.reservation_id}`} className="mt-3 block rounded-xl bg-ink-50 p-2.5 text-xs hover:bg-brand-50">
                    <div className="flex justify-between"><span className="font-mono font-medium text-ink-700">{x.current.internal_ref}</span><span className="text-ink-500">{RESERVATION_STATUS_LABELS[x.current.status as ReservationStatus] ?? x.current.status}</span></div>
                    <p className="mt-0.5 text-ink-600">{x.current.guest}</p>
                    <p className="text-ink-400" dir="ltr">{x.current.check_in} → {x.current.check_out}</p>
                    {x.current.balance_due > 0 && <p className="mt-0.5 font-medium text-warning-700">متبقٍ {formatCurrency(x.current.balance_due / 100)}</p>}
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

const SEG_COLORS: Record<string, string> = {
  confirmed: "bg-brand-500/80 text-white", pending_verification: "bg-warning-500/80 text-white", checked_in: "bg-success-500/85 text-white",
  checked_out: "bg-ink-400/70 text-white", closed: "bg-ink-300 text-ink-800", draft: "bg-ink-200 text-ink-700",
};
const WEEKDAYS = ["أحد", "اثنين", "ثلاثاء", "أربعاء", "خميس", "جمعة", "سبت"];
const dayDiff = (a: string, b: string) => Math.round((Date.parse(b + "T00:00:00Z") - Date.parse(a + "T00:00:00Z")) / 86400000);
const NO_CAL: ReservationCalendar | null = null;

/** «تقويم الحجوزات» (decision 14, 10.2): the units of the branch against the days — each stay a bar from arrival to departure. */
function CalendarView({ roomFilter }: { roomFilter: (roomId: string) => boolean }) {
  const [from, setFrom] = useState(() => addDaysISO(todayISO(), -2));
  const [span, setSpan] = useState<14 | 30>(14);
  const to = addDaysISO(from, span - 1);
  const cal = useBranchQuery<ReservationCalendar | null>((b) => listsApi.calendar(b, from, to), [from, to], NO_CAL);
  const data = cal.data;
  const days = useMemo(() => Array.from({ length: span }, (_, i) => addDaysISO(from, i)), [from, span]);
  const today = data?.today ?? todayISO();
  const byRoom = useMemo(() => { const m = new Map<string, CalendarSegment[]>(); for (const s of data?.segments ?? []) { if (!m.has(s.room_id)) m.set(s.room_id, []); m.get(s.room_id)!.push(s); } return m; }, [data]);
  const units = (data?.units ?? []).filter((u) => roomFilter(u.room_id));
  const colW = 40;
  return (
    <div data-testid="reservation-calendar">
      <div className="mb-3 flex flex-wrap items-center gap-2 text-sm">
        <button type="button" className="btn-ghost px-2 py-1" onClick={() => setFrom(addDaysISO(from, -span))} aria-label="الفترة السابقة"><ChevronRight className="h-4 w-4" /></button>
        <label className="flex items-center gap-1.5 text-xs text-ink-600">من <input type="date" className="input w-auto py-1 text-xs" dir="ltr" value={from} onChange={(e) => e.target.value && setFrom(e.target.value)} aria-label="بداية التقويم" /></label>
        <span className="text-xs text-ink-500" dir="ltr">→ {to}</span>
        <button type="button" className="btn-ghost px-2 py-1" onClick={() => setFrom(addDaysISO(from, span))} aria-label="الفترة التالية"><ChevronLeft className="h-4 w-4" /></button>
        <button type="button" className="btn-ghost py-1 text-xs" onClick={() => setFrom(addDaysISO(todayISO(), -2))}>اليوم</button>
        {([14, 30] as const).map((n) => <button key={n} type="button" onClick={() => setSpan(n)} className={`rounded-lg px-3 py-1 text-xs font-medium ${span === n ? "bg-brand-600 text-white" : "bg-ink-100 text-ink-600"}`}>{n} يومًا</button>)}
        <span className="mr-auto flex flex-wrap items-center gap-2 text-[11px] text-ink-500">
          {Object.entries({ confirmed: "مؤكد", pending_verification: "بانتظار التحقق", checked_in: "مقيم", checked_out: "غادر", closed: "مغلق" }).map(([k, v]) => <span key={k} className="flex items-center gap-1"><span className={`inline-block h-3 w-3 rounded ${SEG_COLORS[k]}`} /> {v}</span>)}
        </span>
      </div>
      <DataState loading={cal.loading} error={cal.error} empty={!!data && units.length === 0} onRetry={cal.reload} emptyIcon={<DoorClosed className="h-10 w-10" />} emptyTitle="لا وحدات مطابقة">
        <div className="card overflow-x-auto p-0">
          <div style={{ minWidth: 190 + span * colW }}>
            <div className="grid border-b border-ink-100 bg-ink-50 text-[11px] text-ink-500" style={{ gridTemplateColumns: `190px repeat(${span}, ${colW}px)` }}>
              <div className="sticky right-0 z-10 border-l border-ink-100 bg-ink-50 px-3 py-2 font-medium">الوحدة</div>
              {days.map((d) => { const dt = new Date(d + "T00:00:00Z"); const isToday = d === today; return <div key={d} className={`border-l border-ink-50 px-1 py-1 text-center ${isToday ? "bg-brand-50 font-semibold text-brand-700" : ""}`} data-today={isToday || undefined}><div>{WEEKDAYS[dt.getUTCDay()]}</div><div dir="ltr">{d.slice(5)}</div></div>; })}
            </div>
            {units.map((unit) => {
              const segs = byRoom.get(unit.room_id) ?? [];
              return (
                <div key={unit.room_id} className="grid border-b border-ink-50 text-xs" style={{ gridTemplateColumns: `190px repeat(${span}, ${colW}px)`, minHeight: 40 }} data-testid="calendar-row" data-room={unit.room_number}>
                  <div className="sticky right-0 z-10 flex items-center justify-between gap-2 border-l border-ink-100 bg-white px-3 py-1.5">
                    <div><span className="font-semibold text-ink-800">{unit.room_number}</span><span className="mr-1 text-[10px] text-ink-400">{unit.category}</span>{unit.floor && <div className="text-[10px] text-ink-400">{unit.block ? `${unit.block} / ` : ""}{unit.floor}</div>}</div>
                    <Badge className={`${CLEANLINESS_COLORS[unit.cleanliness] ?? "bg-ink-100"} px-1.5 py-0 text-[10px]`}>{CLEANLINESS_LABELS[unit.cleanliness] ?? unit.cleanliness}</Badge>
                  </div>
                  <div className="relative col-span-full col-start-2 grid" style={{ gridTemplateColumns: `repeat(${span}, ${colW}px)`, gridColumn: `2 / span ${span}` }}>
                    {days.map((d) => <div key={d} className={`border-l border-ink-50 ${d === today ? "bg-brand-50/60" : ""}`} style={{ gridRow: 1 }} />)}
                    {segs.map((s) => {
                      const start = Math.max(0, dayDiff(from, s.from_date)); const end = Math.min(span, dayDiff(from, s.to_date));
                      if (end <= start) return null;
                      const title = `${s.internal_ref} · ${s.guest ?? "—"} · ${RESERVATION_STATUS_LABELS[s.status as ReservationStatus] ?? s.status}${s.payment_status ? ` · ${PAYMENT_STATUS_LABELS[s.payment_status as keyof typeof PAYMENT_STATUS_LABELS] ?? s.payment_status}` : ""}${s.balance_due_halalas ? ` · متبقٍ ${formatCurrency(s.balance_due_halalas / 100)}` : ""}`;
                      return (
                        <Link key={s.reservation_id + s.from_date} to={`/staff/reservations/${s.reservation_id}`} title={title} data-testid="calendar-segment" data-ref={s.internal_ref}
                          className={`my-1.5 flex items-center gap-1 overflow-hidden whitespace-nowrap px-1.5 text-[11px] leading-7 ${SEG_COLORS[s.status] ?? "bg-ink-300"} ${s.starts_before ? "rounded-l-md" : "rounded-r-md"} ${s.ends_after ? "rounded-r-none" : "rounded-l-md"} ${s.starts_before ? "rounded-r-none" : ""}`}
                          style={{ gridColumn: `${start + 1} / ${end + 1}`, gridRow: 1 }}>
                          <span className="truncate">{s.guest ?? s.internal_ref}</span>
                          {s.balance_due_halalas ? <span className="text-[10px] opacity-90">· متبقٍ</span> : null}
                        </Link>
                      );
                    })}
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      </DataState>
      <p className="mt-2 text-[11px] text-ink-400">كل شريط إقامة من يوم الوصول إلى يوم المغادرة (ليلة المغادرة خالية). الملغاة وعدم الحضور لا تظهر. انقر الشريط لفتح الحجز.</p>
    </div>
  );
}
