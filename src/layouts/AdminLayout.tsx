import { DemoBanner } from "../components/DemoBanner";
import { Outlet, NavLink, Link, useNavigate } from "react-router-dom";
import { useAuth } from "../lib/auth";
import { cn } from "../lib/utils";
import { adminNav, firstAdminPath } from "../lib/nav";
import { LogOut, Hotel } from "lucide-react";
import { ROLE_LABELS } from "../lib/types";
import { OpsCopilot } from "../components/OpsCopilot";
import { KeyboxAlertBanner } from "../components/KeyboxAlert";
import { useKeyboxAlerts } from "../lib/keyboxAlerts";
import { useReviewSummary } from "../lib/reviewAlerts";
import { ReviewNavCount } from "../components/ReviewBanner";

export default function AdminLayout() {
  const { profile, signOut } = useAuth();
  const navigate = useNavigate();
  // Groups/links come from the role table in lib/nav.ts (the route guard uses the same table); empty groups are hidden.
  const groups = adminNav(profile?.role).map((g) => ({ title: g.title, items: g.items.map((p) => ({ to: p.path, label: p.label, icon: p.icon })) }));
  const adminHome = firstAdminPath(profile?.role) ?? "/staff/dashboard";
  const codeAlerts = useKeyboxAlerts();   // «الرموز»: red until the codes of the units left by guests are changed
  const review = useReviewSummary();       // the owner's «بحاجة لمراجعة وتدقيق»: its count on the link

  async function handleSignOut() {
    await signOut();
    navigate("/staff/login");
  }

  return (
    <div className="flex min-h-screen bg-ink-50">
      <aside className="fixed inset-y-0 right-0 z-20 hidden w-72 flex-col border-l border-ink-100 bg-white lg:flex">
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
      </aside>

      <div className="flex w-full flex-col lg:pr-72">
        <DemoBanner />
        <div className="sticky top-0 z-10">
          <header className="border-b border-ink-100 bg-white/90 px-4 py-3 backdrop-blur lg:hidden">
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
