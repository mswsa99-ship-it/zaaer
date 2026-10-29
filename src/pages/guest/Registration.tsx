import { useEffect, useState, useCallback } from "react";
import { useParams, useNavigate, Link } from "react-router-dom";
import { ArrowLeft, UserPlus, CheckCircle2, AlertCircle, IdCard } from "lucide-react";
import { guestApi, toArabicError, VALIDATION_AR, type GuestSession, type GuestStaySummary } from "../../lib/api";
import { Card, ErrorBanner, Spinner } from "../../components/ui";
import { IDENTITY_TYPE_LABELS, GUEST_VERIFICATION_LABELS, type IdentityType, type GuestVerificationStatus } from "../../lib/types";
import { gregorianToHijri, hijriToGregorian, maskId, todayISO } from "../../lib/utils";
import { checkIdentityNumber, checkMinAge, checkPersonName, checkPhone, fieldError, latinDigits, maxBirthDate } from "../../lib/validation";

type GuestRow = GuestSession["guests"][number];

export default function Registration() {
  const { token } = useParams();
  const navigate = useNavigate();
  const [data, setData] = useState<GuestSession | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<{ guest: GuestRow | null; open: boolean }>({ guest: null, open: false });

  const load = useCallback(async () => {
    if (!token) return;
    try { setData(await guestApi.session(token)); setError(null); }
    catch (e) { setError(toArabicError(e)); }
    setLoading(false);
  }, [token]);
  useEffect(() => { load(); }, [load]);

  if (loading) return <div className="mx-auto max-w-md px-4 py-12"><Spinner className="mx-auto h-8 w-8" /></div>;
  if (error || !data) return <div className="mx-auto max-w-md px-4 py-12"><ErrorBanner message={error ?? "تعذّر التحميل"} /><Link to="/booking/lookup" className="mt-4 inline-block text-sm text-brand-600">إعادة التحقق</Link></div>;

  const r = data.reservation;
  const totalGuests = r.adults + r.companions;
  const submittedCount = data.guests.filter((g) => g.data_submitted).length;
  const allSubmitted = submittedCount >= totalGuests && totalGuests > 0;
  const canAdd = data.guests.length < totalGuests;

  return (
    <div className="mx-auto max-w-2xl px-4 py-8 lg:py-12">
      <Link to={`/booking/status/${token}`} className="mb-4 inline-flex items-center gap-1.5 text-sm text-ink-400 hover:text-ink-600"><ArrowLeft className="h-4 w-4" /> حالة الحجز</Link>

      <div className="mb-6">
        <h1 className="text-2xl font-bold text-ink-800">تسجيل بيانات النزلاء</h1>
        <p className="mt-2 text-sm text-ink-500">الحجز {r.internal_ref} — {r.branch_name}</p>
        <div className="mt-3 flex flex-wrap gap-2 text-xs text-ink-500">
          <span className="rounded-lg bg-ink-50 px-3 py-1">الوصول: {r.check_in}</span>
          <span className="rounded-lg bg-ink-50 px-3 py-1">المغادرة: {r.check_out}</span>
          <span className="rounded-lg bg-ink-50 px-3 py-1">{r.adults} نزيل + {r.companions} مرافق</span>
        </div>
      </div>

      <Card className="mb-6">
        <div className="flex items-center justify-between">
          <div><p className="text-sm font-medium text-ink-700">تقدّم التسجيل</p><p className="mt-1 text-xs text-ink-400">{submittedCount} من {totalGuests} شخص</p></div>
          <div className="text-2xl font-bold text-brand-600">{Math.round((submittedCount / Math.max(totalGuests, 1)) * 100)}%</div>
        </div>
        <div className="mt-3 h-2 overflow-hidden rounded-full bg-ink-100"><div className="h-full rounded-full bg-brand-500 transition-all" style={{ width: `${(submittedCount / Math.max(totalGuests, 1)) * 100}%` }} /></div>
      </Card>

      <div className="space-y-3">
        {data.guests.map((g) => (
          <Card key={g.id} className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-full bg-ink-100 text-ink-500"><IdCard className="h-5 w-5" /></div>
              <div>
                <div className="flex items-center gap-2">
                  <p className="text-sm font-semibold text-ink-800">{g.full_name || "لم يُسجّل بعد"}</p>
                  {g.is_primary && <span className="badge bg-brand-50 text-brand-700">رئيسي</span>}
                </div>
                <p className="mt-0.5 text-xs text-ink-400">
                  {g.identity_type ? IDENTITY_TYPE_LABELS[g.identity_type as IdentityType] : "—"} · {g.identity_number_last4 ? maskId(g.identity_number_last4) : "بدون رقم"} · {GUEST_VERIFICATION_LABELS[g.verification_status as GuestVerificationStatus]}
                </p>
              </div>
            </div>
            {g.verification_status === "verified" ? (
              <span className="badge bg-success-500/10 text-success-600"><CheckCircle2 className="h-3 w-3" /> معتمد</span>
            ) : g.data_submitted ? (
              <button onClick={() => setEditing({ guest: g, open: true })} className="text-xs text-brand-600 hover:underline">تعديل</button>
            ) : (
              <button onClick={() => setEditing({ guest: g, open: true })} className="btn-outline text-xs"><UserPlus className="h-3.5 w-3.5" /> أكمل البيانات</button>
            )}
          </Card>
        ))}

        {canAdd && (
          <Card className="flex items-center justify-between border-dashed">
            <p className="text-sm text-ink-500">أضف بيانات مرافق ({data.guests.length} من {totalGuests})</p>
            <button onClick={() => setEditing({ guest: null, open: true })} className="btn-outline text-xs"><UserPlus className="h-3.5 w-3.5" /> إضافة مرافق</button>
          </Card>
        )}
      </div>

      {allSubmitted ? (
        <div className="mt-8 rounded-2xl bg-success-500/10 p-5 text-center">
          <CheckCircle2 className="mx-auto mb-2 h-8 w-8 text-success-600" />
          <p className="text-sm font-medium text-success-600">تم إكمال تسجيل بيانات جميع النزلاء</p>
          <p className="mt-1 text-xs text-ink-500">سيطابق المشرف البيانات مع الوثائق الأصلية عند الوصول.</p>
          <button onClick={() => navigate(`/booking/status/${token}`)} className="btn-primary mt-4">متابعة حالة الحجز</button>
        </div>
      ) : (
        <div className="mt-6 rounded-xl bg-warning-500/10 p-4 text-sm text-warning-600">
          <div className="flex items-start gap-2"><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" /><p>يجب إكمال بيانات جميع النزلاء قبل تسجيل الوصول. إدخال البيانات لا يعني مطابقة الهوية — سيراجعها المشرف مع الوثيقة الأصلية.</p></div>
        </div>
      )}

      {editing.open && token && (
        <GuestForm token={token} guest={editing.guest} onClose={() => setEditing({ guest: null, open: false })} onSaved={() => { setEditing({ guest: null, open: false }); load(); }} />
      )}
    </div>
  );
}

function GuestForm({ token, guest, onClose, onSaved }: { token: string; guest: GuestRow | null; onClose: () => void; onSaved: () => void }) {
  // decision 19: the main guest reads «ملخص الإقامة» and accepts it with the data (once; a later change is accepted on its own page)
  const [summary, setSummary] = useState<GuestStaySummary | null>(null);
  const [ackOpen, setAckOpen] = useState(false);
  const [ack, setAck] = useState(false);
  useEffect(() => { if (guest?.is_primary) guestApi.staySummary(token).then(setSummary).catch(() => setSummary(null)); }, [token, guest?.is_primary]);
  const needsAck = !!guest?.is_primary && !!summary && !summary.accepted_at;
  const [fullName, setFullName] = useState(guest?.full_name ?? "");
  const [identityType, setIdentityType] = useState<IdentityType>((guest?.identity_type as IdentityType) ?? "national_id");
  const [identityNumber, setIdentityNumber] = useState("");
  const [issueNumber, setIssueNumber] = useState("");
  const [nationality, setNationality] = useState(guest?.nationality ?? "سعودي");
  const [birthDate, setBirthDate] = useState(guest?.birth_date ?? "");
  const [birthCalendar, setBirthCalendar] = useState<"gregorian" | "hijri">("gregorian");
  const [phone, setPhone] = useState("");
  const [relationship, setRelationship] = useState(guest?.relationship ?? (guest?.is_primary ? "self" : "other"));
  const [consent, setConsent] = useState(false);
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);
  const isPrimary = !!guest?.is_primary;
  // 0047: each field says its rule while typing (the server refuses the same)
  const nameErr = fieldError(() => checkPersonName(fullName), VALIDATION_AR);
  const numberErr = identityNumber.trim() ? fieldError(() => checkIdentityNumber(identityType, latinDigits(identityNumber).replace(/\s/g, "")), VALIDATION_AR) : null;
  const phoneErr = phone.trim() ? fieldError(() => checkPhone(phone, false), VALIDATION_AR) : null;

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setFormError(null);
    // light client-side checks; the server is authoritative (fn_guest_submit)
    if (fullName.trim().split(/\s+/).length < 3) { setFormError("الاسم الثلاثي مطلوب كما في الوثيقة."); return; }
    if (!identityNumber.trim()) { setFormError("رقم الوثيقة مطلوب."); return; }
    if (!birthDate) { setFormError("تاريخ الميلاد مطلوب."); return; }
    // 0047: letters-only name, the number's shape, the phone's shape, 15 or older — the same rules as the server
    const ruleError = fieldError(() => {
      checkPersonName(fullName);
      checkIdentityNumber(identityType, latinDigits(identityNumber).replace(/\s/g, ""));
      checkPhone(phone, false);
    }, VALIDATION_AR);
    if (ruleError) { setFormError(ruleError); return; }
    if (!consent) { setFormError("يجب الإقرار بصحة البيانات."); return; }
    if (needsAck && !ack) { setFormError("يجب الإقرار بملخص الإقامة."); return; }

    let finalBirthDate = birthDate;
    if (birthCalendar === "hijri") {
      const [y, m, d] = birthDate.split("-").map(Number);
      const g = hijriToGregorian(y, m, d);
      finalBirthDate = `${g.year}-${String(g.month).padStart(2, "0")}-${String(g.day).padStart(2, "0")}`;
    }
    const ageError = fieldError(() => checkMinAge(finalBirthDate, todayISO()), VALIDATION_AR);
    if (ageError) { setFormError(ageError); return; }
    setSaving(true);
    try {
      await guestApi.submit(token, guest?.id ?? null, {
        full_name: fullName.trim(), identity_type: identityType, identity_number: identityNumber.trim(), identity_issue_number: issueNumber.trim() || null,
        nationality: nationality.trim(), birth_date: finalBirthDate, phone: phone.trim() || null, relationship: isPrimary ? "self" : relationship, consent: "true",
        ...(needsAck && ack ? { ack_hash: summary!.hash } : {}),
      });
      onSaved();
    } catch (err) {
      setFormError(toArabicError(err));
    }
    setSaving(false);
  }

  const hijriHint = (() => {
    if (!birthDate) return null;
    const [y, m, d] = birthDate.split("-").map(Number);
    if (!y || !m || !d) return null;
    if (birthCalendar === "hijri") { const g = hijriToGregorian(y, m, d); return `المقابل ميلاديًا: ${g.year}-${String(g.month).padStart(2, "0")}-${String(g.day).padStart(2, "0")}`; }
    const h = gregorianToHijri(y, m, d); return `المقابل هجريًا: ${h.day}/${h.month}/${h.year}هـ`;
  })();

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/40 p-4" role="dialog" aria-modal="true">
      <Card className="max-h-[90vh] w-full max-w-lg overflow-y-auto scrollbar-thin">
        <div className="mb-4 flex items-center justify-between">
          <h3 className="text-lg font-semibold text-ink-800">{guest ? "استكمال البيانات" : "إضافة مرافق"}</h3>
          <button onClick={onClose} className="text-ink-400 hover:text-ink-600" aria-label="إغلاق">✕</button>
        </div>
        <form onSubmit={save} className="space-y-4" autoComplete="off">
          <div><label className="label">الاسم الثلاثي (كما في الوثيقة)</label><input value={fullName} onChange={(e) => setFullName(e.target.value)} className="input" placeholder="الاسم الأول الأب الجد" aria-invalid={!!nameErr} />{nameErr && <p className="mt-1 text-xs text-danger-600" role="alert">{nameErr}</p>}</div>
          <div className="grid grid-cols-2 gap-4">
            <div><label className="label">نوع الوثيقة</label>
              <select value={identityType} onChange={(e) => setIdentityType(e.target.value as IdentityType)} className="input">
                {Object.entries(IDENTITY_TYPE_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
              </select>
            </div>
            <div><label className="label">رقم الوثيقة</label><input value={identityNumber} onChange={(e) => setIdentityNumber(e.target.value)} className="input" dir="ltr" inputMode="numeric" placeholder={identityType === "national_id" || identityType === "iqama" ? "10 أرقام" : ""} />{numberErr && <p className="mt-1 text-xs text-danger-600" role="alert">{numberErr}</p>}</div>
          </div>
          <div className="grid grid-cols-2 gap-4">
            <div><label className="label">رقم الإصدار (إن وجد)</label><input value={issueNumber} onChange={(e) => setIssueNumber(e.target.value)} className="input" dir="ltr" /></div>
            <div><label className="label">الجنسية</label><input value={nationality} onChange={(e) => setNationality(e.target.value)} className="input" /></div>
          </div>
          {!isPrimary && (
            <div><label className="label">صلة القرابة</label>
              <select value={relationship} onChange={(e) => setRelationship(e.target.value)} className="input">
                <option value="spouse">زوج/زوجة</option><option value="child">ابن/ابنة</option><option value="parent">والد/والدة</option><option value="sibling">أخ/أخت</option><option value="other">أخرى</option>
              </select>
            </div>
          )}
          <div>
            <div className="mb-1.5 flex items-center gap-3">
              <label className="label mb-0">تاريخ الميلاد</label>
              <div className="flex gap-1 text-xs">
                <button type="button" onClick={() => setBirthCalendar("gregorian")} className={`rounded-lg px-2 py-1 ${birthCalendar === "gregorian" ? "bg-brand-100 text-brand-700" : "text-ink-400"}`}>ميلادي</button>
                <button type="button" onClick={() => setBirthCalendar("hijri")} className={`rounded-lg px-2 py-1 ${birthCalendar === "hijri" ? "bg-brand-100 text-brand-700" : "text-ink-400"}`}>هجري</button>
              </div>
            </div>
            {birthCalendar === "gregorian" ? (
              <input type="date" value={birthDate} onChange={(e) => setBirthDate(e.target.value)} className="input" max={maxBirthDate(todayISO())} />
            ) : (
              <input value={birthDate} onChange={(e) => setBirthDate(e.target.value)} className="input" dir="ltr" placeholder="1410-05-15 (سنة-شهر-يوم هجري)" pattern="\d{4}-\d{2}-\d{2}" />
            )}
            {hijriHint && <p className="mt-1 text-xs text-ink-400">{hijriHint}</p>}
          </div>
          <div><label className="label">رقم الجوال {isPrimary ? "(مطلوب)" : "(اختياري)"}</label><input value={phone} onChange={(e) => setPhone(e.target.value)} className="input" dir="ltr" inputMode="tel" placeholder={isPrimary ? "يُترك فارغًا للإبقاء على الرقم المسجل" : "05XXXXXXXX"} />{phoneErr && <p className="mt-1 text-xs text-danger-600" role="alert">{phoneErr}</p>}</div>

          {formError && <ErrorBanner message={formError} />}

          <label className="flex items-start gap-2 text-xs text-ink-500">
            <input type="checkbox" checked={consent} onChange={(e) => setConsent(e.target.checked)} className="mt-0.5" />
            <span>أُقر بصحة البيانات المُدخلة، واطلعت على <Link to="/privacy" target="_blank" className="text-brand-600 underline">سياسة الخصوصية</Link> و<Link to="/terms" target="_blank" className="text-brand-600 underline">شروط الإقامة</Link>.</span>
          </label>
          {needsAck && (
            <div className="rounded-xl border border-brand-100 bg-brand-50/40 p-3" data-testid="summary-ack">
              <button type="button" onClick={() => setAckOpen((v) => !v)} className="text-xs font-medium text-brand-700 underline-offset-2 hover:underline">{ackOpen ? "إخفاء ملخص الإقامة" : "عرض ملخص الإقامة (الحجز، الوحدة، المدة، السعر، المدفوع، التأمين، سياسات الفرع)"}</button>
              {ackOpen && <pre className="mt-2 max-h-48 overflow-auto whitespace-pre-wrap font-sans text-[11px] leading-relaxed text-ink-600" dir={summary!.language === "en" ? "ltr" : "rtl"}>{summary!.text}</pre>}
              <label className="mt-2 flex items-start gap-2 text-xs text-ink-600">
                <input type="checkbox" checked={ack} onChange={(e) => setAck(e.target.checked)} className="mt-0.5" aria-label="أقرّ بملخص الإقامة" />
                <span>قرأت ملخص الإقامة وأقرّ به (يُحفظ نص الملخص ووقت الإقرار).</span>
              </label>
            </div>
          )}

          <button type="submit" className="btn-primary w-full" disabled={saving}>{saving ? <Spinner /> : "حفظ البيانات"}</button>
        </form>
        <p className="mt-3 text-center text-xs text-ink-400">يُشفَّر رقم الوثيقة على الخادم فور الحفظ ولا يُعرض كاملًا لأحد بعد ذلك.</p>
      </Card>
    </div>
  );
}
