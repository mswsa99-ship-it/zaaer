import { useEffect, useState, useCallback } from "react";
import { useParams, Link, useNavigate } from "react-router-dom";
import { ArrowLeft, CheckCircle2, Clock, KeyRound, CreditCard, UserCheck, FileCheck, MessageCircle, MapPin, LogIn, FileText } from "lucide-react";
import { guestApi, toArabicError, type GuestSession, type PublicBranch } from "../../lib/api";
import { Card, Spinner, EmptyState, ErrorBanner } from "../../components/ui";
import { RESERVATION_STATUS_LABELS, PAYMENT_STATUS_LABELS, GUEST_VERIFICATION_LABELS, type ReservationStatus, type PaymentStatus, type GuestVerificationStatus } from "../../lib/types";
import { formatCurrency, formatHijri } from "../../lib/utils";

export default function BookingStatus() {
  const { token } = useParams();
  const navigate = useNavigate();
  const [data, setData] = useState<GuestSession | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [acting, setActing] = useState(false);
  const [branch, setBranch] = useState<PublicBranch | null>(null);

  const load = useCallback(async () => {
    if (!token) return;
    try { setData(await guestApi.session(token)); setError(null); }
    catch (e) { setError(toArabicError(e)); }
    setLoading(false);
  }, [token]);

  useEffect(() => { load(); }, [load]);
  // decision 31: the branch's map link; decision 19: the stay summary page
  const branchId = data?.reservation.branch_id;
  useEffect(() => { if (!branchId) return; guestApi.branch(branchId).then(setBranch).catch(() => setBranch(null)); }, [branchId]);
  // Poll every 15s so supervisor approvals show up without a reload (guest has no realtime access to tables)
  useEffect(() => { const t = setInterval(load, 15000); return () => clearInterval(t); }, [load]);

  if (loading) return <div className="mx-auto max-w-md px-4 py-12"><Spinner className="mx-auto h-8 w-8" /></div>;
  if (error || !data) return <div className="mx-auto max-w-md px-4 py-12"><EmptyState title={error ?? "الرابط غير صالح"} /><Link to="/booking/lookup" className="mt-4 inline-block text-sm text-brand-600">إعادة التحقق</Link></div>;

  const r = data.reservation;
  const required = r.adults + r.companions;
  const submitted = data.guests.filter((g) => g.data_submitted).length;
  const delivered = ["delivered", "acknowledged"].includes(r.access_status);
  const dueHalalas = r.total_halalas - r.paid_halalas;
  // 0033: the arrival is registered at reception; a unit with a key box then gets its code, one without its key
  const arrived = ["checked_in", "checked_out", "closed"].includes(r.status);
  const hasKeybox = r.has_keybox !== false;
  const firstNightPaid = r.first_night_paid ?? r.payment_status === "paid";

  const steps = [
    { label: "تسجيل بيانات النزلاء", icon: UserCheck, done: submitted >= required && required > 0, statusText: `${submitted} من ${required}`, action: submitted < required ? { label: "استكمال البيانات", to: `/booking/registration/${token}` } : null },
    { label: "مطابقة الهوية (الاستقبال)", icon: FileCheck, done: r.identity_status === "verified", statusText: GUEST_VERIFICATION_LABELS[r.identity_status as GuestVerificationStatus] },
    { label: "سداد الليلة الأولى", icon: CreditCard, done: firstNightPaid, statusText: `${PAYMENT_STATUS_LABELS[r.payment_status as PaymentStatus]}${dueHalalas > 0 ? ` · المتبقي على الإقامة ${formatCurrency(dueHalalas / 100)}` : ""}` },
    { label: "تسجيل الوصول في الاستقبال", icon: LogIn, done: arrived, statusText: arrived ? "تم" : "عند وصولك: التسجيل في شموس والتأمين في الاستقبال" },
    hasKeybox
      ? { label: "رمز صندوق المفتاح", icon: KeyRound, done: delivered, statusText: delivered ? "جاهز للعرض" : "بعد تسجيل الوصول" }
      : { label: "مفتاح الوحدة", icon: KeyRound, done: arrived, statusText: arrived ? "يُسلَّم في الاستقبال" : "يُسلَّم في الاستقبال بعد تسجيل الوصول" },
  ];

  async function confirmArrival() {
    if (!token) return;
    setActing(true);
    try { await guestApi.submitCheckin(token); await load(); } catch (e) { setError(toArabicError(e)); }
    setActing(false);
  }

  return (
    <div className="mx-auto max-w-lg px-4 py-8 lg:py-12">
      <Link to="/" className="mb-4 inline-flex items-center gap-1.5 text-sm text-ink-400 hover:text-ink-600"><ArrowLeft className="h-4 w-4" /> الرئيسية</Link>

      <div className="mb-6 text-center">
        <h1 className="text-2xl font-bold text-ink-800">حالة الحجز</h1>
        <p className="mt-1 text-sm text-ink-500">{r.internal_ref} · {r.branch_name}</p>
      </div>

      <Card className="mb-6">
        <div className="grid grid-cols-2 gap-3 text-sm">
          <div><p className="text-xs text-ink-400">الوحدة</p><p className="font-medium text-ink-700">{r.room_number ?? "غير مخصصة بعد"} · {r.category_name}</p></div>
          <div><p className="text-xs text-ink-400">الحالة</p><p className="font-medium text-ink-700">{RESERVATION_STATUS_LABELS[r.status as ReservationStatus]}</p></div>
          <div><p className="text-xs text-ink-400">الوصول</p><p className="font-medium text-ink-700">{r.check_in}<span className="block text-[11px] text-ink-400">{formatHijri(r.check_in)}</span></p></div>
          <div><p className="text-xs text-ink-400">المغادرة</p><p className="font-medium text-ink-700">{r.check_out}<span className="block text-[11px] text-ink-400">{formatHijri(r.check_out)}</span></p></div>
        </div>
      </Card>

      <div className="space-y-3">
        {steps.map((s, i) => (
          <div key={i} className={`card flex items-center gap-3 p-4 ${s.done ? "border-success-500/30" : "border-warning-500/30"}`}>
            <div className={`flex h-9 w-9 items-center justify-center rounded-full ${s.done ? "bg-success-500/15 text-success-600" : "bg-warning-500/15 text-warning-700"}`}>
              {s.done ? <CheckCircle2 className="h-5 w-5" /> : <s.icon className="h-5 w-5" />}
            </div>
            <div className="flex-1">
              <p className="text-sm font-medium text-ink-700">{s.label}</p>
              <p className="text-xs text-ink-400">{s.statusText}</p>
            </div>
            {s.action ? <Link to={s.action.to} className="btn-outline text-xs">{s.action.label}</Link> : !s.done && <Clock className="h-4 w-4 text-ink-400" />}
          </div>
        ))}
      </div>

      {!data.access.allowed && data.access.reasons.length > 0 && !delivered && !(arrived && !hasKeybox) && (
        <div className="mt-4 rounded-xl bg-ink-50 p-4 text-xs text-ink-500">
          <p className="mb-1 font-medium text-ink-600">{arrived ? "قبل تسليم الرمز:" : "قبل تسجيل الوصول:"}</p>
          <ul className="list-disc space-y-0.5 pr-4">{data.access.reasons.map((x, i) => <li key={i}>{x}</li>)}</ul>
        </div>
      )}

      {error && <div className="mt-4"><ErrorBanner message={error} /></div>}

      <div className="mt-6 grid gap-3 sm:grid-cols-2">
        {["locked"].includes(r.access_status) && !arrived && submitted >= required && (
          <button onClick={confirmArrival} disabled={acting} className="btn-primary">
            {acting ? <Spinner /> : <><MapPin className="h-4 w-4" /> وصلت — أبلغ الاستقبال</>}
          </button>
        )}
        {r.access_status === "eligibility_review" && !arrived && (
          <div className="rounded-xl bg-brand-50 p-3 text-center text-sm text-brand-700">أُبلغ الاستقبال بوصولك؛ يُسجَّل وصولك هناك.</div>
        )}
        <button onClick={() => navigate(`/reception?token=${token}`)} className="btn-outline"><MessageCircle className="h-4 w-4" /> محادثة المساعد (متحقق)</button>
        <Link to={`/booking/summary/${token}`} className="btn-outline" data-testid="summary-link"><FileText className="h-4 w-4" /> ملخص الإقامة{r.summary_accepted ? " (مُقرّ)" : ""}</Link>
        {branch?.map_url && <a href={branch.map_url} target="_blank" rel="noopener noreferrer" className="btn-outline" data-testid="map-link"><MapPin className="h-4 w-4" /> الموقع على الخريطة</a>}
      </div>

      {delivered && (
        <div className="mt-6 rounded-2xl bg-accent-500/10 p-5 text-center">
          <KeyRound className="mx-auto mb-2 h-8 w-8 text-accent-600" />
          <p className="text-sm font-medium text-accent-600">رمز صندوق المفتاح جاهز</p>
          <Link to={`/checkin/${token}`} className="btn-accent mt-3">عرض رمز الدخول</Link>
        </div>
      )}
    </div>
  );
}
