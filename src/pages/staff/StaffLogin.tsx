import { useState, useEffect } from "react";
import { useNavigate, Link } from "react-router-dom";
import { Hotel, LogIn, UserPlus } from "lucide-react";
import { useAuth } from "../../lib/auth";
import { isDemo } from "../../lib/supabase";
import { homeFor } from "../../lib/nav";
import { ErrorBanner, Spinner } from "../../components/ui";

export default function StaffLogin() {
  const { signIn, signUp, session, profile, loading: authLoading } = useAuth();
  const navigate = useNavigate();
  const [mode, setMode] = useState<"login" | "signup">("login");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [fullName, setFullName] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    // each role lands where its work starts (housekeeping → tasks, finance → ledger, others → operations board)
    if (!authLoading && session) navigate(homeFor(profile?.role), { replace: true });
  }, [session, profile, authLoading, navigate]);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    if (mode === "login") {
      const { error } = await signIn(email, password);
      if (error) setError(error);
    } else {
      if (fullName.trim().length < 3) {
        setError("الرجاء إدخال الاسم الكامل.");
        setLoading(false);
        return;
      }
      const { error } = await signUp(email, password, fullName);
      if (error) setError(error);
      else setError(null);
    }
    setLoading(false);
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-gradient-to-br from-ink-800 to-brand-800 px-4">
      <div className="w-full max-w-md">
        <div className="mb-6 text-center text-white">
          <div className="mx-auto mb-3 flex h-14 w-14 items-center justify-center rounded-2xl bg-white/15">
            <Hotel className="h-7 w-7" />
          </div>
          <h1 className="text-xl font-bold">منازل الراحة — بوابة الموظفين</h1>
          <p className="mt-1 text-sm text-white/60">مركز عمليات الاستقبال</p>
        </div>

        {isDemo && (
          <div className="card mb-4 p-4">
            <p className="mb-2 text-sm font-semibold text-ink-800">عرض تجريبي — ادخل بدور جاهز (بدون كلمة مرور)</p>
            <div className="grid grid-cols-2 gap-2">
              {[["owner@demo.sa", "المالك — كل الصلاحيات"], ["manager@demo.sa", "مدير الفرع"], ["reception@demo.sa", "مشرف الاستقبال"], ["finance@demo.sa", "المالية"], ["housekeeping@demo.sa", "خدمة الغرف (صلاحيات محدودة)"]].map(([em, label]) => (
                <button key={em} type="button" onClick={async () => { setLoading(true); const { error } = await signIn(em, "demo"); if (error) setError(error); setLoading(false); }} className="btn-outline justify-start text-xs">{label}</button>
              ))}
            </div>
            <p className="mt-2 text-[11px] text-ink-400">جرّب الدخول كـ«خدمة الغرف» لترى كيف تُخفى الصلاحيات المالية ويُرفض تنفيذ ما لا يملكه الدور.</p>
          </div>
        )}
        <div className="card p-6">
          <div className="mb-5 flex gap-2 rounded-xl bg-ink-50 p-1">
            <button onClick={() => setMode("login")} className={`flex-1 rounded-lg py-2 text-sm font-medium ${mode === "login" ? "bg-white text-brand-700 shadow-sm" : "text-ink-500"}`}>
              تسجيل الدخول
            </button>
            <button onClick={() => setMode("signup")} className={`flex-1 rounded-lg py-2 text-sm font-medium ${mode === "signup" ? "bg-white text-brand-700 shadow-sm" : "text-ink-500"}`}>
              حساب جديد
            </button>
          </div>

          <form onSubmit={handleSubmit} className="space-y-4">
            {mode === "signup" && (
              <div>
                <label className="label">الاسم الكامل</label>
                <input value={fullName} onChange={(e) => setFullName(e.target.value)} className="input" placeholder="الاسم الثلاثي" />
              </div>
            )}
            <div>
              <label className="label">البريد الإلكتروني</label>
              <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} className="input" dir="ltr" required />
            </div>
            <div>
              <label className="label">كلمة المرور</label>
              <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} className="input" dir="ltr" required minLength={6} />
            </div>

            {error && <ErrorBanner message={error} />}

            <button type="submit" className="btn-primary w-full" disabled={loading}>
              {loading ? <Spinner /> : mode === "login" ? <><LogIn className="h-4 w-4" /> دخول</> : <><UserPlus className="h-4 w-4" /> إنشاء حساب</>}
            </button>
          </form>

          {mode === "signup" && (
            <p className="mt-3 text-center text-xs text-ink-400">يُنشأ حسابك بصلاحية مالك للمنشأة التجريبية تلقائيًا.</p>
          )}
        </div>

        <Link to="/" className="mt-4 block text-center text-xs text-white/50 hover:text-white">← العودة لصفحة النزيل</Link>
      </div>
    </div>
  );
}
