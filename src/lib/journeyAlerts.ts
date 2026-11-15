/**
 * The journey's clock from the staff's screens (0070, W6): for the owner, the manager and the supervisor of the active
 * branch, every minute (while the page is visible) the server looks at the journey — the morning's options, the held
 * requests, the review invitations, the deposits past their hours, the alerts whose delay is over or that climb — and
 * says how many alerts are open; «رحلة الضيف» in the menu shows that number until they are dealt with.
 */
import { useEffect, useState } from "react";
import { useAuth } from "./auth";
import { useBranch } from "./branch";
import { journeyApi } from "./api";

export function useJourneyAlerts(): number | null {
  const { profile } = useAuth();
  const { branchId } = useBranch();
  const allowed = !!profile && ["owner", "manager", "supervisor"].includes(profile.role);
  const [open, setOpen] = useState<number | null>(null);

  useEffect(() => {
    setOpen(null);   // nothing of the previous branch stays after a switch
    if (!allowed || !branchId) return;
    let alive = true;
    let seq = 0;
    const load = () => {
      if (typeof document !== "undefined" && document.visibilityState === "hidden") return;
      const n = ++seq;
      journeyApi.tick(branchId).then((t) => { if (alive && n === seq) setOpen(t.open_alerts ?? 0); }).catch(() => { /* the next minute tries again */ });
    };
    load();
    const timer = window.setInterval(load, 60_000);
    window.addEventListener("focus", load);
    return () => { alive = false; window.clearInterval(timer); window.removeEventListener("focus", load); };
  }, [allowed, branchId]);

  return open;
}
