import { useEffect, useState, useCallback } from "react";
import { GuestLinkError } from "../../components/GuestLinkError";
import { useParams, useNavigate, Link } from "react-router-dom";
import { ArrowRight, UserPlus, CheckCircle2, AlertCircle, IdCard, Baby, Plus, X } from "lucide-react";
import { guestApi, toArabicError, VALIDATION_AR, type GuestSession, type GuestStaySummary } from "../../lib/api";
import { Card, ErrorBanner, Spinner } from "../../components/ui";
import { Modal, Field } from "../../components/forms";
import { IDENTITY_TYPE_LABELS, GUEST_VERIFICATION_LABELS, type IdentityType, type GuestVerificationStatus } from "../../lib/types";
import { gregorianToHijri, hijriToGregorian, maskId, todayISO, COUNT } from "../../lib/utils";
import { checkIdentityNumber, checkMinAge, checkNameParts, checkPersonName, checkPhone, fieldError, latinDigits, maxBirthDate } from "../../lib/validation";

type GuestRow = GuestSession["guests"][number];

/**
 * «تسجيل بيانات النزلاء» — the guests' own data before arrival. The review of 31 October (0058):
 *  - GUEST-05: a passport or GCC ID takes letters, a two-part name, and its own rule when the number is wrong;
 *  - GUEST-06: the birth date switches between Gregorian and Hijri without losing it, Hijri as day / month / year;
 *  - GUEST-07: children under 15 are given by age — counted, shown to the supervisor, not registered with a document;
 *  - GUEST-11: the form is the shared dialog (focus inside, Escape, labelled fields); GUEST-16/19: counts and phone label.
 */
export default function Registration() {
  const { token } = useParams();
  const navigate = useNavigate();
  const [data, setData] = useState<GuestSession | null>(null);
  const [kids, setKids] = useState<{ children_ages: number[]; target: number } | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<{ guest: GuestRow | null; open: boolean }>({ guest: null, open: false });

  const load = useCallback(async () => {
    if (!token) return;
    try {
      const [s, c] = await Promise.all([guestApi.session(token), guestApi.children(token).catch(() => null)]);
      setData(s); setKids(c); setError(null);
    } catch (e) { setError(toArabicError(e)); }
    setLoading(false);
  }, [token]);
  useEffect(() => { load(); }, [load]);

  if (loading) return <div className="mx-auto max-w-md px-4 py-12"><Spinner className="mx-auto h-8 w-8" /></div>;
  if (error || !data) return <GuestLinkError message={error ?? "الرابط غير صالح"} />;

  const r = data.reservation;
  const children = kids?.children_ages ?? [];
  const target = kids?.target ?? r.adults + r.companions;
  const submittedCount = data.guests.filter((g) => g.data_submitted).length;
  const allSubmitted = submittedCount >= target && target > 0;
  const canAdd = data.guests.length < target;

  return (
    <div className="mx-auto max-w-2xl px-4 py-8 lg:py-12">
      <Link to={`/booking/status/${token}`} className="mb-4 inline-flex min-h-[44px] items-center gap-1.5 text-sm text-ink-500 hover:text-ink-700"><ArrowRight className="h-4 w-4" /> حالة الحجز</Link>

      <div className="mb-6">
        <h1 className="text-2xl font-bold text-ink-800">تسجيل بيانات النزلاء</h1>
        <p className="mt-2 text-sm text-ink-500">الحجز {r.internal_ref} — {r.branch_name}</p>
        <div className="mt-3 flex flex-wrap gap-2 text-xs text-ink-500">
          <span className="rounded-lg bg-ink-50 px-3 py-1">الوصول: {r.check_in}</span>
          <span className="rounded-lg bg-ink-50 px-3 py-1">المغادرة: {r.check_out}</span>
          <span className="rounded-lg bg-ink-50 px-3 py-1">{COUNT.guest(r.adults + r.companions)}{children.length ? `، منهم ${COUNT.child(children.length)} دون 15 سنة` : ""}</span>
        </div>
      </div>

      <Card className="mb-6">
        <div className="flex items-center justify-between">
          <div><p className="text-sm font-medium text-ink-700">تقدّم التسجيل</p><p className="mt-1 text-xs text-ink-500">سُجّلت بيانات {submittedCount} من {COUNT.guest(target)}</p></div>
          <div className="text-2xl font-bold text-brand-600">{Math.round((submittedCount / Math.max(target, 1)) * 100)}%</div>
        </div>
        <div className="mt-3 h-2 overflow-hidden rounded-full bg-ink-100"><div className="h-full rounded-full bg-brand-500 transition-all" style={{ width: `${Math.min(100, (submittedCount / Math.max(target, 1)) * 100)}%` }} /></div>
      </Card>

      <div className="space-y-3">
        {data.guests.map((g) => (
          <Card key={g.id} className="flex items-center justify-between gap-3">
            <div className="flex min-w-0 items-center gap-3">
              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-ink-100 text-ink-500"><IdCard className="h-5 w-5" /></div>
              <div className="min-w-0">
                <div className="flex items-center gap-2">
                  <p className="text-sm font-semibold text-ink-800">{g.full_name || "لم يُسجّل بعد"}</p>
                  {g.is_primary && <span className="badge bg-brand-50 text-brand-700">رئيسي</span>}
                </div>
                <p className="mt-0.5 text-xs text-ink-500">
                  {g.identity_type ? IDENTITY_TYPE_LABELS[g.identity_type as IdentityType] : "—"} · {g.identity_number_last4 ? maskId(g.identity_number_last4) : "بدون رقم"} · {GUEST_VERIFICATION_LABELS[g.verification_status as GuestVerificationStatus]}
                </p>
              </div>
            </div>
            {g.verification_status === "verified" ? (
              <span className="badge bg-success-500/10 text-success-600"><CheckCircle2 className="h-3 w-3" /> معتمد</span>
            ) : g.data_submitted ? (
              <button onClick={() => setEditing({ guest: g, open: true })} className="btn-ghost min-h-[44px] text-xs text-brand-600">تعديل</button>
            ) : (
              <button onClick={() => setEditing({ guest: g, open: true })} className="btn-outline text-xs"><UserPlus className="h-3.5 w-3.5" /> أكمل البيانات</button>
            )}
          </Card>
        ))}

        {canAdd && (
          <Card className="flex flex-wrap items-center justify-between gap-2 border-dashed">
            <p className="text-sm text-ink-500">{target - data.guests.length === 1 ? "بقي نزيل واحد لم تُضف بياناته" : `بقي ${COUNT.guest(target - data.guests.length)} لم تُضف بياناتهم`} (15 سنة فأكثر)</p>
            <button onClick={() => setEditing({ guest: null, open: true })} className="btn-outline text-xs"><UserPlus className="h-3.5 w-3.5" /> إضافة نزيل</button>
          </Card>
        )}

        {token && <ChildrenCard token={token} ages={children} editable={!["cancelled", "rejected", "closed", "checked_out", "no_show"].includes(r.status)} onSaved={load} />}
      </div>

      {allSubmitted ? (
        <div className="mt-8 rounded-2xl bg-success-500/10 p-5 text-center">
          <CheckCircle2 className="mx-auto mb-2 h-8 w-8 text-success-600" />
          <p className="text-sm font-medium text-success-600">تم إكمال تسجيل بيانات جميع النزلاء</p>
          <p className="mt-1 text-xs text-ink-500">سيطابق المشرف البيانات مع الوثائق الأصلية عند الوصول.</p>
          <button onClick={() => navigate(`/booking/status/${token}`)} className="btn-primary mt-4">متابعة حالة الحجز</button>
        </div>
      ) : (
        <div className="mt-6 rounded-xl bg-warning-500/10 p-4 text-sm text-warning-700">
          <div className="flex items-start gap-2"><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" /><p>يجب إكمال بيانات جميع النزلاء (15 سنة فأكثر) قبل تسجيل الوصول. إدخال البيانات لا يعني مطابقة الهوية — سيراجعها المشرف مع الوثيقة الأصلية.</p></div>
        </div>
      )}

      {token && <GuestForm token={token} open={editing.open} guest={editing.guest} onClose={() => setEditing({ guest: null, open: false })} onSaved={() => { setEditing({ guest: null, open: false }); load(); }} />}
    </div>
  );
}

/** GUEST-07: children under 15 by age — they take a companion's place, are not registered with a document, and the
 *  supervisor sees them on the booking. */
function ChildrenCard({ token, ages, editable, onSaved }: { token: string; ages: number[]; editable: boolean; onSaved: () => void }) {
  const [list, setList] = useState<string[]>(ages.map(String));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  useEffect(() => { setList(ages.map(String)); }, [ages.join(",")]); // eslint-disable-line react-hooks/exhaustive-deps
  const dirty = list.join(",") !== ages.join(",");
  async function save() {
    setBusy(true); setErr(null); setSaved(false);
    try {
      const v = list.map((x) => latinDigits(x).trim()).filter((x) => x !== "");
      if (v.some((x) => !/^\d{1,2}$/.test(x) || Number(x) > 14)) throw new Error("VALIDATION: child_age");
      await guestApi.setChildren(token, v.map(Number)); setSaved(true); onSaved();
    } catch (e) { setErr(toArabicError(e)); }
    setBusy(false);
  }
  return (
    <Card className="space-y-3" data-testid="children">
      <div className="flex items-start gap-3">
        <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-accent-500/10 text-accent-700"><Baby className="h-5 w-5" /></div>
        <div>
          <p className="text-sm font-semibold text-ink-800">أطفال دون 15 سنة</p>
          <p className="mt-0.5 text-xs leading-5 text-ink-500">لا يُسجَّل الأطفال دون 15 سنة بوثيقة. اذكر أعمارهم هنا: يُحسبون في عدد نزلاء الحجز ويراهم المشرف، ويُعرَّف بهم عند الوصول.</p>
        </div>
      </div>
      {list.length > 0 && (
        <ul className="flex flex-wrap gap-2">
          {list.map((a, i) => (
            <li key={i} className="flex items-center gap-1 rounded-xl bg-ink-50 px-2 py-1">
              <label className="text-xs text-ink-600" htmlFor={`child-${i}`}>الطفل {i + 1}: العمر</label>
              <input id={`child-${i}`} className="input w-16 py-1 text-center" dir="ltr" inputMode="numeric" maxLength={2} value={a} disabled={!editable}
                onChange={(e) => setList(list.map((x, j) => (j === i ? e.target.value : x)))} />
              {editable && <button type="button" className="btn-ghost min-h-[44px] min-w-[44px] p-1" aria-label={`حذف الطفل ${i + 1}`} onClick={() => setList(list.filter((_, j) => j !== i))}><X className="h-4 w-4" /></button>}
            </li>
          ))}
        </ul>
      )}
      {err && <ErrorBanner message={err} />}
      {saved && !dirty && <p className="text-xs text-success-600" role="status">حُفظت أعمار الأطفال.</p>}
      {editable && (
        <div className="flex flex-wrap gap-2">
          {list.length < 10 && <button type="button" className="btn-outline text-xs" onClick={() => setList([...list, ""])}><Plus className="h-3.5 w-3.5" /> إضافة طفل</button>}
          {dirty && <button type="button" className="btn-primary text-xs" disabled={busy} onClick={save}>{busy ? <Spinner className="h-3.5 w-3.5" /> : "حفظ الأعمار"}</button>}
        </div>
      )}
    </Card>
  );
}

const HIJRI_MONTHS = ["محرم", "صفر", "ربيع الأول", "ربيع الآخر", "جمادى الأولى", "جمادى الآخرة", "رجب", "شعبان", "رمضان", "شوال", "ذو القعدة", "ذو الحجة"];
const pad = (n: number) => String(n).padStart(2, "0");
const isoOf = (y: number, m: number, d: number) => `${String(y).padStart(4, "0")}-${pad(m)}-${pad(d)}`;

function GuestForm({ token, open, guest, onClose, onSaved }: { token: string; open: boolean; guest: GuestRow | null; onClose: () => void; onSaved: () => void }) {
  // decision 19: the main guest reads «ملخص الإقامة» and accepts it with the data (once; a later change is accepted on its own page)
  const [summary, setSummary] = useState<GuestStaySummary | null>(null);
  const [ackOpen, setAckOpen] = useState(false);
  const [ack, setAck] = useState(false);
  const [fullName, setFullName] = useState("");
  const [identityType, setIdentityType] = useState<IdentityType>("national_id");
  const [identityNumber, setIdentityNumber] = useState("");
  const [issueNumber, setIssueNumber] = useState("");
  const [nationality, setNationality] = useState("سعودي");
  const [birthDate, setBirthDate] = useState("");            // always Gregorian (YYYY-MM-DD); the Hijri fields convert into it
  const [birthCalendar, setBirthCalendar] = useState<"gregorian" | "hijri">("gregorian");
  const [hijri, setHijri] = useState({ y: "", m: "", d: "" });
  const [phone, setPhone] = useState("");
  const [relationship, setRelationship] = useState("other");
  const [consent, setConsent] = useState(false);
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);
  const isPrimary = !!guest?.is_primary;

  useEffect(() => {
    if (!open) return;
    setFullName(guest?.full_name ?? ""); setIdentityType((guest?.identity_type as IdentityType) ?? "national_id"); setIdentityNumber(""); setIssueNumber("");
    setNationality(guest?.nationality ?? "سعودي"); setBirthDate(guest?.birth_date ?? ""); setBirthCalendar("gregorian"); setHijri({ y: "", m: "", d: "" });
    setPhone(""); setRelationship(guest?.relationship && guest.relationship !== "self" ? guest.relationship : "other"); setConsent(false); setAck(false); setFormError(null);
    if (guest?.is_primary) guestApi.staySummary(token).then(setSummary).catch(() => setSummary(null)); else setSummary(null);
  }, [open, guest, token]);
  const needsAck = isPrimary && !!summary && !summary.accepted_at;
  const passportLike = identityType === "passport" || identityType === "gcc_id";

  // 0047: each field says its rule while typing (the server refuses the same)
  const nameErr = fullName.trim() ? fieldError(() => { checkPersonName(fullName); }, VALIDATION_AR) : null;
  const numberErr = identityNumber.trim() ? fieldError(() => checkIdentityNumber(identityType, latinDigits(identityNumber).replace(/\s/g, "")), VALIDATION_AR) : null;
  const phoneErr = phone.trim() ? fieldError(() => checkPhone(phone, false), VALIDATION_AR) : null;

  // GUEST-06: the Hijri date is read as numbers whatever digits are typed, and checked before it is converted
  const hy = Number(latinDigits(hijri.y)), hm = Number(hijri.m), hd = Number(hijri.d);
  const hijriValid = hy >= 1300 && hy <= 1500 && hm >= 1 && hm <= 12 && hd >= 1 && hd <= 30;
  const hijriErr = birthCalendar === "hijri" && hijri.y && hijri.m && hijri.d && !hijriValid ? "التاريخ الهجري غير صحيح (السنة بين 1300 و1500)." : null;
  useEffect(() => {
    if (birthCalendar !== "hijri") return;
    if (hijriValid) { const g = hijriToGregorian(hy, hm, hd); setBirthDate(isoOf(g.year, g.month, g.day)); } else setBirthDate("");
  }, [birthCalendar, hy, hm, hd, hijriValid]);
  function switchCalendar(c: "gregorian" | "hijri") {
    if (c === birthCalendar) return;
    if (c === "hijri" && birthDate) { const [y, m, d] = birthDate.split("-").map(Number); const h = gregorianToHijri(y, m, d); setHijri({ y: String(h.year), m: String(h.month), d: String(h.day) }); }
    setBirthCalendar(c);   // the Gregorian value stays as it was, so switching back keeps it
  }
  const otherCalendar = (() => {
    if (!birthDate) return null;
    const [y, m, d] = birthDate.split("-").map(Number); if (!y || !m || !d) return null;
    if (birthCalendar === "hijri") return `الموافق ميلاديًا: ${d}/${m}/${y}`;
    const h = gregorianToHijri(y, m, d); return `الموافق هجريًا: ${h.day} ${HIJRI_MONTHS[h.month - 1]} ${h.year}هـ`;
  })();

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setFormError(null);
    if (!identityNumber.trim()) { setFormError("رقم الوثيقة مطلوب."); return; }
    if (!birthDate) { setFormError(hijriErr ?? "تاريخ الميلاد مطلوب."); return; }
    // 0047 / 0058: the name's parts for the document, letters only, the number's shape, the phone's shape, 15 or older
    const ruleError = fieldError(() => {
      checkNameParts(fullName, identityType);
      checkPersonName(fullName);
      checkIdentityNumber(identityType, latinDigits(identityNumber).replace(/\s/g, ""));
      checkPhone(phone, false);
      checkMinAge(birthDate, todayISO());
    }, VALIDATION_AR);
    if (ruleError) { setFormError(ruleError); return; }
    if (!consent) { setFormError("يجب الإقرار بصحة البيانات."); return; }
    if (needsAck && !ack) { setFormError("يجب الإقرار بملخص الإقامة."); return; }
    setSaving(true);
    try {
      await guestApi.submit(token, guest?.id ?? null, {
        full_name: fullName.trim(), identity_type: identityType, identity_number: latinDigits(identityNumber).replace(/\s/g, "").toUpperCase(), identity_issue_number: issueNumber.trim() || null,
        nationality: nationality.trim(), birth_date: birthDate, phone: phone.trim() || null, relationship: isPrimary ? "self" : relationship, consent: "true",
        ...(needsAck && ack ? { ack_hash: summary!.hash } : {}),
      });
      onSaved();
    } catch (err) {
      setFormError(toArabicError(err));
    }
    setSaving(false);
  }

  return (
    <Modal open={open} title={guest ? "استكمال البيانات" : "إضافة نزيل"} onClose={onClose}>
      <form onSubmit={save} className="space-y-4" autoComplete="off">
        <Field label={passportLike ? "الاسم كما في الوثيقة" : "الاسم الثلاثي (كما في الوثيقة)"} error={nameErr}>
          <input value={fullName} onChange={(e) => setFullName(e.target.value)} className="input" placeholder={passportLike ? "الاسم الأول واسم العائلة" : "الاسم الأول الأب الجد"} aria-invalid={!!nameErr} />
        </Field>
        <div className="grid grid-cols-2 gap-4">
          <Field label="نوع الوثيقة">
            <select value={identityType} onChange={(e) => setIdentityType(e.target.value as IdentityType)} className="input">
              {Object.entries(IDENTITY_TYPE_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select>
          </Field>
          <Field label={identityType === "passport" ? "رقم الجواز" : "رقم الوثيقة"} error={numberErr}>
            <input value={identityNumber} onChange={(e) => setIdentityNumber(e.target.value)} className="input" dir="ltr"
              inputMode={passportLike ? "text" : "numeric"} autoCapitalize={passportLike ? "characters" : "off"}
              placeholder={passportLike ? "حروف وأرقام" : "10 أرقام"} />
          </Field>
        </div>
        <div className="grid grid-cols-2 gap-4">
          <Field label="رقم الإصدار (إن وجد)"><input value={issueNumber} onChange={(e) => setIssueNumber(e.target.value)} className="input" dir="ltr" /></Field>
          <Field label="الجنسية"><input value={nationality} onChange={(e) => setNationality(e.target.value)} className="input" /></Field>
        </div>
        {!isPrimary && (
          <Field label="صلة القرابة" hint="الأطفال دون 15 سنة يُذكرون بأعمارهم في «أطفال دون 15 سنة» ولا يُسجَّلون هنا.">
            <select value={relationship} onChange={(e) => setRelationship(e.target.value)} className="input">
              <option value="spouse">زوج/زوجة</option><option value="child">ابن/ابنة (15 سنة فأكثر)</option><option value="parent">والد/والدة</option><option value="sibling">أخ/أخت</option><option value="other">أخرى</option>
            </select>
          </Field>
        )}
        <fieldset>
          <div className="mb-1.5 flex items-center gap-3">
            <legend className="label mb-0">تاريخ الميلاد</legend>
            <div className="flex gap-1 text-xs" role="radiogroup" aria-label="التقويم">
              {(["gregorian", "hijri"] as const).map((c) => (
                <button key={c} type="button" role="radio" aria-checked={birthCalendar === c} onClick={() => switchCalendar(c)}
                  className={`min-h-[36px] rounded-lg px-3 ${birthCalendar === c ? "bg-brand-100 text-brand-700" : "text-ink-500"}`}>{c === "gregorian" ? "ميلادي" : "هجري"}</button>
              ))}
            </div>
          </div>
          {birthCalendar === "gregorian" ? (
            <input type="date" value={birthDate} onChange={(e) => setBirthDate(e.target.value)} className="input" dir="ltr" max={maxBirthDate(todayISO())} aria-label="تاريخ الميلاد الميلادي" />
          ) : (
            <div className="grid grid-cols-3 gap-2">
              <select className="input" value={hijri.d} onChange={(e) => setHijri({ ...hijri, d: e.target.value })} aria-label="اليوم الهجري"><option value="">اليوم</option>{Array.from({ length: 30 }, (_, i) => <option key={i} value={i + 1}>{i + 1}</option>)}</select>
              <select className="input" value={hijri.m} onChange={(e) => setHijri({ ...hijri, m: e.target.value })} aria-label="الشهر الهجري"><option value="">الشهر</option>{HIJRI_MONTHS.map((m, i) => <option key={m} value={i + 1}>{m}</option>)}</select>
              <input className="input" dir="ltr" inputMode="numeric" maxLength={4} placeholder="السنة" value={hijri.y} onChange={(e) => setHijri({ ...hijri, y: e.target.value })} aria-label="السنة الهجرية" />
            </div>
          )}
          {hijriErr ? <p className="mt-1 text-xs text-danger-600" role="alert">{hijriErr}</p> : otherCalendar && <p className="mt-1 text-xs text-ink-500">{otherCalendar}</p>}
        </fieldset>
        <Field label={isPrimary ? "رقم الجوال (اختياري)" : "رقم الجوال (اختياري)"} hint={isPrimary ? "اتركه فارغًا ليبقى الرقم الذي حجزت به." : undefined} error={phoneErr}>
          <input value={phone} onChange={(e) => setPhone(e.target.value)} className="input" dir="ltr" inputMode="tel" placeholder="05XXXXXXXX" />
        </Field>

        {formError && <ErrorBanner message={formError} />}

        <label className="flex items-start gap-2 text-xs text-ink-600">
          <input type="checkbox" checked={consent} onChange={(e) => setConsent(e.target.checked)} className="mt-0.5 h-4 w-4" />
          <span>أُقر بصحة البيانات المُدخلة، واطلعت على <Link to="/privacy" target="_blank" className="text-brand-600 underline">سياسة الخصوصية</Link> و<Link to="/terms" target="_blank" className="text-brand-600 underline">شروط الاستخدام</Link>.</span>
        </label>
        {needsAck && (
          <div className="rounded-xl border border-brand-100 bg-brand-50/40 p-3" data-testid="summary-ack">
            <button type="button" onClick={() => setAckOpen((v) => !v)} className="text-xs font-medium text-brand-700 underline-offset-2 hover:underline">{ackOpen ? "إخفاء ملخص الإقامة" : "عرض ملخص الإقامة (الحجز، الوحدة، المدة، السعر، المدفوع، التأمين، سياسات الفرع)"}</button>
            {ackOpen && <pre className="mt-2 max-h-48 overflow-auto whitespace-pre-wrap font-sans text-[11px] leading-relaxed text-ink-600" dir={summary!.language === "en" ? "ltr" : "rtl"}>{summary!.text}</pre>}
            <label className="mt-2 flex items-start gap-2 text-xs text-ink-600">
              <input type="checkbox" checked={ack} onChange={(e) => setAck(e.target.checked)} className="mt-0.5 h-4 w-4" aria-label="أقرّ بملخص الإقامة" />
              <span>قرأت ملخص الإقامة وأقرّ به (يُحفظ نص الملخص ووقت الإقرار).</span>
            </label>
          </div>
        )}

        <div className="sticky bottom-0 -mx-5 bg-white px-5 pb-1 pt-2 sm:-mx-6 sm:px-6">
          <button type="submit" className="btn-primary w-full" disabled={saving}>{saving ? <Spinner /> : "حفظ البيانات"}</button>
        </div>
      </form>
      <p className="mt-3 text-center text-xs text-ink-500">يُشفَّر رقم الوثيقة على الخادم فور الحفظ ولا يُعرض كاملًا لأحد بعد ذلك.</p>
    </Modal>
  );
}
