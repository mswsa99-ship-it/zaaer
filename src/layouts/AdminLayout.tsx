import { DemoBanner } from "../components/DemoBanner";
import { useEffect, useState } from "react";
import { Outlet, NavLink, Link, useNavigate, useLocation } from "react-router-dom";
import { useAuth } from "../lib/auth";
import { cn } from "../lib/utils";
import { adminNav, firstAdminPath } from "../lib/nav";
import { LogOut, Hotel, Menu, X } from "lucide-react";
import { ROLE_LABELS } from "../lib/types";
import { OpsCopilot } from "../components/OpsCopilot";
import { KeyboxAlertBanner } from "../components/KeyboxAlert";
import { useKeyboxAlerts } from "../lib/keyboxAlerts";
import { useReviewSummary } from "../lib/reviewAlerts";
import { ReviewNavCount } from "../components/ReviewBanner";

export default function AdminLayout() {
  const { profile, signOut, can, canFull } = useAuth();
  const allows = { can, canFull };
  const navigate = useNavigate();
  // Groups/links come from the role table in lib/nav.ts (the route guard uses the same table); empty groups are hidden.
  const groups = adminNav(profile?.role, allows).map((g) => ({ title: g.title, items: g.items.map((p) => ({ to: p.path, label: p.label, icon: p.icon })) }));
  const adminHome = firstAdminPath(profile?.role, allows) ?? "/staff/dashboard";
  const codeAlerts = useKeyboxAlerts();   // «الرموز»: red until the codes of the units left by guests are changed
  const review = useReviewSummary();       // the owner's «بحاجة لمراجعة وتدقيق»: its count on the link

  // phones and tablets: the same menu opens as a drawer (it was missing below the desktop width)
  const [menuOpen, setMenuOpen] = useState(false);
  const location = useLocation();
  useEffect(() => { setMenuOpen(false); }, [location.pathname]);
  useEffect(() => {
    if (!menuOpen) return;
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") setMenuOpen(false); };
    document.addEventListener("keydown", key);
    return () => document.removeEventListener("keydown", key);
  }, [menuOpen]);

  async function handleSignOut() {
    await signOut();
    navigate("/staff/login");
  }

  const menu = (
    <>
        <div className="flex items-center gap-2.5 border-b border-ink-100 px-5 py-4">
          <div className="flex h-9 w-9 items-center justify-center rounded-xl bg-ink-800 text-white">
            <Hotel className="h-5 w-5" />
          </div>
          <div className="leading-tight">
            <p className="text-sm font-semibold text-ink-800">فايف اورز</p>
            <p className="text-[11px] text-ink-400">لوحة الإدارة</p>
          </div>
        </div>
        <nav className="flex-1 space-y-4 overflow-y-auto px-3 py-4 scrollbar-thin">
          {groups.map((g) => (
            <div key={g.title}>
              <p className="px-3 pb-1.5 text-[11px] font-semibold uppercase tracking-wide text-ink-300">{g.title}</p>
              <div className="space-y-0.5">
                {g.items.map((item) => (
                  <NavLink
                    key={item.to}
                    to={item.to}
                    className={({ isActive }) =>
                      cn(
                        "flex items-center gap-3 rounded-xl px-3 py-2 text-sm font-medium transition-colors",
                        isActive ? "bg-ink-800 text-white" : "text-ink-600 hover:bg-ink-50 hover:text-ink-800"
                      )
                    }
                  >
                    <item.icon className="h-4 w-4" />
                    {item.label}
                    {item.to === "/admin/review" && <ReviewNavCount summary={review} />}
                  </NavLink>
                ))}
              </div>
            </div>
          ))}
        </nav>
        <div className="border-t border-ink-100 p-3">
          <Link to="/staff/dashboard" className="block rounded-xl px-3 py-2 text-xs text-ink-400 hover:bg-ink-50 hover:text-ink-600">
            ← مركز عمليات المشرف
          </Link>
          <div className="mt-1 flex items-center justify-between rounded-xl bg-ink-50 px-3 py-2.5">
            <div className="leading-tight">
              <p className="text-sm font-medium text-ink-700">{profile?.full_name}</p>
              <p className="text-[11px] text-ink-400">{profile ? ROLE_LABELS[profile.role] : ""}</p>
            </div>
            <button onClick={handleSignOut} className="text-ink-400 hover:text-danger-500" title="تسجيل الخروج" aria-label="تسجيل الخروج">
              <LogOut className="h-4 w-4" />
            </button>
          </div>
        </div>
    </>
  );

  return (
    <div className="flex min-h-screen bg-ink-50">
      <aside className="fixed inset-y-0 right-0 z-20 hidden w-72 flex-col border-l border-ink-100 bg-white lg:flex">{menu}</aside>
      {menuOpen && (
        <div className="fixed inset-0 z-40 lg:hidden" role="dialog" aria-modal="true" aria-label="قائمة الإدارة">
          <button type="button" className="absolute inset-0 bg-ink-900/40" aria-label="إغلاق القائمة" onClick={() => setMenuOpen(false)} />
          <aside className="absolute inset-y-0 right-0 flex w-[min(20rem,85vw)] flex-col bg-white shadow-xl" data-testid="admin-menu-drawer">
            <button type="button" onClick={() => setMenuOpen(false)} className="absolute left-2 top-3 flex h-11 w-11 items-center justify-center rounded-xl text-ink-500 hover:bg-ink-50" aria-label="إغلاق القائمة"><X className="h-5 w-5" /></button>
            {menu}
          </aside>
        </div>
      )}

      <div className="flex w-full flex-col lg:pr-72">
        <DemoBanner />
        <div className="sticky top-0 z-10">
          <header className="flex items-center gap-2 border-b border-ink-100 bg-white/90 px-2 py-1.5 backdrop-blur lg:hidden">
            <button type="button" onClick={() => setMenuOpen(true)} className="flex min-h-[44px] items-center gap-2 rounded-xl px-3 text-sm font-medium text-ink-700 hover:bg-ink-50" aria-expanded={menuOpen} data-testid="admin-menu-button">
              <Menu className="h-5 w-5" /> القائمة
            </button>
            <Link to={adminHome} className="text-sm font-semibold text-ink-800">لوحة الإدارة — فايف اورز</Link>
          </header>
          <KeyboxAlertBanner alerts={codeAlerts} />
        </div>
        <main className="flex-1 p-4 pb-24 lg:p-8 lg:pb-24">{/* bottom room: the floating «مساعد العمليات» button never covers the last control */}
          <Outlet />
        </main>
      </div>
      <OpsCopilot />
    </div>
  );
}
