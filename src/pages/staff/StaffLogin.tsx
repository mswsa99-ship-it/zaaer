import { useState, useEffect } from "react";
import { roomaiAsset } from "../../lib/brand";
import { useNavigate, Link } from "react-router-dom";
import { LogIn, UserPlus, Mail } from "lucide-react";
import { useAuth, takeSignOutReason } from "../../lib/auth";
import { passwordProblem, PASSWORD_HINT } from "../../lib/password";
import { isDemo } from "../../lib/supabase";
import { homeFor } from "../../lib/nav";
import { ErrorBanner, Spinner } from "../../components/ui";
import { useOrganizationName } from "../../lib/organization";

export default function StaffLogin() {
  const orgName = useOrganizationName();
  const { signIn, signUp, requestPasswordReset, session, profile, isPlatformOperator, loading: authLoading } = useAuth();
  const navigate = useNavigate();
  const [mode, setMode] = useState<"login" | "signup" | "forgot">("login");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [fullName, setFullName] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [revoked, setRevoked] = useState(false);
  useEffect(() => { if (takeSignOutReason() === "revoked") setRevoked(true); }, []);

  useEffect(() => {
    // each role lands where its work starts (housekeeping → tasks, finance → ledger, others → operations board)
    if (!authLoading && session) navigate(isPlatformOperator ? "/platform" : homeFor(profile?.role), { replace: true });
  }, [session, profile, isPlatformOperator, authLoading, navigate]);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setNotice(null);
    setLoading(true);
    if (mode === "login") {
      const { error } = await signIn(email, password);
      if (error) setError(error);
    } else if (mode === "forgot") {
      // 0074: the same answer whether the address has an account or not (nobody learns who works here)
      const { error } = await requestPasswordReset(email);
      if (error) setError(error);
      else setNotice("إن كان هذا البريد مسجّلًا فستصله رسالة فيها رابط لتعيين كلمة مرور جديدة. افتح الرابط وأدخل كلمتك الجديدة (تحقق من الرسائل غير المرغوب فيها).");
    } else {
      const weak = passwordProblem(password);
      if (weak) { setError(weak); setLoading(false); return; }
      if (fullName.trim().length < 3) {
        setError("الرجاء إدخال الاسم الكامل.");
        setLoading(false);
        return;
      }
      const { error, needsConfirmation } = await signUp(email, password, fullName);
      if (error) setError(error);
      else if (needsConfirmation) {
        setNotice(`أُنشئ الحساب. أرسلنا رابط تأكيد إلى ${email} — افتحه من بريدك (وتحقق من الرسائل غير المرغوب فيها)، ثم سجّل الدخول هنا.`);
        setMode("login");
        setPassword("");
      }
    }
    setLoading(false);
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-gradient-to-br from-ink-800 to-brand-800 px-4">
      <div className="w-full max-w-md">
        <div className="mb-6 text-center text-white">
          <img src={roomaiAsset("roomai-logo-reversed.svg")} alt="RoomAI" className="mx-auto mb-3 h-12" />
          <h1 className="text-xl font-bold">بوابة الموظفين</h1>
          <p className="mt-1 text-sm text-white/60">{orgName || "مركز العمليات"}</p>
        </div>

        {isDemo && (
          <div className="card mb-4 p-4">
            <p className="mb-2 text-sm font-semibold text-ink-800">عرض تجريبي — ادخل بدور جاهز (بدون كلمة مرور)</p>
            <div className="grid grid-cols-2 gap-2">
              {[["platform@demo.sa", "مشغّل المنصة (عرض تجريبي)"], ["owner@demo.sa", "المالك — كل الصلاحيات"], ["manager@demo.sa", "مدير الفرع"], ["reception@demo.sa", "مشرف الاستقبال"], ["finance@demo.sa", "المالية"], ["housekeeping@demo.sa", "خدمة الغرف (صلاحيات محدودة)"]].map(([em, label]) => (
                <button key={em} type="button" onClick={async () => { setLoading(true); const { error } = await signIn(em, "demo"); if (error) setError(error); setLoading(false); }} className="btn-outline justify-start text-xs">{label}</button>
              ))}
            </div>
            <p className="mt-2 text-[11px] text-ink-400">جرّب الدخول كـ«خدمة الغرف» لترى كيف تُخفى الصلاحيات المالية ويُرفض تنفيذ ما لا يملكه الدور.</p>
          </div>
        )}
        <div className="card p-6">
          <div className="mb-5 flex gap-2 rounded-xl bg-ink-50 p-1">
            <button onClick={() => setMode("login")} className={`flex-1 rounded-lg py-2 text-sm font-medium ${mode !== "signup" ? "bg-white text-brand-700 shadow-sm" : "text-ink-500"}`}>
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
              <label className="label" htmlFor="staff-email">البريد الإلكتروني</label>
              <input id="staff-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} className="input" dir="ltr" required autoComplete="email" />
            </div>
            {mode !== "forgot" && (
              <div>
                <label className="label" htmlFor="staff-password">كلمة المرور</label>
                <input id="staff-password" type="password" value={password} onChange={(e) => setPassword(e.target.value)} className="input" dir="ltr" required minLength={6}
                  autoComplete={mode === "signup" ? "new-password" : "current-password"} />
                {mode === "signup" && <p className="mt-1 text-xs text-ink-400">{PASSWORD_HINT}</p>}
                {mode === "login" && (
                  <button type="button" onClick={() => { setMode("forgot"); setError(null); setNotice(null); }} className="mt-1.5 text-xs font-medium text-brand-700 hover:underline" data-testid="forgot-password">
                    نسيت كلمة المرور؟
                  </button>
                )}
              </div>
            )}
            {mode === "forgot" && <p className="text-xs text-ink-500">اكتب بريدك المسجّل، وسنرسل إليه رابطًا تعيّن منه كلمة مرور جديدة.</p>}

            {notice && <div role="status" className="rounded-xl border border-success-500/30 bg-success-500/10 px-4 py-3 text-sm text-success-600" data-testid="login-notice">{notice}</div>}
            {revoked && <div role="status" data-testid="revoked-notice" className="rounded-xl border border-warning-500/30 bg-warning-500/10 px-4 py-3 text-sm text-warning-700">أُنهيت جلستك من الإدارة أو أُوقف الحساب. إن كان حسابك فعّالًا فسجّل الدخول من جديد.</div>}
            {error && <ErrorBanner message={error} />}

            <button type="submit" className="btn-primary w-full" disabled={loading}>
              {loading ? <Spinner /> : mode === "login" ? <><LogIn className="h-4 w-4" /> دخول</> : mode === "forgot" ? <><Mail className="h-4 w-4" /> إرسال رابط التعيين</> : <><UserPlus className="h-4 w-4" /> إنشاء حساب</>}
            </button>
            {mode === "forgot" && (
              <button type="button" onClick={() => { setMode("login"); setNotice(null); setError(null); }} className="w-full text-center text-xs text-ink-500 hover:text-ink-700">
                رجوع إلى تسجيل الدخول
              </button>
            )}
          </form>

          {mode === "signup" && (
            <p className="mt-3 text-center text-xs text-ink-400">سجّل بالبريد الذي دعاك به المالك؛ يُربط حسابك بدورك وفروعك تلقائيًا عند أول دخول بعد تأكيد البريد.</p>
          )}
        </div>

        <Link to="/" className="mt-4 block text-center text-xs text-white/80 hover:text-white">→ العودة إلى صفحة النزيل</Link>
      </div>
    </main>
  );
}
