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
};

export function BottomTabs({ items, onMore, moreOpen }: { items: TabItem[]; onMore: () => void; moreOpen: boolean }) {
  return (
    <nav aria-label="التنقل الرئيسي" data-testid="bottom-tabs"
      className="fixed inset-x-0 bottom-0 z-30 flex border-t border-ink-100 bg-white pb-[env(safe-area-inset-bottom)] lg:hidden">
      {items.map((it) => (
        <NavLink key={it.to} to={it.to}
          className={({ isActive }) => cn("flex min-h-[56px] flex-1 flex-col items-center justify-center gap-0.5 text-xs font-semibold", isActive ? "text-brand-700" : "text-ink-500")}>
          <it.icon className="h-5 w-5" aria-hidden="true" />
          <span>{SHORT[it.to] ?? it.label}</span>
        </NavLink>
      ))}
      <button type="button" onClick={onMore} aria-expanded={moreOpen} data-testid="bottom-tabs-more"
        className="flex min-h-[56px] flex-1 flex-col items-center justify-center gap-0.5 text-xs font-semibold text-ink-500">
        <MoreHorizontal className="h-5 w-5" aria-hidden="true" />
        <span>المزيد</span>
      </button>
    </nav>
  );
}
