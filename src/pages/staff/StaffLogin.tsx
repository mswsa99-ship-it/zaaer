import "./StaffLogin.typography.css";
import "./StaffLogin.contrast.css";
import OwnerRegister from "./OwnerRegister";
import { useState, useEffect } from "react";
import { roomaiAsset } from "../../lib/brand";
import { useNavigate, useSearchParams, Link } from "react-router-dom";
import { LogIn, Mail } from "lucide-react";
import { useAuth, takeSignOutReason } from "../../lib/auth";
import { isDemo } from "../../lib/supabase";
import { loginDestination } from "../../lib/loginRouting";
import { ErrorBanner, Spinner } from "../../components/ui";
import { useOrganizationName } from "../../lib/organization";

export default function StaffLogin({ entry = "hotel" }: { entry?: "hotel" | "platform" }) {
  const orgName = useOrganizationName();
  const { signIn, requestPasswordReset, session, profile, isPlatformOperator, identityError, can, canFull, refreshProfile, signOut, loading: authLoading } = useAuth();
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const returnTo = searchParams.get("returnTo");
  const [mode, setMode] = useState<"login" | "forgot" | "register">("login");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [revoked, setRevoked] = useState(false);
  useEffect(() => { if (takeSignOutReason() === "revoked") setRevoked(true); }, []);

  useEffect(() => {
    const target = loginDestination({ loading: authLoading, hasSession: !!session, error: identityError, operator: isPlatformOperator, profile, allows: { can, canFull }, entry, returnTo });
    if (target && !(mode === "register" && !profile)) navigate(target, { replace: true });
  }, [session, profile, isPlatformOperator, identityError, can, canFull, authLoading, entry, returnTo, navigate, mode]);


  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setNotice(null);
    setLoading(true);
    if (mode === "register") { setLoading(false); return; }
    if (mode === "login") {
      const { error } = await signIn(email, password);
      if (error) setError(error);
    } else if (mode === "forgot") {
      // 0074: the same answer whether the address has an account or not (nobody learns who works here)
      const { error } = await requestPasswordReset(email);
      if (error) setError(error);
      else setNotice("إن كان هذا البريد مسجّلًا فستصله رسالة فيها رابط لتعيين كلمة مرور جديدة. افتح الرابط وأدخل كلمتك الجديدة (تحقق من الرسائل غير المرغوب فيها).");
    }
    setLoading(false);
  }

  return (
    <main className="login-type-midpoint flex min-h-screen items-center justify-center bg-gradient-to-br from-ink-800 to-brand-800 px-4">
      <div className={`w-full ${mode === "register" ? "max-w-2xl py-8" : "max-w-md"}`}>
        <div className="mb-6 text-center text-white">
          <img src={roomaiAsset("roomai-logo-reversed.svg")} alt="RoomAI" className="mx-auto mb-3 h-12" />
          <h1 className="text-xl font-bold">{entry === "platform" ? "دخول مشغّل المنصة" : "تسجيل الدخول"}</h1>
          <p className="mt-1 text-sm text-white/60">{orgName || "RoomAI"}</p>
        </div>

        {session && !authLoading && (identityError || (profile && !profile.is_active) || profile?.role === "guest" || (entry === "hotel" ? isPlatformOperator : !isPlatformOperator)) ? (
          <div className="card mb-4 space-y-3 p-4" role="alert" data-testid="identity-blocked">
            <p>{identityError || "هذا الحساب غير مخوّل لهذا المدخل. استخدم المدخل المخصص لحسابك."}</p>
            <button className="btn-primary" onClick={() => void refreshProfile()}>إعادة المحاولة</button>
            <button className="btn-outline" onClick={() => void signOut()}>تسجيل الخروج</button>
          </div>
        ) : null}
        {isDemo && mode !== "register" && (
          <div className="card mb-4 p-4">
            <p className="mb-2 text-sm font-semibold text-ink-800">عرض تجريبي — ادخل بدور جاهز (بدون كلمة مرور)</p>
            <div className="grid grid-cols-2 gap-2">
              {[["platform@demo.sa", "مشغّل المنصة (عرض تجريبي)"], ["owner@demo.sa", "المالك — كل الصلاحيات"], ["manager@demo.sa", "مدير الفرع"], ["reception@demo.sa", "مشرف الاستقبال"], ["finance@demo.sa", "المالية"], ["housekeeping@demo.sa", "خدمة الغرف (صلاحيات محدودة)"]].filter(([em]) => entry === "platform" ? em === "platform@demo.sa" : em !== "platform@demo.sa").map(([em, label]) => (
                <button key={em} type="button" onClick={async () => { setLoading(true); const { error } = await signIn(em, "demo"); if (error) setError(error); setLoading(false); }} className="btn-outline justify-start text-xs">{label}</button>
              ))}
            </div>
            <p className="mt-2 text-[11px] text-ink-400">جرّب الدخول كـ«خدمة الغرف» لترى كيف تُخفى الصلاحيات المالية ويُرفض تنفيذ ما لا يملكه الدور.</p>
          </div>
        )}
        <div className="card p-6">
          <p className="mb-4 text-center text-sm text-ink-500">{entry === "platform" ? "مدخل مستقل للحسابات التقنية المخوّلة فقط." : mode === "register" ? "التسجيل الجديد فقط متاح للملاك أو مسؤول الفندق." : "للحسابات الحالية: المالك والإدارة والموظفون."}</p>
          <div className="mb-5 flex gap-2 rounded-xl bg-ink-50 p-1">
            <button onClick={() => setMode("login")} className={`flex-1 rounded-lg py-2 text-sm font-medium ${mode !== "register" ? "bg-white text-brand-700 shadow-sm" : "text-ink-500"}`}>
              تسجيل الدخول
            </button>
            {entry === "hotel" && <button onClick={() => { setPassword(""); setMode("register"); setNotice(null); setError(null); }} className={`flex-1 rounded-lg py-2 text-sm font-medium ${mode === "register" ? "bg-white text-brand-700 shadow-sm" : "text-ink-500"}`}>
              تسجيل جديد
            </button>}
          </div>

          {mode === "register" ? <OwnerRegister embedded onLogin={() => setMode("login")} /> : <form onSubmit={handleSubmit} className="space-y-4">
            <div>
              <label className="label" htmlFor="staff-email">البريد الإلكتروني</label>
              <input id="staff-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} className="input" dir="ltr" required autoComplete="email" />
            </div>
            {mode !== "forgot" && (
              <div>
                <label className="label" htmlFor="staff-password">كلمة المرور</label>
                <input id="staff-password" type="password" value={password} onChange={(e) => setPassword(e.target.value)} className="input" dir="ltr" required minLength={6}
                  autoComplete="current-password" />
                {(
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
              {loading ? <Spinner /> : mode !== "forgot" ? <><LogIn className="h-4 w-4" /> دخول</> : <><Mail className="h-4 w-4" /> إرسال رابط التعيين</>}
            </button>
            {mode === "forgot" && (
              <button type="button" onClick={() => { setMode("login"); setNotice(null); setError(null); }} className="w-full text-center text-xs text-ink-500 hover:text-ink-700">
                رجوع إلى تسجيل الدخول
              </button>
            )}
          </form>}


        </div>

        {entry === "platform" && <Link to="/login" className="mt-4 block text-center text-xs text-white/80 hover:text-white">العودة إلى دخول الفندق</Link>}
      </div>
    </main>
  );
}
