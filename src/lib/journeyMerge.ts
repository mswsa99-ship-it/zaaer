import type { StaffReviews, ReviewAspect } from "./api";

type Mark = "overall" | ReviewAspect;

// Merge the per-branch review reads of the owner's all-branches board.
// exact = every branch returned all of its reviews (rows === count), so each mark is the plain average of the raw rows.
// Otherwise the branches' own rounded one-decimal averages are weighted by review count: an approximation, flagged exact=false.
export function mergeReviews(rv: StaffReviews[]): { merged: StaffReviews | null; exact: boolean } {
  if (!rv.length) return { merged: null, exact: true };
  const exact = rv.every((x) => x.reviews.length === x.summary.count);
  const raw = rv.flatMap((x) => x.reviews) as unknown as Array<Record<string, unknown>>;
  const keys = ["overall", ...rv[0].aspects.map((a) => a.key)] as Mark[];
  const avgOf = (k: Mark): number | null => {
    if (exact) {
      const v = raw.map((r) => r[k]).filter((n): n is number => typeof n === "number");
      return v.length ? Math.round((v.reduce((a, n) => a + n, 0) / v.length) * 10) / 10 : null;
    }
    const w = rv.filter((x) => x.summary[k] != null && x.summary.count > 0);
    const n = w.reduce((a, x) => a + x.summary.count, 0);
    return n ? Math.round((w.reduce((a, x) => a + (x.summary[k] as number) * x.summary.count, 0) / n) * 10) / 10 : null;
  };
  const marks = Object.fromEntries(keys.map((k) => [k, avgOf(k)])) as Record<Mark, number | null>;
  const merged = {
    ...rv[0], invited: rv.reduce((a, x) => a + x.invited, 0),
    summary: { count: rv.reduce((a, x) => a + x.summary.count, 0), below: rv.reduce((a, x) => a + x.summary.below, 0), ...marks },
    reviews: rv.flatMap((x) => x.reviews),
  } as unknown as StaffReviews;
  return { merged, exact };
}
