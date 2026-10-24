/**
 * «تسوية الشبكة» (decision 13): once a day, what the card terminal says it took (its settlement slip) against the
 * terminal vouchers recorded for that bank account on that branch day — taken in, minus paid back. Equal is matched;
 * a difference is saved with its explanation and goes to the owner's review. The server recomputes the vouchers'
 * total itself; the screen only shows it.
 */
import { useEffect, useState } from "react";
import { CreditCard, CheckCircle2, AlertTriangle } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { moneyApi, toArabicError, type CashAccount, type PosDay, type PosSettlement as Settlement } from "../../lib/api";
import { accountLabel } from "../../lib/useCashAccounts";
import { SectionTitle, LoadingScreen, Card, ErrorBanner, Badge, LoadErrorCard, Spinner, EmptyState } from "../../components/ui";
import { Field, MoneyInput } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { VOUCHER_KIND_LABELS, type VoucherKind } from "../../lib/types";
import { formatCurrency, formatDateTime, todayISO, addDaysISO } from "../../lib/utils";

const sar = (h: number | null | undefined) => formatCurrency((h ?? 0) / 100);
interface Data { accounts: CashAccount[]; history: Settlement[] }
const NO_DATA: Data = { accounts: [], history: [] };

export default function PosSettlement() {
  const [date, setDate] = useState(todayISO());
  const [accountId, setAccountId] = useState("");
  const [tick, setTick] = useState(0);

  // G24 (decision 40): the active branch's bank accounts and its last two weeks of settlements
  const q = useBranchQuery<Data>(async (branchId) => {
    const [a, h] = await Promise.all([
      supabase.from("cash_accounts").select("id, branch_id, kind, name, bank_name, account_last4, is_default, is_active, archived_at, archive_reason, version")
        .eq("branch_id", branchId).eq("kind", "bank_account").is("archived_at", null).order("name"),
      supabase.from("pos_settlements").select("id, account_id, business_date, terminal_total_halalas, system_total_halalas, difference_halalas, voucher_count, status, note, version, updated_at")
        .eq("branch_id", branchId).gte("business_date", addDaysISO(todayISO(), -14)).order("business_date", { ascending: false }),
    ]);
    return { accounts: must(a) as CashAccount[], history: must(h) as Settlement[] };
  }, [tick], NO_DATA);
  const { accounts, history } = q.data; const branchId = q.branchId;
  useEffect(() => {
    if (!accounts.some((a) => a.id === accountId)) setAccountId(accounts.find((a) => a.is_default)?.id ?? accounts[0]?.id ?? "");
  }, [accounts, accountId]);

  if (q.loading) return <LoadingScreen />;
  const nameOf = (id: string) => { const a = accounts.find((x) => x.id === id); return a ? accountLabel(a) : "—"; };

  return (
    <div>
      <SectionTitle title="تسوية الشبكة" subtitle="إجمالي جهاز الشبكة لليوم مقابل سندات الشبكة المسجلة على الحساب نفسه" action={<BranchPicker />} />
      {q.error && <div className="mb-4">{accounts.length ? <ErrorBanner message={q.error} /> : <LoadErrorCard message={q.error} onRetry={q.reload} />}</div>}
      {!q.error && accounts.length === 0 ? <EmptyState icon={<CreditCard className="h-10 w-10" />} title="لا يوجد حساب بنكي فعّال" description="يعرّف المالك أو المدير حساب الشبكة من «الصناديق والحسابات»." /> : accounts.length > 0 && (
        <div className="grid gap-4 lg:grid-cols-3">
          <div className="space-y-4 lg:col-span-2">
            <Card>
              <div className="grid gap-3 sm:grid-cols-2">
                <Field label="اليوم"><input type="date" className="input" dir="ltr" max={todayISO()} value={date} onChange={(e) => e.target.value && setDate(e.target.value)} /></Field>
                <Field label="الحساب البنكي (جهاز الشبكة)"><select className="input" value={accountId} onChange={(e) => setAccountId(e.target.value)} aria-label="الحساب البنكي">{accounts.map((a) => <option key={a.id} value={a.id}>{accountLabel(a)}{a.is_default ? " (الافتراضي)" : ""}</option>)}</select></Field>
              </div>
            </Card>
            {branchId && accountId && <DayCard branchId={branchId} accountId={accountId} date={date} onSaved={() => setTick((t) => t + 1)} />}
          </div>
          <Card>
            <h3 className="mb-2 text-sm font-semibold text-ink-700">آخر أسبوعين</h3>
            {history.length === 0 ? <p className="text-xs text-ink-400">لا تسويات بعد.</p> : (
              <div className="divide-y divide-ink-50 text-sm" data-testid="pos-history">
                {history.map((s) => (
                  <button key={s.id} type="button" onClick={() => { setDate(s.business_date); setAccountId(s.account_id); }} className="flex w-full items-center justify-between gap-2 py-2 text-right hover:bg-ink-50/50">
                    <span><span dir="ltr" className="font-medium text-ink-700">{s.business_date}</span><span className="block text-[11px] text-ink-400">{nameOf(s.account_id)}</span></span>
                    {s.status === "matched" ? <Badge className="bg-success-500/10 text-success-600">مطابقة</Badge> : <Badge className="bg-danger-500/10 text-danger-600">فرق <span dir="ltr">{sar(s.difference_halalas)}</span></Badge>}
                  </button>
                ))}
              </div>
            )}
          </Card>
        </div>
      )}
    </div>
  );
}

function DayCard({ branchId, accountId, date, onSaved }: { branchId: string; accountId: string; date: string; onSaved: () => void }) {
  const [day, setDay] = useState<PosDay | null>(null);
  const [error, setError] = useState<string | null>(null);         // loading the day failed
  const [saveError, setSaveError] = useState<string | null>(null); // saving was refused (shown under the form)
  const [terminal, setTerminal] = useState<number | null>(null);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  // another day or account: start clean; a reload after saving keeps the card and its "saved" line on screen
  useEffect(() => { setDay(null); setSaved(null); setSaveError(null); }, [branchId, accountId, date]);
  useEffect(() => {
    let alive = true;
    setError(null);
    moneyApi.posDay(branchId, accountId, date).then(
      (d) => { if (!alive) return; setDay(d); setTerminal(d.settlement ? d.settlement.terminal_total_halalas : null); setNote(d.settlement?.note ?? ""); },
      (e) => { if (alive) setError(toArabicError(e)); });
    return () => { alive = false; };
  }, [branchId, accountId, date, tick]);

  if (error) return <LoadErrorCard message={error} onRetry={() => setTick((t) => t + 1)} />;
  if (!day) return <div className="py-6 text-center"><Spinner /></div>;
  const s = day.settlement;
  const diff = terminal == null ? null : terminal - day.system_total_halalas;
  const stale = s && s.system_total_halalas !== day.system_total_halalas;

  async function save(e: React.FormEvent) {
    e.preventDefault();
    if (terminal == null) return;
    setSaved(null); setSaveError(null);
    if (diff !== 0 && !note.trim()) { setSaveError(toArabicError(new Error("VALIDATION: note_required"))); return; }
    setBusy(true);
    try {
      const r = await moneyApi.posSettle({ branch_id: branchId, account_id: accountId, business_date: date, terminal_total_halalas: terminal, note: note.trim() || undefined, version: s?.version });
      setSaved(r.settlement.status === "matched" ? "حُفظت: مطابقة." : "حُفظت مع الفرق وسببه، وتظهر للمالك للمراجعة.");
      setTick((t) => t + 1); onSaved();
    } catch (err) { setSaveError(toArabicError(err)); }
    finally { setBusy(false); }
  }

  return (
    <Card>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4" data-testid="pos-day">
        <div><p className="text-[11px] text-ink-400">قُبض بالشبكة</p><p className="font-medium" dir="ltr">{sar(day.in_halalas)}</p></div>
        <div><p className="text-[11px] text-ink-400">رُدّ بالشبكة</p><p className="font-medium" dir="ltr">{sar(day.out_halalas)}</p></div>
        <div><p className="text-[11px] text-ink-400">صافي السندات</p><p className="font-semibold text-ink-800" dir="ltr" data-testid="pos-system-total">{sar(day.system_total_halalas)}</p></div>
        <div><p className="text-[11px] text-ink-400">عدد السندات</p><p className="font-medium">{day.voucher_count}</p></div>
      </div>
      {day.vouchers.length > 0 && (
        <div className="mt-3 max-h-48 overflow-y-auto rounded-lg border border-ink-50 text-xs">
          {day.vouchers.map((v) => (
            <div key={v.id} className="flex flex-wrap items-center justify-between gap-x-3 gap-y-0.5 border-b border-ink-50 px-3 py-1.5 last:border-0">
              <span className="font-mono">{v.number}</span><span className="text-ink-500">{VOUCHER_KIND_LABELS[v.kind as VoucherKind] ?? v.kind}{v.reference ? ` · ${v.reference}` : ""}</span>
              <span dir="ltr" className={v.kind === "refund" || v.kind === "deposit_refund" ? "text-danger-600" : ""}>{v.kind === "refund" || v.kind === "deposit_refund" ? "−" : ""}{sar(v.amount_halalas)}</span>
              <span className="text-ink-400">{formatDateTime(v.occurred_at)}</span>
            </div>
          ))}
        </div>
      )}
      {s && (
        <div className={`mt-3 flex items-start gap-2 rounded-xl px-3 py-2 text-sm ${s.status === "matched" ? "bg-success-500/10 text-success-600" : "bg-danger-500/10 text-danger-600"}`} data-testid="pos-settlement-status">
          {s.status === "matched" ? <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" /> : <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />}
          <span>{s.status === "matched" ? "سُوّي هذا اليوم: مطابق." : <>سُوّي هذا اليوم بفرق <span dir="ltr">{sar(s.difference_halalas)}</span>: {s.note}</>} <span className="text-xs opacity-80">({formatDateTime(s.updated_at)})</span>
            {stale && <span className="block text-xs">تغيّرت سندات الشبكة لهذا اليوم بعد التسوية — أعد التسوية.</span>}
          </span>
        </div>
      )}
      <form onSubmit={save} className="mt-4 grid gap-3 sm:grid-cols-2">
        <Field label="إجمالي جهاز الشبكة لليوم" hint="الصافي في إيصال تسوية الجهاز (المبيعات ناقص المرتجعات)."><MoneyInput valueHalalas={terminal} onChange={setTerminal} min={-100000000} /></Field>
        <Field label={diff ? "سبب الفرق (إلزامي)" : "ملاحظة"}><input className="input" value={note} onChange={(e) => setNote(e.target.value)} aria-label="سبب الفرق" /></Field>
        {diff != null && <p className={`sm:col-span-2 text-sm ${diff === 0 ? "text-success-600" : "text-danger-600"}`} data-testid="pos-diff">{diff === 0 ? "مطابق للسندات." : <>الفرق: <span dir="ltr">{sar(diff)}</span> {diff > 0 ? "(الجهاز أكثر من السندات)" : "(السندات أكثر من الجهاز)"}</>}</p>}
        <div className="sm:col-span-2 flex items-center gap-3">
          <button type="submit" disabled={busy || terminal == null} className="btn-primary text-sm">{busy ? <Spinner className="h-4 w-4" /> : null} {s ? "تحديث التسوية" : "حفظ التسوية"}</button>
          {saved && <span className="text-sm text-success-600">{saved}</span>}
          {saveError && <span className="text-sm text-danger-600" role="alert">{saveError}</span>}
        </div>
      </form>
    </Card>
  );
}
