import { useCallback, useEffect, useState } from "react";
import { useParams, Link } from "react-router-dom";
import { ArrowLeft, CheckCircle2, FileText, Printer } from "lucide-react";
import { guestApi, toArabicError, type GuestStaySummary } from "../../lib/api";
import { Card, Spinner, ErrorBanner } from "../../components/ui";
import { formatDateTime } from "../../lib/utils";

/**
 * «ملخص الإقامة» (decision 19): the stay, its money, the deposit and the branch's policies, in the branch's language.
 * The guest accepts it here (or when registering); the exact text and the time are kept. A payment or a change of the
 * stay produces a new text: the earlier acceptance stays with its own text and the page says the current one is not
 * yet accepted.
 */
export default function StaySummary() {
  const { token } = useParams();
  const [s, setS] = useState<GuestStaySummary | null>(null);
  const [logo, setLogo] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const load = useCallback(async () => {
    if (!token) return;
    try {
      const x = await guestApi.staySummary(token); setS(x); setError(null);
      if (x.branch.logo_version) { try { setLogo(await guestApi.branchMedia(x.branch.id, "logo")); } catch { /* no logo */ } }
    } catch (e) { setError(toArabicError(e)); }
  }, [token]);
  useEffect(() => { load(); }, [load]);

  if (error && !s) return <div className="mx-auto max-w-md px-4 py-12"><ErrorBanner message={error} /><Link to="/booking/lookup" className="mt-4 inline-block text-sm text-brand-600">إعادة التحقق</Link></div>;
  if (!s) return <div className="mx-auto max-w-md px-4 py-12"><Spinner className="mx-auto h-8 w-8" /></div>;
  const en = s.language === "en";
  return (
    <div className="mx-auto max-w-2xl px-4 py-8 lg:py-12">
      <Link to={`/booking/status/${token}`} className="mb-4 inline-flex items-center gap-1.5 text-sm text-ink-400 hover:text-ink-600 print:hidden"><ArrowLeft className="h-4 w-4" /> حالة الحجز</Link>
      <div className="mb-5 flex items-center justify-between gap-3">
        <div className="flex items-center gap-2"><FileText className="h-6 w-6 text-brand-600" /><h1 className="text-2xl font-bold text-ink-800">{en ? "Stay summary" : "ملخص الإقامة"}</h1></div>
        {logo && <img src={logo} alt="" className="h-12 max-w-[140px] object-contain" />}
      </div>
      <Card className="mb-4">
        <pre className="whitespace-pre-wrap font-sans text-sm leading-relaxed text-ink-700" dir={en ? "ltr" : "rtl"} data-testid="guest-summary-text">{s.text}</pre>
      </Card>
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      {s.accepted_at && s.current ? (
        <div className="rounded-2xl bg-success-500/10 p-4 text-center text-sm text-success-600" data-testid="summary-accepted">
          <CheckCircle2 className="mx-auto mb-1 h-6 w-6" /> {en ? "Accepted" : "تم الإقرار"} · {formatDateTime(s.accepted_at)} {s.method === "paper" ? (en ? "(signed on paper)" : "(توقيع ورقي)") : ""}
        </div>
      ) : (
        <div className="space-y-3">
          {s.accepted_at && <p className="rounded-xl bg-warning-500/10 p-3 text-xs text-warning-600">{en ? "The summary changed since your last acceptance (a payment or a change of the stay). Please read and accept the current one." : "تغيّر الملخص منذ إقرارك السابق (دفعة أو تعديل في الإقامة). اقرأ النسخة الحالية وأقرّ بها."}</p>}
          <button onClick={async () => { if (!token) return; setBusy(true); try { await guestApi.acknowledge(token, s.hash); await load(); } catch (e) { setError(toArabicError(e)); } finally { setBusy(false); } }} disabled={busy} className="btn-primary w-full" data-testid="accept-summary">
            {busy ? <Spinner /> : en ? "I have read the summary and accept it" : "قرأت ملخص الإقامة وأقرّ به"}
          </button>
        </div>
      )}
      <button onClick={() => window.print()} className="btn-outline mt-4 w-full print:hidden"><Printer className="h-4 w-4" /> {en ? "Print" : "طباعة"}</button>
    </div>
  );
}
