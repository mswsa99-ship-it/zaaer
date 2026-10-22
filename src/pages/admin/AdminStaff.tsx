import { useEffect, useState, useCallback } from "react";
import { supabase } from "../../lib/supabase";
import { staffApi, toArabicError } from "../../lib/api";
import { useAuth } from "../../lib/auth";
import { useBranch } from "../../lib/branch";
import { SectionTitle, LoadingScreen, Card, EmptyState, Badge, Spinner, ErrorBanner } from "../../components/ui";
import { UserCog, UserPlus } from "lucide-react";
import { ROLE_LABELS } from "../../lib/types";

interface StaffRow {
  id: string; full_name: string; email: string; role: string; is_active: boolean; auth_user_id: string | null;
}

const INVITE_ROLES = ["owner", "manager", "supervisor", "finance", "housekeeping"] as const;

export default function AdminStaff() {
  const { profile } = useAuth();
  const isOwner = profile?.role === "owner";
  const { branches } = useBranch();
  const [staff, setStaff] = useState<StaffRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [acting, setActing] = useState<string | null>(null);

  // invite form
  const [email, setEmail] = useState("");
  const [fullName, setFullName] = useState("");
  const [role, setRole] = useState<string>("supervisor");
  const [branchIds, setBranchIds] = useState<string[]>([]);
  const [inviting, setInviting] = useState(false);
  const [invited, setInvited] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data, error: e } = await supabase.from("staff_profiles").select("id, full_name, email, role, is_active, auth_user_id").order("full_name");
    if (e) setError(toArabicError(e));
    setStaff((data as StaffRow[]) ?? []);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  async function toggleActive(s: StaffRow) {
    if (!isOwner) return;
    setActing(s.id); setError(null);
    const { error: e } = await supabase.from("staff_profiles").update({ is_active: !s.is_active }).eq("id", s.id);
    if (e) setError(toArabicError(e));
    await load();
    setActing(null);
  }

  async function invite() {
    setError(null); setInvited(null);
    if (!email.trim() || !fullName.trim()) { setError("البريد والاسم مطلوبان."); return; }
    setInviting(true);
    try {
      await staffApi.invite(email.trim(), fullName.trim(), role, branchIds);
      setInvited(email.trim());
      setEmail(""); setFullName(""); setBranchIds([]);
      await load();
    } catch (e) { setError(toArabicError(e)); }
    setInviting(false);
  }

  if (loading) return <LoadingScreen />;

  return (
    <div>
      <SectionTitle title="الموظفون" subtitle={`${staff.length} موظف`} />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}

      {isOwner && (
        <Card className="mb-5">
          <h3 className="mb-3 flex items-center gap-2 text-sm font-semibold text-ink-700"><UserPlus className="h-4 w-4 text-brand-600" /> دعوة موظف</h3>
          <p className="mb-3 text-xs text-ink-400">يُنشأ ملف الموظف الآن ويرتبط تلقائيًا بحسابه عند أول تسجيل دخول بنفس البريد. لا يمكن للموظف اختيار دوره بنفسه.</p>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <div><label className="label">البريد الإلكتروني</label><input className="input" dir="ltr" type="email" value={email} onChange={(e) => setEmail(e.target.value)} /></div>
            <div><label className="label">الاسم الكامل</label><input className="input" value={fullName} onChange={(e) => setFullName(e.target.value)} /></div>
            <div>
              <label className="label">الدور</label>
              <select className="input" value={role} onChange={(e) => setRole(e.target.value)}>
                {INVITE_ROLES.map((r) => <option key={r} value={r}>{ROLE_LABELS[r]}</option>)}
              </select>
            </div>
            <div>
              <label className="label">الفروع</label>
              <div className="flex flex-wrap gap-2 rounded-xl border border-ink-100 p-2">
                {branches.map((b) => (
                  <label key={b.id} className="flex items-center gap-1.5 text-xs text-ink-700">
                    <input type="checkbox" className="accent-brand-600" checked={branchIds.includes(b.id)} onChange={(e) => setBranchIds((ids) => e.target.checked ? [...ids, b.id] : ids.filter((x) => x !== b.id))} />
                    {b.name_ar}
                  </label>
                ))}
                {branches.length === 0 && <span className="text-xs text-ink-300">لا توجد فروع</span>}
              </div>
            </div>
          </div>
          <div className="mt-3 flex items-center gap-3">
            <button onClick={invite} disabled={inviting} className="btn-primary text-sm">{inviting ? <Spinner className="h-4 w-4" /> : "إرسال الدعوة"}</button>
            {invited && <Badge className="bg-success-500/10 text-success-600">تمت دعوة {invited}</Badge>}
          </div>
        </Card>
      )}

      {staff.length === 0 ? (
        <EmptyState icon={<UserCog className="h-10 w-10" />} title="لا يوجد موظفون" />
      ) : (
        <div className="grid gap-3 sm:grid-cols-2">
          {staff.map((s) => (
            <Card key={s.id} className="flex items-center justify-between">
              <div>
                <p className="text-sm font-semibold text-ink-800">{s.full_name}</p>
                <p className="text-xs text-ink-400" dir="ltr">{s.email}</p>
                <div className="mt-1 flex gap-1">
                  <Badge className={s.auth_user_id ? "bg-success-500/10 text-success-600" : "bg-warning-500/10 text-warning-600"}>{s.auth_user_id ? "مرتبط" : "بانتظار تسجيل الدخول"}</Badge>
                </div>
              </div>
              <div className="flex flex-col items-end gap-1">
                <Badge className="bg-brand-50 text-brand-700">{ROLE_LABELS[s.role as keyof typeof ROLE_LABELS] ?? s.role}</Badge>
                <Badge className={s.is_active ? "bg-success-500/10 text-success-600" : "bg-ink-100 text-ink-400"}>{s.is_active ? "نشط" : "موقوف"}</Badge>
                {isOwner && s.id !== profile?.id && (
                  <button onClick={() => toggleActive(s)} disabled={acting === s.id} className="text-xs text-brand-600 hover:underline">
                    {acting === s.id ? <Spinner className="h-3 w-3" /> : s.is_active ? "إيقاف" : "تفعيل"}
                  </button>
                )}
              </div>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}
