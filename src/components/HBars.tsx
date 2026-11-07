/**
 * OWNER-09 / OWNER-14: a ranked list of a few categories (3–12) as HTML rows with an inline bar — the label and the
 * value are text, so they read on a phone, in RTL, without hovering, and a colour belongs to its category (by its key),
 * not to its rank.
 */
import { cn } from "../lib/utils";

const PALETTE = ["#1f5f74", "#2bb3a3", "#d98a1b", "#7a5ea8", "#c0392b", "#33476a", "#5b8c2a", "#b0567d"];
/** The same category gets the same colour on every chart, whatever its rank. */
export function colourFor(key: string): string {
  let h = 0;
  for (let i = 0; i < key.length; i++) h = (h * 31 + key.charCodeAt(i)) >>> 0;
  return PALETTE[h % PALETTE.length];
}

export interface HBarRow { key: string; label: string; value: number; display?: string; note?: string }

export function HBars({ rows, empty, testId, className }: { rows: HBarRow[]; empty: string; testId?: string; className?: string }) {
  const sorted = [...rows].sort((a, b) => b.value - a.value);
  const max = Math.max(1, ...sorted.map((r) => Math.abs(r.value)));
  if (!sorted.length) return <p className="py-6 text-center text-sm text-ink-400">{empty}</p>;
  return (
    <ul className={cn("space-y-2.5", className)} data-testid={testId}>
      {sorted.map((r) => (
        <li key={r.key} className="text-sm" data-testid="hbar">
          <div className="mb-1 flex items-baseline justify-between gap-3">
            <span className="min-w-0 truncate text-ink-700">{r.label}{r.note && <span className="ms-1 text-[11px] text-ink-400">{r.note}</span>}</span>
            <span className="shrink-0 font-semibold tabular-nums text-ink-800" dir="ltr">{r.display ?? r.value.toLocaleString("en-US")}</span>
          </div>
          <div className="h-2 overflow-hidden rounded-full bg-ink-100" aria-hidden="true">
            <div className="h-full rounded-full" style={{ width: `${Math.max(2, (Math.abs(r.value) / max) * 100)}%`, background: colourFor(r.key) }} />
          </div>
        </li>
      ))}
    </ul>
  );
}
