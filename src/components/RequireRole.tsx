/**
 * Route guard by role (GAP08) and by authorised branch (GAP02), rendered INSIDE the layout so the navigation stays
 * usable: a page the role may not open becomes an in-page card — never a redirect loop, never a blank page.
 *
 * Used as a pathless layout route: <Route element={<RequireRole />}> … pages … </Route>, or around a single element.
 * The allow-list lives in src/lib/nav.ts (the same table drives both layouts' navigation).
 * The server keeps enforcing every rule; this is UX and defence in depth.
 */
import type { ReactNode } from "react";
import { Link, Outlet, useLocation } from "react-router-dom";
import { ShieldAlert, Building2, UserX, RefreshCw } from "lucide-react";
import { useAuth } from "../lib/auth";
import { useBranch, NO_BRANCH_MESSAGE } from "../lib/branch";
import { pageFor, pageAllowed } from "../lib/nav";
import { ROLE_LABELS } from "../lib/types";
import { Card, LoadingScreen } from "./ui";

export function RequireRole({ children }: { children?: ReactNode }) {
  const { profile, loading, can, canFull } = useAuth();
  const { pathname } = useLocation();
  const { branches, loading: branchLoading, error: branchError, reload } = useBranch();

  if (loading) return null;

  if (!profile || !profile.is_active) {
    return (
      <GuardCard icon={<UserX className="h-6 w-6" />} title={profile ? "حسابك غير مفعّل" : "لا يوجد ملف موظف مرتبط بحسابك"} description="تواصل مع المدير لتفعيل حسابك قبل استخدام النظام." />
    );
  }

  const page = pageFor(pathname);
  if (!page || !pageAllowed(page, profile.role, { can, canFull })) {
    return (
      <GuardCard
        icon={<ShieldAlert className="h-6 w-6" />}
        title="هذه الصفحة غير متاحة لدورك"
        description={`صلاحيات دورك الحالي (${ROLE_LABELS[profile.role]}) لا تشمل هذه الصفحة. تواصل مع المدير إذا كنت تحتاج الوصول إليها.`}
        action={<Link to="/staff/dashboard" className="btn-outline text-sm">العودة إلى لوحة العمليات</Link>}
      />
    );
  }

  if ((page.scope ?? "branch") === "branch") {
    if (branchLoading) return <LoadingScreen />;
    if (branches.length === 0) {
      const owner = profile.role === "owner";
      return (
        <GuardCard
          icon={<Building2 className="h-6 w-6" />}
          title={NO_BRANCH_MESSAGE}
          description={owner ? "لا يوجد فرع فعال في المنشأة بعد؛ أضف فرعًا من صفحة الفروع ليبدأ العمل." : "لا يمكن عرض بيانات أي فرع قبل ربط حسابك بفرع واحد على الأقل."}
          detail={branchError ? `تعذّر تحميل الفروع المخوّلة: ${branchError}` : undefined}
          action={
            <div className="flex flex-wrap gap-2">
              {owner && <Link to="/admin/branches" className="btn-primary text-sm">إدارة الفروع</Link>}
              <button type="button" onClick={reload} className="btn-outline text-sm"><RefreshCw className="h-4 w-4" /> إعادة المحاولة</button>
            </div>
          }
        />
      );
    }
  }

  return children !== undefined ? <>{children}</> : <Outlet />;
}

function GuardCard({ icon, title, description, detail, action }: { icon: ReactNode; title: string; description: string; detail?: string; action?: ReactNode }) {
  return (
    <div className="mx-auto max-w-xl py-10" role="alert">
      <Card className="flex flex-col items-center gap-3 text-center">
        <div className="flex h-12 w-12 items-center justify-center rounded-xl bg-warning-500/10 text-warning-700">{icon}</div>
        <h2 className="text-lg font-semibold text-ink-800">{title}</h2>
        <p className="max-w-md text-sm text-ink-500">{description}</p>
        {detail && <p className="max-w-md text-xs text-danger-600">{detail}</p>}
        {action && <div className="mt-2">{action}</div>}
      </Card>
    </div>
  );
}
