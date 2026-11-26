import { useEffect, useRef, useState } from "react";
import { CalendarDays, ChevronLeft, ChevronRight } from "lucide-react";
import { confirmPick, describeRange, inPick, monthCells, tapDay, type Pick } from "../lib/dateRange";
import { todayISO } from "../lib/utils";

const MONTHS = ["يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو", "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"];
const WEEK = ["س", "ح", "ن", "ث", "ر", "خ", "ج"]; // Saturday first

/**
 * One control for a day or a period (owner request, 25 Nov). Tap one day and «موافق» = that day only; tap a second
 * day and «موافق» = the whole period from the first to the second, both included. `single` keeps the one-day
 * meaning for screens whose data is one business day. The shown value is always left-to-right ISO digits, so the
 * order of the dates never flips on a right-to-left page.
 */
export function DateRangePicker({ from, to, onChange, min, max, single = false, clearable = false, label, className }: {
  from: string; to: string; onChange: (from: string, to: string) => void; min?: string; max?: string; single?: boolean; clearable?: boolean; label: string; className?: string;
}) {
  const [open, setOpen] = useState(false);
  const [pick, setPick] = useState<Pick>({ a: from || null, b: !from || from === to ? null : to });
  const start = from || todayISO();
  const [view, setView] = useState({ y: Number(start.slice(0, 4)), m: Number(start.slice(5, 7)) - 1 });
  const [fresh, setFresh] = useState(true); // the first tap after opening always starts a new selection
  const btn = useRef<HTMLButtonElement>(null);
  const dlg = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") { setOpen(false); btn.current?.focus(); } };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);
  // keyboard and screen reader: opening moves focus into the dialog (the chosen day, else today, else the first day you may pick)
  useEffect(() => {
    if (!open) return;
    const root = dlg.current; if (!root) return;
    (root.querySelector<HTMLElement>('[data-day][aria-pressed="true"]:not([disabled])') ?? root.querySelector<HTMLElement>(`[data-day="${todayISO()}"]:not([disabled])`) ?? root.querySelector<HTMLElement>("[data-day]:not([disabled])"))?.focus();
  }, [open]);
  const openIt = () => { setPick({ a: from || null, b: !from || from === to ? null : to }); setView({ y: Number(start.slice(0, 4)), m: Number(start.slice(5, 7)) - 1 }); setFresh(true); setOpen(true); };
  const move = (d: number) => setView((v) => { const t = v.y * 12 + v.m + d; return { y: Math.floor(t / 12), m: t % 12 }; });
  const disabled = (d: string) => (!!min && d < min) || (!!max && d > max);
  const confirmed = confirmPick(pick);
  const done = () => { if (!confirmed) return; onChange(confirmed.from, confirmed.to); setOpen(false); btn.current?.focus(); };
  return (
    <div className={"relative " + (className ?? "")} data-testid="date-range-picker">
      <button ref={btn} type="button" className="input flex items-center justify-between gap-2 text-start" aria-haspopup="dialog" aria-expanded={open} aria-label={label} onClick={openIt}>
        <CalendarDays className="h-4 w-4 shrink-0 text-rai-ink-muted" />
        <bdi dir="ltr" className="tabular-nums sm:whitespace-nowrap" data-testid="date-range-value">{from ? (from === to ? from : <><span className="whitespace-nowrap">{from}</span> → <span className="whitespace-nowrap">{to}</span></>) : "كل التواريخ"}</bdi>
      </button>
      {open && (
        <>
          <button type="button" tabIndex={-1} aria-hidden="true" className="fixed inset-0 z-40 cursor-default" onClick={() => setOpen(false)} />
          <div ref={dlg} role="dialog" aria-label={label} className="fixed inset-x-3 bottom-3 z-50 rounded-2xl border border-rai-line bg-rai-surface p-3 shadow-lg sm:absolute sm:inset-x-auto sm:bottom-auto sm:start-0 sm:top-full sm:mt-1 sm:w-80">
            <div className="mb-2 flex items-center justify-between">
              <button type="button" className="btn-ghost min-h-[44px] min-w-[44px] px-2" aria-label="الشهر السابق" onClick={() => move(-1)}><ChevronRight className="h-5 w-5" /></button>
              <span className="text-sm font-semibold text-rai-ink">{MONTHS[view.m]} <bdi dir="ltr">{view.y}</bdi></span>
              <button type="button" className="btn-ghost min-h-[44px] min-w-[44px] px-2" aria-label="الشهر التالي" onClick={() => move(1)}><ChevronLeft className="h-5 w-5" /></button>
            </div>
            <div className="grid grid-cols-7 gap-1 text-center text-xs text-rai-ink-muted">{WEEK.map((w) => <span key={w} className="py-1">{w}</span>)}</div>
            <div className="grid grid-cols-7 gap-1" role="grid">
              {monthCells(view.y, view.m).map((d, i) => d === null ? <span key={"e" + i} /> : (
                <button key={d} type="button" disabled={disabled(d)} data-day={d} aria-pressed={inPick(pick, d)} aria-label={d}
                  onClick={() => { setPick(fresh ? { a: d, b: null } : tapDay(pick, d, single)); setFresh(false); }}
                  className={`min-h-[44px] rounded-xl text-sm tabular-nums ${inPick(pick, d) ? "bg-rai-action font-semibold text-rai-action-ink ring-1 ring-rai-line-strong" : "text-rai-ink hover:bg-rai-surface-sunken"} ${d === todayISO() && !inPick(pick, d) ? "ring-1 ring-rai-line-strong" : ""} disabled:cursor-not-allowed disabled:border-transparent disabled:bg-transparent disabled:text-rai-ink-muted disabled:line-through disabled:opacity-40 disabled:ring-0 disabled:hover:bg-transparent`}>{Number(d.slice(8))}</button>
              ))}
            </div>
            <p className="mt-2 text-center text-xs text-rai-ink-muted" aria-live="polite"><bdi dir="ltr" className="tabular-nums">{confirmed ? describeRange(confirmed.from, confirmed.to) : "—"}</bdi>{!single && pick.b === null && confirmed ? " · يوم واحد" : ""}</p>
            <div className="mt-2 flex gap-2">
              <button type="button" className="btn-primary min-h-[44px] flex-1" disabled={!confirmed} onClick={done}>موافق</button>
              {clearable && from && <button type="button" className="btn-outline min-h-[44px]" onClick={() => { onChange("", ""); setOpen(false); }}>كل التواريخ</button>}
              <button type="button" className="btn-outline min-h-[44px]" onClick={() => { setOpen(false); btn.current?.focus(); }}>إلغاء</button>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
