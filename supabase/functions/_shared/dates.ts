/**
 * Business dates are the branch's, never UTC's: between 00:00 and 03:00 in Riyadh the UTC date is still yesterday.
 * Same rule as fn_branch_today() in SQL (branches.timezone, default Asia/Riyadh).
 */

/** The branch-local calendar day (YYYY-MM-DD); an invalid IANA name in branches.timezone must not take a function down. */
export function localDay(tz: string | null | undefined, at: Date = new Date()): string {
  for (const z of [tz, "Asia/Riyadh"]) {
    try { if (z) return at.toLocaleDateString("en-CA", { timeZone: z }); } catch { /* invalid zone → next */ }
  }
  return at.toISOString().slice(0, 10);
}
