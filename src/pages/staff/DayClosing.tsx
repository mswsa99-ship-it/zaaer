/**
 * «إقفال اليوم» (the accounting stage, A2 and A3; migration 0063). For a branch-local day the server computes the units
 * and the table «طريقة الدفع × مصدر الحجز», and a box for cash, the terminal, transfers and each platform with money
 * that day; the supervisor enters what was counted and the reason of every difference. Sending goes through a review
 * whose summary the server checks (a voucher arriving meanwhile asks for a new review). After sending, a window of the
 * branch's minutes where an edit is free but recorded for the owner's review; after it, a request the management
 * approves or refuses. The archive lists every closing with its state, the days without one, and the pending requests.
 */
import { useEffect, useMemo, useState } from "react";
import { Lock, Unlock, FileClock, AlertTriangle, CheckCircle2, Send, Pencil, Settings2 } from "lucide-react";
import { closingApi, toArabicError, type ClosingDay, type ClosingLineInput, type ClosingList, type ClosingReview, type ClosingState, type ClosingBox, type ClosingFigures } from "../../lib/api";
import { useBranch } from "../../lib/branch";
import { useAuth } from "../../lib/auth";
import { SectionTitle, Card, Badge, Spinner, LoadErrorCard, ErrorBanner, AmountBox, AmountGrid } from "../../components/ui";
import { Field, MoneyInput, Modal, ActionForm, Submit, ReasonInput } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { formatCurrency, formatDateTime, todayISO, addDaysISO } from "../../lib/utils";

const sar = (h: number | null | undefined) => (h == null ? "—" : formatCurrency(h / 100));
const timeOf = (iso: string | null | undefined) => (iso ? new Date(iso).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", timeZone: "Asia/Riyadh" }) : "—");

const STATE_BADGE: Record<ClosingState, { label: string; cls: string }> = {
  none: { label: "لم يبدأ", cls: "bg-ink-100 text-ink-600" },
  draft: { label: "مسودة", cls: "bg-warning-500/10 text-warning-700" },
  open: { label: "أُرسل — التعديل مفتوح", cls: "bg-brand-50 text-brand-700" },
  locked: { label: "مقفل", cls: "bg-success-500/10 text-success-600" },
};
const COLUMNS: Array<{ box: string; label: string }> = [{ box: "cash", label: "النقد" }, { box: "pos", label: "الشبكة" }, { box: "bank_transfer", label: "التحويل" }, { box: "platform", label: "آجل المنصة" }];

type Draft = Record<string, { entered: number | null; reason: string }>;
const draftOf = (d: ClosingDay): Draft => Object.fromEntries(d.lines.map((l) => [l.key, { entered: l.entered_halalas, reason: l.reason ?? "" }]));
const linesOf = (draft: Draft): ClosingLineInput[] => Object.entries(draft).map(([key, v]) => ({ key, entered_halalas: v.entered, reason: v.reason.trim() || null }));

export default function DayClosing() {
  const { branchId } = useBranch();
  const { can } = useAuth();
  const [date, setDate] = useState(todayISO());
  const [tick, setTick] = useState(0);
  const reload = () => setTick((t) => t + 1);
  return (
    <div>
      <SectionTitle title="إقفال اليوم" subtitle="أرقام اليوم كما سجّلها النظام، مقابل ما عُدّ فعلًا وسبب كل فرق" action={<BranchPicker />} />
      {branchId && (
        <div className="grid gap-4 lg:grid-cols-3">
          <div className="min-w-0 space-y-4 lg:col-span-2">
            <DayPanel branchId={branchId} date={date} setDate={setDate} tick={tick} onChanged={reload} canEdit={can("day.close")} />
          </div>
          <div className="min-w-0 space-y-4">
            <Archive branchId={branchId} tick={tick} onPick={setDate} canApprove={can("day.close.approve")} onChanged={reload} />
            {can("branch.settings") && <WindowSetting branchId={branchId} tick={tick} onChanged={reload} />}
          </div>
        </div>
      )}
    </div>
  );
}

function DayPanel({ branchId, date, setDate, tick, onChanged, canEdit }: { branchId: string; date: string; setDate: (d: string) => void; tick: number; onChanged: () => void; canEdit: boolean }) {
  const [day, setDay] = useState<ClosingDay | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [draft, setDraft] = useState<Draft>({});
  const [note, setNote] = useState("");
  const [amending, setAmending] = useState(false);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [review, setReview] = useState<ClosingReview | null>(null);
  const [askEdit, setAskEdit] = useState(false);
  const [local, setLocal] = useState(0);

  useEffect(() => { setDay(null); setNotice(null); setActionError(null); setAmending(false); }, [branchId, date]);
  useEffect(() => {
    let alive = true; setError(null);
    closingApi.get(branchId, date).then((d) => { if (!alive) return; setDay(d); setDraft(draftOf(d)); setNote(d.closing?.note ?? ""); }, (e) => { if (alive) setError(toArabicError(e)); });
    return () => { alive = false; };
  }, [branchId, date, tick, local]);

  if (error) return <LoadErrorCard message={error} onRetry={() => setLocal((t) => t + 1)} />;
  if (!day) return <div className="py-10 text-center"><Spinner /></div>;

  const sent = day.closing?.status === "submitted";
  const figures: ClosingFigures = sent && day.closing?.figures ? day.closing.figures : day.live;
  const editable = canEdit && (day.state === "none" || day.state === "draft" || (day.state === "open" && amending));
  const pending = day.requests.find((r) => r.status === "pending");
  const badge = STATE_BADGE[day.state];

  async function run(fn: () => Promise<void>) { setBusy(true); setActionError(null); setNotice(null); try { await fn(); } catch (e) { setActionError(toArabicError(e)); } finally { setBusy(false); } }
  const saveDraft = () => run(async () => {
    await closingApi.save({ branch_id: branchId, business_date: date, version: day.closing?.version, note: note.trim() || null, lines: linesOf(draft) });
    setNotice("حُفظت المسودة."); setLocal((t) => t + 1); onChanged();
  });
  const openReview = () => run(async () => {
    const saved = await closingApi.save({ branch_id: branchId, business_date: date, version: day.closing?.version, note: note.trim() || null, lines: linesOf(draft) });
    setReview(await closingApi.review(saved.id)); setLocal((t) => t + 1);
  });
  const saveAmend = (reason: string) => run(async () => {
    if (!day.closing) return;
    const r = await closingApi.amend({ id: day.closing.id, version: day.closing.version, reason, lines: linesOf(draft) });
    setNotice(r.unchanged ? "لا تغيير." : "حُفظ التعديل وسُجّل للمراجعة."); setAmending(false); setLocal((t) => t + 1); onChanged();
  });

  return (
    <>
      <Card>
        <div className="flex flex-wrap items-end justify-between gap-3">
          <Field label="اليوم"><input type="date" className="input" dir="ltr" max={todayISO()} value={date} onChange={(e) => e.target.value && setDate(e.target.value)} aria-label="اليوم" /></Field>
          <div className="flex flex-wrap items-center gap-2" data-testid="closing-state">
            <Badge className={badge.cls}>{day.state === "locked" ? <Lock className="ml-1 inline h-3 w-3" /> : day.state === "open" ? <Unlock className="ml-1 inline h-3 w-3" /> : <FileClock className="ml-1 inline h-3 w-3" />}{badge.label}</Badge>
            {day.state === "open" && <span className="text-xs text-ink-500">يُعدَّل حتى <span dir="ltr">{timeOf(day.closing?.edit_until)}</span></span>}
            {sent && <span className="text-xs text-ink-500">أرسله {day.closing?.submitted_by ?? "—"} · {formatDateTime(day.closing!.submitted_at!)}</span>}
          </div>
        </div>
        {day.changed_since_sent && (
          <p className="mt-3 flex items-start gap-2 rounded-xl bg-warning-500/10 px-3 py-2 text-sm text-warning-700" data-testid="closing-changed"><AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />تغيّرت سندات هذا اليوم بعد إرسال الإقفال. الأرقام أدناه هي المُرسلة، والأرقام الحالية تختلف عنها.</p>
        )}
        <AmountGrid className="mt-4" testId="closing-rooms">
          <AmountBox label="الوحدات" value={figures.rooms.units} />
          <AmountBox label="مؤجرة" value={figures.rooms.rented} />
          <AmountBox label="وصول" value={figures.rooms.arrivals} />
          <AmountBox label="مغادرة" value={figures.rooms.departures} />
          <AmountBox label="خارج الخدمة" value={figures.rooms.out_of_service} />
        </AmountGrid>
      </Card>

      <Card>
        <h2 className="mb-1 text-sm font-semibold text-ink-700">الصناديق</h2>
        <p className="mb-3 text-xs text-ink-500">صافي اليوم في كل صندوق: المقبوض (إيجار وتأمين) ناقص المردود. أدخل ما عُددته فعلًا، واكتب سبب أي فرق.</p>
        <div className="space-y-3" data-testid="closing-boxes">
          {figures.boxes.map((b) => <BoxRow key={b.key} b={b} value={draft[b.key]} editable={editable} onChange={(v) => setDraft({ ...draft, [b.key]: v })} />)}
        </div>
        <Field label="ملاحظة على اليوم" className="mt-3"><textarea className="input" rows={2} value={note} disabled={!(canEdit && (day.state === "none" || day.state === "draft"))} onChange={(e) => setNote(e.target.value)} aria-label="ملاحظة على اليوم" /></Field>
        {actionError && <div className="mt-3"><ErrorBanner message={actionError} /></div>}
        {notice && <p className="mt-3 flex items-center gap-1 text-sm text-success-600"><CheckCircle2 className="h-4 w-4" />{notice}</p>}
        {canEdit && (
          <div className="mt-4 flex flex-wrap gap-2">
            {(day.state === "none" || day.state === "draft") && <>
              <button type="button" className="btn-primary text-sm" disabled={busy} onClick={openReview}><Send className="h-4 w-4" /> مراجعة وإرسال</button>
              <button type="button" className="btn-outline text-sm" disabled={busy} onClick={saveDraft}>حفظ المسودة</button>
            </>}
            {day.state === "open" && !amending && <button type="button" className="btn-outline text-sm" onClick={() => setAmending(true)}><Pencil className="h-4 w-4" /> تعديل الإقفال</button>}
            {day.state === "locked" && !pending && <button type="button" className="btn-outline text-sm" onClick={() => setAskEdit(true)}>طلب تعديل من الإدارة</button>}
            {day.state === "locked" && pending && <p className="text-sm text-ink-500" data-testid="closing-request-pending">طلب تعديل بانتظار قرار الإدارة: {pending.reason}</p>}
          </div>
        )}
        {amending && <AmendForm busy={busy} onCancel={() => { setAmending(false); setDraft(draftOf(day)); }} onSave={saveAmend} />}
      </Card>

      <Matrix figures={figures} />

      {day.requests.length > 0 && (
        <Card>
          <h2 className="mb-2 text-sm font-semibold text-ink-700">طلبات التعديل</h2>
          <div className="divide-y divide-ink-50 text-sm">
            {day.requests.map((r) => (
              <div key={r.id} className="py-2">
                <div className="flex flex-wrap items-center gap-2"><Badge className={r.status === "pending" ? "bg-warning-500/10 text-warning-700" : r.status === "approved" ? "bg-success-500/10 text-success-600" : "bg-danger-500/10 text-danger-600"}>{r.status === "pending" ? "بانتظار القرار" : r.status === "approved" ? "وافقت الإدارة" : "رفضت الإدارة"}</Badge><span className="text-xs text-ink-400">{r.requested_by ?? "—"} · {formatDateTime(r.requested_at)}</span></div>
                <p className="mt-1 text-ink-700">{r.reason}</p>
                {r.decision_note && <p className="text-xs text-ink-500">ملاحظة الإدارة: {r.decision_note}</p>}
              </div>
            ))}
          </div>
        </Card>
      )}

      <Modal open={!!review} title="مراجعة الإقفال قبل إرساله" onClose={() => setReview(null)} wide>
        {review && <ReviewBody review={review} onSent={(msg) => { setReview(null); setNotice(msg); setLocal((t) => t + 1); onChanged(); }} />}
      </Modal>
      <Modal open={askEdit} title="طلب تعديل الإقفال" onClose={() => setAskEdit(false)}>
        {askEdit && day.closing && <RequestForm closingId={day.closing.id} onDone={() => { setAskEdit(false); setNotice("أُرسل الطلب إلى الإدارة."); setLocal((t) => t + 1); onChanged(); }} onCancel={() => setAskEdit(false)} />}
      </Modal>
    </>
  );
}

function BoxRow({ b, value, editable, onChange }: { b: ClosingBox; value: { entered: number | null; reason: string } | undefined; editable: boolean; onChange: (v: { entered: number | null; reason: string }) => void }) {
  const v = value ?? { entered: null, reason: "" };
  const diff = v.entered == null ? null : v.entered - b.system_halalas;
  return (
    <div className="rounded-xl border border-ink-100 p-3" data-testid={`closing-box-${b.box}`}>
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <span className="font-semibold text-ink-800">{b.label}{b.required && <span className="mr-1 text-xs font-normal text-ink-400">(إلزامي)</span>}</span>
        <span className="text-sm text-ink-500">سجّل النظام <span dir="ltr" className="font-semibold text-ink-800 tabular-nums">{sar(b.system_halalas)}</span></span>
      </div>
      <div className="mt-2 grid gap-3 sm:grid-cols-2">
        <Field label={b.box === "pos" ? "إجمالي جهاز الشبكة" : b.box === "cash" ? "عدّ النقد" : "المؤكَّد"}>
          <MoneyInput valueHalalas={v.entered} onChange={(h) => onChange({ ...v, entered: h })} min={-100000000} disabled={!editable} label={`${b.label}: المُدخل`} />
        </Field>
        <Field label={diff ? "سبب الفرق (إلزامي)" : "السبب"}>
          <input className="input" value={v.reason} disabled={!editable} onChange={(e) => onChange({ ...v, reason: e.target.value })} aria-label={`${b.label}: سبب الفرق`} />
        </Field>
      </div>
      {diff != null && <p className={`mt-1 text-sm ${diff === 0 ? "text-success-600" : "text-danger-600"}`} data-testid={`closing-diff-${b.box}`}>{diff === 0 ? "مطابق." : <>الفرق <span dir="ltr">{sar(diff)}</span> {diff > 0 ? "(المعدود أكثر)" : "(المعدود أقل)"}</>}</p>}
    </div>
  );
}

function Matrix({ figures }: { figures: ClosingFigures }) {
  const sources = useMemo(() => [...new Map(figures.matrix.map((m) => [m.source_id ?? "direct", m.source])).entries()], [figures]);
  const cell = (src: string, box: string) => figures.matrix.filter((m) => (m.source_id ?? "direct") === src && m.box === box).reduce((s, m) => s + m.net, 0);
  const colTotal = (box: string) => figures.matrix.filter((m) => m.box === box).reduce((s, m) => s + m.net, 0);
  return (
    <Card>
      <h2 className="mb-2 text-sm font-semibold text-ink-700">طريقة الدفع × مصدر الحجز</h2>
      {sources.length === 0 ? <p className="text-sm text-ink-400">لا سندات في هذا اليوم.</p> : (
        <div className="overflow-x-auto">
          <table className="w-full min-w-[32rem] text-sm" data-testid="closing-matrix">
            <thead><tr className="border-b border-ink-100 text-xs text-ink-500"><th className="py-2 text-right font-medium">المصدر</th>{COLUMNS.map((c) => <th key={c.box} className="py-2 text-left font-medium">{c.label}</th>)}<th className="py-2 text-left font-medium">المجموع</th></tr></thead>
            <tbody>
              {sources.map(([id, name]) => (
                <tr key={id} className="border-b border-ink-50">
                  <td className="py-2 text-ink-700">{name}</td>
                  {COLUMNS.map((c) => <td key={c.box} className="py-2 text-left tabular-nums" dir="ltr">{cell(id, c.box) ? sar(cell(id, c.box)) : "—"}</td>)}
                  <td className="py-2 text-left font-semibold tabular-nums" dir="ltr">{sar(COLUMNS.reduce((s, c) => s + cell(id, c.box), 0))}</td>
                </tr>
              ))}
            </tbody>
            <tfoot><tr className="text-ink-800"><td className="py-2 font-semibold">المجموع</td>{COLUMNS.map((c) => <td key={c.box} className="py-2 text-left font-semibold tabular-nums" dir="ltr">{sar(colTotal(c.box))}</td>)}<td className="py-2 text-left font-bold tabular-nums" dir="ltr">{sar(COLUMNS.reduce((s, c) => s + colTotal(c.box), 0))}</td></tr></tfoot>
          </table>
        </div>
      )}
    </Card>
  );
}

function ReviewBody({ review, onSent }: { review: ClosingReview; onSent: (msg: string) => void }) {
  const [confirmed, setConfirmed] = useState(false);
  const label = (key: string) => review.figures.boxes.find((b) => b.key === key)?.label ?? key;
  const blocked = review.missing.length > 0 || review.unexplained.length > 0;
  return (
    <ActionForm onSubmit={async () => { const r = await closingApi.submit(review.id, review.version, review.hash); onSent(`أُرسل الإقفال. يمكن تعديله حتى ${timeOf(r.edit_until)}، وكل تعديل يُسجَّل للمراجعة.`); }}>
      <div className="space-y-2 text-sm" data-testid="closing-review">
        {review.figures.boxes.map((b) => { const l = review.lines.find((x) => x.key === b.key); return (
          <div key={b.key} className="flex flex-wrap items-baseline justify-between gap-2 border-b border-ink-50 pb-2">
            <span className="font-medium text-ink-800">{b.label}</span>
            <span className="text-ink-600">النظام <span dir="ltr" className="tabular-nums">{sar(b.system_halalas)}</span> · المُدخل <span dir="ltr" className="tabular-nums">{sar(l?.entered_halalas)}</span> · الفرق <span dir="ltr" className={`tabular-nums ${l?.difference_halalas ? "text-danger-600" : ""}`}>{sar(l?.difference_halalas)}</span></span>
            {l?.reason && <span className="w-full text-xs text-ink-500">السبب: {l.reason}</span>}
          </div>
        ); })}
      </div>
      {review.missing.length > 0 && <p className="mt-3 text-sm text-danger-600">ناقص قبل الإرسال: {review.missing.map(label).join("، ")}.</p>}
      {review.unexplained.length > 0 && <p className="mt-3 text-sm text-danger-600">فرق بلا سبب: {review.unexplained.map(label).join("، ")}.</p>}
      <p className="mt-3 text-xs text-ink-500">بعد الإرسال يبقى التعديل متاحًا {review.edit_minutes} دقيقة، وكل تعديل يُسجَّل ويصل للمراجعة. بعدها لا يُعدَّل إلا بموافقة الإدارة.</p>
      {!blocked && <label className="mt-3 flex items-center gap-2 text-sm"><input type="checkbox" checked={confirmed} onChange={(e) => setConfirmed(e.target.checked)} /> راجعت الأرقام وهي صحيحة</label>}
      {blocked ? <p className="mt-4 text-sm text-ink-500">أغلق المراجعة وأكمل الناقص ثم راجع من جديد.</p> : confirmed ? <Submit label="إرسال الإقفال" /> : <p className="mt-4 text-xs text-ink-400">أشّر على المراجعة ليظهر زر الإرسال.</p>}
    </ActionForm>
  );
}

function AmendForm({ busy, onCancel, onSave }: { busy: boolean; onCancel: () => void; onSave: (reason: string) => void }) {
  const [reason, setReason] = useState("");
  return (
    <div className="mt-4 rounded-xl border border-brand-100 bg-brand-50/40 p-3" data-testid="closing-amend">
      <p className="mb-2 text-sm text-ink-700">عدّل الأرقام أعلاه، واكتب سبب التعديل. يُسجَّل قبل التعديل وبعده ويصل للمراجعة.</p>
      <ReasonInput value={reason} onChange={setReason} label="سبب التعديل (إلزامي)" />
      <div className="mt-3 flex gap-2">
        <button type="button" className="btn-primary text-sm" disabled={busy || !reason.trim()} onClick={() => onSave(reason.trim())}>حفظ التعديل</button>
        <button type="button" className="btn-outline text-sm" onClick={onCancel}>إلغاء</button>
      </div>
    </div>
  );
}

function RequestForm({ closingId, onDone, onCancel }: { closingId: string; onDone: () => void; onCancel: () => void }) {
  const [reason, setReason] = useState("");
  return (
    <ActionForm onSubmit={async () => { if (!reason.trim()) throw new Error("VALIDATION: reason"); await closingApi.requestEdit(closingId, reason.trim()); onDone(); }}>
      <p className="mb-3 text-sm text-ink-600">انتهت مهلة التعديل. يصل الطلب إلى الإدارة، وإن وافقت تُفتح مهلة جديدة.</p>
      <ReasonInput value={reason} onChange={setReason} />
      <Submit label="إرسال الطلب" onCancel={onCancel} />
    </ActionForm>
  );
}

function Archive({ branchId, tick, onPick, canApprove, onChanged }: { branchId: string; tick: number; onPick: (d: string) => void; canApprove: boolean; onChanged: () => void }) {
  const [data, setData] = useState<ClosingList | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [deciding, setDeciding] = useState<{ id: string; approve: boolean; date: string } | null>(null);
  const [note, setNote] = useState("");
  useEffect(() => {
    let alive = true; setError(null);
    closingApi.list(branchId, addDaysISO(todayISO(), -30), todayISO()).then((d) => { if (alive) setData(d); }, (e) => { if (alive) setError(toArabicError(e)); });
    return () => { alive = false; };
  }, [branchId, tick]);
  if (error) return <LoadErrorCard message={error} />;
  if (!data) return <Card><Spinner /></Card>;
  return (
    <>
      {canApprove && data.pending_requests.length > 0 && (
        <Card data-testid="closing-pending-requests">
          <h2 className="mb-2 text-sm font-semibold text-ink-700">طلبات تعديل بانتظار قرارك</h2>
          <div className="space-y-3 text-sm">
            {data.pending_requests.map((r) => (
              <div key={r.id} className="rounded-lg border border-ink-100 p-2">
                <button type="button" className="font-medium text-brand-700 underline" dir="ltr" onClick={() => onPick(r.business_date)}>{r.business_date}</button>
                <p className="text-ink-700">{r.reason}</p>
                <p className="text-xs text-ink-400">{r.requested_by ?? "—"} · {formatDateTime(r.requested_at)}</p>
                <div className="mt-2 flex gap-2">
                  <button type="button" className="btn-primary text-xs" onClick={() => { setNote(""); setDeciding({ id: r.id, approve: true, date: r.business_date }); }}>موافقة</button>
                  <button type="button" className="btn-outline text-xs" onClick={() => { setNote(""); setDeciding({ id: r.id, approve: false, date: r.business_date }); }}>رفض</button>
                </div>
              </div>
            ))}
          </div>
        </Card>
      )}
      <Card>
        <h2 className="mb-2 text-sm font-semibold text-ink-700">أرشيف الإقفالات (آخر 30 يومًا)</h2>
        {data.missing_days.length > 0 && <p className="mb-2 rounded-lg bg-warning-500/10 px-2 py-1 text-xs text-warning-700" data-testid="closing-missing">أيام بلا إقفال مُرسل: <span dir="ltr">{data.missing_days.slice(0, 7).join("، ")}</span>{data.missing_days.length > 7 ? " …" : ""}</p>}
        {data.closings.length === 0 ? <p className="text-xs text-ink-400">لا إقفالات بعد.</p> : (
          <div className="divide-y divide-ink-50 text-sm" data-testid="closing-archive">
            {data.closings.map((c) => (
              <button key={c.id} type="button" onClick={() => onPick(c.business_date)} className="flex w-full items-center justify-between gap-2 py-2 text-right hover:bg-ink-50/50">
                <span><span dir="ltr" className="font-medium text-ink-700">{c.business_date}</span><span className="block text-[11px] text-ink-400">{c.submitted_by ?? "—"}{c.difference_halalas ? <> · فرق <span dir="ltr">{sar(c.difference_halalas)}</span></> : null}</span></span>
                <span className="flex items-center gap-1">{c.pending_request && <Badge className="bg-warning-500/10 text-warning-700">طلب</Badge>}<Badge className={STATE_BADGE[c.state].cls}>{STATE_BADGE[c.state].label}</Badge></span>
              </button>
            ))}
          </div>
        )}
      </Card>
      <Modal open={!!deciding} title={deciding?.approve ? "الموافقة على التعديل" : "رفض طلب التعديل"} onClose={() => setDeciding(null)}>
        {deciding && (
          <ActionForm onSubmit={async () => { if (!deciding.approve && !note.trim()) throw new Error("VALIDATION: note_required"); await closingApi.decide(deciding.id, deciding.approve, note.trim() || null); setDeciding(null); onChanged(); }}>
            <p className="mb-3 text-sm text-ink-600">{deciding.approve ? "تُفتح للمشرف مهلة تعديل جديدة لإقفال يوم " : "يبقى إقفال يوم "}<span dir="ltr">{deciding.date}</span>{deciding.approve ? "، وكل تعديل فيها يُسجَّل للمراجعة." : " كما هو."}</p>
            <ReasonInput value={note} onChange={setNote} label={deciding.approve ? "ملاحظة (اختيارية)" : "سبب الرفض (إلزامي)"} />
            <Submit label={deciding.approve ? "موافقة" : "رفض"} onCancel={() => setDeciding(null)} danger={!deciding.approve} />
          </ActionForm>
        )}
      </Modal>
    </>
  );
}

function WindowSetting({ branchId, tick, onChanged }: { branchId: string; tick: number; onChanged: () => void }) {
  const [minutes, setMinutes] = useState<number | null>(null);
  const [value, setValue] = useState("");
  const [editing, setEditing] = useState(false);
  useEffect(() => { closingApi.get(branchId, todayISO()).then((d) => { setMinutes(d.edit_minutes); setValue(String(d.edit_minutes)); }, () => setMinutes(null)); }, [branchId, tick]);
  if (minutes == null) return null;
  return (
    <Card data-testid="closing-window-setting">
      <h2 className="mb-1 flex items-center gap-1 text-sm font-semibold text-ink-700"><Settings2 className="h-4 w-4" /> مهلة التعديل بعد الإرسال</h2>
      {!editing ? (
        <div className="flex items-center justify-between gap-2 text-sm"><span><span dir="ltr">{minutes}</span> دقيقة لهذا الفرع</span><button type="button" className="btn-ghost text-xs" onClick={() => setEditing(true)}>تغيير</button></div>
      ) : (
        <ActionForm onSubmit={async () => { const n = Number(value); if (!Number.isInteger(n)) throw new Error("VALIDATION: edit_minutes"); await closingApi.setMinutes(branchId, n); setEditing(false); onChanged(); }}>
          <Field label="الدقائق (من 5 إلى 240)"><input className="input" dir="ltr" inputMode="numeric" value={value} onChange={(e) => setValue(e.target.value.replace(/\D/g, "").slice(0, 3))} aria-label="مهلة التعديل بالدقائق" /></Field>
          <Submit label="حفظ" onCancel={() => setEditing(false)} />
        </ActionForm>
      )}
    </Card>
  );
}
