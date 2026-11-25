/**
 * The red alert of «الرموز»: units of the active branch whose key-box code must still be changed after a guest left.
 * Shown on every staff page (both layouts) until the codes are changed — refreshed when a unit changes (check-out,
 * cleaning), every 30 seconds, when the window regains focus, and at once after a code is saved on this device.
 */
import { useEffect, useState } from "react";
import { supabase } from "./supabase";
import { useAuth } from "./auth";
import { useBranch } from "./branch";
import { codesApi, type KeyboxAlerts } from "./api";

const CHANGED = "zaaer:keybox-changed";

/** Tell the alert that a code was saved here, so it clears without waiting for the next refresh. */
export function notifyKeyboxChanged() {
  window.dispatchEvent(new Event(CHANGED));
}

export function useKeyboxAlerts(): KeyboxAlerts | null {
  const { profile, can } = useAuth();
  const { branchId, branches, allBranches } = useBranch();
  const scopeKey = allBranches ? "all:" + branches.map((b) => b.id).join(",") : branchId;
  const allowed = !!profile && can("keybox.code");
  const [alerts, setAlerts] = useState<KeyboxAlerts | null>(null);

  useEffect(() => {
    setAlerts(null);   // nothing of the previous branch stays on screen after a switch (G24)
    if (!allowed || !scopeKey) return;
    let alive = true;
    let seq = 0;       // an older refresh that answers after a newer one is dropped
    // «جميع الفروع» (owner): the alert covers every branch, each room named with its branch; otherwise the active branch only
    const fetchAlerts = (): Promise<KeyboxAlerts> => !allBranches ? codesApi.alerts(branchId as string)
      : Promise.all(branches.map((b) => codesApi.alerts(b.id).then((a) => ({ a, name: b.name_ar })))).then((parts) => ({
        count: parts.reduce((n, x) => n + x.a.count, 0),
        oldest_since: parts.map((x) => x.a.oldest_since).filter((v): v is string => !!v).sort()[0] ?? null,
        rooms: parts.flatMap((x) => x.a.rooms.map((r) => `${r} (${x.name})`)),
      }));
    const load = () => { const n = ++seq; fetchAlerts().then((a) => { if (alive && n === seq) setAlerts(a); }).catch(() => { /* the next refresh tries again */ }); };
    load();
    const timer = window.setInterval(load, 30_000);
    window.addEventListener("focus", load);
    window.addEventListener(CHANGED, load);
    const ch = supabase.channel(`keybox-alerts-${scopeKey}`).on("postgres_changes", { event: "*", schema: "public", table: "rooms" }, () => load()).subscribe();
    return () => {
      alive = false;
      window.clearInterval(timer);
      window.removeEventListener("focus", load);
      window.removeEventListener(CHANGED, load);
      supabase.removeChannel(ch);
    };
  }, [allowed, scopeKey]); // eslint-disable-line react-hooks/exhaustive-deps

  return alerts;
}
