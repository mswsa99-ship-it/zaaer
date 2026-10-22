/**
 * Stay management + financial ledger for one reservation (Zaaer core):
 * charges · receipts/deposits · refunds · invoices · extend/shorten · switch room · cancel / no-show · allocation history.
 * Every button explains its effect before executing; nothing here writes to tables directly.
 */
import { useCallback, useEffect, useState } from "react";
import { Wallet, Receipt, Undo2, FileText, CalendarRange, ArrowLeftRight, Ban, UserX, History, Plus, ShieldAlert } from "lucide-react";
import { opsApi, toArabicError, newIdempotencyKey, type ReservationDetail, type Finance } from "../lib/api";
import { useAuth } from "../lib/auth";
import { supabase } from "../lib/supabase";
import { Card, Badge, ErrorBanner, Spinner } from "./ui";
import { Modal, Field, ActionForm, Submit, MoneyInput, ReasonInput } from "./forms";
import { PAYMENT_METHOD_LABELS, VOUCHER_KIND_LABELS, CHARGE_KIND_LABELS, CLEANLINESS_LABELS, type PaymentMethod, type VoucherKind, type ChargeKind } from "../lib/types";
import { formatCurrency, formatDateTime } from "../lib/utils";

const sar = (h: number | undefined | null) => formatCurrency((h ?? 0) / 100);
type Dialog = null | "receipt" | "deposit" | "refund" | "deposit_refund" | "deposit_apply" | "adjust" | "service" | "extend" | "switch" | "cancel" | "no_show" | "invoice";

export function ReservationOperations({ reservationId, onChanged }: { reservationId: string; onChanged: () => void }) {
  const { profile } = useAuth();
  const role = profile?.role ?? "guest";
  const canMoney = ["owner", "manager", "supervisor", "finance"].includes(role);
  const canRefund = ["owner", "manager", "finance"].includes(role);
  const canManage = ["owner", "manager", "supervisor"].includes(role);
  const isMgr = ["owner", "manager"].includes(role);

  const [d, setD] = useState<ReservationDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [dialog, setDialog] = useState<Dialog>(null);
  const [tab, setTab] = useState<"ledger" | "stay" | "history">("ledger");

  const load = useCallback(async () => { try { setD(await opsApi.detail(reservationId)); setError(null); } catch (e) { setError(toArabicError(e)); } }, [reservationId]);
  useEffect(() => { load(); }, [load]);
  useEffect(() => {
    const ch = supabase.channel(`ops-${reservationId}`).on("postgres_changes", { event: "*", schema: "public", table: "financial_vouchers", filter: `reservation_id=eq.${reservationId}` }, () => load()).subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [reservationId, load]);

  if (!d) return error ? <ErrorBanner message={error} /> : <div className="py-6 text-center"><Spinner /></div>;
  const r = d.reservation; const f = d.finance ?? ({ rent: 0, addons: 0, discounts: 0, penalties: 0, adjustments: 0, tax: 0, total: 0, received: 0, refunded: 0, deposit_applied: 0, net_collected: 0, balance_due: 0, credit: 0, deposit_received: 0, deposit_refunded: 0, deposit_balance: 0, payment_status: "pending" } as Finance);
  const open = !["cancelled", "rejected", "closed", "no_show"].includes(r.status);
  const done = async () => { setDialog(null); await load(); onChanged(); };

  return (
    <div className="space-y-4">
      <Card>
        <div className="mb-3 flex items-center justify-between">
          <h2 className="flex items-center gap-2 text-base font-semibold text-ink-800"><Wallet className="h-5 w-5 text-brand-600" /> الملخص المالي</h2>
          <div className="flex gap-1 rounded-xl bg-ink-50 p-1 text-xs">
            {(["ledger", "stay", "history"] as const).map((t) => <button key={t} onClick={() => setTab(t)} className={`rounded-lg px-3 py-1.5 ${tab === t ? "bg-white font-medium text-ink-800 shadow-sm" : "text-ink-500"}`}>{t === "ledger" ? "الدفتر" : t === "stay" ? "الإقامة" : "السجل"}</button>)}
          </div>
        </div>
        {canMoney && f ? <FinanceGrid f={f} /> : <p className="text-xs text-ink-400">البيانات المالية متاحة لأدوار الاستقبال والمالية والإدارة فقط.</p>}
        {tab === "ledger" && canMoney && (
          <div className="mt-4 flex flex-wrap gap-2 border-t border-ink-50 pt-3">
            {open && <button onClick={() => setDialog("receipt")} className="btn-accent text-xs"><Receipt className="h-3.5 w-3.5" /> سند قبض إقامة</button>}
            {open && <button onClick={() => setDialog("deposit")} className="btn-outline text-xs"><Receipt className="h-3.5 w-3.5" /> قبض تأمين</button>}
            {canRefund && f.received - f.refunded > 0 && <button onClick={() => setDialog("refund")} className="btn-outline text-xs"><Undo2 className="h-3.5 w-3.5" /> استرداد إقامة</button>}
            {canRefund && f.deposit_balance > 0 && <button onClick={() => setDialog("deposit_refund")} className="btn-outline text-xs"><Undo2 className="h-3.5 w-3.5" /> رد تأمين</button>}
            {canRefund && f.deposit_balance > 0 && f.balance_due > 0 && <button onClick={() => setDialog("deposit_apply")} className="btn-outline text-xs"><ArrowLeftRight className="h-3.5 w-3.5" /> تغطية رسوم من التأمين</button>}
            {canManage && open && <button onClick={() => setDialog("service")} className="btn-outline text-xs"><Plus className="h-3.5 w-3.5" /> إضافة خدمة</button>}
            {canManage && open && <button onClick={() => setDialog("adjust")} className="btn-outline text-xs"><Plus className="h-3.5 w-3.5" /> خصم / تسوية / غرامة</button>}
            {(d.charges ?? []).some((c) => !c.invoice_id) && <button onClick={() => setDialog("invoice")} className="btn-outline text-xs"><FileText className="h-3.5 w-3.5" /> إصدار فاتورة</button>}
          </div>
        )}
        {tab === "stay" && canManage && (
          <div className="mt-4 flex flex-wrap gap-2 border-t border-ink-50 pt-3">
            {["confirmed", "checked_in", "pending_verification"].includes(r.status) && <button onClick={() => setDialog("extend")} className="btn-outline text-xs"><CalendarRange className="h-3.5 w-3.5" /> تغيير المغادرة / تمديد</button>}
            {["confirmed", "checked_in", "pending_verification"].includes(r.status) && <button onClick={() => setDialog("switch")} className="btn-outline text-xs"><ArrowLeftRight className="h-3.5 w-3.5" /> تبديل الوحدة</button>}
            {["confirmed", "pending_verification", "draft"].includes(r.status) && <button onClick={() => setDialog("cancel")} className="btn-ghost text-xs text-danger-600"><Ban className="h-3.5 w-3.5" /> إلغاء الحجز</button>}
            {["confirmed", "pending_verification"].includes(r.status) && r.check_in <= new Date().toISOString().slice(0, 10) && <button onClick={() => setDialog("no_show")} className="btn-ghost text-xs text-danger-600"><UserX className="h-3.5 w-3.5" /> عدم حضور</button>}
          </div>
        )}
      </Card>

      {tab === "ledger" && (
        <div className="grid gap-4 lg:grid-cols-2">
          <Card>
            <h3 className="mb-2 text-sm font-semibold text-ink-700">الرسوم</h3>
            <Table rows={(d.charges ?? []).map((c) => [<span key="k" className="text-xs text-ink-400">{CHARGE_KIND_LABELS[c.kind as ChargeKind] ?? c.kind}</span>, c.description, <span key="v" dir="ltr" className={c.total_halalas < 0 ? "text-success-600" : ""}>{sar(c.total_halalas)}</span>, c.invoice_id ? <Badge key="i" className="bg-ink-100 text-ink-500">مفوتر</Badge> : ""])} empty="لا رسوم" />
          </Card>
          <Card>
            <h3 className="mb-2 text-sm font-semibold text-ink-700">السندات</h3>
            <Table rows={(d.vouchers ?? []).map((v) => [<span key="n" className="font-mono text-xs">{v.number}</span>, <span key="k">{VOUCHER_KIND_LABELS[v.kind as VoucherKind] ?? v.kind}<div className="text-[10px] text-ink-400">{PAYMENT_METHOD_LABELS[v.method as PaymentMethod] ?? v.method}{v.reference ? ` · ${v.reference}` : ""} · {formatDateTime(v.occurred_at)}</div></span>, <span key="v" dir="ltr" className={v.status === "cancelled" ? "line-through text-ink-400" : ""}>{sar(v.amount_halalas)}</span>,
              v.status === "cancelled" ? <Badge key="s" className="bg-danger-500/10 text-danger-600" >ملغى</Badge> : isMgr ? <CancelVoucherButton key="c" id={v.id} onDone={done} /> : ""])} empty="لا سندات" />
          </Card>
          {(d.invoices ?? []).length > 0 && (
            <Card className="lg:col-span-2">
              <h3 className="mb-2 text-sm font-semibold text-ink-700">الفواتير</h3>
              <Table rows={(d.invoices ?? []).map((i) => [<span key="n" className="font-mono text-xs">{i.number}</span>, `${i.period_from} → ${i.period_to}`, <span key="v" dir="ltr">{sar(i.total_halalas)}</span>, i.status === "cancelled" ? <Badge key="s" className="bg-danger-500/10 text-danger-600">ملغاة</Badge> : <Badge key="s" className="bg-success-500/10 text-success-600">صادرة</Badge>])} empty="" />
            </Card>
          )}
        </div>
      )}

      {tab === "stay" && (
        <Card>
          <h3 className="mb-2 text-sm font-semibold text-ink-700">سجل التخصيص (الوحدات والفترات)</h3>
          <Table rows={d.allocations.map((a) => [<span key="r" className="font-medium">{a.room_number}</span>, <span key="d" dir="ltr">{a.from_date} → {a.to_date}</span>, a.status === "active" ? <Badge key="s" className="bg-success-500/10 text-success-600">نشط</Badge> : a.status === "closed" ? <Badge key="s" className="bg-ink-100 text-ink-500">مغلق</Badge> : <Badge key="s" className="bg-danger-500/10 text-danger-600">ملغى</Badge>, <span key="x" className="text-xs text-ink-400">{a.reason ?? ""}</span>])} empty="لم تُخصص وحدة بعد" />
          <p className="mt-3 text-xs text-ink-400">سعر الليلة المتفق عليه: {sar(r.nightly_rate_halalas)} · الوحدة الحالية: {d.room ? `${d.room.room_number} (${CLEANLINESS_LABELS[d.room.cleanliness]})` : "—"}</p>
        </Card>
      )}

      {tab === "history" && (
        <Card>
          <h3 className="mb-2 flex items-center gap-2 text-sm font-semibold text-ink-700"><History className="h-4 w-4" /> سجل التعديلات</h3>
          <div className="space-y-2">
            {d.history.map((h, i) => (
              <div key={i} className="rounded-lg border border-ink-50 px-3 py-2 text-xs">
                <div className="flex justify-between"><span className="font-medium text-ink-700">{ACTION_LABELS[h.action] ?? h.action}</span><span className="text-ink-400">{h.actor ?? "النظام"} · {formatDateTime(h.at)}</span></div>
                {h.details?.reason ? <p className="mt-0.5 text-ink-500">السبب: {String(h.details.reason)}</p> : null}
                {h.details?.before && h.details?.after ? <p className="mt-0.5 text-ink-400" dir="ltr">{JSON.stringify(h.details.before)} → {JSON.stringify(h.details.after)}</p> : null}
              </div>
            ))}
            {d.history.length === 0 && <p className="text-xs text-ink-400">لا أحداث.</p>}
          </div>
        </Card>
      )}

      {/* ---------- dialogs ---------- */}
      <VoucherDialog open={dialog === "receipt" || dialog === "deposit"} kind={dialog === "deposit" ? "deposit" : "receipt"} reservationId={reservationId} suggested={dialog === "deposit" ? 0 : f.balance_due} onClose={() => setDialog(null)} onDone={done} />
      <RefundDialog open={dialog === "refund" || dialog === "deposit_refund" || dialog === "deposit_apply"} kind={(dialog as "refund" | "deposit_refund" | "deposit_apply") ?? "refund"} reservationId={reservationId} available={dialog === "refund" ? f.received - f.refunded : dialog === "deposit_apply" ? Math.min(f.deposit_balance, f.balance_due) : f.deposit_balance} onClose={() => setDialog(null)} onDone={done} />
      <AdjustDialog open={dialog === "adjust"} reservationId={reservationId} version={r.version} isMgr={isMgr} onClose={() => setDialog(null)} onDone={done} />
      <ServiceDialog open={dialog === "service"} reservationId={reservationId} branchId={r.branch_id} onClose={() => setDialog(null)} onDone={done} />
      <ExtendDialog open={dialog === "extend"} d={d} onClose={() => setDialog(null)} onDone={done} />
      <SwitchDialog open={dialog === "switch"} d={d} onClose={() => setDialog(null)} onDone={done} />
      <ReasonDialog open={dialog === "cancel"} title="إلغاء الحجز" warning={`الإلغاء يحرر الوحدة ولا يسترد أي مبلغ تلقائيًا${f.net_collected + f.deposit_balance > 0 ? ` — يوجد ${sar(f.net_collected)} محصّل و${sar(f.deposit_balance)} تأمين تحتاج قرار استرداد مستقل` : ""}.`} onClose={() => setDialog(null)} onSubmit={async (reason) => { await opsApi.cancelReservation(reservationId, reason); await done(); }} />
      <ReasonDialog open={dialog === "no_show"} title="تسجيل عدم حضور" warning="عدم الحضور حالة مستقلة عن الإلغاء، يحرر الوحدة ولا يغير المال." onClose={() => setDialog(null)} onSubmit={async (reason) => { await opsApi.noShow(reservationId, reason); await done(); }} />
      <Modal open={dialog === "invoice"} title="إصدار فاتورة" onClose={() => setDialog(null)}>
        <ActionForm onSubmit={async () => { await opsApi.createInvoice(reservationId); await done(); }}>
          <p className="text-sm text-ink-600">تُصدر فاتورة بالبنود غير المفوترة ({(d.charges ?? []).filter((c) => !c.invoice_id).length} بند) كلقطة ثابتة لا تتأثر بتعديل الكتالوج لاحقًا. الفاتورة ليست إثبات قبض.</p>
          <Submit label="إصدار" onCancel={() => setDialog(null)} />
        </ActionForm>
      </Modal>
    </div>
  );
}

function FinanceGrid({ f }: { f: Finance }) {
  const cell = (l: string, v: number, cls = "text-ink-800") => <div><p className="text-[11px] text-ink-400">{l}</p><p className={`font-medium ${cls}`} dir="ltr">{sar(v)}</p></div>;
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-4 lg:grid-cols-8">
      {cell("الإجمالي", f.total)}{cell("المحصل", f.net_collected, "text-success-600")}{cell("المتبقي", f.balance_due, f.balance_due > 0 ? "text-warning-600" : "text-success-600")}{cell("رصيد للضيف", f.credit, "text-brand-700")}
      {cell("تأمين مقبوض", f.deposit_received)}{cell("تأمين مسترد", f.deposit_refunded)}{cell("رصيد التأمين", f.deposit_balance, "text-brand-700")}{cell("الضريبة", f.tax, "text-ink-500")}
    </div>
  );
}

function Table({ rows, empty }: { rows: Array<Array<React.ReactNode>>; empty: string }) {
  if (rows.length === 0) return <p className="text-xs text-ink-400">{empty}</p>;
  return <div className="divide-y divide-ink-50 text-sm">{rows.map((r, i) => <div key={i} className="grid grid-cols-[auto_1fr_auto_auto] items-center gap-3 py-2">{r.map((c, j) => <div key={j} className={j === 1 ? "min-w-0 text-ink-700" : ""}>{c}</div>)}</div>)}</div>;
}

function CancelVoucherButton({ id, onDone }: { id: string; onDone: () => Promise<void> }) {
  const [open, setOpen] = useState(false);
  return (<>
    <button onClick={() => setOpen(true)} className="btn-ghost px-2 py-1 text-[11px] text-danger-600">إلغاء السند</button>
    <ReasonDialog open={open} title="إلغاء سند" warning="الإلغاء يعكس أثر السند محاسبيًا ويبقي سجله. لا يعني أن مزود الدفع ردّ المبلغ للضيف." onClose={() => setOpen(false)} onSubmit={async (reason) => { await opsApi.cancelVoucher(id, reason); setOpen(false); await onDone(); }} />
  </>);
}

function ReasonDialog({ open, title, warning, onClose, onSubmit }: { open: boolean; title: string; warning: string; onClose: () => void; onSubmit: (reason: string) => Promise<void> }) {
  const [reason, setReason] = useState("");
  return (
    <Modal open={open} title={title} onClose={onClose}>
      <ActionForm onSubmit={async () => { if (!reason.trim()) throw new Error("VALIDATION: reason"); await onSubmit(reason.trim()); setReason(""); }}>
        <div className="mb-3 flex items-start gap-2 rounded-xl bg-warning-500/10 p-3 text-xs text-warning-600"><ShieldAlert className="mt-0.5 h-4 w-4 shrink-0" />{warning}</div>
        <ReasonInput value={reason} onChange={setReason} />
        <Submit label="تأكيد" onCancel={onClose} danger />
      </ActionForm>
    </Modal>
  );
}

const METHODS: PaymentMethod[] = ["cash", "mada", "card", "bank_transfer", "pos", "payment_link", "booking_platform", "ota_deferred"];

function VoucherDialog({ open, kind, reservationId, suggested, onClose, onDone }: { open: boolean; kind: "receipt" | "deposit"; reservationId: string; suggested: number; onClose: () => void; onDone: () => Promise<void> }) {
  const [amount, setAmount] = useState<number | null>(suggested || null); const [method, setMethod] = useState<PaymentMethod>("cash"); const [ref, setRef] = useState(""); const [note, setNote] = useState("");
  const [key, setKey] = useState(newIdempotencyKey());
  useEffect(() => { if (open) { setAmount(suggested || null); setKey(newIdempotencyKey()); setRef(""); setNote(""); } }, [open, suggested]);
  return (
    <Modal open={open} title={kind === "receipt" ? "سند قبض إقامة" : "سند قبض تأمين"} onClose={onClose}>
      <ActionForm onSubmit={async () => {
        if (!amount || amount <= 0) throw new Error("VALIDATION: amount");
        if (method !== "cash" && !ref.trim()) throw new Error("VALIDATION: reference_required");
        await opsApi.createVoucher({ reservation_id: reservationId, kind, amount_halalas: amount, method, reference: ref.trim() || undefined, note: note || undefined, idempotency_key: key });
        await onDone();
      }}>
        <p className="mb-3 text-xs text-ink-500">{kind === "receipt" ? "يُخصم من المتبقي على الإقامة." : "يُحتجز في دفتر التأمين المنفصل ولا يسدد الإقامة."}</p>
        <div className="space-y-3">
          <Field label="المبلغ"><MoneyInput valueHalalas={amount} onChange={setAmount} /></Field>
          <Field label="طريقة الدفع"><select className="input" value={method} onChange={(e) => setMethod(e.target.value as PaymentMethod)}>{METHODS.map((m) => <option key={m} value={m}>{PAYMENT_METHOD_LABELS[m]}</option>)}</select></Field>
          <Field label={`رقم العملية / المرجع${method !== "cash" ? " (إلزامي)" : ""}`}><input className="input" dir="ltr" value={ref} onChange={(e) => setRef(e.target.value)} /></Field>
          <Field label="ملاحظة"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>
        </div>
        <Submit label="حفظ السند" onCancel={onClose} />
      </ActionForm>
    </Modal>
  );
}

function RefundDialog({ open, kind, reservationId, available, onClose, onDone }: { open: boolean; kind: "refund" | "deposit_refund" | "deposit_apply"; reservationId: string; available: number; onClose: () => void; onDone: () => Promise<void> }) {
  const [amount, setAmount] = useState<number | null>(null); const [method, setMethod] = useState<PaymentMethod>("cash"); const [ref, setRef] = useState(""); const [reason, setReason] = useState("");
  const [key, setKey] = useState(newIdempotencyKey());
  useEffect(() => { if (open) { setAmount(available); setKey(newIdempotencyKey()); setReason(""); } }, [open, available]);
  const titles = { refund: "استرداد من مقبوض الإقامة", deposit_refund: "رد تأمين", deposit_apply: "استخدام التأمين لتغطية رسوم" };
  return (
    <Modal open={open} title={titles[kind]} onClose={onClose}>
      <ActionForm onSubmit={async () => {
        if (!amount || amount <= 0) throw new Error("VALIDATION: amount");
        await opsApi.refund({ reservation_id: reservationId, kind, amount_halalas: amount, method, reference: ref || undefined, reason: reason.trim(), idempotency_key: key });
        await onDone();
      }}>
        <p className="mb-3 text-xs text-ink-500">المتاح: <span dir="ltr">{sar(available)}</span>. يمنع الخادم أي رد يتجاوزه حتى مع طلبين متزامنين.</p>
        <div className="space-y-3">
          <Field label="المبلغ"><MoneyInput valueHalalas={amount} onChange={setAmount} /></Field>
          {kind !== "deposit_apply" && <Field label="طريقة الرد"><select className="input" value={method} onChange={(e) => setMethod(e.target.value as PaymentMethod)}>{METHODS.map((m) => <option key={m} value={m}>{PAYMENT_METHOD_LABELS[m]}</option>)}</select></Field>}
          {kind !== "deposit_apply" && <Field label="مرجع العملية"><input className="input" dir="ltr" value={ref} onChange={(e) => setRef(e.target.value)} /></Field>}
          <ReasonInput value={reason} onChange={setReason} />
        </div>
        <Submit label="تنفيذ" onCancel={onClose} />
      </ActionForm>
    </Modal>
  );
}

function AdjustDialog({ open, reservationId, version, isMgr, onClose, onDone }: { open: boolean; reservationId: string; version: number; isMgr: boolean; onClose: () => void; onDone: () => Promise<void> }) {
  const [kind, setKind] = useState<"discount" | "adjustment" | "penalty" | "addon">(isMgr ? "discount" : "addon"); const [amount, setAmount] = useState<number | null>(null); const [desc, setDesc] = useState(""); const [reason, setReason] = useState("");
  return (
    <Modal open={open} title="تعديل إجمالي الحجز" onClose={onClose}>
      <ActionForm onSubmit={async () => { if (!amount) throw new Error("VALIDATION: amount"); await opsApi.adjustPrice(reservationId, kind, amount, desc, reason.trim(), version); await onDone(); }}>
        <div className="space-y-3">
          <Field label="النوع"><select className="input" value={kind} onChange={(e) => setKind(e.target.value as typeof kind)}>
            {isMgr && <option value="discount">خصم (يخفض الإجمالي)</option>}{isMgr && <option value="adjustment">تسوية (موجبة أو سالبة)</option>}<option value="penalty">غرامة</option><option value="addon">إضافة</option>
          </select></Field>
          <Field label="المبلغ" hint={kind === "adjustment" ? "استخدم قيمة سالبة للتخفيض" : undefined}><MoneyInput valueHalalas={amount} onChange={setAmount} min={kind === "adjustment" ? -100000000 : 0} /></Field>
          <Field label="الوصف"><input className="input" value={desc} onChange={(e) => setDesc(e.target.value)} /></Field>
          <ReasonInput value={reason} onChange={setReason} />
        </div>
        <p className="mt-2 text-xs text-ink-400">لا يُعدَّل أي سند سبق تحصيله؛ يُضاف بند جديد مع سبب ويُعاد حساب الإجمالي.</p>
        <Submit label="حفظ" onCancel={onClose} />
      </ActionForm>
    </Modal>
  );
}

function ServiceDialog({ open, reservationId, branchId, onClose, onDone }: { open: boolean; reservationId: string; branchId: string; onClose: () => void; onDone: () => Promise<void> }) {
  const [services, setServices] = useState<Array<{ id: string; name_ar: string; price_halalas: number; is_free: boolean; billing_unit: string }>>([]);
  const [svc, setSvc] = useState(""); const [qty, setQty] = useState(1);
  useEffect(() => { if (!open) return; supabase.from("service_definitions").select("id, name_ar, price_halalas, is_free, billing_unit").eq("branch_id", branchId).eq("is_active", true).is("archived_at", null).order("name_ar").then(({ data }) => { setServices((data as typeof services) ?? []); setSvc((data?.[0] as { id: string } | undefined)?.id ?? ""); }); }, [open, branchId]);
  const s = services.find((x) => x.id === svc);
  return (
    <Modal open={open} title="إضافة خدمة" onClose={onClose}>
      <ActionForm onSubmit={async () => { if (!svc) throw new Error("SERVICE_NOT_AVAILABLE"); await opsApi.addService(reservationId, svc, qty); await onDone(); }}>
        {services.length === 0 ? <p className="text-sm text-ink-500">لا توجد خدمات معرّفة لهذا الفرع. أضفها من إدارة الخدمات.</p> : (
          <div className="space-y-3">
            <Field label="الخدمة"><select className="input" value={svc} onChange={(e) => setSvc(e.target.value)}>{services.map((x) => <option key={x.id} value={x.id}>{x.name_ar} — {x.is_free ? "مجانية" : sar(x.price_halalas)}</option>)}</select></Field>
            {s?.billing_unit === "quantity" && <Field label="الكمية"><input type="number" min={1} className="input" dir="ltr" value={qty} onChange={(e) => setQty(Number(e.target.value))} /></Field>}
            <p className="text-xs text-ink-400">يُحفظ الاسم والسعر والضريبة لحظة الإضافة.</p>
          </div>
        )}
        <Submit label="إضافة" onCancel={onClose} />
      </ActionForm>
    </Modal>
  );
}

function ExtendDialog({ open, d, onClose, onDone }: { open: boolean; d: ReservationDetail; onClose: () => void; onDone: () => Promise<void> }) {
  const r = d.reservation;
  const [date, setDate] = useState(r.check_out); const [mode, setMode] = useState<"keep_rate" | "reprice">("keep_rate"); const [reason, setReason] = useState("");
  useEffect(() => { if (open) setDate(r.check_out); }, [open, r.check_out]);
  const delta = Math.round((new Date(date).getTime() - new Date(r.check_out).getTime()) / 86400000);
  return (
    <Modal open={open} title="تغيير تاريخ المغادرة" onClose={onClose}>
      <ActionForm onSubmit={async () => { await opsApi.amendStay(r.id, date, mode, reason.trim(), r.version); await onDone(); }}>
        <div className="space-y-3">
          <div className="grid grid-cols-2 gap-3 text-sm"><div><p className="text-xs text-ink-400">المغادرة الحالية</p><p dir="ltr">{r.check_out}</p></div><Field label="المغادرة الجديدة"><input type="date" className="input" dir="ltr" min={r.check_in} value={date} onChange={(e) => setDate(e.target.value)} /></Field></div>
          <Field label="التسعير"><select className="input" value={mode} onChange={(e) => setMode(e.target.value as typeof mode)}><option value="keep_rate">الإبقاء على سعر الليلة المتفق عليه ({sar(r.nightly_rate_halalas)})</option><option value="reprice">إعادة التسعير بالسعر الأساسي الحالي</option></select></Field>
          <ReasonInput value={reason} onChange={setReason} />
          <div className="rounded-xl bg-ink-50 p-3 text-xs text-ink-600">{delta > 0 ? `تمديد ${delta} ليلة: يُفحص تعارض الوحدة في الفترة المضافة أولًا، ثم يُضاف بند إيجار جديد ويُعاد حساب الإجمالي.` : delta < 0 ? `تقصير ${-delta} ليلة: تُضاف تسوية سالبة بقيمة الليالي المحذوفة.` : "لا تغيير."}</div>
        </div>
        <Submit label="تطبيق" onCancel={onClose} />
      </ActionForm>
    </Modal>
  );
}

function SwitchDialog({ open, d, onClose, onDone }: { open: boolean; d: ReservationDetail; onClose: () => void; onDone: () => Promise<void> }) {
  const r = d.reservation;
  const today = new Date().toISOString().slice(0, 10);
  const [effective, setEffective] = useState(today > r.check_in ? today : r.check_in); const [room, setRoom] = useState(""); const [reason, setReason] = useState("");
  const [rooms, setRooms] = useState<Array<{ room_id: string; room_number: string; category_name: string; cleanliness: string; status: string }>>([]);
  useEffect(() => { if (!open) return; opsApi.availableRooms(r.branch_id, effective, r.check_out, null, r.id).then((x) => setRooms(x.filter((y) => y.room_id !== r.room_id))).catch(() => setRooms([])); }, [open, effective, r.branch_id, r.check_out, r.id, r.room_id]);
  return (
    <Modal open={open} title="تبديل الوحدة" onClose={onClose}>
      <ActionForm onSubmit={async () => { if (!room) throw new Error("ROOM_NOT_FOUND"); await opsApi.switchRoom(r.id, room, effective, reason.trim(), r.version); await onDone(); }}>
        <div className="space-y-3">
          <p className="text-sm text-ink-600">الوحدة الحالية: <b>{d.room?.room_number ?? "—"}</b></p>
          <Field label="تاريخ السريان"><input type="date" className="input" dir="ltr" min={r.check_in} max={r.check_out} value={effective} onChange={(e) => setEffective(e.target.value)} /></Field>
          <Field label="الوحدة الجديدة (متاحة لبقية الفترة)"><select className="input" value={room} onChange={(e) => setRoom(e.target.value)}><option value="">اختر</option>{rooms.map((x) => <option key={x.room_id} value={x.room_id}>{x.room_number} · {x.category_name} · {CLEANLINESS_LABELS[x.cleanliness]}</option>)}</select></Field>
          <ReasonInput value={reason} onChange={setReason} />
          <div className="rounded-xl bg-ink-50 p-3 text-xs text-ink-600">يُغلق تخصيص الوحدة القديمة عند تاريخ السريان ويُفتح تخصيص جديد (التاريخ محفوظ). أثناء الإقامة: تتحول القديمة إلى «تحتاج تنظيفًا» ويلزم مراجعة رمز الدخول للجديدة. فرق السعر عند تغيير النوع يُضاف كتسوية منفصلة.</div>
        </div>
        <Submit label="تبديل" onCancel={onClose} />
      </ActionForm>
    </Modal>
  );
}

const ACTION_LABELS: Record<string, string> = {
  "reservation.created": "إنشاء الحجز", "reservation.departure_changed": "تغيير تاريخ المغادرة", "reservation.room_switched": "تبديل الوحدة", "reservation.total_changed": "تعديل إجمالي الحجز",
  "reservation.service_added": "إضافة خدمة", "reservation.cancelled": "إلغاء الحجز", "reservation.no_show": "عدم حضور", "voucher.receipt_created": "سند قبض", "voucher.deposit_created": "قبض تأمين",
  "voucher.refund_created": "استرداد", "voucher.deposit_refund_created": "رد تأمين", "voucher.deposit_apply_created": "تغطية من التأمين", "voucher.cancelled": "إلغاء سند", "invoice.issued": "إصدار فاتورة", "invoice.cancelled": "إلغاء فاتورة",
  assign_room: "تخصيص وحدة", checkout: "مغادرة", confirm_payment: "تأكيد سداد", approve_checkin: "اعتماد الدخول", deliver_access_code: "تسليم رمز الدخول", approve_identity: "اعتماد الهوية", reject_identity: "رفض الهوية", confirm_gov_registration: "تأكيد التسجيل النظامي",
};
