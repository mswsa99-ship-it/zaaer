/**
 * The «الإدارة» entry of the one-app menu: a single top-level button that opens the admin groups, each group a button
 * that opens its pages. Presentation only; the pages and who sees them come from lib/nav.ts (same rules as before).
 */
import { useEffect, useState } from "react";
import { NavLink, useLocation } from "react-router-dom";
import { ChevronDown, Settings2 } from "lucide-react";
import { cn } from "../lib/utils";
import type { MenuGroup } from "../lib/nav";

export function AdminMenuGroups({ groups, compact, idPrefix }: { groups: MenuGroup[]; compact?: boolean; idPrefix: string }) {
  const { pathname } = useLocation();
  const currentGroup = groups.find((g) => g.items.some((p) => pathname === p.path || pathname.startsWith(p.path + "/")))?.title ?? null;
  const [open, setOpen] = useState(!!currentGroup);
  const [openGroup, setOpenGroup] = useState<string | null>(currentGroup);
  useEffect(() => { if (currentGroup) { setOpen(true); setOpenGroup(currentGroup); } }, [currentGroup]);
  if (groups.length === 0) return null;
  const row = cn("flex w-full items-center gap-3 rounded-xl px-3 text-sm font-medium", compact ? "min-h-[44px]" : "py-2.5");
  return (
    <div data-testid="admin-menu-groups">
      <button type="button" aria-expanded={open} aria-controls={`${idPrefix}-admin`} onClick={() => setOpen((v) => !v)} data-testid="admin-menu-toggle"
        className={cn(row, currentGroup ? "bg-rai-spark-tint text-rai-spark-text" : "text-rai-ink hover:bg-rai-surface-sunken")}>
        <Settings2 className="h-4 w-4" aria-hidden="true" />
        <span>الإدارة</span>
        <ChevronDown className={cn("mr-auto h-4 w-4 transition-transform", open && "rotate-180")} aria-hidden="true" />
      </button>
      {open && (
        <div id={`${idPrefix}-admin`} className="mr-3 mt-1 space-y-1 border-r border-rai-line pr-2">
          {groups.map((g) => {
            const gid = `${idPrefix}-g-${groups.indexOf(g)}`;
            const isOpen = openGroup === g.title;
            return (
              <div key={g.title}>
                <button type="button" aria-expanded={isOpen} aria-controls={gid} onClick={() => setOpenGroup(isOpen ? null : g.title)}
                  className={cn(row, "text-xs text-rai-ink-muted hover:bg-rai-surface-sunken")}>
                  <span>{g.title}</span>
                  <ChevronDown className={cn("mr-auto h-3.5 w-3.5 transition-transform", isOpen && "rotate-180")} aria-hidden="true" />
                </button>
                {isOpen && (
                  <div id={gid} className="space-y-0.5">
                    {g.items.map((p) => (
                      <NavLink key={p.path} to={p.path}
                        className={({ isActive }) => cn(row, "text-sm", isActive ? "bg-rai-spark-tint text-rai-spark-text" : "text-rai-ink hover:bg-rai-surface-sunken")}>
                        <p.icon className="h-4 w-4 shrink-0" aria-hidden="true" />
                        <span>{p.label}</span>
                      </NavLink>
                    ))}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
