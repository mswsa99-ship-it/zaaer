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
import { CODES_ROLES } from "./nav";

const CHANGED = "zaaer:keybox-changed";

/** Tell the alert that a code was saved here, so it clears without waiting for the next refresh. */
export function notifyKeyboxChanged() {
  window.dispatchEvent(new Event(CHANGED));
}

export function useKeyboxAlerts(): KeyboxAlerts | null {
  const { profile } = useAuth();
  const { branchId } = useBranch();
  const allowed = !!profile && (CODES_ROLES as readonly string[]).includes(profile.role);
  const [alerts, setAlerts] = useState<KeyboxAlerts | null>(null);

  useEffect(() => {
    if (!allowed || !branchId) { setAlerts(null); return; }
    let alive = true;
    const load = () => { codesApi.alerts(branchId).then((a) => { if (alive) setAlerts(a); }).catch(() => { /* the next refresh tries again */ }); };
    load();
    const timer = window.setInterval(load, 30_000);
    window.addEventListener("focus", load);
    window.addEventListener(CHANGED, load);
    const ch = supabase.channel(`keybox-alerts-${branchId}`).on("postgres_changes", { event: "*", schema: "public", table: "rooms" }, () => load()).subscribe();
    return () => {
      alive = false;
      window.clearInterval(timer);
      window.removeEventListener("focus", load);
      window.removeEventListener(CHANGED, load);
      supabase.removeChannel(ch);
    };
  }, [allowed, branchId]);

  return alerts;
}
