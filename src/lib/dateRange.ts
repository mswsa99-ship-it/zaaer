/**
 * Day or period selection (owner request, 25 Nov): the person taps one day and confirms = that day only;
 * taps a second day and confirms = the whole period, both days included. Pure helpers, so the rule is testable
 * without a browser. Dates are ISO yyyy-mm-dd strings, never Date objects in local time.
 */
export interface Pick { a: string | null; b: string | null }

/** One tap on a day: the first tap (or a tap after a complete pair) starts again; the second tap closes the pair. */
export function tapDay(p: Pick, day: string, single = false): Pick {
  if (single || p.a === null || p.b !== null) return { a: day, b: null };
  return { a: p.a, b: day };
}

/** The confirmed selection: a lone day is that day; two days are the inclusive period in date order. */
export function confirmPick(p: Pick): { from: string; to: string } | null {
  if (p.a === null) return null;
  if (p.b === null) return { from: p.a, to: p.a };
  return p.a <= p.b ? { from: p.a, to: p.b } : { from: p.b, to: p.a };
}

/** Is the day inside the (pending) selection, for the highlight. */
export function inPick(p: Pick, day: string): boolean {
  const c = confirmPick(p);
  return !!c && day >= c.from && day <= c.to;
}

/** Every day of the inclusive period (callers cap the length before fanning out). */
export function eachDay(from: string, to: string, cap = 62): string[] {
  const out: string[] = [];
  let d = new Date(from + "T12:00:00Z");
  const end = new Date(to + "T12:00:00Z").getTime();
  while (d.getTime() <= end && out.length < cap) {
    out.push(d.toISOString().slice(0, 10));
    d = new Date(d.getTime() + 86400_000);
  }
  return out;
}

/** Cells of one month for a Saturday-first week: leading nulls, then every day of the month. */
export function monthCells(year: number, month0: number): Array<string | null> {
  const first = new Date(Date.UTC(year, month0, 1, 12));
  const lead = (first.getUTCDay() + 1) % 7; // Saturday = 0
  const days = new Date(Date.UTC(year, month0 + 1, 0, 12)).getUTCDate();
  const cells: Array<string | null> = Array.from({ length: lead }, () => null);
  for (let i = 1; i <= days; i++) cells.push(new Date(Date.UTC(year, month0, i, 12)).toISOString().slice(0, 10));
  return cells;
}

/** «2026-11-20 → 2026-11-25» or one day; always left-to-right digits so the order never flips in an RTL page. */
export function describeRange(from: string, to: string): string {
  return from === to ? from : `${from} → ${to}`;
}
