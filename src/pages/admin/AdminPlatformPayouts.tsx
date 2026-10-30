/**
 * «مطابقة المنصات» (decision 24): a stay paid through a booking platform is recorded as «آجل عبر المنصة» — the
 * platform collected it and pays it into the bank later, usually monthly. Here finance ticks the platform's payments
 * that one bank deposit covers, enters what actually arrived, and the difference (the platform's commission, usually)
 * is explained. Until then a payment stays on the unmatched list.
 */
import { useEffect, useMemo, useState } from "react";
import { Building, Ban } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { moneyApi, type CashAccount, type PlatformPayment } from "../../lib/api";
import { useAuth } from "../../lib/auth";
import { accountLabel } from "../../lib/useCashAccounts";
import { SectionTitle, LoadingScreen, Card, ErrorBanner, Badge, LoadErrorCard, EmptyState } from "../../components/ui";
import { Modal, Field, ActionForm, Submit, MoneyInput, ReasonInput } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { formatCurrency, todayISO, isoDateIn, UI_LOCALE } from "../../lib/utils";

const sar = (h: number | null | undefined) => formatCurrency((h ?? 0) / 100);
interface Payout { id: string; source_id: string; account_id: string; expected_halalas: number; received_halalas: number; difference_halalas: number; voucher_count: number; received_on: string; reference: string; note: string | null; status: string; cancel_reason: string | null; created_at: string }
interface Data { unsettled: PlatformPayment[]; payouts: Payout[]; accounts: CashAccount[]; sources: Array<{ id: string; name: string }> }
const NO_DATA: Data = { unsettled: [], payouts: [], accounts: [], sources: [] };
/** The month a payment belongs to, by the property's calendar day (not the UTC one). */
const monthOf = (iso: string) => isoDateIn(new Date(iso)).slice(0, 7);
/** "2026-10" → "أكتوبر 2026" (Gregorian: platforms pay by calendar month). */
const monthName = (ym: string) => new Date(`${ym}-15T12:00:00Z`).toLocaleDateString(UI_LOCALE, { month: "long", year: "numeric", timeZone: "UTC" });

export default function AdminPlatformPayouts() {
  const { canFull } = useAuth();
  const canCancel = canFull("platform.payouts");
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [confirming, setConfirming] = useState(false);
  const [cancelFor, setCancelFor] = useState<Payout | null>(null);
  const [reason, setReason] = useState("");
  const [form, setForm] = useState<{ received: number | null; on: string; account: string; reference: string; note: string }>({ received: null, on: todayISO(), account: "", reference: "", note: "" });

  // G24 (decision 40): the active branch's unmatched platform payments and its payouts
  const q = useBranchQuery<Data>(async (branchId) => {
    const [u, p, a, s] = await Promise.all([
      moneyApi.platformUnsettled(branchId),
      supabase.from("platform_payouts").select("id, source_id, account_id, expected_halalas, received_halalas, difference_halalas, voucher_count, received_on, reference, note, status, cancel_reason, created_at").eq("branch_id", branchId).order("received_on", { ascending: false }).limit(50),
      supabase.from("cash_accounts").select("id, branch_id, kind, name, bank_name, account_last4, is_default, is_active, archived_at, archive_reason, version").eq("branch_id", branchId).eq("kind", "bank_account").order("name"),
      supabase.from("booking_sources").select("id, name").order("name"),
    ]);
    return { unsettled: u, payouts: must(p) as Payout[], accounts: must(a) as CashAccount[], sources: (s.data as Data["sources"]) ?? [] };
  }, [], NO_DATA);
  const { unsettled, payouts, accounts, sources } = q.data; const branchId = q.branchId;
  useEffect(() => { setPicked(new Set()); }, [branchId]);   // a selection never carries over to another branch

  const groups = useMemo(() => {
    const m = new Map<string, { source_id: string; source: string; month: string; items: PlatformPayment[] }>();
    for (const x of unsettled) {
      const k = `${x.source_id}|${monthOf(x.occurred_at)}`;
      if (!m.has(k)) m.set(k, { source_id: x.source_id, source: x.source_name ?? "—", month: monthOf(x.occurred_at), items: [] });
      m.get(k)!.items.push(x);
    }
    return [...m.values()];
  }, [unsettled]);
  const chosen = unsettled.filter((x) => picked.has(x.id));
  const chosenSources = [...new Set(chosen.map((x) => x.source_id))];
  const expected = chosen.reduce((s, x) => s + x.signed_halalas, 0);

  if (q.loading) return <LoadingScreen />;
  const sourceName = (id: string) => sources.find((s) => s.id === id)?.name ?? "—";
  const accountName = (id: string) => { const a = accounts.find((x) => x.id === id); return a ? accountLabel(a) : "—"; };
  const toggle = (id: string) => setPicked((s) => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n; });
  const activeAccounts = accounts.filter((a) => !a.archived_at && a.is_active);

  return (
    <div>
      <SectionTitle title="مطابقة المنصات" subtitle="الدفعات الآجلة عبر المنصات مقابل ما أودعته المنصة في الحساب — شهريًا" action={<BranchPicker />} />
      {q.error && <div className="mb-4">{unsettled.length + payouts.length ? <ErrorBanner message={q.error} /> : <LoadErrorCard message={q.error} onRetry={q.reload} />}</div>}

      <h3 className="mb-2 text-sm font-semibold text-ink-700">دفعات لم تُطابق بعد</h3>
      {groups.length === 0 ? (!q.error && <EmptyState icon={<Building className="h-10 w-10" />} title="لا دفعات آجلة غير مطابقة" description="تظهر هنا كل دفعة سُجّلت «آجل عبر المنصة» حتى تُطابق مع إيداع المنصة." />) : (
        <div className="space-y-3">
          {groups.map((g) => {
            const total = g.items.reduce((s, x) => s + x.signed_halalas, 0);
            const allIn = g.items.every((x) => picked.has(x.id));
            return (
              <Card key={g.source_id + g.month}>
                <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
                  <p className="font-semibold text-ink-800">{g.source} · {monthName(g.month)}</p>
                  <div className="flex items-center gap-3 text-sm"><span className="text-ink-500">{g.items.length} دفعة · <span dir="ltr">{sar(total)}</span></span>
                    <button type="button" className="btn-ghost text-xs" onClick={() => setPicked((s) => { const n = new Set(s); for (const x of g.items) { if (allIn) n.delete(x.id); else n.add(x.id); } return n; })}>{allIn ? "إلغاء التحديد" : "تحديد الكل"}</button></div>
                </div>
                <div className="divide-y divide-ink-50 text-sm">
                  {g.items.map((x) => (
                    <label key={x.id} className="flex cursor-pointer items-center gap-3 py-1.5" data-testid="platform-payment">
                      <input type="checkbox" className="h-4 w-4 accent-brand-600" checked={picked.has(x.id)} onChange={() => toggle(x.id)} />
                      <span className="font-mono text-xs">{x.number}</span>
                      <span className="min-w-0 flex-1 truncate text-ink-600">{x.internal_ref}{x.external_ref ? ` · ${x.external_ref}` : ""} · وصول <span dir="ltr">{x.check_in}</span></span>
                      <span dir="ltr" className={x.kind === "refund" ? "text-danger-600" : "text-ink-800"}>{sar(x.signed_halalas)}</span>
                    </label>
                  ))}
                </div>
              </Card>
            );
          })}
        </div>
      )}
      {chosen.length > 0 && (
        <div className="sticky bottom-4 mt-4 flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-brand-200 bg-white p-3 shadow-lg">
          <span className="text-sm text-ink-700">{chosen.length} دفعة · المتوقع <span dir="ltr" className="font-semibold">{sar(expected)}</span>{chosenSources.length > 1 && <span className="mr-2 text-danger-600">— اختر دفعات منصة واحدة</span>}</span>
          <button type="button" className="btn-primary text-sm" disabled={chosenSources.length !== 1} onClick={() => { setForm({ received: expected, on: todayISO(), account: activeAccounts.find((a) => a.is_default)?.id ?? activeAccounts[0]?.id ?? "", reference: "", note: "" }); setConfirming(true); }}>تأكيد إيداع المنصة</button>
        </div>
      )}

      <h3 className="mb-2 mt-8 text-sm font-semibold text-ink-700">إيداعات مطابقة</h3>
      {payouts.length === 0 ? <p className="text-sm text-ink-400">لا إيداعات بعد.</p> : (
        <Card className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead><tr className="border-b border-ink-100 text-xs text-ink-400"><th className="py-2 text-right font-medium">التاريخ</th><th className="text-right font-medium">المنصة</th><th className="text-right font-medium">المتوقع</th><th className="text-right font-medium">المستلم</th><th className="text-right font-medium">الفرق</th><th className="text-right font-medium">المرجع</th><th></th></tr></thead>
            <tbody>
              {payouts.map((p) => (
                <tr key={p.id} className={`border-b border-ink-50 ${p.status === "cancelled" ? "text-ink-400 line-through" : ""}`}>
                  <td className="py-2" dir="ltr">{p.received_on}</td><td>{sourceName(p.source_id)}<span className="block text-[11px] text-ink-400 no-underline">{accountName(p.account_id)} · {p.voucher_count} دفعة</span></td>
                  <td dir="ltr">{sar(p.expected_halalas)}</td><td dir="ltr">{sar(p.received_halalas)}</td>
                  <td dir="ltr" className={p.difference_halalas === 0 ? "" : "text-warning-700"}>{sar(p.difference_halalas)}{p.note && <span className="block text-[11px] text-ink-400" dir="rtl">{p.note}</span>}</td>
                  <td className="font-mono text-xs">{p.reference}</td>
                  <td className="text-left">{p.status === "cancelled" ? <Badge className="bg-ink-100 text-ink-500" >ملغاة</Badge> : canCancel ? <button className="btn-ghost text-xs text-danger-600" onClick={() => { setReason(""); setCancelFor(p); }}><Ban className="h-3.5 w-3.5" /> إلغاء</button> : null}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}

      <Modal open={confirming} title="تأكيد إيداع المنصة" onClose={() => setConfirming(false)}>
        {confirming && branchId && (
          <ActionForm onSubmit={async () => {
            if (form.received == null || form.received <= 0) throw new Error("VALIDATION: amount");
            if (!form.reference.trim()) throw new Error("VALIDATION: reference_required");
            if (form.received !== expected && !form.note.trim()) throw new Error("VALIDATION: note_required");
            await moneyApi.platformConfirm({ branch_id: branchId, source_id: chosenSources[0], voucher_ids: chosen.map((x) => x.id), received_halalas: form.received, received_on: form.on, account_id: form.account || undefined, reference: form.reference.trim(), note: form.note.trim() || undefined });
            setConfirming(false); setPicked(new Set()); q.reload();
          }}>
            <p className="mb-3 text-sm text-ink-600">{sourceName(chosenSources[0])}: {chosen.length} دفعة، والمتوقع <span dir="ltr">{sar(expected)}</span></p>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="المبلغ المستلم فعلًا"><MoneyInput valueHalalas={form.received} onChange={(h) => setForm({ ...form, received: h })} /></Field>
              <Field label="تاريخ الاستلام"><input type="date" className="input" dir="ltr" max={todayISO()} value={form.on} onChange={(e) => setForm({ ...form, on: e.target.value })} /></Field>
              <Field label="الحساب البنكي"><select className="input" value={form.account} onChange={(e) => setForm({ ...form, account: e.target.value })}>{activeAccounts.map((a) => <option key={a.id} value={a.id}>{accountLabel(a)}</option>)}</select></Field>
              <Field label="مرجع الإيداع (إلزامي)"><input className="input" dir="ltr" value={form.reference} onChange={(e) => setForm({ ...form, reference: e.target.value })} aria-label="مرجع الإيداع" /></Field>
              {form.received != null && form.received !== expected && <Field label={`سبب الفرق ${sar((form.received ?? 0) - expected)} (إلزامي)`} className="sm:col-span-2"><input className="input" value={form.note} onChange={(e) => setForm({ ...form, note: e.target.value })} placeholder="مثال: عمولة المنصة" aria-label="سبب الفرق" /></Field>}
            </div>
            <Submit label="تأكيد" onCancel={() => setConfirming(false)} />
          </ActionForm>
        )}
      </Modal>
      <Modal open={!!cancelFor} title="إلغاء مطابقة" onClose={() => setCancelFor(null)}>
        {cancelFor && (
          <ActionForm onSubmit={async () => { if (!reason.trim()) throw new Error("VALIDATION: reason"); await moneyApi.platformCancel(cancelFor.id, reason.trim()); setCancelFor(null); q.reload(); }}>
            <p className="mb-3 text-sm text-ink-600">تعود الدفعات إلى «لم تُطابق بعد»، وتبقى هذه المطابقة في السجل ملغاة.</p>
            <ReasonInput value={reason} onChange={setReason} />
            <Submit label="إلغاء المطابقة" onCancel={() => setCancelFor(null)} danger />
          </ActionForm>
        )}
      </Modal>
    </div>
  );
}
