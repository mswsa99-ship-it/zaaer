/**
 * The invoices of a stay (decisions 26, 27). Internal invoices only: no tax invoice, no credit or debit note.
 *  - «إنشاء فاتورة» as in Zaaer: the reservation, the guest, the arrival and the departure, then the period (from/to,
 *    the whole stay by default) with what the invoice would carry, and «إنشاء» or «تجاهل». A period invoice carries its
 *    nights at their saved price, with the discount and the tax in the same proportion; the server computes every share.
 *  - Each invoice with how it came (partial, at the departure, when the deposit was settled), its version and its lines.
 *  - The edit, with a reason: the bill-to name and note, the period of a partial invoice; the amounts follow the stay's
 *    lines as they stand. The version before is kept and shown; the edit waits in the owner's review list.
 *  - The cancellation is the owner's or a manager's, with a reason; what the invoice carried is free again.
 */
import { useEffect, useState } from "react";
import { Eye, EyeOff, PencilLine, Ban, History, ShieldAlert } from "lucide-react";
import { invoiceApi, toArabicError, type Invoice, type InvoiceLine, type InvoicePreview, type ReservationDetail } from "../lib/api";
import { Badge, ErrorBanner, Spinner } from "./ui";
import { Modal, Field, ActionForm, ReasonInput, Submit, useFormBusy } from "./forms";
import { CHARGE_KIND_LABELS, type ChargeKind } from "../lib/types";
import { formatCurrency, formatDateTime } from "../lib/utils";

const sar = (h: number | undefined | null) => formatCurrency((h ?? 0) / 100);

export const INVOICE_ORIGIN_AR: Record<Invoice["origin"], string> = { manual: "يدوية", checkout: "تلقائية عند المغادرة", deposit_settled: "تلقائية عند تسوية التأمين" };
/** How an invoice came: a partial invoice for a period, everything left by hand, or one of the two automatic ones. */
export const invoiceKindLabel = (i: Pick<Invoice, "scope" | "origin">) => (i.origin !== "manual" ? INVOICE_ORIGIN_AR[i.origin] : i.scope === "period" ? "جزئية لفترة" : "كل ما لم يُفوتر");

/** A new invoice starts with the whole stay — after the last partial invoice, when there is one; everything left once the
 *  partial invoices reach the departure. */
function invoiceDefaults(d: ReservationDetail): { mode: "period" | "remaining"; from: string; to: string } {
  const r = d.reservation;
  const last = (d.invoices ?? []).filter((i) => i.status === "issued" && i.scope === "period").map((i) => i.period_to).sort().pop() ?? null;
  if (last && last >= r.check_out) return { mode: "remaining", from: r.check_in, to: r.check_out };
  return { mode: "period", from: last && last > r.check_in ? last : r.check_in, to: r.check_out };
}

function Info({ label, value, ltr }: { label: string; value: string; ltr?: boolean }) {
  return <div className="min-w-0"><dt className="text-[11px] text-ink-400">{label}</dt><dd className="truncate font-medium text-ink-800" dir={ltr ? "ltr" : undefined}>{value}</dd></div>;
}

/** The lines an invoice carries: each one's share, and the line's whole when the share is a part of it. */
export function InvoiceLines({ lines }: { lines: InvoiceLine[] }) {
  return (
    <div className="divide-y divide-ink-50 rounded-xl border border-ink-100 text-sm">
      {lines.map((l) => (
        <div key={l.charge_id} className="flex items-start justify-between gap-3 px-3 py-2">
          <div className="min-w-0">
            <p className="text-ink-700">{l.description}</p>
            <p className="text-[11px] text-ink-400">{CHARGE_KIND_LABELS[l.kind as ChargeKind] ?? l.kind}{l.amount_halalas !== l.total_halalas ? ` · جزء من ${sar(l.total_halalas)}` : ""}</p>
          </div>
          <span dir="ltr" className={`shrink-0 ${l.amount_halalas < 0 ? "text-success-600" : "text-ink-800"}`}>{sar(l.amount_halalas)}</span>
        </div>
      ))}
    </div>
  );
}

function Totals({ sub, tax, total }: { sub: number; tax: number; total: number }) {
  return (
    <div className="space-y-1 rounded-xl bg-ink-50 px-3 py-2 text-sm">
      <div className="flex justify-between text-ink-500"><span>قبل الضريبة</span><span dir="ltr">{sar(sub)}</span></div>
      {tax !== 0 && <div className="flex justify-between text-ink-500"><span>الضريبة</span><span dir="ltr">{sar(tax)}</span></div>}
      <div className="flex justify-between font-semibold text-ink-800"><span>الإجمالي</span><span dir="ltr" data-testid="invoice-preview-total">{sar(total)}</span></div>
    </div>
  );
}

/** What the server says the invoice would carry, and anything that stops it. */
function PreviewBox({ pv, error }: { pv: InvoicePreview | null; error: string | null }) {
  if (error) return <ErrorBanner message={error} />;
  if (!pv) return <div className="py-4 text-center"><Spinner /></div>;
  return (
    <div className="space-y-2" data-testid="invoice-preview">
      {pv.problems.length > 0 && (
        <div className="flex items-start gap-2 rounded-xl bg-warning-500/10 p-3 text-xs text-warning-600" role="status">
          <ShieldAlert className="mt-0.5 h-4 w-4 shrink-0" /><div>{pv.problems.map((p) => <p key={p}>{p}</p>)}</div>
        </div>
      )}
      {pv.lines.length > 0 && <InvoiceLines lines={pv.lines} />}
      {pv.lines.length > 0 && <Totals sub={pv.subtotal_halalas} tax={pv.tax_halalas} total={pv.total_halalas} />}
    </div>
  );
}

/** Asks the server for the preview a moment after the inputs settle; an older answer never replaces a newer one. */
function usePreview(open: boolean, args: Parameters<typeof invoiceApi.preview>[0] | null) {
  const [pv, setPv] = useState<InvoicePreview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const key = JSON.stringify(args);
  useEffect(() => {
    if (!open || !args) return;
    let alive = true;
    setPv(null); setError(null);
    const t = window.setTimeout(() => { invoiceApi.preview(args).then((x) => { if (alive) setPv(x); }, (e) => { if (alive) setError(toArabicError(e)); }); }, 200);
    return () => { alive = false; window.clearTimeout(t); };
  }, [open, key]);
  return { pv, error };
}

function CreateOrIgnore({ disabled, onIgnore }: { disabled: boolean; onIgnore: () => void }) {
  const busy = useFormBusy();
  return (
    <div className="mt-5 flex gap-2">
      <button type="submit" disabled={busy || disabled} className="btn-primary">{busy ? <Spinner className="h-4 w-4" /> : null} إنشاء</button>
      <button type="button" onClick={onIgnore} className="btn-outline">تجاهل</button>
    </div>
  );
}

/** «إنشاء فاتورة» (decision 27). */
export function InvoiceDialog({ open, d, onClose, onDone }: { open: boolean; d: ReservationDetail; onClose: () => void; onDone: () => Promise<void> }) {
  const r = d.reservation;
  const [mode, setMode] = useState<"period" | "remaining">("period");
  const [from, setFrom] = useState(r.check_in);
  const [to, setTo] = useState(r.check_out);
  useEffect(() => {
    if (!open) return;
    const x = invoiceDefaults(d); setMode(x.mode); setFrom(x.from); setTo(x.to);
  }, [open]);
  const args = mode === "remaining" ? { reservation_id: r.id } : from && to ? { reservation_id: r.id, from, to } : null;
  const { pv, error } = usePreview(open, args);
  const guest = pv?.reservation.guest ?? d.guests?.find((g) => g.is_primary)?.full_name ?? "—";
  return (
    <Modal open={open} title="إنشاء فاتورة" onClose={onClose} wide>
      <ActionForm onSubmit={async () => {
        if (!args) throw new Error("VALIDATION: period");
        await invoiceApi.issue(args);
        await onDone();
      }}>
        <div className="space-y-3">
          <dl className="grid grid-cols-2 gap-3 rounded-xl bg-ink-50 p-3 text-sm sm:grid-cols-4">
            <Info label="الحجز" value={r.internal_ref + (r.external_ref ? ` · ${r.external_ref}` : "")} />
            <Info label="الضيف" value={guest} />
            <Info label="الوصول" value={r.check_in} ltr />
            <Info label="المغادرة" value={r.check_out} ltr />
          </dl>
          <div className="flex gap-1 rounded-xl bg-ink-50 p-1 text-xs" role="radiogroup" aria-label="ما تحمله الفاتورة">
            {([["period", "فترة"], ["remaining", "كل ما لم يُفوتر"]] as const).map(([m, label]) => (
              <button key={m} type="button" role="radio" aria-checked={mode === m} onClick={() => setMode(m)}
                className={`flex-1 rounded-lg px-3 py-1.5 ${mode === m ? "bg-white font-medium text-ink-800 shadow-sm" : "text-ink-500"}`}>{label}</button>
            ))}
          </div>
          {mode === "period" ? (
            <div className="grid grid-cols-2 gap-3">
              <Field label="الفترة من"><input type="date" className="input" dir="ltr" value={from} onChange={(e) => setFrom(e.target.value)} aria-label="الفترة من" /></Field>
              <Field label="إلى"><input type="date" className="input" dir="ltr" value={to} min={from} onChange={(e) => setTo(e.target.value)} aria-label="الفترة إلى" /></Field>
            </div>
          ) : <p className="text-xs text-ink-500">كل ما على الإقامة ولم تحمله فاتورة بعد، أيًّا كان تاريخه.</p>}
          <p className="text-xs text-ink-400">ليالي الفترة بسعرها المحفوظ، والخصم والضريبة بالنسبة نفسها، والخدمة في يومها. فاتورة داخلية؛ ليست إثبات قبض.</p>
          <PreviewBox pv={pv} error={error} />
        </div>
        <CreateOrIgnore disabled={!pv?.ok} onIgnore={onClose} />
      </ActionForm>
    </Modal>
  );
}

/** The edit, with a reason (decision 26): the bill-to, the period of a partial invoice; the amounts follow the lines. */
function EditInvoiceDialog({ inv, onClose, onDone }: { inv: Invoice | null; onClose: () => void; onDone: () => Promise<void> }) {
  const open = !!inv;
  const [name, setName] = useState(""); const [note, setNote] = useState("");
  const [from, setFrom] = useState(""); const [to, setTo] = useState(""); const [reason, setReason] = useState("");
  useEffect(() => {
    if (!inv) return;
    setName(inv.bill_to?.name ?? ""); setNote(inv.bill_to?.note ?? ""); setFrom(inv.period_from); setTo(inv.period_to); setReason("");
  }, [inv]);
  const period = inv?.scope === "period";
  const { pv, error } = usePreview(open, inv ? (period ? { invoice_id: inv.id, from, to } : { invoice_id: inv.id }) : null);
  if (!inv) return null;
  return (
    <Modal open={open} title={`تعديل الفاتورة ${inv.number}`} onClose={onClose} wide>
      <ActionForm onSubmit={async () => {
        if (!reason.trim()) throw new Error("VALIDATION: reason");
        if (!name.trim()) throw new Error("VALIDATION: bill_to_name");
        const res = await invoiceApi.edit({ invoice_id: inv.id, reason: reason.trim(), bill_to: { name: name.trim(), note: note.trim() }, ...(period ? { from, to } : {}) });
        if (res.unchanged) throw new Error("INVOICE_UNCHANGED");
        await onDone();
      }}>
        <div className="space-y-3">
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="اسم العميل على الفاتورة"><input className="input" value={name} onChange={(e) => setName(e.target.value)} aria-label="اسم العميل على الفاتورة" /></Field>
            <Field label="ملاحظة على الفاتورة"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} aria-label="ملاحظة على الفاتورة" /></Field>
          </div>
          {period && (
            <div className="grid grid-cols-2 gap-3">
              <Field label="الفترة من"><input type="date" className="input" dir="ltr" value={from} onChange={(e) => setFrom(e.target.value)} aria-label="الفترة من" /></Field>
              <Field label="إلى"><input type="date" className="input" dir="ltr" value={to} min={from} onChange={(e) => setTo(e.target.value)} aria-label="الفترة إلى" /></Field>
            </div>
          )}
          <p className="text-xs text-ink-500">المبالغ تتبع بنود الإقامة كما هي الآن ولا تُكتب يدويًا. الإجمالي الحالي <span dir="ltr">{sar(inv.total_halalas)}</span>{pv?.ok ? <> ← بعد التعديل <span dir="ltr">{sar(pv.total_halalas)}</span></> : null}.</p>
          <PreviewBox pv={pv} error={error} />
          <ReasonInput value={reason} onChange={setReason} />
          <p className="text-xs text-ink-400">يُحفظ الإصدار السابق كما هو، ويظهر التعديل في قائمة «بحاجة لمراجعة وتدقيق» للمالك.</p>
        </div>
        <Submit label="حفظ التعديل" onCancel={onClose} />
      </ActionForm>
    </Modal>
  );
}

function CancelInvoiceDialog({ inv, onClose, onDone }: { inv: Invoice | null; onClose: () => void; onDone: () => Promise<void> }) {
  const [reason, setReason] = useState("");
  useEffect(() => { if (inv) setReason(""); }, [inv]);
  if (!inv) return null;
  return (
    <Modal open title={`إلغاء الفاتورة ${inv.number}`} onClose={onClose}>
      <ActionForm onSubmit={async () => { if (!reason.trim()) throw new Error("VALIDATION: reason"); await invoiceApi.cancel(inv.id, reason.trim()); await onDone(); }}>
        <div className="mb-3 flex items-start gap-2 rounded-xl bg-warning-500/10 p-3 text-xs text-warning-600"><ShieldAlert className="mt-0.5 h-4 w-4 shrink-0" />تبقى الفاتورة مسجلة بحالة «ملغاة»، ويعود ما حملته إلى «لم يُفوتر»، ويظهر الإلغاء في قائمة المراجعة للمالك. الإقامة المغلقة تعود إلى «غادر» حتى تُفوتر من جديد.</div>
        <ReasonInput value={reason} onChange={setReason} />
        <Submit label="إلغاء الفاتورة" onCancel={onClose} danger />
      </ActionForm>
    </Modal>
  );
}

/** One invoice: how it came, its period and version, its total; its lines and earlier versions on «عرض». */
function InvoiceRow({ inv, canEdit, canCancel, onEdit, onCancel }: { inv: Invoice; canEdit: boolean; canCancel: boolean; onEdit: () => void; onCancel: () => void }) {
  const [shown, setShown] = useState(false);
  const issued = inv.status === "issued";
  return (
    <div className="py-2.5" data-testid={`invoice-${inv.number}`}>
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1.5 text-sm">
        <span className="font-mono text-xs">{inv.number}</span>
        <Badge className="bg-ink-100 text-ink-600">{invoiceKindLabel(inv)}</Badge>
        {inv.version > 1 && <Badge className="bg-brand-500/10 text-brand-700">الإصدار {inv.version}</Badge>}
        <span dir="ltr" className="text-xs text-ink-500">{inv.period_from} → {inv.period_to}</span>
        {inv.bill_to?.name && <span className="min-w-0 truncate text-xs text-ink-500">{inv.bill_to.name}</span>}
        <span className="mr-auto font-medium" dir="ltr">{sar(inv.total_halalas)}</span>
        {issued ? <Badge className="bg-success-500/10 text-success-600">صادرة</Badge> : <Badge className="bg-danger-500/10 text-danger-600">ملغاة</Badge>}
        <div className="flex gap-1">
          <button type="button" onClick={() => setShown((x) => !x)} className="btn-ghost px-2 py-1 text-[11px]" aria-expanded={shown}>{shown ? <EyeOff className="h-3.5 w-3.5" /> : <Eye className="h-3.5 w-3.5" />} {shown ? "إخفاء" : "عرض"}</button>
          {issued && canEdit && <button type="button" onClick={onEdit} className="btn-ghost px-2 py-1 text-[11px]"><PencilLine className="h-3.5 w-3.5" /> تعديل</button>}
          {issued && canCancel && <button type="button" onClick={onCancel} className="btn-ghost px-2 py-1 text-[11px] text-danger-600"><Ban className="h-3.5 w-3.5" /> إلغاء</button>}
        </div>
      </div>
      {shown && (
        <div className="mt-2 space-y-2">
          <p className="text-[11px] text-ink-400">
            أصدرها {inv.issued_by ?? "النظام"} · {formatDateTime(inv.issued_at)}
            {inv.updated_at ? ` · آخر تعديل ${inv.updated_by ?? ""} · ${formatDateTime(inv.updated_at)}` : ""}
            {inv.bill_to?.note ? ` · ${inv.bill_to.note}` : ""}
            {inv.cancelled_at ? ` · أُلغيت ${formatDateTime(inv.cancelled_at)}: ${inv.cancel_reason ?? ""}` : ""}
          </p>
          <InvoiceLines lines={inv.lines} />
          <Totals sub={inv.subtotal_halalas} tax={inv.tax_halalas} total={inv.total_halalas} />
          {inv.versions.length > 0 && (
            <div className="rounded-xl border border-ink-100 p-3" data-testid="invoice-versions">
              <h4 className="mb-1.5 flex items-center gap-1.5 text-xs font-semibold text-ink-600"><History className="h-3.5 w-3.5" /> الإصدارات السابقة</h4>
              <ul className="space-y-1.5 text-xs text-ink-600">
                {[...inv.versions].reverse().map((v) => (
                  <li key={v.version}>
                    <span className="font-medium">الإصدار {v.version}</span>: <span dir="ltr">{sar(v.total_halalas)}</span> · <span dir="ltr">{v.period_from} → {v.period_to}</span>{v.bill_to?.name ? ` · ${v.bill_to.name}` : ""}
                    <span className="text-ink-400"> — عُدّل {formatDateTime(v.replaced_at)}{v.replaced_by ? ` بواسطة ${v.replaced_by}` : ""}: {v.reason}</span>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

/** The invoices of the stay, and how much of its value no invoice carries yet. */
export function InvoiceList({ d, canEdit, canCancel, onDone }: { d: ReservationDetail; canEdit: boolean; canCancel: boolean; onDone: () => Promise<void> }) {
  const [editing, setEditing] = useState<Invoice | null>(null);
  const [cancelling, setCancelling] = useState<Invoice | null>(null);
  const left = d.invoicing?.uninvoiced_halalas ?? 0;
  const invoices = d.invoices ?? [];
  return (
    <>
      <div className="mb-1 flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-sm font-semibold text-ink-700">الفواتير</h3>
        {left > 0 && <span className="text-xs text-warning-600" data-testid="uninvoiced">لم يُفوتر بعد: <span dir="ltr">{sar(left)}</span></span>}
        {left < 0 && <span className="text-xs text-danger-600" data-testid="uninvoiced">الفواتير تزيد على قيمة الإقامة <span dir="ltr">{sar(-left)}</span> — عدّل الفاتورة</span>}
      </div>
      {invoices.length === 0 ? <p className="text-xs text-ink-400">لا فواتير بعد. تُصدر فاتورة الإقامة تلقائيًا عند المغادرة.</p> : (
        <div className="divide-y divide-ink-50">
          {invoices.map((i) => <InvoiceRow key={i.id} inv={i} canEdit={canEdit} canCancel={canCancel} onEdit={() => setEditing(i)} onCancel={() => setCancelling(i)} />)}
        </div>
      )}
      <EditInvoiceDialog inv={editing} onClose={() => setEditing(null)} onDone={async () => { setEditing(null); await onDone(); }} />
      <CancelInvoiceDialog inv={cancelling} onClose={() => setCancelling(null)} onDone={async () => { setCancelling(null); await onDone(); }} />
    </>
  );
}
