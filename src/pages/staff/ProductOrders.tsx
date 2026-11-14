/**
 * «طلبات المنتجات» (the guest journey, W1; migration 0068): what the guests in their rooms ordered — from WhatsApp, or
 * by the reception for them. An order waits for its payment; taking the payment at reception (cash, card or transfer)
 * puts the lines in the stay's account, issues the receipt and creates the delivery task in one step, and the order
 * is delivered when that task is done in «خدمة الغرف». The reception cancels an order that waits; a paid one that was
 * not delivered is cancelled by the owner or the manager (its receipt is cancelled with it).
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { ShoppingBag, Plus, Minus, Ban, Wallet, MessageCircle, ConciergeBell } from "lucide-react";
import { productsApi, newIdempotencyKey, toArabicError, type ProductOrder, type ProductOrderStatus, type ProductMenu } from "../../lib/api";
import { useBranch } from "../../lib/branch";
import { useAuth } from "../../lib/auth";
import { useCashAccounts } from "../../lib/useCashAccounts";
import { SectionTitle, Card, Badge, Spinner, LoadErrorCard, EmptyState, AmountBox, AmountGrid } from "../../components/ui";
import { Field, Modal, ActionForm, Submit, ReasonInput } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { PaymentFields } from "../../components/ReservationOperations";
import { formatCurrency, formatDateTime } from "../../lib/utils";
import { METHOD_ACCOUNT_KIND, METHOD_NEEDS_REFERENCE, type PaymentMethod } from "../../lib/types";

const sar = (h: number) => formatCurrency(h / 100);
export const ORDER_STATUS: Record<ProductOrderStatus, [string, string]> = {
  pending_payment: ["بانتظار الدفع", "bg-warning-500/10 text-warning-700"],
  paid: ["بانتظار التسليم", "bg-brand-50 text-brand-700"],
  delivered: ["سُلِّم", "bg-success-50 text-success-700"],
  cancelled: ["ملغى", "bg-ink-100 text-ink-600"],
};
const TASK_STATUS: Record<string, string> = { pending: "لم تبدأ", in_progress: "قيد التنفيذ", completed: "أُنجزت", cancelled: "أُلغيت" };
type View = "open" | ProductOrderStatus | "all";
const VIEWS: Array<[View, string]> = [["open", "المفتوحة"], ["pending_payment", "بانتظار الدفع"], ["paid", "بانتظار التسليم"], ["delivered", "سُلِّمت"], ["cancelled", "ملغاة"], ["all", "الكل"]];

export default function ProductOrders() {
  const { branchId } = useBranch();
  const { can } = useAuth();
  const [view, setView] = useState<View>("open");
  const [days, setDays] = useState(7);
  const [rows, setRows] = useState<ProductOrder[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [paying, setPaying] = useState<ProductOrder | null>(null);
  const [cancelling, setCancelling] = useState<ProductOrder | null>(null);
  const [creating, setCreating] = useState(false);
  const [changed, setChanged] = useState(false);
  const reload = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    if (!branchId) return;
    let alive = true; setError(null);
    productsApi.orders(branchId, null, days).then((r) => { if (alive) setRows(r); }, (e) => { if (alive) setError(toArabicError(e)); });
    return () => { alive = false; };
  }, [branchId, days, tick]);
  // a guest's order from WhatsApp arrives while the page is open: it is looked for again every 30 seconds
  useEffect(() => {
    const t = setInterval(() => { if (typeof document === "undefined" || document.visibilityState === "visible") reload(); }, 30_000);
    return () => clearInterval(t);
  }, [reload]);

  const list = rows ?? [];
  const shown = list.filter((o) => view === "all" || (view === "open" ? o.status === "pending_payment" || o.status === "paid" : o.status === view));
  const count = (s: ProductOrderStatus) => list.filter((o) => o.status === s).length;
  const waitingPay = list.filter((o) => o.status === "pending_payment");

  return (
    <div>
      <SectionTitle title="طلبات المنتجات" subtitle="ما يطلبه النزيل المقيم من واتساب أو يطلبه له الاستقبال: الدفع لدى الاستقبال، ثم السند ومهمة التسليم معًا" action={
        <div className="flex min-w-0 flex-wrap items-center gap-2"><BranchPicker />
          {can("voucher.receipt") && <button type="button" className="btn-primary text-sm" onClick={() => setCreating(true)}><Plus className="h-4 w-4" /> طلب لنزيل</button>}
        </div>} />
      <Card className="mb-4">
        <AmountGrid testId="order-totals">
          <AmountBox label="بانتظار الدفع" value={<span data-testid="orders-waiting-pay">{count("pending_payment")}</span>} tone={count("pending_payment") ? "text-warning-700" : "text-ink-900"} />
          <AmountBox label="قيمة ما ينتظر الدفع" value={sar(waitingPay.reduce((s, o) => s + o.total_halalas, 0))} />
          <AmountBox label="بانتظار التسليم" value={count("paid")} tone={count("paid") ? "text-brand-700" : "text-ink-900"} />
          <AmountBox label="سُلِّمت في الفترة" value={count("delivered")} />
        </AmountGrid>
        <div className="mt-3 flex flex-wrap items-center gap-2 text-sm text-ink-600">
          <label htmlFor="orders-days">المسلَّمة والملغاة مما طُلب خلال</label>
          <select id="orders-days" className="input w-auto" value={days} onChange={(e) => setDays(Number(e.target.value))}>
            {[1, 7, 30, 90].map((d) => <option key={d} value={d}>{d === 1 ? "يوم واحد" : d <= 10 ? `${d} أيام` : `${d} يومًا`}</option>)}
          </select>
          <span className="text-xs text-ink-400">المفتوحة تظهر دائمًا مهما كان عمرها.</span>
        </div>
      </Card>
      {changed && <p className="mb-3 rounded-xl bg-warning-500/10 px-3 py-2 text-sm text-warning-700" role="alert" data-testid="order-changed">أُضيف إلى الطلب منتج أثناء الدفع ولم يُسجَّل شيء. راجع الإجمالي الجديد ثم تسلّم الدفع.</p>}
      <div className="mb-4 flex gap-1 overflow-x-auto rounded-2xl bg-ink-50 p-1" role="tablist" aria-label="عرض الطلبات">
        {VIEWS.map(([v, label]) => (
          <button key={v} type="button" role="tab" aria-selected={view === v} onClick={() => setView(v)}
            className={`min-h-[44px] shrink-0 rounded-xl px-3 text-sm font-semibold transition ${view === v ? "bg-white text-brand-700 shadow-sm" : "text-ink-500 hover:text-ink-700"}`}>{label}</button>
        ))}
      </div>
      {error ? <LoadErrorCard message={error} onRetry={reload} /> : rows == null ? <div className="py-10 text-center"><Spinner /></div> : shown.length === 0 ? (
        <EmptyState icon={<ShoppingBag className="h-10 w-10" />} title={view === "open" ? "لا طلبات مفتوحة" : "لا طلبات هنا"}
          description="يطلب النزيل المقيم من واتساب بإرسال «المنتجات»، أو يطلب له الاستقبال بزر «طلب لنزيل». المنتجات وإتاحتها لكل فرع من «المنتجات» في الإدارة." />
      ) : (
        <div className="grid gap-3 lg:grid-cols-2" data-testid="product-orders">
          {shown.map((o) => <OrderCard key={o.id} o={o} canCancelPaid={can("voucher.cancel")} onPay={() => { setChanged(false); setPaying(o); }} onCancel={() => setCancelling(o)} />)}
        </div>
      )}
      <Modal open={!!paying} title="تسلّم دفع الطلب" onClose={() => setPaying(null)}>
        {paying && branchId && <PayForm order={paying} branchId={branchId} onDone={() => { setPaying(null); reload(); }} onChanged={() => { setChanged(true); setPaying(null); reload(); }} onCancel={() => setPaying(null)} />}
      </Modal>
      <Modal open={!!cancelling} title="إلغاء الطلب" onClose={() => setCancelling(null)}>
        {cancelling && <CancelForm order={cancelling} onDone={() => { setCancelling(null); reload(); }} onCancel={() => setCancelling(null)} />}
      </Modal>
      <Modal open={creating} title="طلب منتجات لنزيل" onClose={() => setCreating(false)} wide>
        {creating && branchId && <CreateForm branchId={branchId} onDone={() => { setCreating(false); setView("open"); reload(); }} onCancel={() => setCreating(false)} />}
      </Modal>
    </div>
  );
}

function OrderCard({ o, canCancelPaid, onPay, onCancel }: { o: ProductOrder; canCancelPaid: boolean; onPay: () => void; onCancel: () => void }) {
  const [label, tone] = ORDER_STATUS[o.status];
  return (
    <Card className={o.status === "cancelled" ? "opacity-70" : ""} data-testid="product-order">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="font-semibold text-ink-800">غرفة {o.room_number ?? "—"}</h3>
            <Badge className={tone} testId="order-status">{label}</Badge>
            <Badge className="bg-ink-100 text-ink-600">{o.source === "whatsapp" ? <><MessageCircle className="ml-1 inline h-3 w-3" />واتساب</> : <><ConciergeBell className="ml-1 inline h-3 w-3" />الاستقبال</>}</Badge>
          </div>
          <p className="mt-1 text-xs text-ink-500">
            <span dir="ltr" className="font-mono">{o.number}</span> · {formatDateTime(o.created_at)}
            {o.internal_ref && <> · <Link className="text-brand-700 hover:underline" to={`/staff/reservations/${o.reservation_id}`}><span dir="ltr">{o.internal_ref}</span></Link></>}
          </p>
        </div>
        <div className="text-left">
          <span dir="ltr" className="text-lg font-bold tabular-nums text-ink-900" data-testid="order-total">{sar(o.total_halalas)}</span>
          <TaxNote order={o} />
        </div>
      </div>
      <ul className="mt-3 space-y-1 text-sm" data-testid="order-lines">
        {o.lines.map((l) => (
          <li key={l.product_id} className="flex items-baseline justify-between gap-2">
            <span className="min-w-0 text-ink-700"><span className="tabular-nums" dir="ltr">{l.quantity}</span> × {l.name}</span>
            <span dir="ltr" className="tabular-nums text-ink-500">{sar(l.total_halalas)}</span>
          </li>
        ))}
      </ul>
      <div className="mt-3 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-ink-500">
        {o.voucher_number && <span>سند القبض <span dir="ltr" className="font-mono">{o.voucher_number}</span></span>}
        {o.task_status && <span>مهمة التسليم: {TASK_STATUS[o.task_status] ?? o.task_status}</span>}
        {o.delivered_at && <span>سُلِّم {formatDateTime(o.delivered_at)}</span>}
        {o.status === "cancelled" && o.cancel_reason && <span className="text-danger-600">سبب الإلغاء: {o.cancel_reason}</span>}
      </div>
      {(o.status === "pending_payment" || (o.status === "paid" && canCancelPaid)) && (
        <div className="mt-3 flex flex-wrap gap-2">
          {o.status === "pending_payment" && <button type="button" className="btn-primary min-h-[44px] text-sm" onClick={onPay} data-testid="order-pay"><Wallet className="h-4 w-4" /> تسلّم الدفع</button>}
          <button type="button" className="btn-ghost min-h-[44px] text-sm text-danger-600" onClick={onCancel}><Ban className="h-4 w-4" /> إلغاء الطلب</button>
        </div>
      )}
      {o.status === "paid" && <p className="mt-2 text-xs text-ink-500">يصل الطلب بإنجاز مهمة التسليم في «خدمة الغرف».</p>}
    </Card>
  );
}

function PayForm({ order, branchId, onDone, onChanged, onCancel }: { order: ProductOrder; branchId: string; onDone: () => void; onChanged: () => void; onCancel: () => void }) {
  const { active: accounts } = useCashAccounts(branchId);
  const [method, setMethod] = useState<PaymentMethod>("cash");
  const [accountId, setAccountId] = useState("");
  const [ref, setRef] = useState("");
  const [key] = useState(newIdempotencyKey());
  // a number already on another voucher is a warning: the operator confirms it, the owner sees it (MONEY-03)
  const [dupWarn, setDupWarn] = useState<string | null>(null);
  useEffect(() => { setDupWarn(null); }, [ref, method]);
  return (
    <ActionForm onSubmit={async () => {
      if (METHOD_NEEDS_REFERENCE.includes(method) && !ref.trim()) throw new Error("VALIDATION: reference_required");
      try {
        await productsApi.pay({ order_id: order.id, method: method as "cash" | "pos" | "bank_transfer", account_id: METHOD_ACCOUNT_KIND[method] ? accountId || null : null,
          reference: ref.trim() || null, idempotency_key: key, expected_version: order.version, ...(dupWarn ? { duplicate_reference_ok: true } : {}) });
      } catch (e) {
        if (!dupWarn && /DUPLICATE_REFERENCE/.test((e as Error).message ?? "")) { setDupWarn(toArabicError(e)); return; }
        // an item was added while this dialog was open: the cashier sees the new total before taking the money
        if (/VERSION_CONFLICT/.test((e as Error).message ?? "")) { onChanged(); return; }
        throw e;
      }
      onDone();
    }}>
      <div className="mb-3 rounded-xl bg-ink-50 p-3 text-sm">
        <div className="flex items-baseline justify-between gap-2"><span>الطلب <span dir="ltr" className="font-mono">{order.number}</span> — غرفة {order.room_number ?? "—"}</span>
          <span dir="ltr" className="font-bold tabular-nums">{sar(order.total_halalas)}</span></div>
        <TaxNote order={order} />
        <ul className="mt-2 space-y-0.5 text-xs text-ink-600">{order.lines.map((l) => <li key={l.product_id}><span dir="ltr">{l.quantity}</span> × {l.name}</li>)}</ul>
      </div>
      <p className="mb-3 text-xs text-ink-500">يُضاف الطلب إلى حساب الإقامة ويُسدَّد بسند قبض بالمبلغ نفسه، فلا يتغير المتبقي على الإقامة، وتُنشأ مهمة التسليم للغرفة.</p>
      <div className="space-y-3">
        <PaymentFields method={method} setMethod={setMethod} accountId={accountId} setAccountId={setAccountId} reference={ref} setReference={setRef} accounts={accounts} verb="receive" atProperty />
        {dupWarn && <p className="rounded-xl bg-warning-500/10 px-3 py-2 text-sm text-warning-700" data-testid="duplicate-reference">{dupWarn} يظهر هذا للمالك في «المراجعة».</p>}
      </div>
      <Submit label={dupWarn ? "تأكيد التسجيل رغم التكرار" : `تسلّم ${sar(order.total_halalas)} وإنشاء مهمة التسليم`} onCancel={onCancel} />
    </ActionForm>
  );
}

function CancelForm({ order, onDone, onCancel }: { order: ProductOrder; onDone: () => void; onCancel: () => void }) {
  const [reason, setReason] = useState("");
  return (
    <ActionForm onSubmit={async () => { if (!reason.trim()) throw new Error("VALIDATION: reason"); await productsApi.cancel(order.id, reason.trim()); onDone(); }}>
      <p className="mb-3 text-sm text-ink-600">
        {order.status === "paid"
          ? <>يُلغى سند القبض <span dir="ltr" className="font-mono">{order.voucher_number}</span> (يُعاد المبلغ للنزيل)، ويُوازن حساب الإقامة، وتُلغى مهمة التسليم. يصل الإلغاء للمراجعة.</>
          : <>يُلغى الطلب <span dir="ltr" className="font-mono">{order.number}</span> ولا يمس حساب الإقامة.</>}
      </p>
      <ReasonInput value={reason} onChange={setReason} />
      <Submit label="إلغاء الطلب" danger onCancel={onCancel} cancelLabel="رجوع" />
    </ActionForm>
  );
}

const taxPct = (bp: number) => `${(bp / 100).toFixed(2).replace(/\.?0+$/, "")}%`;
/** How much of an order's total is value-added tax (0069); nothing when it carries none. */
function TaxNote({ order }: { order: ProductOrder }) {
  if (!order.tax_halalas) return null;
  return <p className="text-xs text-ink-500" data-testid="order-tax">{order.tax_included ? "شامل ضريبة" : "منها ضريبة"} <span dir="ltr" className="tabular-nums">{sar(order.tax_halalas)}</span></p>;
}

function CreateForm({ branchId, onDone, onCancel }: { branchId: string; onDone: () => void; onCancel: () => void }) {
  const [menu, setMenu] = useState<ProductMenu | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [stay, setStay] = useState("");
  const [qty, setQty] = useState<Record<string, number>>({});
  useEffect(() => {
    let alive = true;
    productsApi.menu(branchId).then((m) => { if (alive) { setMenu(m); setStay(m.stays[0]?.id ?? ""); } }, (e) => { if (alive) setErr(toArabicError(e)); });
    return () => { alive = false; };
  }, [branchId]);
  const prices = useMemo(() => new Map((menu?.categories ?? []).flatMap((c) => c.products.map((p) => [p.id, p.price_halalas] as const))), [menu]);
  const items = Object.entries(qty).filter(([, n]) => n > 0).map(([product_id, quantity]) => ({ product_id, quantity }));
  const subtotal = items.reduce((s, i) => s + (prices.get(i.product_id) ?? 0) * i.quantity, 0);
  // 0069: the products' tax of the policy the chosen stay was made under
  const tax = menu?.stays.find((x) => x.id === stay);
  const step = (id: string, d: number) => setQty((q) => ({ ...q, [id]: Math.max(0, Math.min(50, (q[id] ?? 0) + d)) }));

  if (err) return <LoadErrorCard message={err} />;
  if (!menu) return <div className="py-8 text-center"><Spinner /></div>;
  if (menu.stays.length === 0) return <EmptyState icon={<ShoppingBag className="h-10 w-10" />} title="لا نزلاء مقيمون الآن" description="الطلب للنزيل المقيم في وحدته بعد تسجيل وصوله." />;
  if (menu.categories.length === 0) return <EmptyState icon={<ShoppingBag className="h-10 w-10" />} title="لا منتجات متاحة في هذا الفرع" description="يضيف المالك المنتجات ويتيحها للفرع من «المنتجات» في الإدارة." />;
  return (
    <ActionForm onSubmit={async () => { if (!stay) throw new Error("VALIDATION: not_in_stay"); if (!items.length) throw new Error("VALIDATION: items"); await productsApi.create(stay, items); onDone(); }}>
      <Field label="النزيل">
        <select className="input" value={stay} onChange={(e) => setStay(e.target.value)} aria-label="النزيل">
          {menu.stays.map((s) => <option key={s.id} value={s.id}>غرفة {s.room_number} — {s.internal_ref}</option>)}
        </select>
      </Field>
      <div className="mt-3 space-y-4" data-testid="order-menu">
        {menu.categories.map((c) => (
          <section key={c.id} aria-label={c.name}>
            <h4 className="mb-1 text-sm font-semibold text-ink-700">{c.name}</h4>
            <ul className="divide-y divide-ink-50 rounded-xl border border-ink-100">
              {c.products.map((p) => (
                <li key={p.id} className="flex items-center justify-between gap-2 px-3 py-2">
                  <div className="min-w-0">
                    <p className="text-sm text-ink-800">{p.name}</p>
                    <p className="text-xs text-ink-500"><span dir="ltr">{sar(p.price_halalas)}</span>{p.description ? ` · ${p.description}` : ""}</p>
                  </div>
                  <div className="flex shrink-0 items-center gap-1">
                    <button type="button" className="btn-ghost min-h-[44px] min-w-[44px] justify-center p-0" onClick={() => step(p.id, -1)} disabled={!qty[p.id]} aria-label={`إنقاص ${p.name}`}><Minus className="h-4 w-4" /></button>
                    <span className="w-6 text-center tabular-nums" aria-live="polite" data-testid={`qty-${p.name}`}>{qty[p.id] ?? 0}</span>
                    <button type="button" className="btn-ghost min-h-[44px] min-w-[44px] justify-center p-0" onClick={() => step(p.id, 1)} aria-label={`زيادة ${p.name}`}><Plus className="h-4 w-4" /></button>
                  </div>
                </li>
              ))}
            </ul>
          </section>
        ))}
      </div>
      <p className="mt-3 text-sm text-ink-700">المجموع بأسعار المنتجات: <span dir="ltr" className="font-semibold tabular-nums" data-testid="order-subtotal">{sar(subtotal)}</span>{" "}
        <span className="text-xs text-ink-400" data-testid="order-tax-rule">{!tax?.tax_rate_bp ? "— بلا ضريبة على منتجات هذه الإقامة." : tax.tax_included ? `— شامل ضريبة القيمة المضافة ${taxPct(tax.tax_rate_bp)} للخاضع منها.` : `— وتُضاف ضريبة القيمة المضافة ${taxPct(tax.tax_rate_bp)} على الخاضع منها عند الإنشاء.`}</span></p>
      <Submit label="إنشاء الطلب" onCancel={onCancel} />
    </ActionForm>
  );
}
