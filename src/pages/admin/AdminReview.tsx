/**
 * «بحاجة لمراجعة وتدقيق» — the owner's list (§16). Every voucher correction or cancellation (decision 11), every invoice
 * edit or cancellation (decision 26), every correction of a stay (undo an arrival, reopen a departure, undo a
 * cancellation — decision 10) and what the monitors found (decision 54) waits here, with who, when and why, until the
 * owner marks it reviewed, with a note. Opening the list also runs the monitors of the active branch when they are due.
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { ClipboardCheck, CheckCheck, Activity } from "lucide-react";
import { reviewApi, toArabicError, type ReviewItem } from "../../lib/api";
import { useBranch } from "../../lib/branch";
import { notifyReviewChanged } from "../../lib/reviewAlerts";
import { SectionTitle, Card, Badge, DataState, ErrorBanner, Spinner } from "../../components/ui";
import { PAYMENT_METHOD_LABELS, type PaymentMethod } from "../../lib/types";
import { formatCurrency, formatDateTime } from "../../lib/utils";

const sar = (h: unknown) => (typeof h === "number" ? formatCurrency(h / 100) : "—");

const KIND_AR: Record<string, string> = {
  voucher_corrected: "تصحيح سند", voucher_cancelled: "إلغاء سند", invoice_edited: "تعديل فاتورة", invoice_cancelled: "إلغاء فاتورة",
  check_in_undone: "تراجع عن تسجيل الوصول", stay_reopened: "إعادة فتح إقامة", cancel_undone: "تراجع عن إلغاء",
  "monitor:allocation_conflict": "تعارض تخصيص", "monitor:ledger_mismatch": "الملخص المالي يختلف عن الدفتر", "monitor:deposit_invalid": "رصيد تأمين غير صالح",
  "monitor:provider_stuck": "مزود خارجي متوقف", "monitor:verification_failures": "محاولات تحقق فاشلة", "monitor:duplicate_departure": "مهام مغادرة مكررة",
  "monitor:out_of_scope": "محاولات خارج الصلاحية",
};
type Group = "" | "voucher" | "invoice" | "stay" | "monitor";
const GROUPS: Array<[Group, string]> = [["", "كل الأنواع"], ["voucher", "السندات"], ["invoice", "الفواتير"], ["stay", "تصحيحات الإقامة"], ["monitor", "المراقبة"]];
const groupOf = (kind: string): Group => (kind.startsWith("monitor:") ? "monitor" : kind.startsWith("voucher_") ? "voucher" : kind.startsWith("invoice_") ? "invoice" : "stay");
const methodAr = (m: unknown) => (typeof m === "string" ? PAYMENT_METHOD_LABELS[m as PaymentMethod] ?? m : "—");

/** What changed, in a line: the voucher before and after, the invoice's totals and periods, what a monitor counted. */
function Details({ item }: { item: ReviewItem }) {
  const d = (item.details ?? {}) as Record<string, any>;   // the shape depends on the kind
  if (item.kind === "voucher_corrected" && d.before && d.after) {
    return <p className="text-xs text-ink-500">قبل: <span dir="ltr">{sar(d.before.amount_halalas)}</span> {methodAr(d.before.method)}{d.before.reference ? ` · ${d.before.reference}` : ""} ← بعد: <span dir="ltr">{sar(d.after.amount_halalas)}</span> {methodAr(d.after.method)}{d.after.reference ? ` · ${d.after.reference}` : ""}{d.issued_by_self ? " · صححه من أصدره" : ""}</p>;
  }
  if (item.kind === "voucher_cancelled") return <p className="text-xs text-ink-500"><span dir="ltr">{sar(d.amount_halalas)}</span> · {methodAr(d.method)}</p>;
  if (item.kind === "invoice_edited") {
    const samePeriod = JSON.stringify(d.before_period) === JSON.stringify(d.after_period);
    return <p className="text-xs text-ink-500">الإجمالي <span dir="ltr">{sar(d.before_total_halalas)}</span> ← <span dir="ltr">{sar(d.after_total_halalas)}</span>{!samePeriod && Array.isArray(d.after_period) ? <> · الفترة <span dir="ltr">{d.before_period?.join(" → ")}</span> ← <span dir="ltr">{d.after_period.join(" → ")}</span></> : null}</p>;
  }
  if (item.kind === "invoice_cancelled") return <p className="text-xs text-ink-500">إجمالي الفاتورة <span dir="ltr">{sar(d.total_halalas)}</span></p>;
  if (item.kind === "monitor:ledger_mismatch" && d.stored && d.ledger) {
    return <p className="text-xs text-ink-500">المسجّل: الإجمالي <span dir="ltr">{sar(d.stored.total)}</span>، المحصل <span dir="ltr">{sar(d.stored.paid)}</span> · الدفتر: الإجمالي <span dir="ltr">{sar(d.ledger.total)}</span>، المحصل <span dir="ltr">{sar(d.ledger.paid)}</span></p>;
  }
  if (item.kind === "monitor:allocation_conflict" && Array.isArray(d.reservations)) return <p className="text-xs text-ink-500">الحجوزات: <span dir="ltr">{d.reservations.join("، ")}</span></p>;
  if (item.kind === "monitor:out_of_scope" && Array.isArray(d.operations) && d.operations.length) return <p className="text-xs text-ink-500">العمليات: <span dir="ltr">{d.operations.join("، ")}</span></p>;
  return null;
}

function ItemRow({ item, selected, onToggle, onMark }: { item: ReviewItem; selected: boolean; onToggle: () => void; onMark: () => void }) {
  const open = !item.reviewed_at;
  const monitor = item.kind.startsWith("monitor:");
  return (
    <div className="flex gap-3 py-3" data-testid="review-item">
      {open && <input type="checkbox" className="mt-1 h-4 w-4 shrink-0" checked={selected} onChange={onToggle} aria-label={`تحديد: ${item.summary}`} />}
      <div className="min-w-0 flex-1 space-y-1">
        <div className="flex flex-wrap items-center gap-2">
          <Badge className={monitor ? "bg-warning-500/10 text-warning-600" : "bg-ink-100 text-ink-600"}>{monitor ? "مراقبة: " : ""}{KIND_AR[item.kind] ?? item.kind}</Badge>
          <span className="text-sm font-medium text-ink-800">{item.summary}</span>
          {item.reservation_id && item.internal_ref && <Link to={`/staff/reservations/${item.reservation_id}`} className="text-xs text-brand-700 underline-offset-2 hover:underline" dir="ltr">{item.internal_ref}</Link>}
        </div>
        {item.reason && <p className="text-xs text-ink-600">السبب: {item.reason}</p>}
        <Details item={item} />
        <p className="text-[11px] text-ink-400">{item.created_by ?? (monitor ? "المراقبة الآلية" : "النظام")} · {formatDateTime(item.created_at)}{item.branch_name ? ` · ${item.branch_name}` : ""}</p>
        {!open && <p className="text-[11px] text-success-600">رُوجع{item.reviewed_by ? ` بواسطة ${item.reviewed_by}` : ""} · {formatDateTime(item.reviewed_at!)}{item.review_note ? ` — ${item.review_note}` : ""}</p>}
        {open && <button type="button" onClick={onMark} className="btn-ghost px-2 py-1 text-[11px] sm:hidden"><CheckCheck className="h-3.5 w-3.5" /> تمت المراجعة</button>}
      </div>
      {open && <button type="button" onClick={onMark} className="btn-ghost hidden h-fit shrink-0 px-2 py-1 text-[11px] sm:inline-flex"><CheckCheck className="h-3.5 w-3.5" /> تمت المراجعة</button>}
    </div>
  );
}

export default function AdminReview() {
  const { branchId } = useBranch();
  const [status, setStatus] = useState<"open" | "reviewed" | "all">("open");
  const [group, setGroup] = useState<Group>("");
  const [items, setItems] = useState<ReviewItem[] | null>(null);
  const [openCount, setOpenCount] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [checked, setChecked] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const r = await reviewApi.list({ status, limit: 500 });
      setItems(r.items); setOpenCount(r.open_count); setError(null);
      setSelected((s) => new Set([...s].filter((id) => r.items.some((x) => x.id === id && !x.reviewed_at))));
    } catch (e) { setError(toArabicError(e)); }
  }, [status]);

  // the monitors of the active branch, when due (the server keeps them to one run every 10 minutes), then the list
  useEffect(() => {
    let alive = true;
    (async () => {
      if (branchId) {
        try { const m = await reviewApi.monitorsIfDue(branchId); if (alive && m.last_run_at) setChecked(m.last_run_at); } catch { /* the list still loads */ }
      }
      if (alive) await load();
    })();
    return () => { alive = false; };
  }, [branchId, load]);

  const shown = useMemo(() => (items ?? []).filter((x) => !group || groupOf(x.kind) === group), [items, group]);
  const counts = useMemo(() => { const c: Record<string, number> = {}; for (const x of items ?? []) { const g = groupOf(x.kind); c[g] = (c[g] ?? 0) + 1; } return c; }, [items]);

  const mark = async (ids: string[]) => {
    if (!ids.length) return;
    setBusy(true);
    try { await reviewApi.mark(ids, note.trim() || undefined); setNote(""); setSelected(new Set()); notifyReviewChanged(); await load(); }
    catch (e) { setError(toArabicError(e)); }
    finally { setBusy(false); }
  };
  const toggle = (id: string) => setSelected((s) => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n; });
  const selectable = shown.filter((x) => !x.reviewed_at).map((x) => x.id);

  return (
    <div>
      <SectionTitle title="بحاجة لمراجعة وتدقيق" subtitle={`${openCount} بانتظار المراجعة — تصحيحات السندات، تعديلات الفواتير وإلغاؤها، تصحيحات الإقامات، وما وجدته المراقبة`} />
      <div className="mb-4 flex flex-wrap items-center gap-2">
        <div className="flex gap-1 rounded-xl bg-ink-50 p-1 text-xs" role="tablist" aria-label="الحالة">
          {([["open", "بانتظار المراجعة"], ["reviewed", "تمت مراجعتها"], ["all", "الكل"]] as const).map(([k, l]) => (
            <button key={k} type="button" role="tab" aria-selected={status === k} onClick={() => { setStatus(k); setItems(null); }}
              className={`rounded-lg px-3 py-1.5 ${status === k ? "bg-white font-medium text-ink-800 shadow-sm" : "text-ink-500"}`}>{l}</button>
          ))}
        </div>
        <div className="flex flex-wrap gap-1 text-xs" role="group" aria-label="النوع">
          {GROUPS.map(([g, l]) => (
            <button key={g || "all"} type="button" aria-pressed={group === g} onClick={() => setGroup(g)}
              className={`rounded-full border px-3 py-1 ${group === g ? "border-brand-500 bg-brand-50 font-medium text-brand-700" : "border-ink-100 text-ink-500"}`}>
              {l}{g && counts[g] ? ` (${counts[g]})` : ""}
            </button>
          ))}
        </div>
        {checked && <span className="mr-auto flex items-center gap-1 text-[11px] text-ink-400"><Activity className="h-3.5 w-3.5" /> آخر فحص للمراقبة {formatDateTime(checked)}</span>}
      </div>
      <DataState loading={items === null && !error} error={error} empty={shown.length === 0} onRetry={() => { setError(null); void load(); }}
        emptyIcon={<ClipboardCheck className="h-10 w-10" />} emptyTitle={status === "open" ? "لا شيء بانتظار المراجعة" : "لا بنود"} emptyDescription="تظهر هنا التصحيحات والتعديلات والإلغاءات وما تجده المراقبة.">
        <Card>
          {status !== "reviewed" && selectable.length > 0 && (
            <div className="mb-2 flex flex-wrap items-center gap-2 border-b border-ink-50 pb-3">
              <label className="flex items-center gap-2 text-xs text-ink-600">
                <input type="checkbox" className="h-4 w-4" checked={selectable.length > 0 && selectable.every((id) => selected.has(id))}
                  onChange={(e) => setSelected(e.target.checked ? new Set(selectable) : new Set())} /> تحديد الكل ({selectable.length})
              </label>
              <input className="input h-8 min-w-0 max-w-sm flex-1 basis-48 text-xs" placeholder="ملاحظة المراجعة (اختيارية)" value={note} onChange={(e) => setNote(e.target.value)} aria-label="ملاحظة المراجعة" />
              <button type="button" disabled={busy || selected.size === 0} onClick={() => mark([...selected])} className="btn-primary text-xs">
                {busy ? <Spinner className="h-3.5 w-3.5" /> : <CheckCheck className="h-3.5 w-3.5" />} تأشير المحدد كمراجَع ({selected.size})
              </button>
            </div>
          )}
          {error && items && <div className="mb-2"><ErrorBanner message={error} /></div>}
          <div className="divide-y divide-ink-50">
            {shown.map((x) => <ItemRow key={x.id} item={x} selected={selected.has(x.id)} onToggle={() => toggle(x.id)} onMark={() => mark([x.id])} />)}
          </div>
        </Card>
      </DataState>
    </div>
  );
}
