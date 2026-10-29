/**
 * Phase 5 pieces of the booking page (decisions 2, 4, 19, 21, 69):
 *  - GuestAlerts: the red alert of a banned guest, the hold on the booking, the main guest's rating and internal note;
 *  - OfficeGuestDialog: the office path of guest data (from the original document, verified at once; a correction with a reason);
 *  - HoldDialog / RateDialog: a hold on one booking; the rating 1–5 with an internal note;
 *  - CancelDialog: cancelling a platform's booking with the platform's cancellation number, the whole group at once;
 *  - PlatformPanel: the platform's fields and «طابقتُ مع المنصة»;
 *  - GroupPanel: the group's units with their own money and the totals;
 *  - StaySummaryDialog: «ملخص الإقامة» to print, and the guest's paper signature recorded against it.
 * Nothing here computes a rule the server does not enforce; every button names what it does.
 */
import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { ShieldAlert, ShieldBan, Star, IdCard, Printer, Link2, CheckCircle2, Users, Ban, FileSignature } from "lucide-react";
import { opsApi, guestApi, guestProfileApi, toArabicError, VALIDATION_AR, type ReservationDetail, type GroupSummary, type StaySummary, type Acknowledgement } from "../lib/api";
import { useAuth } from "../lib/auth";
import { Card, Badge, ErrorBanner, Spinner } from "./ui";
import { Modal, Field, ActionForm, Submit, ReasonInput, Toggle } from "./forms";
import { IDENTITY_TYPE_LABELS, type IdentityType } from "../lib/types";
import { formatCurrency, formatDateTime, todayISO, maskId } from "../lib/utils";
import { checkIdentityNumber, checkMinAge, checkPersonName, checkPhone, fieldError, latinDigits, maxBirthDate } from "../lib/validation";

const sar = (h: number | null | undefined) => formatCurrency((h ?? 0) / 100);
type Guest = ReservationDetail["guests"][number];

/** The red alert of a ban, the hold, and the main guest's rating (decision 21) — above everything else on the booking page. */
export function GuestAlerts({ d, onChanged }: { d: ReservationDetail; onChanged: () => void }) {
  const { can } = useAuth();
  const canHold = can("hold.set");
  const canLift = can("hold.lift");
  const canRate = can("guest.rate");
  const [dialog, setDialog] = useState<null | "hold" | "lift" | "rate">(null);
  const bans = d.bans ?? [];
  const gp = d.guest_profile;
  const open = !["cancelled", "rejected", "closed", "no_show"].includes(d.reservation.status);
  return (
    <div className="space-y-3">
      {bans.map((b) => (
        <div key={b.ban_id} data-testid="guest-ban-alert" className="flex items-start gap-3 rounded-xl border border-danger-500/40 bg-danger-500/10 px-4 py-3 text-sm text-danger-600">
          <ShieldBan className="mt-0.5 h-5 w-5 shrink-0" />
          <div className="min-w-0">
            <p className="font-semibold">الضيف محظور من الإدارة — لا يُسجَّل الوصول ولا يُسلَّم الرمز</p>
            <p className="mt-0.5 text-xs">{b.name} · السبب: {b.reason} · منذ {formatDateTime(b.since)} · المطابقة: {b.matched_by.map((m) => ({ profile: "ملف الضيف", identity: "الهوية", phone: "الجوال" })[m] ?? m).join("، ")}</p>
            {gp && <Link to={`/admin/guests/${gp.id}`} className="mt-1 inline-block text-xs underline">ملف الضيف</Link>}
          </div>
        </div>
      ))}
      {d.hold && (
        <div data-testid="hold-alert" className="flex items-start gap-3 rounded-xl border border-danger-500/30 bg-danger-500/10 px-4 py-3 text-sm text-danger-600">
          <ShieldAlert className="mt-0.5 h-5 w-5 shrink-0" />
          <div className="min-w-0 flex-1">
            <p className="font-semibold">يوجد حظر على هذا الحجز</p>
            <p className="mt-0.5 text-xs">{d.hold.reason}{d.hold.by ? ` · ${d.hold.by}` : ""}{d.hold.at ? ` · ${formatDateTime(d.hold.at)}` : ""}</p>
            <p className="mt-0.5 text-xs">لا يُسجَّل الوصول ولا يُسلَّم الرمز حتى يرفعه المالك أو المدير بسبب.</p>
          </div>
          {canLift && <button onClick={() => setDialog("lift")} className="btn-outline text-xs">رفع الحظر</button>}
        </div>
      )}
      {(gp?.rating != null || gp?.rating_note) && (
        <div data-testid="guest-rating" className="flex items-start gap-3 rounded-xl border border-warning-500/30 bg-warning-500/10 px-4 py-2.5 text-sm text-ink-700">
          <Star className="mt-0.5 h-4 w-4 shrink-0 text-warning-600" />
          <div className="min-w-0 flex-1">
            <p className="text-xs font-semibold">تقييم الضيف: {gp.rating != null ? <Stars n={gp.rating} /> : "—"}{gp.stays > 1 ? ` · ${gp.stays} إقامات` : ""}</p>
            {gp.rating_note && <p className="mt-0.5 text-xs text-ink-600">ملاحظة داخلية: {gp.rating_note}{gp.rated_by ? ` — ${gp.rated_by}` : ""}</p>}
          </div>
        </div>
      )}
      {(canHold || (gp && canRate)) && open && (
        <div className="flex flex-wrap gap-2">
          {canHold && !d.hold && <button onClick={() => setDialog("hold")} className="btn-ghost text-xs text-danger-600"><ShieldAlert className="h-3.5 w-3.5" /> وضع حظر على الحجز</button>}
          {gp && canRate && <button onClick={() => setDialog("rate")} className="btn-ghost text-xs"><Star className="h-3.5 w-3.5" /> {gp.rating != null ? "تعديل تقييم الضيف" : "تقييم الضيف"}</button>}
        </div>
      )}
      <HoldDialog open={dialog === "hold" || dialog === "lift"} hold={dialog === "hold"} reservationId={d.reservation.id} onClose={() => setDialog(null)} onDone={() => { setDialog(null); onChanged(); }} />
      {gp && <RateDialog open={dialog === "rate"} profileId={gp.id} rating={gp.rating} note={gp.rating_note} onClose={() => setDialog(null)} onDone={() => { setDialog(null); onChanged(); }} />}
    </div>
  );
}

export function Stars({ n }: { n: number }) {
  return <span className="inline-flex items-center gap-0.5 align-middle" aria-label={`${n} من 5`} dir="ltr">{[1, 2, 3, 4, 5].map((i) => <Star key={i} className={`h-3.5 w-3.5 ${i <= n ? "fill-warning-500 text-warning-500" : "text-ink-200"}`} />)}</span>;
}

function HoldDialog({ open, hold, reservationId, onClose, onDone }: { open: boolean; hold: boolean; reservationId: string; onClose: () => void; onDone: () => void }) {
  const [reason, setReason] = useState("");
  return (
    <Modal open={open} title={hold ? "وضع حظر على الحجز" : "رفع الحظر عن الحجز"} onClose={onClose}>
      <ActionForm onSubmit={async () => { if (!reason.trim()) throw new Error("VALIDATION: reason"); await opsApi.setHold(reservationId, hold, reason.trim()); setReason(""); onDone(); }}>
        <div className="mb-3 flex items-start gap-2 rounded-xl bg-warning-500/10 p-3 text-xs text-warning-600"><ShieldAlert className="mt-0.5 h-4 w-4 shrink-0" />
          {hold ? "يمنع الحظر تسجيل الوصول وتسليم الرمز لهذا الحجز وحده، ويُدرَج في قائمة المراجعة. رفعه للمالك أو المدير بسبب." : "يعود الحجز إلى مساره الطبيعي؛ السبب يُحفظ في السجل."}
        </div>
        <ReasonInput value={reason} onChange={setReason} />
        <Submit label={hold ? "وضع الحظر" : "رفع الحظر"} onCancel={onClose} danger={hold} />
      </ActionForm>
    </Modal>
  );
}

export function RateDialog({ open, profileId, rating, note, onClose, onDone }: { open: boolean; profileId: string; rating: number | null; note: string | null; onClose: () => void; onDone: () => void }) {
  const [r, setR] = useState<number | null>(rating);
  const [n, setN] = useState(note ?? "");
  useEffect(() => { if (open) { setR(rating); setN(note ?? ""); } }, [open, rating, note]);
  return (
    <Modal open={open} title="تقييم الضيف" onClose={onClose}>
      <ActionForm onSubmit={async () => { await guestProfileApi.rate(profileId, r, n.trim() || null); onDone(); }}>
        <p className="mb-3 text-xs text-ink-500">تقييم داخلي من 1 إلى 5 مع ملاحظة يراها الموظفون في حجوزات الضيف القادمة. لا يراه الضيف.</p>
        <div className="mb-3 flex items-center gap-1" dir="ltr" data-testid="rate-stars">
          {[1, 2, 3, 4, 5].map((i) => <button key={i} type="button" onClick={() => setR(i)} aria-label={`${i} من 5`} className="p-1"><Star className={`h-6 w-6 ${r != null && i <= r ? "fill-warning-500 text-warning-500" : "text-ink-200"}`} /></button>)}
          {r != null && <button type="button" onClick={() => setR(null)} className="ml-2 text-xs text-ink-400">بلا تقييم</button>}
        </div>
        <Field label="ملاحظة داخلية (اختياري، حتى 500 حرف)"><textarea className="input" rows={2} maxLength={500} value={n} onChange={(e) => setN(e.target.value)} aria-label="ملاحظة داخلية" /></Field>
        <Submit label="حفظ" onCancel={onClose} />
      </ActionForm>
    </Modal>
  );
}

/** The office path (decision 2): the owner, a manager or the supervisor enters a guest from the original document. */
export function OfficeGuestDialog({ open, reservationId, guest, onClose, onDone }: { open: boolean; reservationId: string; guest: Guest | null; onClose: () => void; onDone: () => void }) {
  const correcting = !!guest?.data_submitted;
  const [f, setF] = useState({ full_name: "", identity_type: "national_id" as IdentityType, identity_number: "", identity_issue_number: "", nationality: "سعودي", birth_date: "", phone: "", relationship: "other", matched: false, reason: "" });
  useEffect(() => {
    if (open) setF({ full_name: guest?.full_name ?? "", identity_type: (guest?.identity_type as IdentityType) ?? "national_id", identity_number: "", identity_issue_number: "", nationality: guest?.nationality ?? "سعودي", birth_date: guest?.birth_date ?? "", phone: "", relationship: guest?.relationship && guest.relationship !== "self" ? guest.relationship : "other", matched: false, reason: "" });
  }, [open, guest]);
  // 0047: the rules the server applies, said while typing
  const idNumber = latinDigits(f.identity_number).replace(/\s/g, "");
  const errs = {
    name: fieldError(() => checkPersonName(f.full_name), VALIDATION_AR),
    number: idNumber ? fieldError(() => checkIdentityNumber(f.identity_type, idNumber), VALIDATION_AR) : null,
    birth: f.birth_date ? fieldError(() => checkMinAge(f.birth_date, todayISO()), VALIDATION_AR) : null,
    phone: f.phone.trim() ? fieldError(() => checkPhone(f.phone, false), VALIDATION_AR) : null,
  };
  return (
    <Modal open={open} title={guest ? (correcting ? `تصحيح بيانات ${guest.full_name}` : `إدخال بيانات ${guest.full_name} من الوثيقة`) : "إضافة مرافق من الوثيقة"} onClose={onClose} wide>
      <ActionForm onSubmit={async () => {
        await opsApi.enterGuest({ reservation_id: reservationId, guest_id: guest?.id ?? null, full_name: f.full_name.trim(), identity_type: f.identity_type, identity_number: f.identity_number.trim(), identity_issue_number: f.identity_issue_number.trim() || null,
          nationality: f.nationality.trim(), birth_date: f.birth_date, phone: f.phone.trim() || null, relationship: guest?.is_primary ? "self" : f.relationship, document_matched: f.matched, reason: f.reason.trim() || null });
        onDone();
      }}>
        <p className="mb-3 rounded-lg bg-ink-50 px-3 py-2 text-xs text-ink-500">الإدخال من الوثيقة الأصلية يعتمد الهوية فورًا باسمك؛ رقم الوثيقة يُشفَّر ولا يُعرض كاملًا بعد الحفظ.{correcting ? " التصحيح يُسجَّل بسبب، بالقيم قبله وبعده مقنَّعة، ويُدرَج في قائمة المراجعة." : ""}</p>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="الاسم الثلاثي (كما في الوثيقة)" className="sm:col-span-2" error={errs.name}><input className="input" value={f.full_name} aria-invalid={!!errs.name} onChange={(e) => setF({ ...f, full_name: e.target.value })} aria-label="الاسم الثلاثي" /></Field>
          <Field label="نوع الوثيقة"><select className="input" value={f.identity_type} onChange={(e) => setF({ ...f, identity_type: e.target.value as IdentityType })} aria-label="نوع الوثيقة">{Object.entries(IDENTITY_TYPE_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></Field>
          <Field label={correcting ? "رقم الوثيقة (فارغ = الرقم المحفوظ)" : "رقم الوثيقة"} error={errs.number} hint={guest?.identity_number_last4 ? `المحفوظ: ${maskId(guest.identity_number_last4)}` : undefined}><input className="input" dir="ltr" inputMode="numeric" autoComplete="off" value={f.identity_number} onChange={(e) => setF({ ...f, identity_number: e.target.value })} aria-label="رقم الوثيقة" /></Field>
          <Field label="رقم الإصدار (إن وجد)"><input className="input" dir="ltr" value={f.identity_issue_number} onChange={(e) => setF({ ...f, identity_issue_number: e.target.value })} /></Field>
          <Field label="الجنسية"><input className="input" value={f.nationality} onChange={(e) => setF({ ...f, nationality: e.target.value })} aria-label="الجنسية" /></Field>
          <Field label="تاريخ الميلاد (ميلادي)" error={errs.birth}><input type="date" className="input" dir="ltr" max={maxBirthDate(todayISO())} value={f.birth_date} onChange={(e) => setF({ ...f, birth_date: e.target.value })} aria-label="تاريخ الميلاد" /></Field>
          <Field label={`الجوال ${guest?.is_primary ? "(فارغ = الرقم المسجل)" : "(اختياري)"}`} error={errs.phone}><input className="input" dir="ltr" inputMode="tel" placeholder="05xxxxxxxx" aria-invalid={!!errs.phone} value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} /></Field>
          {!guest?.is_primary && <Field label="صلة القرابة"><select className="input" value={f.relationship} onChange={(e) => setF({ ...f, relationship: e.target.value })}><option value="spouse">زوج/زوجة</option><option value="child">ابن/ابنة</option><option value="parent">والد/والدة</option><option value="sibling">أخ/أخت</option><option value="other">أخرى</option></select></Field>}
          {correcting && <Field label="سبب التصحيح (إلزامي)" className="sm:col-span-2"><input className="input" value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} aria-label="سبب التصحيح" /></Field>}
        </div>
        <div className="mt-3"><Toggle checked={f.matched} onChange={(v) => setF({ ...f, matched: v })} label="طابقتُ الوثيقة الأصلية" /></div>
        <Submit label={correcting ? "حفظ التصحيح" : "حفظ واعتماد"} onCancel={onClose} />
      </ActionForm>
    </Modal>
  );
}

/** Cancelling (decision 4): a platform's booking by the platform's cancellation number (the whole group at once), or an internal one by a reason. */
export function CancelDialog({ open, d, group, onClose, onDone }: { open: boolean; d: ReservationDetail; group: GroupSummary | null; onClose: () => void; onDone: () => void }) {
  const platform = d.source?.kind === "external";
  const [reason, setReason] = useState("");
  const [num, setNum] = useState("");
  const [byPlatform, setByPlatform] = useState(true);
  const [whole, setWhole] = useState(false);
  const [result, setResult] = useState<{ cancelled: number; refund: boolean; collected: boolean } | null>(null);
  useEffect(() => { if (open) { setReason(""); setNum(""); setByPlatform(true); setWhole(false); setResult(null); } }, [open]);
  const f = d.finance;
  const unitsInGroup = group?.units.filter((u) => !["cancelled", "rejected", "no_show"].includes(u.status)).length ?? 0;
  return (
    <Modal open={open} title="إلغاء الحجز" onClose={onClose}>
      {result ? (
        <div className="space-y-3 text-sm">
          <p className="font-medium text-ink-800">أُلغي {result.cancelled === 1 ? "الحجز" : `${result.cancelled} حجوزات`}.</p>
          {result.refund && <p className="rounded-xl bg-warning-500/10 p-3 text-xs text-warning-600">يوجد مبلغ محصّل أو تأمين مقبوض؛ الإلغاء لا يرد شيئًا. قرار الاسترداد يُسجَّل من الدفتر بسند مستقل.</p>}
          {result.collected && <p className="rounded-xl bg-brand-50 p-3 text-xs text-brand-700">قبضت المنصة هذا الحجز: سند «آجل عبر المنصات» يبقى حتى تتم مطابقته مع إيداع المنصة أو إلغاؤه من الإدارة.</p>}
          <button onClick={onDone} className="btn-primary w-full text-sm">تم</button>
        </div>
      ) : (
        <ActionForm onSubmit={async () => {
          if (!reason.trim()) throw new Error("VALIDATION: reason");
          const r = await opsApi.cancel({ reservation_id: d.reservation.id, reason: reason.trim(), cancel_number: platform && byPlatform ? num.trim() : null, by_platform: platform ? byPlatform : false, whole_group: whole });
          setResult({ cancelled: r.cancelled, refund: !!r.refund_required_separately, collected: !!r.platform_collected });
        }}>
          <div className="mb-3 flex items-start gap-2 rounded-xl bg-warning-500/10 p-3 text-xs text-warning-600"><ShieldAlert className="mt-0.5 h-4 w-4 shrink-0" />
            الإلغاء يحرر الوحدة ولا يسترد أي مبلغ تلقائيًا{f && f.net_collected + f.deposit_balance > 0 ? ` — يوجد ${sar(f.net_collected)} محصّل و${sar(f.deposit_balance)} تأمين تحتاج قرار استرداد مستقل` : ""}. التراجع ممكن خلال ساعة من الإدارة.
          </div>
          {platform && (
            <div className="mb-3 space-y-3">
              <Toggle checked={byPlatform} onChange={setByPlatform} label="أُلغي على المنصة (أدخل رقم الإلغاء)" />
              {byPlatform
                ? <Field label="رقم الإلغاء من المنصة" hint="يُقبل مرة واحدة؛ إدخاله مرة أخرى لا يغيّر شيئًا."><input className="input" dir="ltr" value={num} onChange={(e) => setNum(e.target.value)} aria-label="رقم الإلغاء" /></Field>
                : <p className="text-xs text-ink-500">إلغاء داخلي (أُدخل الحجز بالخطأ): بلا رقم منصة، بسبب فقط.</p>}
            </div>
          )}
          {group && unitsInGroup > 1 && <div className="mb-3"><Toggle checked={whole} onChange={setWhole} label={`إلغاء كل وحدات المجموعة (${unitsInGroup})`} /></div>}
          <ReasonInput value={reason} onChange={setReason} />
          <Submit label="تأكيد الإلغاء" onCancel={onClose} danger />
        </ActionForm>
      )}
    </Modal>
  );
}

/** The platform's fields (decision 4) and «طابقتُ مع المنصة». */
export function PlatformPanel({ d, canCheck, onChanged }: { d: ReservationDetail; canCheck: boolean; onChanged: () => void }) {
  const p = d.platform;
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  if (!p) return null;
  const toggle = async () => { setBusy(true); setErr(null); try { await opsApi.platformMarkChecked(d.reservation.id, !p.verified_at); onChanged(); } catch (e) { setErr(toArabicError(e)); } finally { setBusy(false); } };
  return (
    <Card data-testid="platform-panel">
      <div className="mb-2 flex items-center gap-2"><Link2 className="h-5 w-5 text-brand-600" /><h2 className="text-base font-semibold text-ink-800">المنصة — {d.source?.name}</h2></div>
      <div className="grid grid-cols-2 gap-3 text-sm">
        <div><p className="text-xs text-ink-400">رقم الحجز في المنصة</p><p className="font-mono font-medium text-ink-800" dir="ltr">{d.reservation.external_ref ?? "—"}</p></div>
        <div><p className="text-xs text-ink-400">تاريخ الحجز في المنصة</p><p className="font-medium text-ink-800" dir="ltr">{p.booked_on ?? "—"}</p></div>
        {p.collects != null && <div><p className="text-xs text-ink-400">من يقبض</p><p className="font-medium text-ink-800">{p.collects ? "المنصة (آجل عبر المنصات)" : "المنشأة عند الوصول"}</p></div>}
        {p.cancel_reference && <div><p className="text-xs text-ink-400">رقم الإلغاء من المنصة</p><p className="font-mono font-medium text-ink-800" dir="ltr">{p.cancel_reference}</p></div>}
      </div>
      <div className="mt-3 flex flex-wrap items-center gap-2 border-t border-ink-50 pt-3">
        {p.verified_at ? <Badge className="bg-success-500/10 text-success-600"><CheckCircle2 className="h-3 w-3" /> طُوبق مع المنصة{p.verified_by ? ` — ${p.verified_by}` : ""} · {formatDateTime(p.verified_at)}</Badge> : <Badge className="bg-ink-100 text-ink-500">لم يُطابَق مع المنصة بعد</Badge>}
        {canCheck && !["cancelled", "rejected", "no_show", "closed"].includes(d.reservation.status) && <button onClick={toggle} disabled={busy} className="btn-outline text-xs" data-testid="platform-check">{busy ? <Spinner className="h-3 w-3" /> : null} {p.verified_at ? "إلغاء المطابقة" : "طابقتُ مع المنصة"}</button>}
      </div>
      {err && <div className="mt-2"><ErrorBanner message={err} /></div>}
    </Card>
  );
}

/** The group's page (decision 69): every unit with its own money, and the totals. */
export function GroupPanel({ current, group }: { current: string; group: GroupSummary }) {
  const t = group.totals;
  return (
    <Card data-testid="group-panel">
      <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
        <h2 className="flex items-center gap-2 text-base font-semibold text-ink-800"><Users className="h-5 w-5 text-brand-600" /> حجز جماعي {group.group_ref}</h2>
        <p className="text-xs text-ink-500">{group.source_name}{group.external_ref ? <> · رقم المنصة <span className="font-mono" dir="ltr">{group.external_ref}</span> (مشترك بين الوحدات)</> : null}</p>
      </div>
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead><tr className="border-b border-ink-100 text-xs text-ink-400"><th className="py-1.5 text-right font-medium">الحجز</th><th className="py-1.5 text-right font-medium">الوحدة</th><th className="py-1.5 text-right font-medium">الحالة</th><th className="py-1.5 text-right font-medium">الأشخاص</th>{t.total_halalas != null && <><th className="py-1.5 text-right font-medium">الإجمالي</th><th className="py-1.5 text-right font-medium">المحصل</th><th className="py-1.5 text-right font-medium">المتبقي</th><th className="py-1.5 text-right font-medium">التأمين</th></>}</tr></thead>
          <tbody>
            {group.units.map((u) => (
              <tr key={u.id} className={`border-b border-ink-50 ${u.id === current ? "bg-brand-50/50" : ""}`}>
                <td className="py-1.5 font-mono text-xs">{u.id === current ? u.internal_ref : <Link to={`/staff/reservations/${u.id}`} className="text-brand-700 hover:underline">{u.internal_ref}</Link>}</td>
                <td className="py-1.5">{u.room_number ?? u.category_name ?? "—"}</td>
                <td className="py-1.5 text-xs text-ink-500">{u.status}</td>
                <td className="py-1.5 text-xs">{u.adults + u.companions}</td>
                {t.total_halalas != null && <><td className="py-1.5" dir="ltr">{sar(u.total_halalas)}</td><td className="py-1.5 text-success-600" dir="ltr">{sar(u.paid_halalas)}</td><td className="py-1.5 text-warning-600" dir="ltr">{sar(u.balance_due_halalas)}</td><td className="py-1.5" dir="ltr">{sar(u.deposit_balance_halalas)}</td></>}
              </tr>
            ))}
          </tbody>
          {t.total_halalas != null && <tfoot><tr className="text-sm font-semibold text-ink-800"><td className="pt-2" colSpan={4}>الإجمالي ({t.units} وحدات{t.active_units != null && t.active_units !== t.units ? `، ${t.active_units} قائمة` : ""})</td><td className="pt-2" dir="ltr" data-testid="group-total">{sar(t.total_halalas)}</td><td className="pt-2 text-success-600" dir="ltr">{sar(t.paid_halalas)}</td><td className="pt-2 text-warning-600" dir="ltr">{sar(t.balance_due_halalas)}</td><td className="pt-2" dir="ltr">{sar(t.deposit_balance_halalas)}</td></tr></tfoot>}
        </table>
      </div>
      <p className="mt-2 text-xs text-ink-400">كل وحدة بماليتها ووصولها كما في الحجز المنفرد؛ التأمين لكل وحدة.</p>
    </Card>
  );
}

/** «ملخص الإقامة» (decision 19): printed from the branch's settings and policies; the paper signature recorded against the printed text. */
export function StaySummaryDialog({ open, reservationId, canRecord, onClose, onChanged }: { open: boolean; reservationId: string; canRecord: boolean; onClose: () => void; onChanged: () => void }) {
  const [s, setS] = useState<(StaySummary & { acknowledgements: Acknowledgement[] }) | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [logo, setLogo] = useState<string | null>(null);
  const load = useCallback(async () => { try { const x = await opsApi.staySummary(reservationId); setS(x); setErr(null); if (x.branch.logo_version) setLogo(await guestApi.branchMedia(x.branch.id, "logo")); } catch (e) { setErr(toArabicError(e)); } }, [reservationId]);
  useEffect(() => { if (open) { setS(null); load(); } }, [open, load]);
  const print = () => {
    if (!s) return;
    const w = window.open("", "_blank", "width=800,height=900");
    if (!w) return;
    const esc = (x: string) => x.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c] ?? c);
    const en = s.language === "en";
    w.document.write(`<!doctype html><html dir="${en ? "ltr" : "rtl"}" lang="${s.language}"><head><meta charset="utf-8"><title>${esc(s.reservation.internal_ref)}</title>
      <style>body{font-family:system-ui,-apple-system,"Segoe UI",Tahoma,sans-serif;margin:32px;color:#111;font-size:14px;line-height:1.7}header{display:flex;justify-content:space-between;align-items:center;border-bottom:2px solid #111;padding-bottom:12px;margin-bottom:16px}img{max-height:64px}pre{white-space:pre-wrap;font:inherit;margin:0}.sig{margin-top:40px;display:flex;justify-content:space-between;gap:24px}.sig div{flex:1;border-top:1px solid #111;padding-top:6px;font-size:12px}.hash{margin-top:24px;font-family:monospace;font-size:10px;color:#666;direction:ltr;text-align:left}@media print{body{margin:16mm}}</style></head><body>
      <header><div><strong>${esc(s.branch.name)}</strong>${s.branch.city ? `<br><small>${esc(s.branch.city)}${s.branch.address ? " — " + esc(s.branch.address) : ""}</small>` : ""}${s.branch.phone ? `<br><small dir="ltr">${esc(s.branch.phone)}</small>` : ""}</div>${logo ? `<img src="${logo}" alt="">` : ""}</header>
      <pre>${esc(s.text)}</pre>
      <div class="sig"><div>${en ? "Guest signature" : "توقيع الضيف"}</div><div>${en ? "Date" : "التاريخ"}</div><div>${en ? "Reception" : "الاستقبال"}</div></div>
      <p class="hash">${esc(s.hash)}</p></body></html>`);
    w.document.close(); w.focus(); w.print();
  };
  return (
    <Modal open={open} title="ملخص الإقامة" onClose={onClose} wide>
      {err && <ErrorBanner message={err} />}
      {!s && !err && <div className="py-6 text-center"><Spinner /></div>}
      {s && (
        <div className="space-y-3">
          <pre className="max-h-[50vh] overflow-auto whitespace-pre-wrap rounded-xl border border-ink-100 bg-ink-50 p-3 text-xs leading-relaxed text-ink-700" dir={s.language === "en" ? "ltr" : "rtl"} data-testid="stay-summary-text">{s.text}</pre>
          <p className="text-[11px] text-ink-400" dir="ltr">بصمة النص: {s.hash.slice(0, 16)}…</p>
          <div>
            <h4 className="mb-1 text-xs font-semibold text-ink-600">الإقرارات المسجلة</h4>
            {s.acknowledgements.length === 0 ? <p className="text-xs text-ink-400">لم يُقر الضيف بعد (إلكترونيًا عند التسجيل، أو ورقيًا من هنا).</p> : (
              <ul className="space-y-1 text-xs text-ink-600" data-testid="ack-list">
                {s.acknowledgements.map((a) => <li key={a.id} className="flex items-center gap-2"><CheckCircle2 className={`h-3.5 w-3.5 ${a.text_hash === s.hash ? "text-success-600" : "text-ink-300"}`} />{a.method === "paper" ? "توقيع ورقي" : "إقرار إلكتروني"} · {formatDateTime(a.accepted_at)}{a.recorded_by ? ` · ${a.recorded_by}` : ""}{a.text_hash !== s.hash ? " · على نص سابق" : ""}</li>)}
              </ul>
            )}
          </div>
          <div className="flex flex-wrap gap-2">
            <button onClick={print} className="btn-primary text-sm"><Printer className="h-4 w-4" /> طباعة / PDF</button>
            {canRecord && !s.acknowledgements.some((a) => a.text_hash === s.hash && a.method === "paper") && (
              <button onClick={async () => { setBusy(true); setErr(null); try { await opsApi.recordPaperAck(reservationId, s.hash); await load(); onChanged(); } catch (e) { setErr(toArabicError(e)); } finally { setBusy(false); } }} disabled={busy} className="btn-outline text-sm" data-testid="record-paper-ack">
                {busy ? <Spinner className="h-4 w-4" /> : <FileSignature className="h-4 w-4" />} وقّع الضيف النسخة الورقية
              </button>
            )}
          </div>
        </div>
      )}
    </Modal>
  );
}

/** One guest's identity line with the office path's actions (decision 2). */
export function GuestEntryBadge({ g }: { g: Guest }) {
  if (g.entry_path === "office") return <Badge className="bg-brand-50 text-brand-700"><IdCard className="h-3 w-3" /> من الوثيقة{g.verified_by ? ` — ${g.verified_by}` : ""}</Badge>;
  if (g.entry_path === "guest") return <Badge className="bg-ink-100 text-ink-500">أدخلها الضيف</Badge>;
  return null;
}

export const BanIcon = Ban;
