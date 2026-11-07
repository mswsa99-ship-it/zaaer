import { DemoBanner } from "../components/DemoBanner";
import { useEffect, useRef, useState } from "react";
import { useFocusTrap, useMainFocusOnRoute, useScrollOnRoute, focusMain } from "../lib/useFocusTrap";
import { Outlet, NavLink, useNavigate, Link, useLocation, useNavigationType } from "react-router-dom";
import { useAuth } from "../lib/auth";
import { ROLE_LABELS } from "../lib/types";
import { cn } from "../lib/utils";
import { staffNav, firstAdminPath } from "../lib/nav";
import { LogOut, Hotel, X } from "lucide-react";
import { BottomTabs, pickTabs } from "../components/BottomTabs";
import { OpsCopilot } from "../components/OpsCopilot";
import { KeyboxAlertBanner, KeyboxNavCount } from "../components/KeyboxAlert";
import { useKeyboxAlerts } from "../lib/keyboxAlerts";
import { useOrganizationName } from "../lib/organization";

export default function StaffLayout() {
  const orgName = useOrganizationName();
  const { profile, signOut, can, canFull } = useAuth();
  const allows = { can, canFull };
  const navigate = useNavigate();
  // Links come from the role table in lib/nav.ts (the route guard uses the same table): a role never sees a link it cannot open.
  const nav = staffNav(profile?.role, allows).map((p) => ({ to: p.path, label: p.label, icon: p.icon }));
  const adminHome = firstAdminPath(profile?.role, allows);
  // «الرموز»: units whose key-box code must still change after a guest left — red on every page until changed
  const codeAlerts = useKeyboxAlerts();
  // U3: on a phone, four pages in the bottom bar and the whole menu behind «المزيد»
  const tabs = pickTabs(nav, ["/staff/rooms", "/staff/access-approvals", "/staff/reservations", "/staff/payments"]);
  const [moreOpen, setMoreOpen] = useState(false);
  const location = useLocation();
  useMainFocusOnRoute(location.pathname);
  useScrollOnRoute(location.key, location.pathname, useNavigationType());
  useEffect(() => { setMoreOpen(false); }, [location.pathname]);
  const drawer = useRef<HTMLElement>(null);
  useFocusTrap(moreOpen, drawer, () => setMoreOpen(false));   // A11Y-03: focus in, Tab kept inside, back to «المزيد»

  async function handleSignOut() {
    await signOut();
    navigate("/staff/login");
  }

  return (
    <div className="flex min-h-screen bg-ink-50">
      <a href="#main" onClick={focusMain} className="sr-only z-50 rounded-xl bg-white px-4 py-2 text-sm font-medium text-brand-700 shadow focus:not-sr-only focus:fixed focus:right-4 focus:top-4">تخطَّ إلى المحتوى</a>
      <aside className="fixed inset-y-0 right-0 z-20 hidden w-64 flex-col border-l border-ink-100 bg-white lg:flex">
        <div className="flex items-center gap-2.5 border-b border-ink-100 px-5 py-4">
          <div className="flex h-9 w-9 items-center justify-center rounded-xl bg-brand-600 text-white">
            <Hotel className="h-5 w-5" />
          </div>
          <div className="leading-tight">
            <p className="text-sm font-semibold text-ink-800">{orgName}</p>
            <p className="text-[11px] text-ink-400">مركز العمليات</p>
          </div>
        </div>
        <nav className="flex-1 space-y-1 overflow-y-auto px-3 py-4 scrollbar-thin">
          {nav.map((item) => (
            <NavLink
              key={item.to}
              to={item.to}
              className={({ isActive }) =>
                cn(
                  "flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-medium transition-colors",
                  isActive ? "bg-brand-50 text-brand-700" : "text-ink-600 hover:bg-ink-50 hover:text-ink-800"
                )
              }
            >
              <item.icon className="h-4.5 w-4.5" />
              {item.label}
              {item.to === "/staff/codes" && <KeyboxNavCount alerts={codeAlerts} />}
            </NavLink>
          ))}
        </nav>
        <div className="border-t border-ink-100 p-3">
          {adminHome && (
            <Link to={adminHome} className="block rounded-xl px-3 py-2 text-xs text-ink-400 hover:bg-ink-50 hover:text-ink-600">
              لوحة الإدارة ↗
            </Link>
          )}
          <div className="flex items-center justify-between rounded-xl bg-ink-50 px-3 py-2.5">
            <div className="leading-tight">
              <p className="text-sm font-medium text-ink-700">{profile?.full_name}</p>
              <p className="text-[11px] text-ink-400">{profile ? ROLE_LABELS[profile.role] : ""}</p>
            </div>
            <button onClick={handleSignOut} className="text-ink-400 hover:text-danger-500" title="تسجيل الخروج">
              <LogOut className="h-4 w-4" />
            </button>
          </div>
        </div>
      </aside>

      {/* Mobile top bar */}
      <div className="flex w-full flex-col lg:pr-64">
        <DemoBanner />
        <div className="sticky top-0 z-10">
          {/* phones/tablets only: a compact bar; the pages are in the bottom bar and «المزيد» */}
          <header className="flex items-center gap-2 border-b border-ink-100 bg-white/90 px-3 py-1.5 backdrop-blur lg:hidden">
            <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-brand-600 text-white"><Hotel className="h-4 w-4" aria-hidden="true" /></div>
            <span className="text-sm font-semibold text-ink-800">{orgName}</span>
            {adminHome && <Link to={adminHome} className="mr-auto flex min-h-[44px] items-center rounded-lg px-3 text-xs font-medium text-ink-600 hover:bg-ink-100">الإدارة ↗</Link>}
            <button onClick={handleSignOut} className={cn("flex h-11 w-11 items-center justify-center rounded-lg text-ink-500 hover:bg-ink-100", !adminHome && "mr-auto")} aria-label="تسجيل الخروج">
              <LogOut className="h-4 w-4" />
            </button>
          </header>
        </div>
        {/* IX-03: the code alert scrolls away with the page instead of pinning a tall block on a phone */}
        <KeyboxAlertBanner alerts={codeAlerts} />
        <main id="main" tabIndex={-1} className="flex-1 p-4 pb-36 outline-none lg:p-8 lg:pb-24">{/* bottom room: the floating «مساعد العمليات» button never covers the last control */}
          <Outlet />
        </main>
      </div>
      <OpsCopilot />
      <BottomTabs items={tabs} onMore={() => setMoreOpen(true)} moreOpen={moreOpen} />
      {moreOpen && (
        <div className="fixed inset-0 z-50 lg:hidden" role="dialog" aria-modal="true" aria-label="كل الصفحات">
          <div className="absolute inset-0 bg-ink-900/40" aria-hidden="true" onClick={() => setMoreOpen(false)} />
          <aside ref={drawer} className="absolute inset-y-0 right-0 flex w-[min(20rem,85vw)] flex-col overflow-y-auto bg-white shadow-xl" data-testid="staff-menu-drawer">
            <div className="flex items-center justify-between border-b border-ink-100 px-4 py-3">
              <p className="text-sm font-semibold text-ink-800">كل الصفحات</p>
              <button type="button" onClick={() => setMoreOpen(false)} className="flex h-11 w-11 items-center justify-center rounded-xl text-ink-500 hover:bg-ink-50" aria-label="إغلاق القائمة"><X className="h-5 w-5" /></button>
            </div>
            <nav className="space-y-1 px-3 py-3">
              {nav.map((item) => (
                <NavLink key={item.to} to={item.to}
                  className={({ isActive }) => cn("flex min-h-[44px] items-center gap-3 rounded-xl px-3 text-sm font-medium", isActive ? "bg-brand-50 text-brand-700" : "text-ink-600 hover:bg-ink-50")}>
                  <item.icon className="h-4 w-4" aria-hidden="true" />
                  {item.label}
                  {item.to === "/staff/codes" && <KeyboxNavCount alerts={codeAlerts} />}
                </NavLink>
              ))}
            </nav>
          </aside>
        </div>
      )}
    </div>
  );
}
