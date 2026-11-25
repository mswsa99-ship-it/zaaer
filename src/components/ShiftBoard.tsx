/**
 * 6.1 (U14): the start page of the day. It opens on what waits today, by role (design source: ShiftBoard):
 *  - reception (supervisor): arrivals, departures, the unpaid, the units to clean; each arrival row carries ONE action —
 *    «حصّل وسجّل» when money is left on it, «سجّل الوصول» when not;
 *  - finance: the unpaid, the stays to follow, the day's closing and the review;
 *  - manager and owner: approvals, identity matches, alerts and what waits for review;
 *  - housekeeping: the units to clean and the tasks.
 * Numbers come from the screens' own data; a tile that opens a page the role cannot open is not shown (PERM-05).
 */
import { Link } from "react-router-dom";
import { CreditCard, LogIn } from "lucide-react";
import type { ReactNode } from "react";
import { cn, maskName } from "../lib/utils";
import type { ReservationCard } from "../lib/hooks";

export interface BoardTile { key: string; label: string; value: ReactNode; note?: string; to: string; tone?: "warning" | "danger" }
export interface BoardRow { r: ReservationCard; action: "collect" | "arrive" }

export function ShiftBoard({ role, title, subtitle, tiles, rowsTitle, rows }: { role: string; title: string; subtitle: string; tiles: BoardTile[]; rowsTitle: string; rows: BoardRow[] }) {
  return (
    <section className="mb-6" data-testid="shift-board" data-role={role} aria-label="بداية اليوم">
      <h2 className="text-xl font-semibold text-ink-800">{title}</h2>
      <p className="mb-3 text-sm text-ink-500">{subtitle}</p>
      <div className="mb-4 flex flex-wrap gap-3" data-testid="shift-tiles">
        {tiles.map((t) => (
          <Link key={t.key} to={t.to} data-testid={`shift-tile-${t.key}`}
            className={cn("card flex min-w-[9.5rem] flex-1 flex-col gap-0.5 p-3 hover:shadow-md", t.tone === "warning" && "border-warning-500/40", t.tone === "danger" && "border-danger-500/40")}>
            <span className="text-xs text-ink-500">{t.label}</span>
            <span className="text-2xl font-semibold tabular-nums text-ink-800">{t.value}</span>
            {t.note && <span className="text-[11px] text-ink-500">{t.note}</span>}
          </Link>
        ))}
      </div>
      <div className="card overflow-hidden p-0" data-testid="shift-rows">
        <div className="border-b border-ink-100 px-4 py-3 text-sm font-semibold text-ink-800">{rowsTitle}</div>
        {rows.length === 0 ? (
          <p className="px-4 py-6 text-center text-sm text-ink-500">لا شيء ينتظر الآن</p>
        ) : (
          <ul className="divide-y divide-ink-100">
            {rows.map(({ r, action }) => (
              <li key={r.id} className="flex flex-wrap items-center gap-3 px-4 py-2.5 text-sm">
                <span className="font-mono text-xs font-semibold text-ink-800" dir="ltr">{r.internal_ref}</span>
                <span className="min-w-0 flex-1 truncate text-ink-600">{maskName(r.primary_guest?.full_name)} · {r.room?.room_number ?? "—"}</span>
                <Link to={`/staff/reservations/${r.id}`} data-testid={`shift-action-${action}`} className="btn-ghost inline-flex h-8 items-center gap-1.5 px-3 text-xs">
                  {action === "collect" ? <CreditCard className="h-3.5 w-3.5" aria-hidden="true" /> : <LogIn className="h-3.5 w-3.5" aria-hidden="true" />}
                  {action === "collect" ? "حصّل وسجّل" : "سجّل الوصول"}
                </Link>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}
