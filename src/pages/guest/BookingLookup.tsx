import { useEffect, useState } from "react";
import { useNavigate, Link, useSearchParams } from "react-router-dom";
import { BookCheck, ArrowLeft, Search, ShieldAlert, Clock } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { guestApi, toArabicError } from "../../lib/api";
import { Card, ErrorBanner, Spinner } from "../../components/ui";

export default function BookingLookup() {
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const [sources, setSources] = useState<{ id: string; name: string }[]>([]);
  const [sourceId, setSourceId] = useState<string>("");
  const [externalRef, setExternalRef] = useState(params.get("ref") ?? "");
  const [phoneLast4, setPhoneLast4] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [outcome, setOutcome] = useState<"unmatched" | "throttled" | null>(null);

  useEffect(() => {
    supabase.from("booking_sources").select("id, name").eq("is_active", true).order("name").then(({ data }) => setSources((data as { id: string; name: string }[]) ?? []));
  }, []);

  async function handleVerify(e: React.FormEvent) {
    e.preventDefault();
    setError(null); setOutcome(null);
    if (!externalRef.trim() || phoneLast4.length !== 4) { setError("يرجى إدخال رقم الحجز وآخر 4 أرقام من جوالك المسجل."); return; }
    setLoading(true);
    try {
      const r = await guestApi.lookup(externalRef.trim(), phoneLast4, sourceId || null);
      if (r.status === "ok" && r.token) {
        navigate(`/booking/status/${r.token}`);
        return;
      }
      if (r.status === "unmatched") setOutcome("unmatched");
      else if (r.status === "throttled") setOutcome("throttled");
      else setError("لم يطابق رمز التحقق الرقم المسجل لهذا الحجز. حاول مرة أخرى.");
    } catch (err) {
      setError(toArabicError(err));
    }
    setLoading(false);
  }

  return (
    <div className="mx-auto max-w-md px-4 py-8 lg:py-12">
      <Link to="/reception" className="mb-4 inline-flex items-center gap-1.5 text-sm text-ink-400 hover:text-ink-600"><ArrowLeft className="h-4 w-4" /> رجوع للمحادثة</Link>

      <div className="mb-6 text-center">
        <div className="mx-auto mb-3 flex h-12 w-12 items-center justify-center rounded-2xl bg-brand-50 text-brand-600"><BookCheck className="h-6 w-6" /></div>
        <h1 className="text-2xl font-bold text-ink-800">التحقق من الحجز</h1>
        <p className="mt-2 text-sm text-ink-500">أدخل مصدر الحجز ورقمه، ثم آخر 4 أرقام من جوالك المسجل لإثبات ملكيتك. رقم الحجز وحده لا يكفي للوصول إلى البيانات.</p>
      </div>

      <Card>
        <form onSubmit={handleVerify} className="space-y-4">
          <div>
            <label className="label">مصدر الحجز</label>
            <select value={sourceId} onChange={(e) => setSourceId(e.target.value)} className="input">
              <option value="">جميع المصادر</option>
              {sources.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
          </div>
          <div>
            <label className="label">رقم الحجز</label>
            <input value={externalRef} onChange={(e) => setExternalRef(e.target.value)} placeholder="مثال: BK-DEMO-1001" className="input" dir="ltr" autoComplete="off" />
          </div>
          <div>
            <label className="label">آخر 4 أرقام من جوالك المسجل</label>
            <input value={phoneLast4} onChange={(e) => setPhoneLast4(e.target.value.replace(/[^\d٠-٩]/g, "").replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d))).slice(0, 4))} placeholder="••••" className="input tracking-[0.5em]" dir="ltr" inputMode="numeric" autoComplete="off" />
            <p className="mt-1.5 text-xs text-ink-400">مطابقة فقط — لا نرسل رسالة ولا نعرض الرقم.</p>
          </div>

          {error && <ErrorBanner message={error} />}

          {outcome === "unmatched" && (
            <div className="rounded-xl border border-warning-500/30 bg-warning-500/10 px-4 py-3 text-sm text-warning-600">
              <div className="flex items-start gap-2">
                <ShieldAlert className="mt-0.5 h-4 w-4 shrink-0" />
                <div>
                  <p className="font-medium">لم نجد حجزًا بهذا الرقم</p>
                  <p className="mt-1 text-xs">تم إنشاء طلب للمشرف بعنوان «حجز غير مطابق» للمتابعة. تأكد من الرقم والمصدر أو تواصل مع الاستقبال.</p>
                </div>
              </div>
            </div>
          )}
          {outcome === "throttled" && (
            <div className="rounded-xl border border-danger-500/30 bg-danger-500/10 px-4 py-3 text-sm text-danger-600">
              <div className="flex items-start gap-2"><Clock className="mt-0.5 h-4 w-4 shrink-0" /><p>تم تجاوز عدد المحاولات لهذا الرقم. حاول بعد 15 دقيقة أو تواصل مع الاستقبال.</p></div>
            </div>
          )}

          <button type="submit" className="btn-primary w-full" disabled={loading}>
            {loading ? <Spinner /> : <><Search className="h-4 w-4" /> تحقق</>}
          </button>
        </form>
      </Card>

      {import.meta.env.DEV && (
        <p className="mt-4 text-center text-xs text-ink-400">بيئة تجريبية: جرّب <span className="font-mono text-ink-500">BK-DEMO-1001</span> مع <span className="font-mono text-ink-500">0111</span></p>
      )}
    </div>
  );
}
