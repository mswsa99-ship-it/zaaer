/**
 * «دفتر الحركة» (the accounting stage, A4; migration 0064): the ledger of the branch's cash box or bank account for a
 * period — the opening balance, every movement in (receipts, deposits, platform payouts) and out (refunds, deposit
 * refunds, expenses), and on every line the running balance = opening + in − out, all computed by the server. The owner
 * (or who holds «الصناديق والحسابات») sets the opening balance with its date and reason.
 * Since 0067 the entries with no voucher of their own are lines too: «تسوية بنكية» (what matching a bank movement booked:
 * a difference, fees, other income, and their reversals) and «فرق إقفال» (a day closing's cash difference), so the
 * ledger ends where the journal stands.
 */
import { useEffect, useState } from "react";
import { BookOpen } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { expenseApi, toArabicError, type CashAccount, type Ledger as LedgerData } from "../../lib/api";
import { useBranch } from "../../lib/branch";
import { useAuth } from "../../lib/auth";
import { SectionTitle, Card, Spinner, LoadErrorCard, EmptyState, AmountBox, AmountGrid } from "../../components/ui";
import { Field, MoneyInput, Modal, ActionForm, Submit, ReasonInput } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { formatCurrency, formatDateTime, todayISO } from "../../lib/utils";
import { DateRangePicker } from "../../components/DateRangePicker";

const sar = (h: number) => formatCurrency(h / 100);
const KIND: Record<string, string> = { receipt: "سند قبض", deposit: "قبض تأمين", refund: "رد مبلغ", deposit_refund: "رد تأمين", platform_payout: "دفعة منصة", expense: "سند صرف",
  bank_adjustment: "تسوية بنكية", closing_difference: "فرق إقفال" };
const monthStart = () => todayISO().slice(0, 8) + "01";

export default function Ledger() {
  const { branchId, allBranches } = useBranch();
  const { can } = useAuth();
  const [accounts, setAccounts] = useState<CashAccount[]>([]);
  const [accountId, setAccountId] = useState("");
  const [from, setFrom] = useState(monthStart());
  const [to, setTo] = useState(todayISO());
  const [data, setData] = useState<LedgerData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [opening, setOpening] = useState(false);

  useEffect(() => {
    if (!branchId) return;
    supabase.from("cash_accounts").select("id, branch_id, kind, name, bank_name, account_last4, account_prefix, account_suffix, is_default, is_active, archived_at, archive_reason, version")
      .eq("branch_id", branchId).order("archived_at", { ascending: true, nullsFirst: true }).order("kind", { ascending: false })
      .then(({ data: d }) => { const a = (d ?? []) as CashAccount[]; setAccounts(a); setAccountId((cur) => (a.some((x) => x.id === cur) ? cur : a[0]?.id ?? "")); });
  }, [branchId]);
  useEffect(() => {
    if (!accountId) return;
    let alive = true; setError(null); setData(null);
    expenseApi.ledger(accountId, from, to).then((d) => { if (alive) setData(d); }, (e) => { if (alive) setError(toArabicError(e)); });
    return () => { alive = false; };
  }, [accountId, from, to, tick]);

  if (allBranches) return <AllBranchesLedger />;
  return (
    <div>
      <SectionTitle title="دفتر الحركة" subtitle="كل داخل وخارج من الصندوق أو الحساب البنكي، والرصيد بعد كل حركة" action={<BranchPicker allowAll />} />
      <Card className="mb-4">
        <div className="grid gap-3 sm:grid-cols-3">
          <Field label="الحساب"><select className="input" value={accountId} onChange={(e) => setAccountId(e.target.value)} aria-label="الحساب">{accounts.map((a) => <option key={a.id} value={a.id}>{a.kind === "cash_box" ? "الصندوق" : "الحساب البنكي"} — {a.name}{a.archived_at ? " (مؤرشف)" : ""}</option>)}</select></Field>
          <Field label="اليوم أو الفترة" className="sm:col-span-2"><DateRangePicker label="اليوم أو الفترة" from={from} to={to} max={todayISO()} onChange={(a, b) => { setFrom(a); setTo(b); }} /></Field>
        </div>
      </Card>
      {error ? <LoadErrorCard message={error} onRetry={() => setTick((t) => t + 1)} /> : !data ? <div className="py-10 text-center"><Spinner /></div> : (
        <>
          <Card className="mb-4">
            <AmountGrid testId="ledger-totals">
              <AmountBox label="الرصيد أول الفترة" value={<span data-testid="ledger-opening">{sar(data.opening_halalas)}</span>} />
              <AmountBox label="الداخل" value={sar(data.in_halalas)} tone="text-success-600" />
              <AmountBox label="الخارج" value={sar(data.out_halalas)} tone="text-danger-600" />
              <AmountBox label="الرصيد آخر الفترة" value={<span data-testid="ledger-closing">{sar(data.closing_halalas)}</span>} />
            </AmountGrid>
            <div className="mt-3 flex flex-wrap items-center justify-between gap-2 text-xs text-ink-500">
              <span>الرصيد الافتتاحي: <span dir="ltr">{sar(data.account.opening_balance_halalas)}</span>{data.account.opening_on ? <> بتاريخ <span dir="ltr">{data.account.opening_on}</span></> : " (لم يُحدَّد تاريخه: يبدأ الحساب من أول حركة)"}</span>
              {can("cash_accounts") && <button type="button" className="btn-ghost min-h-[44px] text-xs" onClick={() => setOpening(true)}>تحديد الرصيد الافتتاحي</button>}
            </div>
          </Card>
          {data.lines.length === 0 ? <EmptyState icon={<BookOpen className="h-10 w-10" />} title="لا حركة في هذه الفترة" /> : (
            <Card>
              <div className="overflow-x-auto">
                <table className="w-full min-w-[40rem] text-sm" data-testid="ledger-lines">
                  <thead><tr className="border-b border-ink-100 text-xs text-ink-500"><th className="py-2 text-right font-medium">التاريخ</th><th className="py-2 text-right font-medium">الحركة</th><th className="py-2 text-right font-medium">البيان</th><th className="py-2 text-left font-medium">داخل</th><th className="py-2 text-left font-medium">خارج</th><th className="py-2 text-left font-medium">الرصيد</th></tr></thead>
                  <tbody>
                    {data.lines.map((l) => (
                      <tr key={l.kind + l.ref_id} className="border-b border-ink-50" data-testid="ledger-line">
                        <td className="py-2 text-xs text-ink-500">{formatDateTime(l.at)}</td>
                        <td className="py-2">{KIND[l.kind] ?? l.kind} <span className="block font-mono text-[11px] text-ink-400" dir="ltr">{l.number}</span></td>
                        <td className="py-2 text-ink-600">{l.description || "—"}</td>
                        <td className="py-2 text-left tabular-nums text-success-600" dir="ltr">{l.in_halalas ? sar(l.in_halalas) : ""}</td>
                        <td className="py-2 text-left tabular-nums text-danger-600" dir="ltr">{l.out_halalas ? sar(l.out_halalas) : ""}</td>
                        <td className="py-2 text-left font-semibold tabular-nums" dir="ltr">{sar(l.balance_halalas)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </Card>
          )}
          <Modal open={opening} title="الرصيد الافتتاحي" onClose={() => setOpening(false)}>
            {opening && <OpeningForm accountId={data.account.id} current={data.account.opening_balance_halalas} on={data.account.opening_on} onDone={() => { setOpening(false); setTick((t) => t + 1); }} onCancel={() => setOpening(false)} />}
          </Modal>
        </>
      )}
    </div>
  );
}

function OpeningForm({ accountId, current, on, onDone, onCancel }: { accountId: string; current: number; on: string | null; onDone: () => void; onCancel: () => void }) {
  const [amount, setAmount] = useState<number | null>(current);
  const [date, setDate] = useState(on ?? todayISO());
  const [reason, setReason] = useState("");
  return (
    <ActionForm onSubmit={async () => { if (!reason.trim()) throw new Error("VALIDATION: reason"); await expenseApi.setOpening(accountId, amount ?? 0, date, reason.trim()); onDone(); }}>
      <p className="mb-3 text-sm text-ink-600">ما كان في الصندوق أو الحساب في هذا التاريخ. يبدأ الدفتر منه، وما قبله لا يُحسب.</p>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="المبلغ"><MoneyInput valueHalalas={amount} onChange={setAmount} min={-100000000} label="المبلغ" /></Field>
        <Field label="التاريخ"><DateRangePicker single label="التاريخ" from={date} to={date} max={todayISO()} onChange={(a) => setDate(a)} /></Field>
      </div>
      <ReasonInput value={reason} onChange={setReason} />
      <Submit label="حفظ" onCancel={onCancel} />
    </ActionForm>
  );
}

/** «جميع الفروع» (owner): every branch's active accounts for one period, with the totals added. Read-only; the lines stay per account. */
function AllBranchesLedger() {
  const { branches } = useBranch();
  const [from, setFrom] = useState(monthStart());
  const [to, setTo] = useState(todayISO());
  const [rows, setRows] = useState<{ branch: string; account: string; d: LedgerData }[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let alive = true; setError(null); setRows(null);
    (async () => {
      const { data: acc, error: e } = await supabase.from("cash_accounts").select("id, branch_id, kind, name, bank_name, account_last4, account_prefix, account_suffix, is_default, is_active, archived_at, archive_reason, version")
        .in("branch_id", branches.map((b) => b.id)).is("archived_at", null).order("kind", { ascending: false });
      if (e) throw e;
      const list = (acc ?? []) as CashAccount[];
      const out = await Promise.all(list.map(async (a) => ({ branch: branches.find((b) => b.id === a.branch_id)?.name_ar ?? "", account: a.name || (a.kind === "bank_account" ? "الحساب البنكي" : "الصندوق"), d: await expenseApi.ledger(a.id, from, to) })));
      if (alive) setRows(out);
    })().catch((e) => { if (alive) setError(toArabicError(e)); });
    return () => { alive = false; };
  }, [from, to, tick, branches]);
  const sum = (f: (d: LedgerData) => number) => (rows ?? []).reduce((a, r) => a + f(r.d), 0);
  return (
    <div>
      <SectionTitle title="دفتر الحركة" subtitle="جميع الفروع: ملخص كل حساب للفترة المختارة، والمجموع" action={<BranchPicker allowAll />} />
      <Card className="mb-4"><Field label="اليوم أو الفترة"><DateRangePicker label="اليوم أو الفترة" from={from} to={to} max={todayISO()} onChange={(a, b) => { setFrom(a); setTo(b); }} /></Field></Card>
      {error ? <LoadErrorCard message={error} onRetry={() => setTick((t) => t + 1)} /> : !rows ? <div className="py-10 text-center"><Spinner /></div> : rows.length === 0 ? <EmptyState icon={<BookOpen className="h-10 w-10" />} title="لا حسابات" /> : (
        <>
          <Card className="mb-4">
            <AmountGrid testId="ledger-all-totals">
              <AmountBox label="الرصيد أول الفترة" value={sar(sum((d) => d.opening_halalas))} />
              <AmountBox label="الداخل" value={sar(sum((d) => d.in_halalas))} tone="text-rai-success" />
              <AmountBox label="الخارج" value={sar(sum((d) => d.out_halalas))} tone="text-rai-danger" />
              <AmountBox label="الرصيد آخر الفترة" value={sar(sum((d) => d.closing_halalas))} />
            </AmountGrid>
          </Card>
          <div className="space-y-3 md:hidden">
            {rows.map((r) => (
              <Card key={r.d.account.id}>
                <p className="text-sm font-semibold">{r.branch} · {r.account}</p>
                <dl className="mt-2 grid grid-cols-2 gap-1 text-xs"><dt>أول الفترة</dt><dd dir="ltr">{sar(r.d.opening_halalas)}</dd><dt>الداخل</dt><dd dir="ltr">{sar(r.d.in_halalas)}</dd><dt>الخارج</dt><dd dir="ltr">{sar(r.d.out_halalas)}</dd><dt>آخر الفترة</dt><dd dir="ltr" className="font-semibold">{sar(r.d.closing_halalas)}</dd></dl>
              </Card>
            ))}
          </div>
          <Card className="hidden md:block">
            <table className="w-full text-sm" data-testid="ledger-all-rows">
              <thead><tr className="border-b border-rai-line text-xs text-rai-ink-muted"><th className="py-2 text-right font-medium">الفرع</th><th className="py-2 text-right font-medium">الحساب</th><th className="py-2 text-left font-medium">أول الفترة</th><th className="py-2 text-left font-medium">الداخل</th><th className="py-2 text-left font-medium">الخارج</th><th className="py-2 text-left font-medium">آخر الفترة</th></tr></thead>
              <tbody>{rows.map((r) => <tr key={r.d.account.id} className="border-b border-rai-line"><td className="py-2">{r.branch}</td><td className="py-2">{r.account}</td><td className="py-2 text-left tabular-nums" dir="ltr">{sar(r.d.opening_halalas)}</td><td className="py-2 text-left tabular-nums text-rai-success" dir="ltr">{sar(r.d.in_halalas)}</td><td className="py-2 text-left tabular-nums text-rai-danger" dir="ltr">{sar(r.d.out_halalas)}</td><td className="py-2 text-left font-semibold tabular-nums" dir="ltr">{sar(r.d.closing_halalas)}</td></tr>)}</tbody>
            </table>
          </Card>
        </>
      )}
    </div>
  );
}
