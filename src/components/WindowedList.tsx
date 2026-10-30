import { useState } from "react";

/**
 * B8–B10 (the owner's notes 9, 10 and 11): a work list that opens on what still needs doing. What is still to do stays
 * listed however old it is; what was done shows for a limited window (24 or 48 hours) under «تمت معالجته». The filter
 * is a choice the user can change; the default is always «غير المعالَج».
 */
export type ListFilter = "open" | "done" | "all";

export function useListFilter() {
  return useState<ListFilter>("open");
}

export function sinceHours(hours: number, now = Date.now()): string {
  return new Date(now - hours * 3600_000).toISOString();
}

export function ListFilterBar({ value, onChange, openLabel, doneLabel, openCount, doneCount, windowHours }: {
  value: ListFilter; onChange: (v: ListFilter) => void; openLabel: string; doneLabel: string; openCount: number; doneCount: number; windowHours: number;
}) {
  const items: Array<[ListFilter, string, number]> = [["open", openLabel, openCount], ["done", `${doneLabel} (آخر ${windowHours} ساعة)`, doneCount], ["all", "الكل", openCount + doneCount]];
  return (
    <div className="mb-4 flex flex-wrap gap-2" role="group" aria-label="تصفية القائمة" data-testid="list-filter">
      {items.map(([k, label, n]) => (
        <button key={k} type="button" onClick={() => onChange(k)} aria-pressed={value === k} data-testid={`list-filter-${k}`}
          className={`min-h-[44px] rounded-xl px-3 py-2 text-sm font-medium ${value === k ? "bg-brand-600 text-white" : "bg-ink-100 text-ink-700"}`}>
          {label} <span className="tabular-nums" dir="ltr">{n}</span>
        </button>
      ))}
    </div>
  );
}

/** The items the filter keeps, open first. */
export function pick<T>(filter: ListFilter, open: T[], done: T[]): T[] {
  return filter === "open" ? open : filter === "done" ? done : [...open, ...done];
}
