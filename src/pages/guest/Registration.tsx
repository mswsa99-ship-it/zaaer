import { useEffect, useState, useCallback, useRef } from "react";
import { GuestLinkError } from "../../components/GuestLinkError";
import { useParams, useNavigate, Link } from "react-router-dom";
import { ArrowRight, ArrowLeft, UserPlus, CheckCircle2, AlertCircle, IdCard, Baby, Plus, X } from "lucide-react";
import { guestApi, VALIDATION_AR, type GuestSession, type GuestStaySummary } from "../../lib/api";
import { useGuestLang, guestError, validationMessages, IDENTITY_TYPE_EN, VERIFICATION_EN, countEn } from "../../lib/guestLang";
import { Card, ErrorBanner, Spinner } from "../../components/ui";
import { Modal, Field } from "../../components/forms";
import { IDENTITY_TYPE_LABELS, GUEST_VERIFICATION_LABELS, type IdentityType, type GuestVerificationStatus } from "../../lib/types";
import { gregorianToHijri, hijriToGregorian, maskId, todayISO, COUNT, HIJRI_MONTH_NAMES, HIJRI_MONTH_NAMES_EN, radioGroupKeys } from "../../lib/utils";
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
  const { en, t } = useGuestLang();
  const enRef = useRef(en); enRef.current = en;

  const load = useCallback(async () => {
    if (!token) return;
    try {
      const [s, c] = await Promise.all([guestApi.session(token), guestApi.children(token).catch(() => null)]);
      setData(s); setKids(c); setError(null);
    } catch (e) { setError(guestError(e, enRef.current)); }
    setLoading(false);
  }, [token]);
  useEffect(() => { load(); }, [load]);

  if (loading) return <div className="mx-auto max-w-md px-4 py-12"><Spinner className="mx-auto h-8 w-8" /></div>;
  if (error || !data) return <GuestLinkError message={error ?? t("الرابط غير صالح", "This link is not valid")} />;

  const r = data.reservation;
  const children = kids?.children_ages ?? [];
  const target = kids?.target ?? r.adults + r.companions;
  const submittedCount = data.guests.filter((g) => g.data_submitted).length;
  const allSubmitted = submittedCount >= target && target > 0;
  const canAdd = data.guests.length < target;

  return (
    <div className="mx-auto max-w-2xl px-4 py-8 lg:py-12">
      <Link to={`/booking/status/${token}`} className="mb-4 inline-flex min-h-[44px] items-center gap-1.5 text-sm text-ink-500 hover:text-ink-700">{en ? <ArrowLeft className="h-4 w-4" /> : <ArrowRight className="h-4 w-4" />} {t("حالة الحجز", "Booking status")}</Link>

      <div className="mb-6">
        <h1 className="text-2xl font-bold text-ink-800">{t("تسجيل بيانات النزلاء", "Guests' details")}</h1>
        <p className="mt-2 text-sm text-ink-500">{t("الحجز", "Booking")} <span dir="ltr">{r.internal_ref}</span> — {r.branch_name}</p>
        <div className="mt-3 flex flex-wrap gap-2 text-xs text-ink-500">
          <span className="rounded-lg bg-ink-50 px-3 py-1">{t("الوصول:", "Arrival:")} {r.check_in}</span>
          <span className="rounded-lg bg-ink-50 px-3 py-1">{t("المغادرة:", "Departure:")} {r.check_out}</span>
          <span className="rounded-lg bg-ink-50 px-3 py-1">{en ? `${countEn(r.adults + r.companions, "guest")}${children.length ? `, of whom ${countEn(children.length, "child", "children")} under 15` : ""}` : `${COUNT.guest(r.adults + r.companions)}${children.length ? `، منهم ${COUNT.child(children.length)} دون 15 سنة` : ""}`}</span>
        </div>
      </div>

      <Card className="mb-6">
        <div className="flex items-center justify-between">
          <div><p className="text-sm font-medium text-ink-700">{t("تقدّم التسجيل", "Progress")}</p><p className="mt-1 text-xs text-ink-500">{en ? `${submittedCount} of ${countEn(target, "guest")} registered` : `سُجّلت بيانات ${submittedCount} من ${COUNT.guest(target)}`}</p></div>
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
                  <p className="text-sm font-semibold text-ink-800">{g.full_name || t("لم يُسجّل بعد", "Not registered yet")}</p>
                  {g.is_primary && <span className="badge bg-brand-50 text-brand-700">{t("رئيسي", "Main guest")}</span>}
                </div>
                <p className="mt-0.5 text-xs text-ink-500">
                  {g.identity_type ? (en ? IDENTITY_TYPE_EN[g.identity_type] : IDENTITY_TYPE_LABELS[g.identity_type as IdentityType]) : "—"} · {g.identity_number_last4 ? <span dir="ltr">{maskId(g.identity_number_last4)}</span> : t("بدون رقم", "No number")} · {en ? VERIFICATION_EN[g.verification_status] ?? g.verification_status : GUEST_VERIFICATION_LABELS[g.verification_status as GuestVerificationStatus]}
                </p>
              </div>
            </div>
            {g.verification_status === "verified" ? (
              <span className="badge bg-success-500/10 text-success-600"><CheckCircle2 className="h-3 w-3" /> {t("معتمد", "Verified")}</span>
            ) : g.data_submitted ? (
              <button onClick={() => setEditing({ guest: g, open: true })} className="btn-ghost min-h-[44px] text-xs text-brand-600">{t("تعديل", "Edit")}</button>
            ) : (
              <button onClick={() => setEditing({ guest: g, open: true })} className="btn-outline text-xs"><UserPlus className="h-3.5 w-3.5" /> {t("استكمال البيانات", "Add details")}</button>
            )}
          </Card>
        ))}

        {canAdd && (
          <Card className="flex flex-wrap items-center justify-between gap-2 border-dashed">
            <p className="text-sm text-ink-500">{en ? `${countEn(target - data.guests.length, "guest")} (15 or older) still to add` : `${target - data.guests.length === 1 ? "بقي نزيل واحد لم تُضف بياناته" : `بقي ${COUNT.guest(target - data.guests.length)} لم تُضف بياناتهم`} (15 سنة فأكثر)`}</p>
            <button onClick={() => setEditing({ guest: null, open: true })} className="btn-outline text-xs"><UserPlus className="h-3.5 w-3.5" /> {t("إضافة نزيل", "Add a guest")}</button>
          </Card>
        )}

        {token && <ChildrenCard token={token} ages={children} editable={!["cancelled", "rejected", "closed", "checked_out", "no_show"].includes(r.status)} onSaved={load} />}
      </div>

      {allSubmitted ? (
        <div className="mt-8 rounded-2xl bg-success-500/10 p-5 text-center">
          <CheckCircle2 className="mx-auto mb-2 h-8 w-8 text-success-600" />
          <p className="text-sm font-medium text-success-600">{t("تم إكمال تسجيل بيانات جميع النزلاء", "All guests' details are complete")}</p>
          <p className="mt-1 text-xs text-ink-500">{t("سيطابق المشرف البيانات مع الوثائق الأصلية عند الوصول.", "The reception will check the details against the original documents when you arrive.")}</p>
          <button onClick={() => navigate(`/booking/status/${token}`)} className="btn-primary mt-4">{t("متابعة حالة الحجز", "Go to booking status")}</button>
        </div>
      ) : (
        <div className="mt-6 rounded-xl bg-warning-500/10 p-4 text-sm text-warning-700">
          <div className="flex items-start gap-2"><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" /><p>{t("يجب إكمال بيانات جميع النزلاء (15 سنة فأكثر) قبل تسجيل الوصول. إدخال البيانات لا يعني مطابقة الهوية — سيراجعها المشرف مع الوثيقة الأصلية.", "Every guest aged 15 or older needs their details before check-in. Submitting them is not the ID check — the reception checks them against the original document.")}</p></div>
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
  const { en, t } = useGuestLang();
  useEffect(() => { setList(ages.map(String)); }, [ages.join(",")]); // eslint-disable-line react-hooks/exhaustive-deps
  const dirty = list.join(",") !== ages.join(",");
  async function save() {
    setBusy(true); setErr(null); setSaved(false);
    try {
      const v = list.map((x) => latinDigits(x).trim()).filter((x) => x !== "");
      if (v.some((x) => !/^\d{1,2}$/.test(x) || Number(x) > 14)) throw new Error("VALIDATION: child_age");
      await guestApi.setChildren(token, v.map(Number)); setSaved(true); onSaved();
    } catch (e) { setErr(guestError(e, en)); }
    setBusy(false);
  }
  return (
    <Card className="space-y-3" data-testid="children">
      <div className="flex items-start gap-3">
        <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-accent-500/10 text-accent-700"><Baby className="h-5 w-5" /></div>
        <div>
          <p className="text-sm font-semibold text-ink-800">{t("أطفال دون 15 سنة", "Children under 15")}</p>
          <p className="mt-0.5 text-xs leading-5 text-ink-500">{t("لا يُسجَّل الأطفال دون 15 سنة بوثيقة. اذكر أعمارهم هنا: يُحسبون في عدد نزلاء الحجز ويراهم المشرف، ويُعرَّف بهم عند الوصول.", "Children under 15 are not registered with a document. Give their ages here: they count among the booking's guests, the reception sees them, and they are introduced on arrival.")}</p>
        </div>
      </div>
      {list.length > 0 && (
        <ul className="flex flex-wrap gap-2">
          {list.map((a, i) => (
            <li key={i} className="flex items-center gap-1 rounded-xl bg-ink-50 px-2 py-1">
              <label className="text-xs text-ink-600" htmlFor={`child-${i}`}>{t(`الطفل ${i + 1}: العمر`, `Child ${i + 1}: age`)}</label>
              <input id={`child-${i}`} className="input w-16 py-1 text-center" dir="ltr" inputMode="numeric" maxLength={2} value={a} disabled={!editable}
                onChange={(e) => setList(list.map((x, j) => (j === i ? e.target.value : x)))} />
              {editable && <button type="button" className="btn-ghost min-h-[44px] min-w-[44px] p-1" aria-label={t(`حذف الطفل ${i + 1}`, `Remove child ${i + 1}`)} onClick={() => setList(list.filter((_, j) => j !== i))}><X className="h-4 w-4" /></button>}
            </li>
          ))}
        </ul>
      )}
      {err && <ErrorBanner message={err} />}
      {saved && !dirty && <p className="text-xs text-success-600" role="status">{t("حُفظت أعمار الأطفال.", "The children's ages are saved.")}</p>}
      {editable && (
        <div className="flex flex-wrap gap-2">
          {list.length < 10 && <button type="button" className="btn-outline text-xs" onClick={() => setList([...list, ""])}><Plus className="h-3.5 w-3.5" /> {t("إضافة طفل", "Add a child")}</button>}
          {dirty && <button type="button" className="btn-primary text-xs" disabled={busy} onClick={save}>{busy ? <Spinner className="h-3.5 w-3.5" /> : t("حفظ الأعمار", "Save ages")}</button>}
        </div>
      )}
    </Card>
  );
}

const HIJRI_MONTHS = HIJRI_MONTH_NAMES;
const HIJRI_MONTHS_EN = HIJRI_MONTH_NAMES_EN;
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
  const { en, t } = useGuestLang();
  const MSG = validationMessages(en, VALIDATION_AR);
  const months = en ? HIJRI_MONTHS_EN : HIJRI_MONTHS;

  useEffect(() => {
    if (!open) return;
    setFullName(guest?.full_name ?? ""); setIdentityType((guest?.identity_type as IdentityType) ?? "national_id"); setIdentityNumber(""); setIssueNumber("");
    setNationality(guest?.nationality ?? (en ? "" : "سعودي")); setBirthDate(guest?.birth_date ?? ""); setBirthCalendar("gregorian"); setHijri({ y: "", m: "", d: "" });
    setPhone(""); setRelationship(guest?.relationship && guest.relationship !== "self" ? guest.relationship : "other"); setConsent(false); setAck(false); setFormError(null);
    if (guest?.is_primary) guestApi.staySummary(token).then(setSummary).catch(() => setSummary(null)); else setSummary(null);
  }, [open, guest, token]); // eslint-disable-line react-hooks/exhaustive-deps
  const needsAck = isPrimary && !!summary && !summary.accepted_at;
  const passportLike = identityType === "passport" || identityType === "gcc_id";

  // 0047: each field says its rule while typing (the server refuses the same)
  const nameErr = fullName.trim() ? fieldError(() => { checkPersonName(fullName); }, MSG) : null;
  const numberErr = identityNumber.trim() ? fieldError(() => checkIdentityNumber(identityType, latinDigits(identityNumber).replace(/\s/g, "")), MSG) : null;
  const phoneErr = phone.trim() ? fieldError(() => checkPhone(phone, false), MSG) : null;

  // GUEST-06: the Hijri date is read as numbers whatever digits are typed, and checked before it is converted
  const hy = Number(latinDigits(hijri.y)), hm = Number(hijri.m), hd = Number(hijri.d);
  const hijriValid = hy >= 1300 && hy <= 1500 && hm >= 1 && hm <= 12 && hd >= 1 && hd <= 30;
  const hijriErr = birthCalendar === "hijri" && hijri.y && hijri.m && hijri.d && !hijriValid ? t("التاريخ الهجري غير صحيح (السنة بين 1300 و1500).", "The Hijri date is not valid (the year is between 1300 and 1500).") : null;
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
    if (birthCalendar === "hijri") return t(`الموافق ميلاديًا: ${d}/${m}/${y}`, `Gregorian: ${d}/${m}/${y}`);
    const h = gregorianToHijri(y, m, d); return t(`الموافق هجريًا: ${h.day} ${HIJRI_MONTHS[h.month - 1]} ${h.year}هـ`, `Hijri: ${h.day} ${HIJRI_MONTHS_EN[h.month - 1]} ${h.year} AH`);
  })();

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setFormError(null);
    if (!identityNumber.trim()) { setFormError(t("رقم الوثيقة مطلوب.", "The document number is required.")); return; }
    if (!birthDate) { setFormError(hijriErr ?? t("تاريخ الميلاد مطلوب.", "The date of birth is required.")); return; }
    // 0047 / 0058: the name's parts for the document, letters only, the number's shape, the phone's shape, 15 or older
    const ruleError = fieldError(() => {
      checkNameParts(fullName, identityType);
      checkPersonName(fullName);
      checkIdentityNumber(identityType, latinDigits(identityNumber).replace(/\s/g, ""));
      checkPhone(phone, false);
      checkMinAge(birthDate, todayISO());
    }, MSG);
    if (ruleError) { setFormError(ruleError); return; }
    if (!consent) { setFormError(t("يجب الإقرار بصحة البيانات.", "Please confirm the details are correct.")); return; }
    if (needsAck && !ack) { setFormError(t("يجب الإقرار بملخص الإقامة.", "Please accept the stay summary.")); return; }
    setSaving(true);
    try {
      await guestApi.submit(token, guest?.id ?? null, {
        full_name: fullName.trim(), identity_type: identityType, identity_number: latinDigits(identityNumber).replace(/\s/g, "").toUpperCase(), identity_issue_number: issueNumber.trim() || null,
        nationality: nationality.trim(), birth_date: birthDate, phone: phone.trim() || null, relationship: isPrimary ? "self" : relationship, consent: "true",
        ...(needsAck && ack ? { ack_hash: summary!.hash } : {}),
      });
      onSaved();
    } catch (err) {
      setFormError(guestError(err, en));
    }
    setSaving(false);
  }

  return (
    <Modal open={open} title={guest ? t("استكمال البيانات", "Guest details") : t("إضافة نزيل", "Add a guest")} onClose={onClose} closeLabel={t("إغلاق", "Close")}>
      <form onSubmit={save} className="space-y-4" autoComplete="off">
        <Field label={passportLike ? t("الاسم كما في الوثيقة", "Name as on the document") : t("الاسم الثلاثي (كما في الوثيقة)", "Full name (as on the ID: first, father's, family)")} error={nameErr}>
          <input value={fullName} onChange={(e) => setFullName(e.target.value)} className="input" placeholder={passportLike ? t("الاسم الأول واسم العائلة", "First name and family name") : t("الاسم الأول الأب الجد", "First, father's and family name")} aria-invalid={!!nameErr} />
        </Field>
        <div className="grid grid-cols-2 gap-4">
          <Field label={t("نوع الوثيقة", "Document type")}>
            <select value={identityType} onChange={(e) => setIdentityType(e.target.value as IdentityType)} className="input">
              {Object.entries(IDENTITY_TYPE_LABELS).map(([k, v]) => <option key={k} value={k}>{en ? IDENTITY_TYPE_EN[k] : v}</option>)}
            </select>
          </Field>
          <Field label={identityType === "passport" ? t("رقم الجواز", "Passport number") : t("رقم الوثيقة", "Document number")} error={numberErr}>
            <input value={identityNumber} onChange={(e) => setIdentityNumber(e.target.value)} className="input" dir="ltr"
              inputMode={passportLike ? "text" : "numeric"} autoCapitalize={passportLike ? "characters" : "off"}
              placeholder={passportLike ? t("حروف وأرقام", "Letters and digits") : t("10 أرقام", "10 digits")} />
          </Field>
        </div>
        <div className="grid grid-cols-2 gap-4">
          <Field label={t("رقم الإصدار (إن وجد)", "Issue number (if any)")}><input value={issueNumber} onChange={(e) => setIssueNumber(e.target.value)} className="input" dir="ltr" /></Field>
          <Field label={t("الجنسية", "Nationality")}><input value={nationality} onChange={(e) => setNationality(e.target.value)} className="input" /></Field>
        </div>
        {!isPrimary && (
          <Field label={t("صلة القرابة", "Relationship")} hint={t("الأطفال دون 15 سنة يُذكرون بأعمارهم في «أطفال دون 15 سنة» ولا يُسجَّلون هنا.", "Children under 15 are given by age under «Children under 15», not registered here.")}>
            <select value={relationship} onChange={(e) => setRelationship(e.target.value)} className="input">
              <option value="spouse">{t("زوج/زوجة", "Spouse")}</option><option value="child">{t("ابن/ابنة (15 سنة فأكثر)", "Son/daughter (15 or older)")}</option><option value="parent">{t("والد/والدة", "Parent")}</option><option value="sibling">{t("أخ/أخت", "Sibling")}</option><option value="other">{t("أخرى", "Other")}</option>
            </select>
          </Field>
        )}
        <fieldset>
          <div className="mb-1.5 flex items-center gap-3">
            <legend className="label mb-0">{t("تاريخ الميلاد", "Date of birth")}</legend>
            <div className="flex gap-1 text-xs" role="radiogroup" onKeyDown={radioGroupKeys} aria-label={t("التقويم", "Calendar")}>
              {(["gregorian", "hijri"] as const).map((c) => (
                <button key={c} type="button" role="radio" aria-checked={birthCalendar === c} tabIndex={birthCalendar === c ? 0 : -1} onClick={() => switchCalendar(c)}
                  className={`min-h-[36px] rounded-lg px-3 ${birthCalendar === c ? "bg-brand-100 text-brand-700" : "text-ink-500"}`}>{c === "gregorian" ? t("ميلادي", "Gregorian") : t("هجري", "Hijri")}</button>
              ))}
            </div>
          </div>
          {birthCalendar === "gregorian" ? (
            <input type="date" value={birthDate} onChange={(e) => setBirthDate(e.target.value)} className="input" dir="ltr" max={maxBirthDate(todayISO())} aria-label={t("تاريخ الميلاد الميلادي", "Date of birth (Gregorian)")} />
          ) : (
            <div className="grid grid-cols-3 gap-2">
              <select className="input" value={hijri.d} onChange={(e) => setHijri({ ...hijri, d: e.target.value })} aria-label={t("اليوم الهجري", "Hijri day")}><option value="">{t("اليوم", "Day")}</option>{Array.from({ length: 30 }, (_, i) => <option key={i} value={i + 1}>{i + 1}</option>)}</select>
              <select className="input" value={hijri.m} onChange={(e) => setHijri({ ...hijri, m: e.target.value })} aria-label={t("الشهر الهجري", "Hijri month")}><option value="">{t("الشهر", "Month")}</option>{months.map((m, i) => <option key={m} value={i + 1}>{m}</option>)}</select>
              <input className="input" dir="ltr" inputMode="numeric" maxLength={4} placeholder={t("السنة", "Year")} value={hijri.y} onChange={(e) => setHijri({ ...hijri, y: e.target.value })} aria-label={t("السنة الهجرية", "Hijri year")} />
            </div>
          )}
          {hijriErr ? <p className="mt-1 text-xs text-danger-600" role="alert">{hijriErr}</p> : otherCalendar && <p className="mt-1 text-xs text-ink-500">{otherCalendar}</p>}
        </fieldset>
        <Field label={t("رقم الجوال (اختياري)", "Mobile number (optional)")} hint={isPrimary ? t("الرقم الذي حُجز به يبقى كما هو؛ لتغييره تواصل مع الاستقبال.", "The number the booking was made with stays as it is; to change it, contact the reception.") : undefined} error={phoneErr}>
          <input value={phone} onChange={(e) => setPhone(e.target.value)} className="input" dir="ltr" inputMode="tel" placeholder="05XXXXXXXX" />
        </Field>

        {formError && <ErrorBanner message={formError} />}

        <label className="flex items-start gap-2 text-xs text-ink-600">
          <input type="checkbox" checked={consent} onChange={(e) => setConsent(e.target.checked)} className="mt-0.5 h-4 w-4" />
          {en
            ? <span>I confirm these details are correct, and I have read the <Link to="/privacy" target="_blank" className="text-brand-600 underline">privacy policy</Link> and the <Link to="/terms" target="_blank" className="text-brand-600 underline">terms of use</Link> (in Arabic).</span>
            : <span>أُقر بصحة البيانات المُدخلة، واطلعت على <Link to="/privacy" target="_blank" className="text-brand-600 underline">سياسة الخصوصية</Link> و<Link to="/terms" target="_blank" className="text-brand-600 underline">شروط الاستخدام</Link>.</span>}
        </label>
        {needsAck && (
          <div className="rounded-xl border border-brand-100 bg-brand-50/40 p-3" data-testid="summary-ack">
            <button type="button" onClick={() => setAckOpen((v) => !v)} className="text-xs font-medium text-brand-700 underline-offset-2 hover:underline">{ackOpen ? t("إخفاء ملخص الإقامة", "Hide the stay summary") : t("عرض ملخص الإقامة (الحجز، الوحدة، المدة، السعر، المدفوع، التأمين، سياسات الفرع)", "Show the stay summary (booking, unit, dates, price, paid, deposit, property rules)")}</button>
            {ackOpen && <pre className="mt-2 max-h-48 overflow-auto whitespace-pre-wrap font-sans text-[11px] leading-relaxed text-ink-600" dir={summary!.language === "en" ? "ltr" : "rtl"}>{summary!.text}</pre>}
            <label className="mt-2 flex items-start gap-2 text-xs text-ink-600">
              <input type="checkbox" checked={ack} onChange={(e) => setAck(e.target.checked)} className="mt-0.5 h-4 w-4" aria-label={t("أقرّ بملخص الإقامة", "I accept the stay summary")} />
              <span>{t("قرأت ملخص الإقامة وأقرّ به (يُحفظ نص الملخص ووقت الإقرار).", "I have read and accept the stay summary (its text and the time are kept).")}</span>
            </label>
          </div>
        )}

        <div className="sticky bottom-0 -mx-5 bg-white px-5 pb-1 pt-2 sm:-mx-6 sm:px-6">
          <button type="submit" className="btn-primary w-full" disabled={saving}>{saving ? <Spinner /> : t("حفظ البيانات", "Save details")}</button>
        </div>
      </form>
      <p className="mt-3 text-center text-xs text-ink-500">{t("يُشفَّر رقم الوثيقة على الخادم فور الحفظ ولا يُعرض كاملًا لأحد بعد ذلك.", "The document number is encrypted on the server when saved and is never shown in full again.")}</p>
    </Modal>
  );
}
