import { useEffect, useState, useCallback, useRef } from "react";
import { GuestLinkError } from "../../components/GuestLinkError";
import { useParams, Link, useNavigate } from "react-router-dom";
import { ArrowRight, ArrowLeft, CheckCircle2, Clock, KeyRound, CreditCard, UserCheck, FileCheck, MessageCircle, MapPin, LogIn, FileText, XCircle, Phone } from "lucide-react";
import { guestApi, type GuestSession, type PublicBranch, type GuestStaySummary } from "../../lib/api";
import { Card, Spinner, ErrorBanner } from "../../components/ui";
import { GuestBranchGuide } from "../../components/GuestBranchGuide";
import { RESERVATION_STATUS_LABELS, PAYMENT_STATUS_LABELS, GUEST_VERIFICATION_LABELS, type ReservationStatus, type PaymentStatus, type GuestVerificationStatus } from "../../lib/types";
import { formatCurrency, formatHijri, formatClock, todayISO } from "../../lib/utils";
import { useGuestLang, guestError, reasonEn, STATUS_EN, PAYMENT_EN, VERIFICATION_EN, moneyEn } from "../../lib/guestLang";

/** GUEST-08: the reasons a guest can act on (their data, their payment); the rest is the desk's work */
const guestCanAct = (x: string) => /بيانات|النزلاء المسجلين|سداد|دفع|مبلغ|المتبقي|الليلة الأولى/.test(x);

export default function BookingStatus() {
  const { token } = useParams();
  const navigate = useNavigate();
  const [data, setData] = useState<GuestSession | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [acting, setActing] = useState(false);
  const [branch, setBranch] = useState<PublicBranch | null>(null);
  const [rules, setRules] = useState<GuestStaySummary["policies"] | null>(null);
  const [target, setTarget] = useState<number | null>(null);   // 0058 (GUEST-07): children under 15 are not registered
  const { en, t } = useGuestLang();
  const enRef = useRef(en); enRef.current = en;

  const load = useCallback(async () => {
    if (!token) return;
    try { setData(await guestApi.session(token)); setError(null); }
    catch (e) { setError(guestError(e, enRef.current)); }
    setLoading(false);
  }, [token]);

  useEffect(() => { load(); }, [load]);
  // decision 31: the branch's map link; decision 19: the stay summary page
  const branchId = data?.reservation.branch_id;
  useEffect(() => { if (!branchId) return; guestApi.branch(branchId).then(setBranch).catch(() => setBranch(null)); }, [branchId]);
  // U3: the stay rules are the branch's own policies (set in the settings), read once from the stay summary
  useEffect(() => { if (!token || !branchId) return; guestApi.staySummary(token).then((x) => setRules(x?.policies ?? null)).catch(() => setRules(null)); }, [token, branchId]);
  useEffect(() => { if (!token || !branchId) return; guestApi.children(token).then((x) => setTarget(x?.target ?? null)).catch(() => setTarget(null)); }, [token, branchId]);
  // Poll every 15s so supervisor approvals show up without a reload (guest has no realtime access to tables)
  useEffect(() => { const t = setInterval(load, 15000); return () => clearInterval(t); }, [load]);

  if (loading) return <div className="mx-auto max-w-md px-4 py-12"><Spinner className="mx-auto h-8 w-8" /></div>;
  if (error || !data) return <GuestLinkError message={error ?? t("الرابط غير صالح", "This link is not valid")} />;

  const r = data.reservation;
  const required = target ?? r.adults + r.companions;
  const submitted = data.guests.filter((g) => g.data_submitted).length;
  // GUEST-02: after departure the code is no longer «ready» here (the code page refuses it too)
  const departed = ["checked_out", "closed"].includes(r.status);
  const delivered = ["delivered", "acknowledged"].includes(r.access_status) && !departed;
  const dueHalalas = r.total_halalas - r.paid_halalas;
  // 0033: the arrival is registered at reception; a unit with a key box then gets its code, one without its key
  const arrived = ["checked_in", "checked_out", "closed"].includes(r.status);
  const hasKeybox = r.has_keybox !== false;
  const firstNightPaid = r.first_night_paid ?? r.payment_status === "paid";

  const hijri = (d: string) => formatHijri(d, en);
  const money = (h: number) => (en ? moneyEn(h / 100) : formatCurrency(h / 100));
  const steps = [
    { label: t("تسجيل بيانات النزلاء", "Guests' details"), icon: UserCheck, done: submitted >= required && required > 0, statusText: t(`${submitted} من ${required}`, `${submitted} of ${required}`), action: submitted < required && !departed && !["checked_in"].includes(r.status) ? { label: t("استكمال البيانات", "Complete details"), to: `/booking/registration/${token}` } : null },
    { label: t("مطابقة الهوية (الاستقبال)", "ID check (at the reception)"), icon: FileCheck, done: r.identity_status === "verified", statusText: en ? VERIFICATION_EN[r.identity_status] ?? r.identity_status : GUEST_VERIFICATION_LABELS[r.identity_status as GuestVerificationStatus] },
    { label: t("سداد الليلة الأولى", "First night's payment"), icon: CreditCard, done: firstNightPaid, statusText: `${en ? PAYMENT_EN[r.payment_status] ?? r.payment_status : PAYMENT_STATUS_LABELS[r.payment_status as PaymentStatus]}${dueHalalas > 0 ? t(` · المتبقي على الإقامة ${money(dueHalalas)}`, ` · ${money(dueHalalas)} left on the stay`) : ""}` },
    { label: t("تسجيل الوصول في الاستقبال", "Check-in at the reception"), icon: LogIn, done: arrived, statusText: arrived ? t("تم", "Done") : t("عند وصولك يسجّلك الاستقبال في نظام شموس (إلزامي للإيواء) ويستلم مبلغ التأمين", "On arrival: guest registration with the authorities and the security deposit, at the reception") },
    hasKeybox
      ? { label: t("رمز صندوق المفتاح", "Key-box code"), icon: KeyRound, done: delivered, statusText: delivered ? t("جاهز للعرض", "Ready to view") : t("بعد تسجيل الوصول", "After check-in") }
      : { label: t("مفتاح الوحدة", "Unit key"), icon: KeyRound, done: arrived, statusText: arrived ? t("يُسلَّم في الاستقبال", "Handed over at the reception") : t("يُسلَّم في الاستقبال بعد تسجيل الوصول", "Handed over at the reception after check-in") },
  ];

  async function confirmArrival() {
    if (!token) return;
    setActing(true);
    try { await guestApi.submitCheckin(token); await load(); } catch (e) { setError(guestError(e, en)); }
    setActing(false);
  }

  // 0053 (GUEST-01): a booking that ended without a stay gets one clear page — no steps, no amounts, no actions
  const ENDED: Record<string, string> = en ? { cancelled: "This booking is cancelled", no_show: "This booking was recorded as a no-show", rejected: "This booking was rejected" } : { cancelled: "هذا الحجز ملغى", no_show: "سُجِّل هذا الحجز «لم يحضر»", rejected: "هذا الحجز مرفوض" };
  if (ENDED[r.status]) {
    return (
      <div className="mx-auto max-w-md px-4 py-10" data-testid="booking-ended">
        <Card>
          <div className="flex items-start gap-3">
            <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-danger-500/10 text-danger-600"><XCircle className="h-5 w-5" /></div>
            <div className="min-w-0">
              <h1 className="text-lg font-bold text-ink-800">{ENDED[r.status]}</h1>
              <p className="mt-1 text-sm text-ink-600">{r.branch_name} · <span className="font-mono" dir="ltr">{r.internal_ref}</span> · {r.check_in} → {r.check_out}</p>
              <p className="mt-2 text-sm text-ink-600">{t("لا يلزم أي إجراء منك على هذا الحجز، ولا يُسجَّل وصول عليه.", "Nothing is needed from you on this booking, and no check-in is made on it.")}</p>
            </div>
          </div>
          {branch?.phone && <p className="mt-4 rounded-xl bg-ink-50 px-3 py-2 text-sm text-ink-700">{t("للاستفسار: اتصل بالاستقبال على", "Questions? Call the reception on")} <span className="font-mono font-semibold" dir="ltr">{branch.phone}</span></p>}
          <div className="mt-4 grid gap-2 sm:grid-cols-2">
            {branch?.booking_platform_url
              ? <a href={branch.booking_platform_url} target="_blank" rel="noopener noreferrer" className="btn-primary justify-center">{t("حجز جديد", "New booking")}</a>
              : <Link to="/booking/new" className="btn-primary justify-center">{t("حجز جديد", "New booking")}</Link>}
            <Link to="/booking/lookup" className="btn-outline justify-center">{t("حجوزاتي", "My bookings")}</Link>
          </div>
        </Card>
      </div>
    );
  }

  // U3: one welcome line for where the stay is
  const today = todayISO();
  const greeting = ["checked_out", "closed"].includes(r.status) ? t("شكرًا لإقامتك معنا", "Thank you for staying with us")
    : arrived ? t("نتمنى لك إقامة طيبة", "We wish you a pleasant stay")
    : r.check_in === today ? t("أهلًا وسهلًا، إقامتك تبدأ اليوم", "Welcome — your stay starts today")
    : r.check_in > today ? t(`أهلًا وسهلًا، موعد وصولك ${r.check_in}`, `Welcome — you arrive on ${r.check_in}`)
    : t(`موعد وصولك كان ${r.check_in} — إن كنت ما زلت قادمًا فتواصل مع الاستقبال`, `Your arrival date was ${r.check_in} — if you are still coming, please contact the reception`);   // GUEST-18: an arrival date that has passed
  const checkInTime = formatClock(branch?.check_in_time, en);   // GUEST-17: the same time format as the terms page

  return (
    <div>
      <header className="bg-brand-800 px-4 pb-10 pt-6 text-white" data-testid="guest-hero">
        <div className="mx-auto max-w-lg">
          <Link to="/" className="mb-3 inline-flex min-h-[44px] items-center gap-1.5 text-sm text-brand-100 hover:text-white">{en ? <ArrowLeft className="h-4 w-4" /> : <ArrowRight className="h-4 w-4" />} {t("الرئيسية", "Home")}</Link>
          <p className="font-semibold" dir="auto">{r.branch_name}</p>
          <h1 className="mt-2 text-xl font-bold leading-8" data-testid="guest-greeting">{greeting}</h1>
          <p className="mt-1 text-sm font-medium text-brand-100">{t("حالة الحجز", "Booking status")} · <span className="font-mono" dir="ltr">{r.internal_ref}</span>{checkInTime && !arrived ? t(` · الوصول من ${checkInTime}`, ` · check-in from ${checkInTime}`) : ""}</p>
        </div>
      </header>
    <div className="mx-auto -mt-6 max-w-lg px-4 pb-10">

      <Card className="mb-6">
        <h2 className="mb-3 text-base font-semibold text-ink-800">{t("حجزك", "Your booking")}</h2>
        <div className="grid grid-cols-2 gap-3 text-sm">
          <div><p className="text-xs text-ink-400">{t("الوحدة", "Unit")}</p><p className="font-medium text-ink-700">{r.room_number ?? t("غير مخصصة بعد", "Not assigned yet")} · {r.category_name}</p></div>
          <div><p className="text-xs text-ink-400">{t("الحالة", "Status")}</p><p className="font-medium text-ink-700">{en ? STATUS_EN[r.status] ?? r.status : RESERVATION_STATUS_LABELS[r.status as ReservationStatus]}</p></div>
          <div><p className="text-xs text-ink-400">{t("الوصول", "Arrival")}</p><p className="font-medium text-ink-700">{r.check_in}<span className="block text-[11px] text-ink-400">{hijri(r.check_in)}</span></p></div>
          <div><p className="text-xs text-ink-400">{t("المغادرة", "Departure")}</p><p className="font-medium text-ink-700">{r.check_out}<span className="block text-[11px] text-ink-400">{hijri(r.check_out)}</span></p></div>
        </div>
      </Card>

      <h2 className="mb-3 text-base font-semibold text-ink-800">{arrived ? t("إقامتك", "Your stay") : t("قبل وصولك", "Before you arrive")}</h2>
      <ol className="space-y-3" aria-label={t("خطوات الإقامة", "Stay steps")}>
        {steps.map((s, i) => (
          <li key={i} className={`card flex items-center gap-3 p-4 ${s.done ? "border-success-500/30" : "border-warning-500/30"}`}>
            <div className={`flex h-9 w-9 items-center justify-center rounded-full ${s.done ? "bg-success-500/15 text-success-600" : "bg-warning-500/15 text-warning-700"}`}>
              {s.done ? <CheckCircle2 className="h-5 w-5" /> : <s.icon className="h-5 w-5" />}
            </div>
            <div className="flex-1">
              <p className="text-sm font-medium text-ink-700">{s.label}</p>
              <p className="text-xs text-ink-400">{s.statusText}</p>
            </div>
            {s.action ? <Link to={s.action.to} className="btn-primary text-xs">{s.action.label}</Link> : !s.done && <Clock className="h-4 w-4 text-ink-400" aria-hidden="true" />}
          </li>
        ))}
      </ol>

      {/* GUEST-08: only what the guest can do is listed; the desk's own steps are said once, in the guest's words */}
      {!data.access.allowed && data.access.reasons.length > 0 && !delivered && !departed && !(arrived && !hasKeybox) && (() => {
        const mine = data.access.reasons.filter(guestCanAct);
        const desk = data.access.reasons.length - mine.length;
        return (
          <div className="mt-4 rounded-xl bg-ink-50 p-4 text-xs text-ink-600" data-testid="guest-reasons">
            {mine.length > 0 && <><p className="mb-1 font-medium text-ink-700">{arrived ? t("قبل تسليم الرمز:", "Before the code is released:") : t("مطلوب منك قبل الوصول:", "Needed from you before arrival:")}</p><ul className="list-disc space-y-0.5 ps-4">{mine.map((x, i) => <li key={i}>{en ? reasonEn(x) : x}</li>)}</ul></>}
            {desk > 0 && <p className={mine.length ? "mt-2" : ""}>{t("بقية الخطوات يُنجزها الاستقبال عند وصولك.", "The other steps are done by the reception when you arrive.")}</p>}
          </div>
        );
      })()}

      {error && <div className="mt-4"><ErrorBanner message={error} /></div>}

      <div className="mt-6 grid gap-3 sm:grid-cols-2">
        {["locked"].includes(r.access_status) && !arrived && submitted >= required && (
          <button onClick={confirmArrival} disabled={acting} className="btn-primary">
            {acting ? <Spinner /> : <><MapPin className="h-4 w-4" /> {t("وصلتُ — إبلاغ الاستقبال", "I have arrived — tell the reception")}</>}
          </button>
        )}
        {r.access_status === "eligibility_review" && !arrived && (
          <div className="rounded-xl bg-brand-50 p-3 text-center text-sm text-brand-700">{t("أُبلغ الاستقبال بوصولك؛ يُسجَّل وصولك هناك.", "The reception knows you have arrived; check-in is done there.")}</div>
        )}
        <button onClick={() => navigate(`/reception?token=${token}`)} className="btn-outline"><MessageCircle className="h-4 w-4" /> {t("محادثة المساعد عن حجزك", "Chat with the assistant (verified)")}</button>
        <Link to={`/booking/summary/${token}`} className="btn-outline" data-testid="summary-link"><FileText className="h-4 w-4" /> {t("ملخص الإقامة", "Stay summary")}{r.summary_accepted ? t(" (مُقرّ)", " (accepted)") : ""}</Link>
        {branch?.phone && <a href={`tel:${branch.phone.replace(/[^0-9+]/g, "")}`} className="btn-outline" data-testid="call-reception"><Phone className="h-4 w-4" /> {t("اتصل بالاستقبال", "Call the reception")} <span className="font-mono text-xs" dir="ltr">{branch.phone}</span></a>}
        {branch?.map_url && <a href={branch.map_url} target="_blank" rel="noopener noreferrer" className="btn-outline" data-testid="map-link"><MapPin className="h-4 w-4" /> {t("الموقع على الخريطة", "Location on the map")}</a>}
      </div>

      {branchId && <GuestBranchGuide branchId={branchId} showBank={dueHalalas > 0 && !["checked_out", "closed", "cancelled"].includes(r.status)} />}

      {rules && rules.length > 0 && (
        <Card className="mt-6" data-testid="guest-rules">
          <h2 className="mb-2 text-base font-semibold text-ink-800">{t("قواعد الإقامة", "Stay rules")}</h2>
          <ul className="space-y-2 text-sm text-ink-700">
            {rules.map((p, i) => <li key={i} dir="auto"><p className="font-medium text-ink-800">{p.title}</p><p className="whitespace-pre-line text-ink-600">{p.content}</p></li>)}
          </ul>
        </Card>
      )}

      {delivered && (
        <div className="mt-6 rounded-2xl bg-accent-500/10 p-5 text-center">
          <KeyRound className="mx-auto mb-2 h-8 w-8 text-accent-700" />
          <p className="text-sm font-medium text-accent-700">{t("رمز صندوق المفتاح جاهز", "Your key-box code is ready")}</p>
          <Link to={`/checkin/${token}`} className="btn-accent mt-3">{t("عرض رمز الصندوق", "Show the key-box code")}</Link>
        </div>
      )}
    </div>
    </div>
  );
}
