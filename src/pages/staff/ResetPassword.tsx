/**
 * «تعيين كلمة المرور» (0074): the page every e-mailed link opens — the forgotten password, the change of password from
 * «حسابي» or from a colleague's reset, and the owner's invitation. Supabase Auth reads the link's token and opens a
 * session; here the person chooses their new password (the rule in lib/password.ts), and the other devices are signed
 * out. An expired or used link says so and offers a new one. Without a session (the page opened by hand) it leads
 * back to «نسيت كلمة المرور».
 */
import { useEffect, useMemo, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { KeyRound, CheckCircle2 } from "lucide-react";
import { useAuth } from "../../lib/auth";
import { homeFor } from "../../lib/nav";
import { newPasswordProblem, PASSWORD_HINT } from "../../lib/password";
import { ErrorBanner, Spinner } from "../../components/ui";

/** The link's own error (Supabase puts it in the address: #error=…&error_code=otp_expired&…), if any. */
function linkError(): string | null {
  try {
    // the link's fragment is the address's last «#…» holding «=» (the demo's own route is a «#/…» without one)
    const raw = window.location.hash;
    const frag = raw.slice(raw.lastIndexOf("#") + 1);
    const h = new URLSearchParams(frag.includes("=") ? frag : "");
    const q = new URLSearchParams(window.location.search);
    const code = h.get("error_code") ?? q.get("error_code") ?? h.get("error") ?? q.get("error");
    return code;
  } catch { return null; }
}

export default function ResetPassword() {
  const { session, profile, loading, updatePassword } = useAuth();
  const navigate = useNavigate();
  const [pw, setPw] = useState("");
  const [confirm, setConfirm] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);
  const badLink = useMemo(linkError, []);
  // a session may arrive a moment after the page (the token in the address is read by the auth client)
  const [waited, setWaited] = useState(false);
  useEffect(() => { const t = setTimeout(() => setWaited(true), 2500); return () => clearTimeout(t); }, []);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    const problem = newPasswordProblem(pw, confirm);
    if (problem) { setError(problem); return; }
    setSaving(true);
    const { error } = await updatePassword(pw);
    setSaving(false);
    if (error) { setError(error); return; }
    setDone(true);
    setPw(""); setConfirm("");
  }

  const shell = (body: React.ReactNode) => (
    <main className="flex min-h-screen items-center justify-center bg-rai-canvas text-rai-ink px-4">
      <div className="w-full max-w-md">
        <div className="mb-6 text-center text-rai-ink">
          <div className="mx-auto mb-3 flex h-14 w-14 items-center justify-center rounded-2xl bg-rai-shell"><KeyRound className="h-7 w-7" aria-hidden="true" /></div>
          <h1 className="text-xl font-bold">تعيين كلمة المرور</h1>
        </div>
        <div className="card p-6" data-testid="reset-password">{body}</div>
      </div>
    </main>
  );

  if (done) {
    return shell(
      <div className="space-y-4 text-center" role="status" data-testid="reset-done">
        <CheckCircle2 className="mx-auto h-10 w-10 text-rai-success" aria-hidden="true" />
        <p className="text-sm text-rai-ink">تم تعيين كلمة المرور الجديدة، وخرجت أجهزتك الأخرى. ادخل بها من الآن.</p>
        <button type="button" className="btn-primary w-full" onClick={() => navigate(homeFor(profile?.role), { replace: true })}>متابعة إلى النظام</button>
      </div>,
    );
  }

  if (!session && (badLink || (!loading && waited))) {
    return shell(
      <div className="space-y-4 text-center" data-testid="reset-invalid">
        <p className="text-sm text-rai-ink">{badLink ? "انتهت صلاحية الرابط أو استُعمل من قبل." : "افتح هذه الصفحة من الرابط الذي وصلك على البريد."}</p>
        <p className="text-xs text-rai-ink-muted">اطلب رابطًا جديدًا من صفحة الدخول ← «نسيت كلمة المرور؟».</p>
        <Link to="/staff/login" className="btn-primary w-full justify-center">إلى صفحة الدخول</Link>
      </div>,
    );
  }

  if (!session) return shell(<div className="flex justify-center py-6"><Spinner /></div>);

  return shell(
    <form onSubmit={submit} className="space-y-4" noValidate>
      <p className="text-sm text-rai-ink-muted">الحساب: <span dir="ltr" className="font-medium">{session.user?.email}</span></p>
      <div>
        <label className="label" htmlFor="new-password">كلمة المرور الجديدة</label>
        <input id="new-password" type="password" className="input" dir="ltr" autoComplete="new-password" value={pw} onChange={(e) => setPw(e.target.value)} required />
        <p className="mt-1 text-xs text-rai-ink-muted">{PASSWORD_HINT}</p>
      </div>
      <div>
        <label className="label" htmlFor="confirm-password">أعد كتابتها</label>
        <input id="confirm-password" type="password" className="input" dir="ltr" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} required />
      </div>
      {error && <ErrorBanner message={error} />}
      <button type="submit" className="btn-primary w-full" disabled={saving} data-testid="reset-submit">{saving ? <Spinner /> : "حفظ كلمة المرور"}</button>
    </form>,
  );
}
