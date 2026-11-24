import { PRODUCT_NAME, roomaiAsset } from "../lib/brand";
import { DemoBanner } from "../components/DemoBanner";
import { useEffect, useRef, useState } from "react";
import { useFocusTrap, useMainFocusOnRoute, useScrollOnRoute, focusMain } from "../lib/useFocusTrap";
import { useGlobalShortcuts } from "../lib/shortcuts";
import { Outlet, NavLink, useNavigate, Link, useLocation, useNavigationType } from "react-router-dom";
import { useAuth } from "../lib/auth";
import { ROLE_LABELS } from "../lib/types";
import { cn } from "../lib/utils";
import { staffMenu, hubTabs, pageFor, firstAdminPath } from "../lib/nav";
import { LogOut, X, UserCog } from "lucide-react";
import { BottomTabs, pickTabs } from "../components/BottomTabs";
import { OpsCopilot } from "../components/OpsCopilot";
import { KeyboxAlertBanner, KeyboxNavCount } from "../components/KeyboxAlert";
import { useKeyboxAlerts } from "../lib/keyboxAlerts";
import { useOrganizationName } from "../lib/organization";
import { useJourneyAlerts } from "../lib/journeyAlerts";

export default function StaffLayout() {
  const orgName = useOrganizationName();
  const { profile, signOut, can, canFull } = useAuth();
  const allows = { can, canFull };
  const navigate = useNavigate();
  // Links come from the role table in lib/nav.ts (the route guard uses the same table): a role never sees a link it cannot open.
  const nav = staffMenu(profile?.role, allows).map((p) => ({ to: p.path, label: p.label, icon: p.icon, members: p.members }));   // 6.2: centres with tabs, at most 9 links
  const adminHome = firstAdminPath(profile?.role, allows);
  // «الرموز»: units whose key-box code must still change after a guest left — red on every page until changed
  const codeAlerts = useKeyboxAlerts();
  // «رحلة الضيف»: the open alerts of the journey (its clock runs from here every minute)
  const journeyAlerts = useJourneyAlerts();
  // U3: on a phone, four pages in the bottom bar and the whole menu behind «المزيد»
  const tabs = pickTabs(nav, ["/staff/rooms", "/staff/access-approvals", "/staff/reservations", "/staff/payments"]);
  const [moreOpen, setMoreOpen] = useState(false);
  const location = useLocation();
  useMainFocusOnRoute(location.pathname);
  useGlobalShortcuts();   // 6.15
  useScrollOnRoute(location.key, location.pathname, useNavigationType());
  useEffect(() => { setMoreOpen(false); }, [location.pathname]);
  const drawer = useRef<HTMLElement>(null);
  useFocusTrap(moreOpen, drawer, () => setMoreOpen(false));   // A11Y-03: focus in, Tab kept inside, back to «المزيد»

  async function handleSignOut() {
    await signOut();
    navigate("/staff/login");
  }

  return (
    <div className={cn("flex min-h-screen bg-ink-50", location.pathname === "/staff/dashboard" && "ops-center-shell")}>
      <a href="#main" onClick={focusMain} className="sr-only z-50 rounded-xl bg-white px-4 py-2 text-sm font-medium text-brand-700 shadow focus:not-sr-only focus:fixed focus:right-4 focus:top-4">تخطَّ إلى المحتوى</a>
      <aside className="fixed inset-y-0 right-0 z-20 hidden w-64 flex-col border-l border-ink-100 bg-white lg:flex">
        <div className="flex items-center gap-2.5 border-b border-ink-100 px-5 py-4">
          <img src={roomaiAsset("roomai-mark.svg")} alt="RoomAI" className="h-9 w-9" />
          <div className="leading-tight">
            <p className="text-sm font-semibold text-ink-800">{PRODUCT_NAME}</p>
            <p className="text-[11px] text-ink-400">{orgName || "مركز العمليات"}</p>
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
                  (isActive || item.members?.includes(location.pathname)) ? "bg-brand-50 text-brand-700" : "text-ink-600 hover:bg-ink-50 hover:text-ink-800"
                )
              }
            >
              <item.icon className="h-4.5 w-4.5" />
              {item.label}
              {item.to === "/staff/codes" && <KeyboxNavCount alerts={codeAlerts} />}
              {!!item.members?.includes("/staff/journey") && !!journeyAlerts && <span className="mr-auto inline-flex min-w-[1.25rem] items-center justify-center rounded-full bg-danger-500 px-1.5 text-[11px] font-semibold leading-5 text-white" aria-label={`${journeyAlerts} تنبيهات مفتوحة`}>{journeyAlerts}</span>}
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
            <div className="min-w-0 leading-tight">
              <p className="truncate text-sm font-medium text-ink-700">{profile?.full_name}</p>
              <p className="text-[11px] text-ink-400">{profile ? ROLE_LABELS[profile.role] : ""}</p>
            </div>
            {/* 0074: «حسابي» — the password, the e-mailed link and the devices (its own short name, not the person's) */}
            <Link to="/staff/account" className="mr-auto ml-2 shrink-0 rounded-lg px-2 py-1 text-[11px] font-medium text-brand-700 hover:bg-white" title="كلمة المرور والأجهزة" data-testid="my-account-link">حسابي</Link>
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
            <img src={roomaiAsset("roomai-mark.svg")} alt="" className="h-8 w-8" />
            <span className="text-sm font-semibold text-ink-800">{PRODUCT_NAME}</span>
            {adminHome && <Link to={adminHome} className="mr-auto flex min-h-[44px] items-center rounded-lg px-3 text-xs font-medium text-ink-600 hover:bg-ink-100">الإدارة ↗</Link>}
            <Link to="/staff/account" className={cn("flex h-11 w-11 items-center justify-center rounded-lg text-ink-500 hover:bg-ink-100", !adminHome && "mr-auto")} aria-label="حسابي" data-testid="my-account-link-phone"><UserCog className="h-4 w-4" aria-hidden="true" /></Link>
            <button onClick={handleSignOut} className="flex h-11 w-11 items-center justify-center rounded-lg text-ink-500 hover:bg-ink-100" aria-label="تسجيل الخروج">
              <LogOut className="h-4 w-4" />
            </button>
          </header>
        </div>
        {/* IX-03: the code alert scrolls away with the page instead of pinning a tall block on a phone */}
        <KeyboxAlertBanner alerts={codeAlerts} />
        <main id="main" tabIndex={-1} className="flex-1 p-4 pb-36 outline-none lg:p-8 lg:pb-24">{/* bottom room: the floating «مساعد العمليات» button never covers the last control */}
          {(() => {
            const hub = pageFor(location.pathname)?.hub;
            const tabsOf = hub ? hubTabs(hub, profile?.role, allows) : [];
            return tabsOf.length > 1 ? (
              <nav aria-label="تبويبات المركز" data-testid="hub-tabs" className="mb-4 flex gap-1 overflow-x-auto border-b border-ink-100">
                {tabsOf.map((t) => (
                  <NavLink key={t.path} to={t.path} className={({ isActive }) => cn("flex min-h-[44px] shrink-0 items-center gap-1.5 border-b-2 px-3 text-sm font-medium", isActive ? "border-brand-600 text-brand-700" : "border-transparent text-ink-600 hover:text-ink-800")}>
                    {t.label}
                    {t.path === "/staff/journey" && !!journeyAlerts && <span className="inline-flex min-w-[1.25rem] items-center justify-center rounded-full bg-danger-500 px-1.5 text-[11px] font-semibold leading-5 text-white" aria-label={`${journeyAlerts} تنبيهات مفتوحة`}>{journeyAlerts}</span>}
                  </NavLink>
                ))}
              </nav>
            ) : null;
          })()}
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
                  className={({ isActive }) => cn("flex min-h-[44px] items-center gap-3 rounded-xl px-3 text-sm font-medium", (isActive || item.members?.includes(location.pathname)) ? "bg-brand-50 text-brand-700" : "text-ink-600 hover:bg-ink-50")}>
                  <item.icon className="h-4 w-4" aria-hidden="true" />
                  {item.label}
                  {item.to === "/staff/codes" && <KeyboxNavCount alerts={codeAlerts} />}
                  {!!item.members?.includes("/staff/journey") && !!journeyAlerts && <span className="mr-auto inline-flex min-w-[1.25rem] items-center justify-center rounded-full bg-danger-500 px-1.5 text-[11px] font-semibold leading-5 text-white" aria-label={`${journeyAlerts} تنبيهات مفتوحة`}>{journeyAlerts}</span>}
                </NavLink>
              ))}
            </nav>
          </aside>
        </div>
      )}
    </div>
  );
}
