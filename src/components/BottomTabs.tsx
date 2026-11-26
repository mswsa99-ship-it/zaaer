/**
 * U3 (approved 31 Oct 2026, design system U2): on a phone the main navigation is a bottom bar of five — four pages
 * the role uses most, then «المزيد» for the whole menu. The four come from the role's own menu (lib/nav.ts), so a link
 * the role cannot open never shows; a role missing one of the preferred pages gets its next menu page instead.
 */
import { NavLink } from "react-router-dom";
import { MoreHorizontal, type LucideIcon } from "lucide-react";
import { cn } from "../lib/utils";

export interface TabItem { to: string; label: string; icon: LucideIcon }

/** The preferred pages first (those the role has), then the rest of its menu, four in all. */
export function pickTabs(items: TabItem[], preferred: string[], count = 4): TabItem[] {
  const out: TabItem[] = [];
  for (const p of preferred) { const it = items.find((x) => x.to === p); if (it) out.push(it); }
  for (const it of items) { if (out.length >= count) break; if (!out.includes(it)) out.push(it); }
  return out.slice(0, count);
}

/** Short labels for the bar (the menu keeps the full ones). */
const SHORT: Record<string, string> = {
  "/staff/rooms": "الوحدات", "/staff/access-approvals": "الوصول", "/staff/reservations": "الحجوزات", "/staff/payments": "المدفوعات",
  "/staff/housekeeping": "الغرف", "/staff/tickets": "البلاغات", "/staff/dashboard": "العمليات",
  "/admin/dashboard": "الإدارة", "/admin/reservations": "الحجوزات", "/admin/finance": "المالية", "/admin/review": "المراجعة",
  "/admin/guests": "النزلاء", "/admin/policies": "السياسات", "/admin/audit-logs": "السجل", "/admin/assistant": "المساعد", "/admin/knowledge": "المعرفة",
};

/** Every item has the same icon box and label line, so the five sit on one rhythm; the page you are on gets a tinted pill. */
const ICON_BOX = "flex h-7 w-14 items-center justify-center rounded-full";
const ACTIVE_BOX = "bg-[color-mix(in_srgb,currentColor_18%,transparent)]";
const LABEL = "whitespace-nowrap px-0.5 text-center text-[12px] leading-4";

export function BottomTabs({ items, onMore, moreOpen }: { items: TabItem[]; onMore: () => void; moreOpen: boolean }) {
  return (
    <nav aria-label="التنقل الرئيسي" data-testid="bottom-tabs"
      className="fixed inset-x-0 bottom-0 z-30 grid grid-cols-[repeat(auto-fit,minmax(3.6rem,1fr))] border-t border-ink-100 bg-white pb-[env(safe-area-inset-bottom)] lg:hidden">
      {items.map((it) => (
        <NavLink key={it.to} to={it.to}
          className={({ isActive }) => cn("flex min-h-[60px] flex-col items-center justify-center gap-1 text-xs font-semibold", isActive ? "text-brand-700" : "text-ink-500")}>
          {({ isActive }) => (<>
            <span className={cn(ICON_BOX, isActive && ACTIVE_BOX)} data-active={isActive ? "true" : undefined}><it.icon className="h-5 w-5" aria-hidden="true" /></span>
            <span className={cn(LABEL, isActive && "font-bold")}>{SHORT[it.to] ?? it.label}</span>
          </>)}
        </NavLink>
      ))}
      <button type="button" onClick={onMore} aria-expanded={moreOpen} data-testid="bottom-tabs-more"
        className="flex min-h-[60px] flex-col items-center justify-center gap-1 text-xs font-semibold text-ink-500">
        <span className={ICON_BOX}><MoreHorizontal className="h-5 w-5" aria-hidden="true" /></span>
        <span className={LABEL}>المزيد</span>
      </button>
    </nav>
  );
}
