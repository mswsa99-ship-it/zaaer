/**
 * Merging per-branch results for the owner's «جميع الفروع» view. Counts and money add up; a percentage is
 * recomputed from the summed parts, never averaged. Pure functions, so they are unit-tested.
 */
type Json = Record<string, unknown>;

/** Adds every numeric field of the same shape (recursing into plain objects); other fields keep the first value. Arrays are left to the caller. */
export function sumDeep<T>(parts: T[]): T {
  if (parts.length === 0) return undefined as unknown as T;
  const first = parts[0] as unknown;
  if (typeof first === "number") return parts.reduce((s, x) => s + (typeof x === "number" ? x : 0), 0) as unknown as T;
  if (first && typeof first === "object" && !Array.isArray(first)) {
    const out: Json = {};
    for (const k of Object.keys(first as Json)) out[k] = sumDeep(parts.map((p) => (p as Json)?.[k]).filter((v) => v !== undefined && v !== null)) ?? (first as Json)[k];
    return out as T;
  }
  return first as T;
}

export function pct(part: number, whole: number): number { return whole > 0 ? Math.round((part / whole) * 1000) / 10 : 0; }

/** Rows with the same key add their numbers (by_source, by_method…): one row per key, in first-seen order. */
export function mergeRows<R extends Json>(lists: R[][], keyOf: (r: R) => string, add: (keyof R)[]): R[] {
  const map = new Map<string, R>();
  for (const l of lists) for (const r of l ?? []) {
    const k = keyOf(r); const cur = map.get(k);
    if (!cur) map.set(k, { ...r });
    else for (const f of add) (cur as Json)[f as string] = Number(cur[f] ?? 0) + Number(r[f] ?? 0);
  }
  return [...map.values()];
}

/** Collection figures of several branches: due and paid add up, the rate is recomputed from the sums (never averaged). */
function mergeCollection(parts: Array<{ due: number; paid: number; platform: number; rate_pct: number; raw_pct: number } | null | undefined>) {
  const ok = parts.filter((p): p is NonNullable<typeof p> => !!p);
  if (ok.length === 0) return null;
  const due = ok.reduce((s, p) => s + p.due, 0), paid = ok.reduce((s, p) => s + p.paid, 0), platform = ok.reduce((s, p) => s + p.platform, 0);
  const raw = pct(paid, due);
  return { due, paid, platform, raw_pct: raw, rate_pct: Math.min(raw, 100) };
}

/** «جميع الفروع» for the finance report: every money and count adds up; rows with the same method, day, staff, account or source join. */
export function mergeReportsFinance<T extends { ledger: Json; charges: Json; collection_rate_pct: number | null; collection?: unknown; by_method: Json[]; by_day: Json[]; by_staff?: Json[]; by_account?: Json[]; reservations: { by_source: Json[] } & Json; period: unknown }>(parts: T[]): T {
  const first = parts[0];
  const col = mergeCollection(parts.map((p) => p.collection as never));
  const merged = {
    ...first,
    ledger: sumDeep(parts.map((p) => p.ledger)),
    charges: sumDeep(parts.map((p) => p.charges)),
    collection: col,
    // the single-branch rule: null when a filter makes the rate meaningless (every part is null then)
    collection_rate_pct: parts.every((p) => p.collection_rate_pct === null) ? null : col ? col.rate_pct : null,
    by_method: mergeRows(parts.map((p) => p.by_method), (r) => String(r.method) + String(r.platform ?? ""), ["amount_halalas"]),
    by_day: mergeRows(parts.map((p) => p.by_day), (r) => String(r.day), ["receipts", "refunds", "platform"]).sort((a, b) => (String(a.day) < String(b.day) ? -1 : 1)),
    by_staff: first.by_staff ? mergeRows(parts.map((p) => p.by_staff ?? []), (r) => String(r.staff_id ?? r.staff), ["receipts", "refunds", "count"]) : undefined,
    by_account: first.by_account ? mergeRows(parts.map((p) => p.by_account ?? []), (r) => String(r.account_id), ["in_halalas", "out_halalas"]) : undefined,
    reservations: {
      ...first.reservations,
      count: parts.reduce((s, p) => s + Number(p.reservations.count), 0), nights: parts.reduce((s, p) => s + Number(p.reservations.nights), 0),
      cancelled: parts.reduce((s, p) => s + Number(p.reservations.cancelled), 0), no_show: parts.reduce((s, p) => s + Number(p.reservations.no_show), 0),
      by_source: mergeRows(parts.map((p) => p.reservations.by_source), (r) => String(r.source_id ?? r.source), ["count", "total_halalas"]),
    },
  };
  return merged as unknown as T;
}

/** Platform payouts of several branches: totals add up and each source/account pair is one row. */
export function mergeReportsPlatforms<T extends { by_source: Json[] }>(parts: T[]): T {
  const total = sumDeep(parts.map((p) => ({ ...p, by_source: [] })));
  return { ...total, by_source: mergeRows(parts.map((p) => p.by_source), (r) => String(r.source) + "|" + String(r.account), ["payouts", "expected_halalas", "commission_halalas", "received_halalas", "difference_halalas"]) } as unknown as T;
}

/** «جميع الفروع» for the discounts report: totals add up, staff rows with the same name and role join, rows are listed newest first. */
export function mergeDiscounts<T extends { total_halalas: number; count: number; by_staff: Json[]; rows: Json[] | null }>(parts: T[]): T {
  const first = parts[0];
  return {
    ...first,
    total_halalas: parts.reduce((s, p) => s + p.total_halalas, 0),
    count: parts.reduce((s, p) => s + p.count, 0),
    by_staff: mergeRows(parts.map((p) => p.by_staff ?? []), (r) => `${r.staff_id ?? r.staff ?? ""}|${r.role ?? ""}`, ["count", "total_halalas"]),
    rows: parts.some((p) => p.rows) ? parts.flatMap((p) => p.rows ?? []).sort((a, b) => String(b.created_at ?? "").localeCompare(String(a.created_at ?? ""))) : null,
  };
}

/** Late entries: counts add up, staff rows join (the largest lag is kept), rows are listed with the latest entry first. */
export function mergeLateEntries<T extends { platform_bookings: number; late: number; after_arrival: number; by_staff: Json[]; rows: Json[] }>(parts: T[]): T {
  const first = parts[0];
  const staff = new Map<string, Json>();
  for (const p of parts) for (const r of p.by_staff ?? []) {
    const k = String(r.staff_id ?? r.staff ?? ""); const cur = staff.get(k);
    if (!cur) staff.set(k, { ...r });
    else { cur.count = Number(cur.count) + Number(r.count); cur.max_lag = Math.max(Number(cur.max_lag ?? 0), Number(r.max_lag ?? 0)); }
  }
  return {
    ...first,
    platform_bookings: parts.reduce((s, p) => s + p.platform_bookings, 0),
    late: parts.reduce((s, p) => s + p.late, 0),
    after_arrival: parts.reduce((s, p) => s + p.after_arrival, 0),
    by_staff: [...staff.values()],
    rows: parts.flatMap((p) => p.rows ?? []).sort((a, b) => String(b.entered_on ?? "").localeCompare(String(a.entered_on ?? ""))),
  };
}

/** Approved identities: counts add up, staff rows join, rows are listed with the latest entry first. */
export function mergeIdentities<T extends { count: number; by_staff: Json[]; rows: Json[] }>(parts: T[]): T {
  const first = parts[0];
  return {
    ...first,
    count: parts.reduce((s, p) => s + p.count, 0),
    by_staff: mergeRows(parts.map((p) => p.by_staff ?? []), (r) => String(r.staff_id ?? r.staff ?? ""), ["office", "guest"]),
    rows: parts.flatMap((p) => p.rows ?? []),
  };
}

/** «جميع الفروع» for the operations centre: counts add up, the occupancy percentages are recomputed from the summed units (never averaged). */
export function mergeDailySummary<T extends { units: { active: number; all?: number; occupied: number }; occupancy_pct: number; occupancy_all_pct?: number }>(parts: Array<T | null>): T | null {
  const ok = parts.filter((p): p is T => !!p);
  if (ok.length === 0) return null;
  const m = sumDeep(ok) as T;
  m.occupancy_pct = pct(m.units.occupied, m.units.active);
  if (ok.every((p) => p.units.all != null)) m.occupancy_all_pct = pct(m.units.occupied, m.units.all ?? 0);
  return m;
}

/** The stay follow-ups of every branch, one list per kind. */
export function mergeFollowups<T extends { overdue: unknown[]; departed_open: unknown[]; late_departures: unknown[] }>(parts: Array<T | null>): T | null {
  const ok = parts.filter((p): p is T => !!p);
  if (ok.length === 0) return null;
  return { ...ok[0], overdue: ok.flatMap((p) => p.overdue), departed_open: ok.flatMap((p) => p.departed_open), late_departures: ok.flatMap((p) => p.late_departures) } as T;
}
