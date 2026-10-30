import { useEffect, useRef, useState } from "react";
import { useNavigate, Link, useSearchParams } from "react-router-dom";
import { ArrowLeft, Smartphone, MessageCircle, CalendarDays, ChevronLeft, Hash } from "lucide-react";
import { guestApi, toArabicError, type PhoneReservation } from "../../lib/api";
import { Card, ErrorBanner, Spinner } from "../../components/ui";
import { RESERVATION_STATUS_LABELS, type ReservationStatus } from "../../lib/types";

/**
 * «حجوزاتي» — the guest's phone number is the key: phone → code by WhatsApp → their bookings → one tap.
 * Until WhatsApp is connected the code step is replaced by "the number of any one of your bookings".
 */
type Step = "phone" | "code" | "ref" | "list";
const SESSION_KEY = "guest_phone_session";
const toLatin = (s: string) => s.replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d))).replace(/[۰-۹]/g, (d) => String("۰۱۲۳۴۵۶۷۸۹".indexOf(d)));

export default function BookingLookup() {
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const [step, setStep] = useState<Step>("phone");
  const [phone, setPhone] = useState("");
  const [code, setCode] = useState("");
  const [ref, setRef] = useState(params.get("ref") ?? "");
  const [list, setList] = useState<PhoneReservation[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const opened = useRef(false);

  // back from a booking page: the verified list is still there for this tab
  useEffect(() => {
    let t: string | null = null;
    try { t = sessionStorage.getItem(SESSION_KEY); } catch { /* storage blocked */ }
    if (t) showList(t, false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function showList(token: string, autoOpen: boolean) {
    setLoading(true); setError(null);
    try {
      const r = await guestApi.phoneReservations(token);
      try { sessionStorage.setItem(SESSION_KEY, token); } catch { /* ignore */ }
      if (autoOpen && r.reservations.length === 1 && !opened.current) { opened.current = true; await open(token, r.reservations[0].internal_ref); return; }
      setList(r.reservations); setStep("list");
    } catch {
      try { sessionStorage.removeItem(SESSION_KEY); } catch { /* ignore */ }
      setStep("phone");
    }
    setLoading(false);
  }

  async function open(token: string, internalRef: string) {
    setLoading(true);
    try { const r = await guestApi.openPhoneReservation(token, internalRef); navigate(`/booking/status/${r.token}`); }
    catch (e) { setError(toArabicError(e)); setLoading(false); }
  }

  async function submitPhone(e: React.FormEvent) {
    e.preventDefault(); setError(null);
    const p = toLatin(phone).replace(/\D/g, "");
    if (p.length < 9) { setError("اكتب رقم جوالك كاملًا، مثل 05xxxxxxxx"); return; }
    setLoading(true);
    const r = await guestApi.sendPhoneCode(p);
    setLoading(false);
    if (r.status === "sent") { setNotice(`إن كان لديك حجز بهذا الرقم فقد أرسلنا رمزًا من 6 أرقام عبر واتساب إلى الرقم المنتهي بـ ${p.slice(-4)}.`); setStep("code"); }
    else if (r.status === "channel_unavailable" || r.status === "send_failed") setStep("ref");
    else if (r.status === "throttled") setError("محاولات كثيرة لهذا الرقم. حاول بعد ساعة أو تواصل مع الاستقبال.");
    else setError("رقم الجوال غير صحيح.");
  }

  async function submitCode(e: React.FormEvent) {
    e.preventDefault(); setError(null);
    const c = toLatin(code).replace(/\D/g, "");
    if (c.length !== 6) { setError("الرمز 6 أرقام."); return; }
    setLoading(true);
    try {
      const r = await guestApi.verifyPhoneCode(toLatin(phone), c);
      if (r.status === "ok" && r.token) { await showList(r.token, true); return; }
      setError(r.status === "mismatch" ? `الرمز غير صحيح${r.attempts_left !== undefined ? ` — بقي ${r.attempts_left} محاولات` : ""}.` : r.status === "throttled" ? "تجاوزت عدد المحاولات. اطلب رمزًا جديدًا." : "انتهت صلاحية الرمز. اطلب رمزًا جديدًا.");
    } catch (err) { setError(toArabicError(err)); }
    setLoading(false);
  }

  async function submitRef(e: React.FormEvent) {
    e.preventDefault(); setError(null);
    if (!ref.trim()) { setError("اكتب رقم الحجز."); return; }
    setLoading(true);
    try {
      const r = await guestApi.verifyPhoneRef(toLatin(phone), ref.trim());
      if (r.status === "ok" && r.token) { await showList(r.token, true); return; }
      setError(r.status === "throttled" ? "محاولات كثيرة. حاول بعد 15 دقيقة أو تواصل مع الاستقبال." : "لم نجد حجزًا بهذا الرقم على هذا الجوال.");
    } catch (err) { setError(toArabicError(err)); }
    setLoading(false);
  }

  function restart() {
    try { sessionStorage.removeItem(SESSION_KEY); } catch { /* ignore */ }
    setStep("phone"); setCode(""); setList(null); setError(null); setNotice(null);
  }

  return (
    <div className="mx-auto max-w-md px-4 py-8 lg:py-12">
      <Link to="/reception" className="mb-4 inline-flex items-center gap-1.5 text-sm text-ink-400 hover:text-ink-600"><ArrowLeft className="h-4 w-4" /> رجوع</Link>

      <div className="mb-6 text-center">
        <div className="mx-auto mb-3 flex h-12 w-12 items-center justify-center rounded-2xl bg-brand-50 text-brand-600">
          {step === "list" ? <CalendarDays className="h-6 w-6" /> : step === "code" ? <MessageCircle className="h-6 w-6" /> : <Smartphone className="h-6 w-6" />}
        </div>
        <h1 className="text-2xl font-bold text-ink-800">حجوزاتي</h1>
        <p className="mt-2 text-sm text-ink-500">
          {step === "phone" && "اكتب رقم جوالك الذي حجزت به."}
          {step === "code" && notice}
          {step === "ref" && "للتأكد أن الجوال لك: اكتب رقم أي حجز لديك (من رسالة التأكيد)."}
          {step === "list" && list && (list.length ? `لديك ${list.length === 1 ? "حجز واحد" : list.length === 2 ? "حجزان" : `${list.length} حجوزات`}` : "لا توجد حجوزات حالية على هذا الرقم.")}
        </p>
      </div>

      {error && <div className="mb-3"><ErrorBanner message={error} /></div>}

      {step === "phone" && (
        <Card>
          <form onSubmit={submitPhone} className="space-y-4">
            <input value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="05xxxxxxxx" className="input text-center text-lg tracking-wider" dir="ltr" inputMode="tel" autoComplete="tel" autoFocus aria-label="رقم الجوال" />
            <button type="submit" className="btn-primary w-full" disabled={loading}>{loading ? <Spinner /> : "متابعة"}</button>
          </form>
        </Card>
      )}

      {step === "code" && (
        <Card>
          <form onSubmit={submitCode} className="space-y-4">
            <input value={code} onChange={(e) => setCode(toLatin(e.target.value).replace(/\D/g, "").slice(0, 6))} placeholder="••••••" className="input text-center text-2xl tracking-[0.5em]" dir="ltr" inputMode="numeric" autoComplete="one-time-code" autoFocus aria-label="رمز التحقق" />
            <button type="submit" className="btn-primary w-full" disabled={loading}>{loading ? <Spinner /> : "عرض حجوزاتي"}</button>
            <div className="flex justify-between text-xs">
              <button type="button" onClick={restart} className="text-ink-400 hover:text-ink-600">تغيير الرقم</button>
              <button type="button" onClick={() => setStep("ref")} className="text-brand-600">لم يصلني الرمز</button>
            </div>
          </form>
        </Card>
      )}

      {step === "ref" && (
        <Card>
          <form onSubmit={submitRef} className="space-y-4">
            <div className="relative">
              <Hash className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-ink-400" />
              <input value={ref} onChange={(e) => setRef(e.target.value)} placeholder="رقم الحجز" className="input text-center" dir="ltr" autoComplete="off" autoFocus aria-label="رقم الحجز" />
            </div>
            <button type="submit" className="btn-primary w-full" disabled={loading}>{loading ? <Spinner /> : "عرض حجوزاتي"}</button>
            <button type="button" onClick={restart} className="w-full text-xs text-ink-400 hover:text-ink-600">تغيير الرقم</button>
          </form>
        </Card>
      )}

      {step === "list" && list && (
        <div className="space-y-3">
          {list.map((r) => (
            <button key={r.internal_ref} onClick={() => { let t: string | null = null; try { t = sessionStorage.getItem(SESSION_KEY); } catch { /* ignore */ } if (t) open(t, r.internal_ref); }} disabled={loading}
              className="flex w-full items-center gap-3 rounded-2xl border border-ink-100 bg-white p-4 text-right shadow-sm transition hover:border-brand-200 hover:bg-brand-50/40">
              <div className="min-w-0 flex-1">
                <div className="flex items-center justify-between gap-2">
                  <span className="font-semibold text-ink-800">{r.category_name ?? r.branch_name ?? "حجز"}</span>
                  <span className="rounded-full bg-brand-50 px-2 py-0.5 text-xs text-brand-700">{RESERVATION_STATUS_LABELS[r.status as ReservationStatus] ?? r.status}</span>
                </div>
                <p className="mt-1 text-sm text-ink-500" dir="ltr">{r.check_in} → {r.check_out}</p>
                <p className="mt-0.5 text-xs text-ink-400">{r.nights} {r.nights === 1 ? "ليلة" : "ليالٍ"}{r.branch_name ? ` · ${r.branch_name}` : ""} · <span dir="ltr">{r.ref}</span></p>
              </div>
              <ChevronLeft className="h-5 w-5 shrink-0 text-ink-400" />
            </button>
          ))}
          {list.length === 0 && <Link to="/booking/new" className="btn-primary w-full">احجز الآن</Link>}
          <button onClick={restart} className="w-full py-2 text-xs text-ink-400 hover:text-ink-600">خروج</button>
        </div>
      )}
    </div>
  );
}
