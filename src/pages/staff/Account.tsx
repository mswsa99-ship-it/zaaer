/**
 * «حسابي» (0074): the signed-in person's own account — their name, e-mail and role; a new password (the rule in
 * lib/password.ts; the other devices are signed out after it); a link e-mailed to their own address for changing it
 * from there; and signing out of every device. Every action is recorded in the owner's «security» log.
 */
import { useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { KeyRound, Mail, LogOut, UserRound } from "lucide-react";
import { useAuth, logAuthEvent } from "../../lib/auth";
import { newPasswordProblem, PASSWORD_HINT } from "../../lib/password";
import { ROLE_LABELS } from "../../lib/types";
import { SectionTitle, Card, ErrorBanner, Spinner } from "../../components/ui";

export default function Account() {
  const { profile, updatePassword, requestPasswordReset, signOutEverywhere } = useAuth();
  const navigate = useNavigate();
  const [pw, setPw] = useState("");
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState<null | "save" | "link" | "all">(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const actionLock = useRef(false);

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setError(null); setNotice(null);
    const problem = newPasswordProblem(pw, confirm);
    if (problem) { setError(problem); return; }
    if (actionLock.current) return;
    actionLock.current = true; setBusy("save");
    try {
      const { error } = await updatePassword(pw);
      if (error) { setError(error); return; }
      setPw(""); setConfirm("");
      setNotice("تغيّرت كلمة المرور، وخرجت أجهزتك الأخرى.");
    } catch { setError("تعذّر تغيير كلمة المرور. حاول مرة أخرى."); }
    finally { actionLock.current = false; setBusy(null); }
  }

  async function emailLink() {
    if (!profile || actionLock.current) return;
    actionLock.current = true;
    setError(null); setNotice(null); setBusy("link");
    try {
      const { error } = await requestPasswordReset(profile.email);
      if (error) setError(error);
      else { await logAuthEvent("security.password_link_sent"); setNotice(`أرسلنا إلى ${profile.email} رابطًا لتغيير كلمة المرور. افتحه واختر كلمتك الجديدة.`); }
    } catch { setError("تعذّر إرسال الرابط. حاول مرة أخرى."); }
    finally { actionLock.current = false; setBusy(null); }
  }

  async function everywhere() {
    if (actionLock.current) return;
    actionLock.current = true; setBusy("all"); setError(null);
    try { await signOutEverywhere(); navigate("/staff/login", { replace: true }); }
    catch { setError("تعذّر تسجيل الخروج من الأجهزة. حاول مرة أخرى."); }
    finally { actionLock.current = false; setBusy(null); }
  }

  return (
    <div className="mx-auto max-w-2xl space-y-4" data-testid="account-page">
      <SectionTitle title="حسابي" subtitle="بيانات دخولك وكلمة مرورك" />
      <Card className="flex items-start gap-3">
        <UserRound className="mt-0.5 h-5 w-5 shrink-0 text-ink-400" aria-hidden="true" />
        <div className="min-w-0 text-sm">
          <p className="font-semibold text-ink-800">{profile?.full_name}</p>
          <p className="truncate text-ink-500" dir="ltr">{profile?.email}</p>
          <p className="text-xs text-ink-400">{profile ? ROLE_LABELS[profile.role] : ""}</p>
        </div>
      </Card>

      {notice && <div role="status" className="rounded-xl border border-success-500/30 bg-success-500/10 px-4 py-3 text-sm text-success-600" data-testid="account-notice">{notice}</div>}
      {error && <ErrorBanner message={error} />}

      <Card>
        <h2 className="mb-3 flex items-center gap-2 text-sm font-semibold text-ink-800"><KeyRound className="h-4 w-4" aria-hidden="true" /> تغيير كلمة المرور</h2>
        <form onSubmit={save} className="space-y-3" noValidate>
          <div>
            <label className="label" htmlFor="account-new-password">كلمة المرور الجديدة</label>
            <input id="account-new-password" type="password" className="input" dir="ltr" autoComplete="new-password" value={pw} onChange={(e) => setPw(e.target.value)} />
            <p className="mt-1 text-xs text-ink-400">{PASSWORD_HINT}</p>
          </div>
          <div>
            <label className="label" htmlFor="account-confirm-password">أعد كتابتها</label>
            <input id="account-confirm-password" type="password" className="input" dir="ltr" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} />
          </div>
          <button type="submit" className="btn-primary" disabled={busy !== null} data-testid="account-save-password">{busy === "save" ? <Spinner className="h-4 w-4" /> : "حفظ كلمة المرور"}</button>
        </form>
        <div className="mt-4 border-t border-ink-100 pt-4">
          <p className="mb-2 text-xs text-ink-500">أو غيّرها من بريدك: يصلك رابط، وتختار منه كلمتك الجديدة.</p>
          <button type="button" onClick={emailLink} disabled={busy !== null} className="btn-outline text-sm" data-testid="account-email-link">
            {busy === "link" ? <Spinner className="h-4 w-4" /> : <><Mail className="h-4 w-4" aria-hidden="true" /> إرسال رابط التغيير إلى بريدي</>}
          </button>
        </div>
      </Card>

      <Card>
        <h2 className="mb-2 flex items-center gap-2 text-sm font-semibold text-ink-800"><LogOut className="h-4 w-4" aria-hidden="true" /> الأجهزة</h2>
        <p className="mb-3 text-xs text-ink-500">إن دخلت من جهاز لا تثق به أو شاركت كلمة مرورك، أنهِ كل جلساتك ثم ادخل من جديد.</p>
        <button type="button" onClick={everywhere} disabled={busy !== null} className="btn-outline text-sm text-danger-600" data-testid="account-sign-out-everywhere">
          {busy === "all" ? <Spinner className="h-4 w-4" /> : "تسجيل الخروج من كل الأجهزة"}
        </button>
      </Card>
    </div>
  );
}
