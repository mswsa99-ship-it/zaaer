import { Link } from "react-router-dom";
import { ClipboardCheck } from "lucide-react";
import type { ReviewSummary } from "../lib/api";
import { arabicCount, sinceArabic } from "../lib/utils";

export const itemsWaiting = (n: number) => arabicCount(n, ["بند واحد ينتظر", "بندان ينتظران", "بنود تنتظر", "بندًا ينتظر"]);

/** The owner's banner on the dashboards (decision 54): what waits in «بحاجة لمراجعة وتدقيق», and how much of it the monitors found. */
export function ReviewBanner({ summary }: { summary: ReviewSummary | null }) {
  if (!summary || summary.open <= 0) return null;
  return (
    <Link to="/admin/review" role="status" aria-live="polite" data-testid="review-banner"
      className="mb-4 flex items-center gap-3 rounded-xl border border-warning-500/30 bg-warning-500/10 px-4 py-3 text-sm text-warning-600 hover:shadow-sm">
      <ClipboardCheck className="h-5 w-5 shrink-0" />
      <span className="min-w-0 flex-1 leading-relaxed">
        <span className="font-semibold">{itemsWaiting(summary.open)}</span> في «بحاجة لمراجعة وتدقيق»
        {summary.monitors > 0 && <> — منها <span className="font-semibold">{summary.monitors}</span> من المراقبة</>}
        {summary.oldest_at && <span className="text-warning-600/80"> · أقدمها {sinceArabic(summary.oldest_at)}</span>}
      </span>
      <span className="shrink-0 rounded-lg bg-white/70 px-2.5 py-1 text-xs font-medium">افتح القائمة</span>
    </Link>
  );
}

/** The count on the list's link in the navigation. */
export function ReviewNavCount({ summary }: { summary: ReviewSummary | null }) {
  if (!summary || summary.open <= 0) return null;
  return <span className="mr-auto inline-flex min-w-[1.25rem] items-center justify-center rounded-full bg-warning-500 px-1.5 text-[11px] font-semibold leading-5 text-white" aria-label={`${summary.open} بانتظار المراجعة`}>{summary.open}</span>;
}
