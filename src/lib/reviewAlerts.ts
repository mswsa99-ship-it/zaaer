/**
 * «بحاجة لمراجعة وتدقيق» for the owner (decision 54, §16): how many items wait, by kind. On the dashboards the server's
 * seven monitors also run for the active branch (at most every 10 minutes — the server decides). The count refreshes every
 * minute, when the window regains focus, and at once after a mark on this device. Anyone but the owner gets nothing.
 */
import { useEffect, useState } from "react";
import { useAuth } from "./auth";
import { useBranch } from "./branch";
import { reviewApi, type ReviewSummary } from "./api";

const CHANGED = "zaaer:review-changed";

/** Tell the banner that items were marked here, so it updates without waiting for the next refresh. */
export function notifyReviewChanged() {
  window.dispatchEvent(new Event(CHANGED));
}

export function useReviewSummary(runMonitors = false): ReviewSummary | null {
  const { profile } = useAuth();
  const { branchId } = useBranch();
  const owner = profile?.role === "owner";
  const [summary, setSummary] = useState<ReviewSummary | null>(null);

  useEffect(() => {
    setSummary(null);
    if (!owner) return;
    let alive = true;
    let seq = 0;   // an older answer that arrives after a newer one is dropped
    const load = () => { const n = ++seq; reviewApi.summary().then((s) => { if (alive && n === seq) setSummary(s); }).catch(() => { /* the next refresh tries again */ }); };
    const monitors = () => {
      if (!branchId) { load(); return; }
      const n = ++seq;
      reviewApi.monitorsIfDue(branchId).then((x) => { if (alive && n === seq) setSummary(x.summary); }).catch(() => load());
    };
    if (runMonitors) monitors(); else load();
    const minute = window.setInterval(load, 60_000);
    const checks = runMonitors ? window.setInterval(monitors, 10 * 60_000) : null;
    window.addEventListener("focus", load);
    window.addEventListener(CHANGED, load);
    return () => {
      alive = false;
      window.clearInterval(minute);
      if (checks) window.clearInterval(checks);
      window.removeEventListener("focus", load);
      window.removeEventListener(CHANGED, load);
    };
  }, [owner, branchId, runMonitors]);

  return summary;
}
