import { Link, useLocation } from "react-router-dom";
import type { KeyboxAlerts } from "../lib/api";
import { arabicCount, sinceArabic } from "../lib/utils";

/** A pulsing light: red for a code that must change (the alert), the others still. */
export function CodeLight({ tone, size = "h-3 w-3" }: { tone: "red" | "amber" | "green" | "grey" | "white"; size?: string }) {
  const color = { red: "bg-danger-500", amber: "bg-warning-500", green: "bg-success-500", grey: "bg-ink-200", white: "bg-white" }[tone];
  const pulse = tone === "red" || tone === "white";
  return (
    <span className={`relative inline-flex shrink-0 ${size}`} aria-hidden="true">
      {pulse && <span className={`absolute inline-flex h-full w-full rounded-full opacity-75 motion-safe:animate-ping ${color}`} />}
      <span className={`relative inline-flex h-full w-full rounded-full ${color}`} />
    </span>
  );
}

export const unitsNeedingChange = (n: number) => arabicCount(n, ["وحدة واحدة تحتاج", "وحدتان تحتاجان", "وحدات تحتاج", "وحدة تحتاج"]);

/**
 * On every staff page while any unit of the branch still waits for its new code (after a guest left): it stays until
 * the codes are changed on «الرموز». Not shown on «الرموز» itself, which lists the same units in red.
 */
export function KeyboxAlertBanner({ alerts }: { alerts: KeyboxAlerts | null }) {
  const { pathname } = useLocation();
  if (!alerts || alerts.count <= 0 || pathname.startsWith("/staff/codes")) return null;
  const names = alerts.rooms.slice(0, 6).join("، ") + (alerts.rooms.length > 6 ? "…" : "");
  return (
    <Link to="/staff/codes" role="status" aria-live="polite" data-testid="keybox-alert"
      className="flex items-center gap-3 bg-danger-500 px-4 py-2.5 text-sm text-white hover:bg-danger-600 lg:px-8">
      <CodeLight tone="white" />
      <span className="min-w-0 flex-1 leading-relaxed">
        <span className="font-semibold">{unitsNeedingChange(alerts.count)} تغيير رمز الصندوق</span> بعد خروج النزيل: {names}
        {alerts.oldest_since && <span className="text-white/80"> · أقدمها {sinceArabic(alerts.oldest_since)}</span>}
      </span>
      <span className="shrink-0 rounded-lg bg-white/15 px-2.5 py-1 text-xs font-medium">افتح «الرموز»</span>
    </Link>
  );
}

/** The count on the «الرموز» link of the navigation. */
export function KeyboxNavCount({ alerts }: { alerts: KeyboxAlerts | null }) {
  if (!alerts || alerts.count <= 0) return null;
  return <span className="mr-auto inline-flex min-w-[1.25rem] items-center justify-center rounded-full bg-danger-500 px-1.5 text-[11px] font-semibold leading-5 text-white" aria-label={`${alerts.count} بانتظار تغيير الرمز`}>{alerts.count}</span>;
}
