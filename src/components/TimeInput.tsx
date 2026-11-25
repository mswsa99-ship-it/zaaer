import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Clock } from "lucide-react";
import { HOURS_24, MINUTES, describeTime, hourLabel, pad2, parseHHMM, periodOf, toHHMM, wheelIndex } from "../lib/timeText";

const ITEM = 44; // px, also the touch target height

function Wheel({ count, index, onIndex, render, label }: { count: number; index: number; onIndex: (i: number) => void; render: (i: number) => React.ReactNode; label: string }) {
  const box = useRef<HTMLDivElement>(null);
  const timer = useRef<number | undefined>(undefined);
  useLayoutEffect(() => { if (box.current) box.current.scrollTop = index * ITEM; /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, []);
  useEffect(() => () => window.clearTimeout(timer.current), []);
  const go = (i: number) => { const c = Math.max(0, Math.min(count - 1, i)); box.current?.scrollTo({ top: c * ITEM, behavior: "smooth" }); onIndex(c); };
  return (
    <div className="relative flex-1">
      <div className="pointer-events-none absolute inset-x-0 top-[44px] h-[44px] rounded-xl bg-rai-action ring-1 ring-rai-line-strong" aria-hidden="true" />
      <div ref={box} role="listbox" tabIndex={0} aria-label={label} aria-activedescendant={undefined}
        className="relative h-[132px] snap-y snap-mandatory overflow-y-scroll overscroll-contain py-[44px] text-center [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
        style={{ touchAction: "pan-y" }}
        onScroll={(e) => { const top = e.currentTarget.scrollTop; window.clearTimeout(timer.current); timer.current = window.setTimeout(() => onIndex(wheelIndex(top, ITEM, count)), 90); }}
        onKeyDown={(e) => { if (e.key === "ArrowDown") { e.preventDefault(); go(index + 1); } else if (e.key === "ArrowUp") { e.preventDefault(); go(index - 1); } }}>
        {Array.from({ length: count }, (_, i) => (
          <div key={i} role="option" aria-selected={i === index} onClick={() => go(i)}
            className={`flex h-[44px] snap-center items-center justify-center tabular-nums ${i === index ? "text-lg font-semibold text-rai-ink" : "text-base text-rai-ink-muted"}`}>{render(i)}</div>
        ))}
      </div>
    </div>
  );
}

/**
 * Arrival / departure time as two scroll wheels: hours (all 24 shown as 12 … 11 صباحًا, then 12 … 11 مساءً, so the period
 * flips by itself when the wheel passes the first 12) and minutes. The value is «HH:MM» or "" — where the screen allows a
 * blank it means the branch time, and «موعد الفرع» clears it.
 */
export function TimeInput({ value, onChange, label, clearable = false, blankLabel = "موعد الفرع", className }: { value: string; onChange: (v: string) => void; label: string; clearable?: boolean; blankLabel?: string; className?: string }) {
  const [open, setOpen] = useState(false);
  const cur = parseHHMM(value);
  const [h, setH] = useState(cur?.h ?? 16);
  const [m, setM] = useState(cur?.m ?? 0);
  const btn = useRef<HTMLButtonElement>(null);
  const openIt = () => { const c = parseHHMM(value); if (c) { setH(c.h); setM(c.m); } setOpen(true); };
  useEffect(() => {
    if (!open) return;
    const k = (e: KeyboardEvent) => { if (e.key === "Escape") { setOpen(false); btn.current?.focus(); } };
    window.addEventListener("keydown", k); return () => window.removeEventListener("keydown", k);
  }, [open]);
  const done = (v: string) => { onChange(v); setOpen(false); btn.current?.focus(); };
  return (
    <div className={"relative " + (className ?? "")} data-testid="time-input">
      <button ref={btn} type="button" className="input flex items-center justify-between gap-2 text-start" aria-haspopup="dialog" aria-expanded={open} aria-label={label} onClick={openIt}>
        <Clock className="h-4 w-4 shrink-0 text-rai-ink-muted" />
        <span data-testid="time-value">{value ? describeTime(value) : <span className="text-rai-ink-muted">{clearable ? blankLabel : "اختر الوقت"}</span>}</span>
      </button>
      {open && (
        <>
          <button type="button" tabIndex={-1} aria-hidden="true" className="fixed inset-0 z-40 cursor-default" onClick={() => setOpen(false)} />
          <div role="dialog" aria-label={label} className="fixed inset-x-3 bottom-3 z-50 rounded-2xl border border-rai-line bg-rai-surface p-3 shadow-lg sm:absolute sm:inset-x-auto sm:bottom-auto sm:start-0 sm:top-full sm:mt-1 sm:w-72">
            <div className="flex items-stretch gap-2" dir="ltr">
              <Wheel label={label + ": الساعة"} count={24} index={h} onIndex={setH} render={(i) => <span>{hourLabel(HOURS_24[i])} <span className="text-xs text-rai-ink-muted">{periodOf(i)}</span></span>} />
              <span className="flex items-center text-lg font-semibold text-rai-ink" aria-hidden="true">:</span>
              <Wheel label={label + ": الدقائق"} count={60} index={m} onIndex={setM} render={(i) => pad2(MINUTES[i])} />
            </div>
            <p className="mt-2 text-center text-sm font-medium text-rai-ink" aria-live="polite">{describeTime(toHHMM(h, m))}</p>
            <div className="mt-2 flex gap-2">
              <button type="button" className="btn-primary min-h-[44px] flex-1" onClick={() => done(toHHMM(h, m))}>موافق</button>
              {clearable && value && <button type="button" className="btn-outline min-h-[44px]" onClick={() => done("")}>{blankLabel}</button>}
              <button type="button" className="btn-outline min-h-[44px]" onClick={() => setOpen(false)}>إلغاء</button>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
