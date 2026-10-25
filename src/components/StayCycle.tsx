/**
 * The stay cycle of one reservation (0033 — decisions 1, 3, 5, 6, 8, 10, 59): Shomoos, the arrival with its two
 * entries, the key-box code after the arrival, the nights paid one by one, the departure with nothing owed, the
 * check-out inspection, «مغلق», and the corrections within their windows. It reads fn_stay_status only, and every
 * action is a server function: the server decides, this screen shows why.
 */
import { useCallback, useEffect, useState, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { AlertCircle, AlertTriangle, BadgeCheck, CheckCircle2, ClipboardCheck, FileCheck, KeyRound, LogIn, LogOut, Moon, RotateCcw, ShieldAlert, Undo2, XCircle } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { useAuth } from "../lib/auth";
import { staffApi, stayApi, toArabicError, newIdempotencyKey, type StayStatus, type PaymentEntry, type CheckInResult } from "../lib/api";
import { useCashAccounts } from "../lib/useCashAccounts";
import { METHOD_ACCOUNT_KIND, METHOD_NEEDS_REFERENCE, RESERVATION_STATUS_LABELS, type PaymentMethod, type ReservationStatus } from "../lib/types";
import { formatCurrency, formatDateTime } from "../lib/utils";
import { Card, Badge, ErrorBanner, Spinner } from "./ui";
import { Modal, Field, ActionForm, Submit, MoneyInput, ReasonInput } from "./forms";
import { PaymentFields } from "./ReservationOperations";

const sar = (h: number | null | undefined) => formatCurrency((h ?? 0) / 100);
/** the hour of an instant at the property (decision 47: the property's clock, whatever the browser's) */
const hhmm = (iso: string) => new Date(iso).toLocaleTimeString("ar-SA", { hour: "2-digit", minute: "2-digit", timeZone: "Asia/Riyadh" });
const when = (iso: string | null | undefined) => (iso ? formatDateTime(iso) : "—");
const ACT_ROLES = ["owner", "manager", "supervisor"];
const MONEY_ROLES = ["owner", "manager", "supervisor", "finance"];
type Done = (message?: string | null) => Promise<void>;

export function StayCycle({ reservationId, branchId, refreshKey, onChanged }: { reservationId: string; branchId: string; refreshKey?: unknown; onChanged: () => void }) {
  const { profile } = useAuth();
  const role = profile?.role ?? "guest";
  const canAct = ACT_ROLES.includes(role);                    // arrival, Shomoos, code, departure, overdue reason
  const canInspect = canAct || role === "housekeeping";       // decision 5: the supervisor or housekeeping inspects
  const money = MONEY_ROLES.includes(role);
  const isMgr = role === "owner" || role === "manager";        // corrections (decision 10)

  const [s, setS] = useState<StayStatus | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [reasons, setReasons] = useState<string[] | null>(null);
  const [revealed, setRevealed] = useState<string | null>(null);

  const load = useCallback(async () => {
    try { setS(await stayApi.status(reservationId)); setLoadError(null); } catch (e) { setLoadError(toArabicError(e)); }
  }, [reservationId]);
  useEffect(() => { load(); }, [load, refreshKey]);

  const done: Done = async (message) => { setReasons(null); setError(null); setNotice(message ?? null); await load(); onChanged(); };
  const fail = (message: string) => { setNotice(null); setError(message); };
  const refused = (items: string[]) => { setNotice(null); setError(null); setReasons(items.length ? items : ["تعذّر تنفيذ الإجراء"]); };

  if (!s) return loadError ? <ErrorBanner message={loadError} /> : <Card><div className="py-6 text-center"><Spinner /></div></Card>;
  const before = ["draft", "pending_verification", "confirmed"].includes(s.status);
  const departed = s.status === "checked_out" || s.status === "closed";
  const common = { s, id: reservationId, done, fail, refused };

  return (
    <div className="space-y-4" data-testid="stay-cycle">
      {loadError && <ErrorBanner message={loadError} />}
      {error && <ErrorBanner message={error} />}
      {notice && <div className="rounded-xl border border-success-500/30 bg-success-500/10 px-4 py-3 text-sm text-success-600" role="status" data-testid="stay-notice">{notice}</div>}
      {reasons && <Reasons title="تعذّر تنفيذ الإجراء للأسباب التالية:" items={reasons} />}
      {(["pending_verification", "confirmed", "checked_in"].includes(s.status) || s.shomoos.registered) && <ShomoosCard {...common} canAct={canAct} money={money} />}
      {before && s.checkin && <ArrivalCard {...common} branchId={branchId} canAct={canAct} money={money} />}
      {s.status === "checked_in" && <InHouseCard {...common} canAct={canAct} canInspect={canInspect} money={money} isMgr={isMgr} onReveal={setRevealed} />}
      {departed && <DepartedCard {...common} canInspect={canInspect} money={money} isMgr={isMgr} />}
      {s.status === "cancelled" && isMgr && s.corrections.undo_cancel_until && <UndoCancel {...common} until={s.corrections.undo_cancel_until} />}
      {revealed && <CodeReveal code={revealed} onClose={() => setRevealed(null)} />}
    </div>
  );
}

interface Common { s: StayStatus; id: string; done: Done; fail: (m: string) => void; refused: (items: string[]) => void }

// ---------------------------------------------------------------- Shomoos (decision 6)
function ShomoosCard({ s, id, done, fail, canAct, money }: Common & { canAct: boolean; money: boolean }) {
  const sh = s.shomoos;
  const changed = sh.registered && sh.guest_count !== sh.guests_now;
  const open = ["pending_verification", "confirmed", "checked_in"].includes(s.status);
  const [reference, setReference] = useState("");
  const [allGuests, setAllGuests] = useState(false);
  const [editing, setEditing] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const run = async (key: string, fn: () => Promise<unknown>, message: string) => {
    setBusy(key);
    try { await fn(); setReference(""); setAllGuests(false); setEditing(false); await done(message); } catch (e) { fail(toArabicError(e)); } finally { setBusy(null); }
  };
  const showForm = canAct && open && (!sh.registered || changed || editing);
  return (
    <Card data-testid="shomoos">
      <Head icon={FileCheck} title="التسجيل في شموس" badge={sh.accepted_at && !changed ? <Badge className="bg-success-500/10 text-success-600">مقبول</Badge> : sh.registered && !changed ? <Badge className="bg-warning-500/10 text-warning-600">بانتظار القبول</Badge> : <Badge className="bg-ink-100 text-ink-500">لم يُسجَّل</Badge>} />
      <div className="grid gap-2 sm:grid-cols-2">
        <Step ok={sh.registered && !changed} label="تسجيل جميع النزلاء والمرافقين"
          detail={sh.registered ? [money && sh.reference ? `المرجع ${sh.reference}` : null, `${sh.guest_count ?? 0} نزيل`, sh.registered_by, when(sh.registered_at)].filter(Boolean).join(" · ") : "لم يُسجَّل بعد"} />
        <Step ok={!!sh.accepted_at && !changed} label="قبول شموس للتسجيل"
          detail={sh.accepted_at ? [sh.accepted_by, when(sh.accepted_at)].filter(Boolean).join(" · ") : sh.registered ? "بانتظار تأكيد القبول" : "بعد التسجيل"} />
      </div>
      {changed && <Warn>تغيّر عدد النزلاء بعد التسجيل ({sh.guest_count ?? 0} ← {sh.guests_now})؛ حدِّث التسجيل في شموس ثم سجّله هنا من جديد.</Warn>}
      {showForm && (
        <form className="mt-3 space-y-2" onSubmit={(e) => { e.preventDefault(); run("register", () => stayApi.shomoos({ reservation_id: id, action: "register", reference: reference.trim(), all_guests: allGuests }), "سُجِّل النزلاء في شموس؛ أكّد قبول شموس حين يصل."); }}>
          <Field label="رقم التسجيل في شموس"><input className="input" dir="ltr" value={reference} onChange={(e) => setReference(e.target.value)} aria-label="رقم التسجيل في شموس" /></Field>
          <label className="flex items-start gap-2 text-sm text-ink-700">
            <input type="checkbox" className="mt-0.5 h-4 w-4" checked={allGuests} onChange={(e) => setAllGuests(e.target.checked)} />
            سُجِّل جميع النزلاء والمرافقين ({sh.guests_now}) في شموس
          </label>
          <div className="flex gap-2">
            <button type="submit" disabled={busy === "register" || !reference.trim() || !allGuests} className="btn-outline flex-1 text-sm">{busy === "register" ? <Spinner className="h-4 w-4" /> : <FileCheck className="h-4 w-4" />} تسجيل شموس</button>
            {editing && <button type="button" onClick={() => setEditing(false)} className="btn-ghost text-sm">إلغاء</button>}
          </div>
          <p className="text-xs text-ink-400">يُسجَّل بعد اعتماد مطابقة الهوية. التسجيل الجديد أو المصحَّح ينتظر قبول شموس من جديد.</p>
        </form>
      )}
      {canAct && open && sh.registered && !changed && !sh.accepted_at && !editing && (
        <button onClick={() => run("accept", () => stayApi.shomoos({ reservation_id: id, action: "accept" }), "أُكِّد قبول شموس للتسجيل.")} disabled={busy === "accept"} className="btn-primary mt-3 w-full text-sm">
          {busy === "accept" ? <Spinner className="h-4 w-4" /> : <CheckCircle2 className="h-4 w-4" />} تأكيد قبول شموس للتسجيل
        </button>
      )}
      {canAct && open && sh.registered && !changed && !editing && <button onClick={() => setEditing(true)} className="btn-ghost mt-2 text-xs">تصحيح رقم التسجيل</button>}
    </Card>
  );
}

// ---------------------------------------------------------------- the arrival (decisions 1, 2, 3)
function ArrivalCard({ s, id, done, refused, branchId, canAct, money }: Common & { branchId: string; canAct: boolean; money: boolean }) {
  const c = s.checkin!;
  const core = c.blockers;
  const accounts = useCashAccounts(money ? branchId : null);
  const [rent, setRent] = useState<number | null>(c.first_night_short ?? 0);
  const [rentMethod, setRentMethod] = useState<PaymentMethod>("cash"); const [rentAccount, setRentAccount] = useState(""); const [rentRef, setRentRef] = useState("");
  const [deposit, setDeposit] = useState<number | null>(c.deposit_short ?? 0);
  const [depMethod, setDepMethod] = useState<PaymentMethod>("cash"); const [depAccount, setDepAccount] = useState(""); const [depRef, setDepRef] = useState("");
  const [reason, setReason] = useState("");
  // one arrival, one pair of entries: a resend after a refusal recorded nothing, so the keys stay the same
  const [keys] = useState(() => ({ rent: newIdempotencyKey(), deposit: newIdempotencyKey() }));
  useEffect(() => { setRent(c.first_night_short ?? 0); }, [c.first_night_short]);
  useEffect(() => { setDeposit(c.deposit_short ?? 0); }, [c.deposit_short]);
  const depositShort = Math.max((c.deposit_short ?? 0) - (deposit ?? 0), 0);
  const entry = (amount: number | null, method: PaymentMethod, account: string, ref: string, key: string): PaymentEntry | undefined =>
    amount && amount > 0 ? { amount_halalas: amount, method, account_id: METHOD_ACCOUNT_KIND[method] ? account || undefined : undefined, reference: ref.trim() || undefined, idempotency_key: key } : undefined;
  const submit = async () => {
    if ((rent ?? 0) > 0 && METHOD_NEEDS_REFERENCE.includes(rentMethod) && !rentRef.trim()) throw new Error("VALIDATION: reference_required");
    if ((deposit ?? 0) > 0 && METHOD_NEEDS_REFERENCE.includes(depMethod) && !depRef.trim()) throw new Error("VALIDATION: reference_required");
    const r: CheckInResult = await stayApi.checkIn({ reservation_id: id, expected_version: s.version, rent: entry(rent, rentMethod, rentAccount, rentRef, keys.rent), deposit: entry(deposit, depMethod, depAccount, depRef, keys.deposit), deposit_reason: depositShort > 0 && reason.trim() ? reason.trim() : undefined });
    if (!r.ok) { refused(r.reasons ?? []); return; }
    const vouchers = [r.rent_voucher ? `سند الإيجار ${r.rent_voucher}` : null, r.deposit_voucher ? `سند التأمين ${r.deposit_voucher}` : null].filter(Boolean).join(" · ");
    await done(`سُجِّل الوصول.${vouchers ? ` ${vouchers}.` : ""} ${r.has_keybox ? "سلّم رمز الصندوق من «رمز صندوق المفتاح» أدناه." : "الوحدة بلا صندوق مفتاح: سلّم مفتاحها للنزيل."}`);
  };
  return (
    <Card data-testid="arrival">
      <Head icon={LogIn} title="تسجيل الوصول" />
      <p className="mb-3 text-xs text-ink-500">شروط الوصول واحدة في كل الفروع ولا تجاوز لها. رمز الصندوق يُسلَّم بعد تسجيل الوصول، كخطوة مستقلة.</p>
      {core.length > 0 ? <Reasons title="شروط لم تكتمل بعد:" items={core} /> : <Ok>الشروط الثابتة مكتملة: الحجز مؤكد، والنزلاء مسجلون ومطابقون، وشموس مقبول، والوحدة نظيفة ومتاحة.</Ok>}
      {money && (
        <div className="mt-3 grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
          <Cell label="الليلة الأولى" value={sar(c.first_night)} />
          <Cell label="المحصّل" value={sar(c.collected)} tone={(c.first_night_short ?? 0) > 0 ? "text-warning-600" : "text-success-600"} />
          <Cell label="تأمين الفرع" value={sar(c.deposit_required)} />
          <Cell label="التأمين المستلم" value={sar(c.deposit_balance)} tone={(c.deposit_short ?? 0) > 0 ? "text-warning-600" : "text-success-600"} />
        </div>
      )}
      {canAct && core.length === 0 && (
        <ActionForm onSubmit={submit}>
          <div className="mt-4 grid gap-4 lg:grid-cols-2">
            <fieldset className="space-y-3 rounded-xl border border-ink-100 p-3">
              <legend className="px-1 text-xs font-semibold text-ink-600">سند قبض الإيجار</legend>
              <Field label="المبلغ" hint={(c.first_night_short ?? 0) > 0 ? `المطلوب قبل الوصول: ${sar(c.first_night_short)} — الليلة الأولى كاملة، والدفعة الجزئية لا تكفي.` : "الليلة الأولى مدفوعة؛ يمكن قبض المزيد الآن أو تركه صفرًا."}>
                <MoneyInput valueHalalas={rent} onChange={setRent} />
              </Field>
              {(rent ?? 0) > 0 && <PaymentFields method={rentMethod} setMethod={setRentMethod} accountId={rentAccount} setAccountId={setRentAccount} reference={rentRef} setReference={setRentRef} accounts={accounts.active} verb="receive" />}
            </fieldset>
            <fieldset className="space-y-3 rounded-xl border border-ink-100 p-3">
              <legend className="px-1 text-xs font-semibold text-ink-600">سند قبض التأمين</legend>
              <Field label="المبلغ" hint={(c.deposit_short ?? 0) > 0 ? `تأمين الفرع ${sar(c.deposit_required)}؛ يُحتجز منفصلًا ويُرد بعد المغادرة وفحصها.` : "التأمين مستلم كاملًا."}>
                <MoneyInput valueHalalas={deposit} onChange={setDeposit} />
              </Field>
              {(deposit ?? 0) > 0 && <PaymentFields method={depMethod} setMethod={setDepMethod} accountId={depAccount} setAccountId={setDepAccount} reference={depRef} setReference={setDepRef} accounts={accounts.active} verb="receive" deposit />}
              {depositShort > 0 && <ReasonInput value={reason} onChange={setReason} label="سبب عدم استلام التأمين كاملًا (إلزامي)" placeholder="مثال: ضيف شركة بعقد سارٍ" />}
            </fieldset>
          </div>
          <Submit label="تسجيل الوصول" />
        </ActionForm>
      )}
      {!canAct && core.length === 0 && <p className="mt-3 text-xs text-ink-400">يسجّل الوصول المشرف أو المدير أو المالك.</p>}
    </Card>
  );
}

// ---------------------------------------------------------------- in house: the code, the nights, the departure
function InHouseCard({ s, id, done, fail, refused, canAct, canInspect, money, isMgr, onReveal }: Common & { canAct: boolean; canInspect: boolean; money: boolean; isMgr: boolean; onReveal: (code: string) => void }) {
  const [channel, setChannel] = useState<"screen" | "supervisor">("screen");
  const [busy, setBusy] = useState<string | null>(null);
  const [dialog, setDialog] = useState<null | "exception" | "undo" | "failed">(null);
  const run = async (key: string, fn: () => Promise<string | null>) => {
    setBusy(key);
    try { const message = await fn(); if (message !== null) await done(message); } catch (e) { fail(toArabicError(e)); } finally { setBusy(null); }
  };
  const d = s.due;
  return (
    <Card data-testid="in-house">
      <Head icon={BadgeCheck} title="الإقامة" badge={<Badge className="bg-success-500/10 text-success-600">مقيم</Badge>} />
      <p className="text-xs text-ink-500">
        وصل {when(s.checked_in_at)}{s.checked_in_by ? ` · سجّله ${s.checked_in_by}` : ""} · المغادرة الساعة {s.departure_time}{s.late_checkout_until ? " (مغادرة متأخرة)" : ""}
      </p>
      {s.late_departure && <Warn>تجاوز النزيل موعد المغادرة ({s.departure_time}): سجّل مغادرته، أو مدّد إقامته، أو أضف خدمة المغادرة المتأخرة.</Warn>}

      <Section icon={KeyRound} title={s.has_keybox ? "رمز صندوق المفتاح" : "مفتاح الوحدة"}>
        {!s.has_keybox ? (
          <p className="flex flex-wrap items-center gap-2 text-sm text-ink-600">الوحدة بلا صندوق مفتاح؛ يُسلَّم مفتاحها للنزيل في الاستقبال.{s.access_status === "key_handed" && <Badge className="bg-success-500/10 text-success-600">سُلِّم المفتاح</Badge>}</p>
        ) : s.code?.delivered ? (
          <div className="space-y-2">
            <Ok>سُلِّم رمز الصندوق لهذا النزيل.</Ok>
            {s.access_status === "delivered" && canAct && <button onClick={() => setDialog("failed")} className="btn-outline text-xs"><AlertTriangle className="h-3.5 w-3.5" /> الإبلاغ عن فشل التسليم</button>}
          </div>
        ) : s.code && s.code.blockers.length > 0 ? (
          <div className="space-y-2">
            <Reasons title="قبل تسليم الرمز:" items={s.code.blockers} />
            {s.keybox_state !== "ready" && <Link to="/staff/codes" className="text-xs font-medium text-brand-600">فتح «الرموز» لتعيين الرمز أو تغييره أو تجربته</Link>}
          </div>
        ) : canAct ? (
          <div className="space-y-2">
            <div className="grid grid-cols-2 gap-2" role="radiogroup" aria-label="قناة التسليم">
              {(["screen", "supervisor"] as const).map((c) => (
                <button key={c} type="button" role="radio" aria-checked={channel === c} onClick={() => setChannel(c)}
                  className={`rounded-xl border px-3 py-2 text-sm ${channel === c ? "border-brand-400 bg-brand-50 text-brand-700" : "border-ink-100 text-ink-600"}`}>{c === "screen" ? "صفحة النزيل" : "شفهيًا عبر المشرف"}</button>
              ))}
            </div>
            <button disabled={busy === "deliver"} onClick={() => run("deliver", async () => {
              const r = await staffApi.deliverAccessCode(id, channel);
              if (!r.ok) { refused(r.reasons ?? []); return null; }
              if (channel === "supervisor" && r.code) onReveal(r.code);
              return channel === "supervisor" ? "سُلِّم رمز الصندوق شفهيًا." : "سُلِّم رمز الصندوق؛ يظهر للنزيل في صفحته.";
            })} className="btn-accent w-full">{busy === "deliver" ? <Spinner className="h-4 w-4" /> : <KeyRound className="h-4 w-4" />} تسليم رمز الصندوق</button>
          </div>
        ) : <p className="text-sm text-ink-500">لم يُسلَّم الرمز بعد.</p>}
      </Section>

      {money && d && (
        <Section icon={Moon} title="الدفع ليلة بليلة" testId="nights-due">
          <div className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
            <Cell label="ليالٍ مدفوعة" value={`${d.nights_covered} من ${d.nights}`} />
            <Cell label="المستحق حتى الآن" value={sar(d.due_now)} />
            <Cell label="المحصّل" value={sar(d.collected)} tone="text-success-600" />
            <Cell label="المتبقي على الإقامة" value={sar(d.balance_due)} tone={d.balance_due > 0 ? "text-warning-600" : "text-success-600"} />
          </div>
          {d.overdue ? (
            <div className="mt-3 rounded-xl border border-danger-500/30 bg-danger-500/10 p-3 text-sm text-danger-600" role="alert" data-testid="overdue">
              <p className="font-medium">ليلة غير مدفوعة بعد موعدها{d.overdue_since ? ` منذ ${formatDateTime(d.overdue_since)}` : ""} — المتأخر <span dir="ltr">{sar(d.overdue_amount)}</span></p>
              <p className="mt-0.5 text-xs">{s.overdue_blocked ? "التمديد وإضافة الخدمات موقوفة حتى السداد، أو حتى تسجيل سبب يسمح بالاستمرار." : "سُجِّل سبب يسمح بالاستمرار حتى هذه الليلة."}</p>
              {s.overdue_blocked && canAct && <button onClick={() => setDialog("exception")} className="btn-outline mt-2 text-xs">تسجيل سبب الاستمرار</button>}
            </div>
          ) : d.next_unpaid_night ? (
            <p className="mt-2 text-xs text-ink-500">ليلة {d.next_unpaid_night} تُستحق{d.next_deadline ? ` بحلول ${formatDateTime(d.next_deadline)}` : ""}، ومهلتها ساعة بعد ذلك.</p>
          ) : <Ok>كل ليالي الإقامة مدفوعة.</Ok>}
          {s.payment_exception && <p className="mt-2 text-xs text-ink-500">سبب الاستمرار: {s.payment_exception.reason} — حتى ليلة {s.payment_exception.through_night} · {s.payment_exception.by ?? "—"}</p>}
          {s.deposit_waiver && <p className="mt-2 text-xs text-ink-500">لم يُستلم التأمين كاملًا عند الوصول: {s.deposit_waiver.reason} · {s.deposit_waiver.by ?? "—"}</p>}
        </Section>
      )}

      {s.inspection ? <InspectionView s={s} money={money} /> : s.inspection_due && canInspect && <InspectionForm id={id} done={done} />}

      {canAct && (
        <Section icon={LogOut} title="المغادرة">
          <button disabled={busy === "checkout"} onClick={() => run("checkout", async () => {
            const r = await stayApi.checkOut(id, s.version);
            if (!r.ok) { refused(r.reasons ?? []); return null; }
            if (r.status === "closed") return "سُجِّلت المغادرة وأُغلقت الإقامة: لا مستحق، ولا رصيد للضيف، والتأمين مُسوّى، وكل البنود مفوترة.";
            return `سُجِّلت المغادرة.${(r.deposit_to_settle_halalas ?? 0) > 0 ? ` يبقى تأمين ${sar(r.deposit_to_settle_halalas)} يُرد بعد فحص المغادرة.` : ""}`;
          })} className="btn-danger w-full">{busy === "checkout" ? <Spinner className="h-4 w-4" /> : <LogOut className="h-4 w-4" />} تسجيل المغادرة</button>
          <p className="mt-1.5 text-xs text-ink-400">لا مغادرة وعلى الحجز مبلغ مستحق، لأي دور. يُصفَّر بسند قبض، أو بالخصم من التأمين بسبب، أو بتسوية سعر من المالك أو المدير بسبب.</p>
        </Section>
      )}

      {isMgr && s.corrections.undo_check_in_until && (
        <button onClick={() => setDialog("undo")} className="btn-ghost mt-3 text-xs text-danger-600"><Undo2 className="h-3.5 w-3.5" /> تراجع عن تسجيل الوصول (حتى {hhmm(s.corrections.undo_check_in_until)})</button>
      )}

      <ReasonModal open={dialog === "exception"} title="سبب استمرار الإقامة مع ليلة غير مدفوعة" warning="يُسجَّل السبب مع اسمك ووقته، ويسمح بالتمديد وإضافة الخدمات حتى هذه الليلة فقط؛ المبلغ يبقى مستحقًا."
        onClose={() => setDialog(null)} onSubmit={async (reason) => { await stayApi.paymentException(id, reason); setDialog(null); await done("سُجِّل سبب الاستمرار."); }} />
      <ReasonModal open={dialog === "undo"} title="تراجع عن تسجيل الوصول" warning="يعود الحجز «مؤكدًا» وتعود الوحدة محجوزة له. إن كان رمز الصندوق قد سُلِّم فيجب تغييره. يُضاف التصحيح إلى قائمة المراجعة لدى المالك."
        onClose={() => setDialog(null)} onSubmit={async (reason) => { const r = await stayApi.undoCheckIn(id, reason); setDialog(null); await done(r.code_needs_change ? "أُلغي تسجيل الوصول. غيّر رمز الصندوق قبل تسليمه لأحد." : "أُلغي تسجيل الوصول."); }} />
      <ReasonModal open={dialog === "failed"} title="الإبلاغ عن فشل تسليم الرمز" warning="يعود الرمز إلى «بانتظار التسليم» لإعادة المحاولة من قناة أخرى."
        onClose={() => setDialog(null)} onSubmit={async (reason) => { await staffApi.markDeliveryFailed(id, reason); setDialog(null); await done("سُجِّل فشل التسليم."); }} />
    </Card>
  );
}

// ---------------------------------------------------------------- departed: the inspection, the deposit, «مغلق»
function DepartedCard({ s, id, done, canInspect, money, isMgr }: Common & { canInspect: boolean; money: boolean; isMgr: boolean }) {
  const [reopen, setReopen] = useState(false);
  const closed = !!s.closure?.closed;
  return (
    <Card data-testid="departed">
      <Head icon={LogOut} title={closed ? "مغلق" : "غادر"} badge={closed ? <Badge className="bg-ink-100 text-ink-600">مغلق</Badge> : <Badge className="bg-warning-500/10 text-warning-600">غادر ولم يُغلق</Badge>} />
      <p className="text-xs text-ink-500">غادر {when(s.checked_out_at)}{s.checked_out_by ? ` · سجّله ${s.checked_out_by}` : ""}</p>
      {closed
        ? <div className="mt-3"><Ok>أُغلقت الإقامة{s.closure?.closed_at ? ` في ${formatDateTime(s.closure.closed_at)}` : ""}: لا مستحق ولا رصيد للضيف، والتأمين مُسوّى، وكل البنود مفوترة.</Ok></div>
        : <div className="mt-3"><Reasons tone="info" title="تُغلق الإقامة وحدها حين يكتمل ما يلي:" items={money && s.closure?.missing.length ? s.closure.missing : ["تسوية المال والتأمين وإصدار الفاتورة"]} /></div>}
      {s.inspection ? <InspectionView s={s} money={money} /> : canInspect && s.inspection_due && <InspectionForm id={id} done={done} />}
      {money && s.deposit_refund_blocker && <p className="mt-3 flex items-center gap-1.5 text-xs text-warning-600"><ShieldAlert className="h-3.5 w-3.5" /> رد التأمين: {s.deposit_refund_blocker}</p>}
      {isMgr && s.corrections.reopen_until && (
        <button onClick={() => setReopen(true)} className="btn-ghost mt-3 text-xs text-danger-600"><RotateCcw className="h-3.5 w-3.5" /> إعادة فتح الإقامة (حتى {hhmm(s.corrections.reopen_until)})</button>
      )}
      <ReasonModal open={reopen} title="إعادة فتح الإقامة" warning="يعود النزيل مقيمًا في وحدته، وتُلغى مهمة تنظيف المغادرة، ويبقى رمزه له إن لم يتغير. يُضاف التصحيح إلى قائمة المراجعة لدى المالك."
        onClose={() => setReopen(false)} onSubmit={async (reason) => { await stayApi.reopenStay(id, reason); setReopen(false); await done("أُعيد فتح الإقامة."); }} />
    </Card>
  );
}

function UndoCancel({ id, done, until }: Common & { until: string }) {
  const [open, setOpen] = useState(false);
  return (
    <Card data-testid="undo-cancel">
      <Head icon={RotateCcw} title="الإلغاء" />
      <p className="text-sm text-ink-600">أُلغي هذا الحجز. يمكن التراجع عن الإلغاء حتى {hhmm(until)} إن بقيت وحدته متاحة.</p>
      <button onClick={() => setOpen(true)} className="btn-outline mt-3 text-sm"><Undo2 className="h-4 w-4" /> تراجع عن الإلغاء</button>
      <ReasonModal open={open} title="تراجع عن الإلغاء" warning="يعود الحجز إلى حالته قبل الإلغاء مع وحدته؛ إن حُجزت الوحدة لغيره بعد الإلغاء يُرفض التراجع. يُضاف التصحيح إلى قائمة المراجعة لدى المالك."
        onClose={() => setOpen(false)} onSubmit={async (reason) => { const r = await stayApi.undoCancel(id, reason); setOpen(false); await done(`أُعيد الحجز: ${RESERVATION_STATUS_LABELS[r.status as ReservationStatus] ?? r.status}.`); }} />
    </Card>
  );
}

// ---------------------------------------------------------------- the check-out inspection (decision 5)
function InspectionForm({ id, done }: { id: string; done: Done }) {
  const [result, setResult] = useState<"ok" | "notes">("ok");
  const [notes, setNotes] = useState("");
  const [suggested, setSuggested] = useState<number | null>(null);
  return (
    <Section icon={ClipboardCheck} title="فحص المغادرة" testId="inspection-form">
      <ActionForm onSubmit={async () => {
        if (result === "notes" && !notes.trim()) throw new Error("VALIDATION: inspection_notes");
        await stayApi.inspect({ reservation_id: id, result, notes: notes.trim() || undefined, suggested_deduction_halalas: result === "notes" && suggested && suggested > 0 ? suggested : undefined });
        await done("سُجِّل فحص المغادرة.");
      }}>
        <div className="grid grid-cols-2 gap-2" role="radiogroup" aria-label="نتيجة الفحص">
          {(["ok", "notes"] as const).map((v) => (
            <button key={v} type="button" role="radio" aria-checked={result === v} onClick={() => setResult(v)}
              className={`rounded-xl border px-3 py-2 text-sm ${result === v ? "border-brand-400 bg-brand-50 text-brand-700" : "border-ink-100 text-ink-600"}`}>{v === "ok" ? "الوحدة سليمة" : "بملاحظات"}</button>
          ))}
        </div>
        {result === "notes" && (
          <div className="mt-3 space-y-3">
            <Field label="الملاحظات (إلزامية)"><textarea className="input" rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="ما الذي وُجد في الوحدة؟" /></Field>
            <Field label="خصم مقترح من التأمين (اختياري)" hint="يقرّر الخصم من يسوّي التأمين، برسم ضرر بسبب."><MoneyInput valueHalalas={suggested} onChange={setSuggested} /></Field>
          </div>
        )}
        <Submit label="حفظ الفحص" />
      </ActionForm>
    </Section>
  );
}

function InspectionView({ s, money }: { s: StayStatus; money: boolean }) {
  const i = s.inspection!;
  return (
    <Section icon={ClipboardCheck} title="فحص المغادرة" testId="inspection">
      <p className="text-sm text-ink-700">{i.result === "ok" ? "الوحدة سليمة." : `بملاحظات: ${i.notes ?? ""}`}</p>
      {money && i.result === "notes" && (i.suggested ?? 0) > 0 && <p className="mt-0.5 text-xs text-ink-500">خصم مقترح من التأمين: {sar(i.suggested)}</p>}
      <p className="mt-0.5 text-xs text-ink-400">{i.by ?? "—"} · {when(i.at)}</p>
    </Section>
  );
}

// ---------------------------------------------------------------- small pieces
function Head({ icon: Icon, title, badge }: { icon: LucideIcon; title: string; badge?: ReactNode }) {
  return <div className="mb-3 flex items-center justify-between gap-2"><h2 className="flex items-center gap-2 text-base font-semibold text-ink-800"><Icon className="h-5 w-5 text-brand-600" /> {title}</h2>{badge}</div>;
}
function Section({ icon: Icon, title, children, testId }: { icon: LucideIcon; title: string; children: ReactNode; testId?: string }) {
  return <section className="mt-4 border-t border-ink-50 pt-3" data-testid={testId}><h3 className="mb-2 flex items-center gap-2 text-sm font-semibold text-ink-700"><Icon className="h-4 w-4 text-ink-400" /> {title}</h3>{children}</section>;
}
function Step({ ok, label, detail }: { ok: boolean; label: string; detail: string }) {
  return (
    <div className={`flex items-start gap-2 rounded-lg px-3 py-2 text-xs ${ok ? "bg-success-500/10 text-success-600" : "bg-ink-50 text-ink-500"}`}>
      {ok ? <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" /> : <XCircle className="mt-0.5 h-4 w-4 shrink-0" />}
      <div><p className="font-medium">{label}</p><p className="mt-0.5 text-[11px] opacity-80">{detail}</p></div>
    </div>
  );
}
function Cell({ label, value, tone = "text-ink-800" }: { label: string; value: string; tone?: string }) {
  return <div><p className="text-[11px] text-ink-400">{label}</p><p className={`font-medium ${tone}`} dir="ltr">{value}</p></div>;
}
function Reasons({ title, items, tone = "warning" }: { title: string; items: string[]; tone?: "warning" | "info" }) {
  const cls = tone === "warning" ? "border-warning-500/30 bg-warning-500/10 text-warning-600" : "border-ink-100 bg-ink-50 text-ink-600";
  return (
    <div className={`rounded-xl border p-3 ${cls}`} data-testid="reasons">
      <p className="flex items-center gap-2 text-sm font-medium"><AlertCircle className="h-4 w-4" /> {title}</p>
      <ul className="mt-1.5 space-y-0.5">{items.map((r, i) => <li key={i} className="text-xs">• {r}</li>)}</ul>
    </div>
  );
}
function Ok({ children }: { children: ReactNode }) {
  return <p className="flex items-start gap-2 rounded-xl bg-success-500/10 px-3 py-2 text-sm text-success-600"><CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" /> <span>{children}</span></p>;
}
function Warn({ children }: { children: ReactNode }) {
  return <p className="mt-3 flex items-start gap-2 rounded-xl bg-warning-500/10 px-3 py-2 text-xs text-warning-600"><AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" /> <span>{children}</span></p>;
}
function ReasonModal({ open, title, warning, onClose, onSubmit }: { open: boolean; title: string; warning: string; onClose: () => void; onSubmit: (reason: string) => Promise<void> }) {
  const [reason, setReason] = useState("");
  return (
    <Modal open={open} title={title} onClose={onClose}>
      <ActionForm onSubmit={async () => { if (!reason.trim()) throw new Error("VALIDATION: reason"); await onSubmit(reason.trim()); setReason(""); }}>
        <div className="mb-3 flex items-start gap-2 rounded-xl bg-warning-500/10 p-3 text-xs text-warning-600"><ShieldAlert className="mt-0.5 h-4 w-4 shrink-0" />{warning}</div>
        <ReasonInput value={reason} onChange={setReason} />
        <Submit label="تأكيد" onCancel={onClose} />
      </ActionForm>
    </Modal>
  );
}
/** The supervisor channel shows the code once, to say it to the guest; it is never kept in the page. */
function CodeReveal({ code, onClose }: { code: string; onClose: () => void }) {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/60 p-4">
      <div className="card w-full max-w-sm p-6 text-center" role="dialog" aria-modal="true">
        <KeyRound className="mx-auto mb-3 h-8 w-8 text-brand-600" />
        <h3 className="text-base font-semibold text-ink-800">رمز صندوق المفتاح</h3>
        <p className="mt-1 text-xs text-ink-400">يُعرض مرة واحدة فقط. بلّغه للنزيل شفهيًا ثم أغلق النافذة.</p>
        <p className="my-5 font-mono text-4xl font-bold tracking-[0.3em] text-ink-900" dir="ltr" data-testid="revealed-code">{code}</p>
        <button onClick={onClose} className="btn-primary w-full"><CheckCircle2 className="h-4 w-4" /> تم التسليم شفهيًا</button>
      </div>
    </div>
  );
}
