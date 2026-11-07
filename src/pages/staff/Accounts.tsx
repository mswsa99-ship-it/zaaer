/**
 * «الحسابات» (the accounting stage, A5; migration 0065): the double entry, read from the server. Every voucher, expense,
 * platform payout, closing difference and opening balance has already made its balanced entry; this page shows the
 * trial balance (its difference must be zero), the income statement, the balance sheet, the numbered chart with each
 * account's statement, and — for the owner — the month lock (a locked month refuses every entry, whatever writes it).
 * Nothing here posts an entry: the books follow the money.
 */
import { useEffect, useMemo, useState } from "react";
import { Scale, Lock, LockOpen, BookOpen } from "lucide-react";
import { glApi, toArabicError, type TrialBalance, type IncomeStatement, type BalanceSheet, type GlChartRow, type AccountStatement } from "../../lib/api";
import { useBranch } from "../../lib/branch";
import { useAuth } from "../../lib/auth";
import { SectionTitle, Card, Spinner, LoadErrorCard, EmptyState, AmountBox, AmountGrid } from "../../components/ui";
import { Field, Modal, ActionForm, Submit, ReasonInput } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { formatCurrency, todayISO } from "../../lib/utils";

const sar = (h: number) => formatCurrency(h / 100);
const monthStart = () => todayISO().slice(0, 8) + "01";
const TYPE: Record<string, string> = { asset: "أصول", liability: "التزامات", equity: "حقوق ملكية", revenue: "إيرادات", expense: "مصروفات" };
type View = "trial" | "income" | "balance" | "chart" | "months";

export default function Accounts() {
  const { branchId } = useBranch();
  const { can } = useAuth();
  const [view, setView] = useState<View>("trial");
  const [all, setAll] = useState(false);
  const [from, setFrom] = useState(monthStart());
  const [to, setTo] = useState(todayISO());
  const scope = all ? null : branchId;
  const views: Array<[View, string]> = [...(can("accounts.view") ? [["trial", "ميزان المراجعة"], ["income", "قائمة الدخل"], ["balance", "الميزانية"], ["chart", "دليل الحسابات"]] as Array<[View, string]> : []),
    ...(can("accounts.close_month") ? [["months", "قفل الشهر"] as [View, string]] : [])];
  const current = views.some(([v]) => v === view) ? view : views[0]?.[0] ?? "trial";

  return (
    <div>
      <SectionTitle title="الحسابات" subtitle="القيود تُنشأ تلقائيًا من كل سند وإقفال؛ هنا تقرؤها" action={<BranchPicker />} />
      <div className="mb-4 flex gap-1 overflow-x-auto rounded-2xl bg-ink-50 p-1" role="tablist" aria-label="عرض الحسابات">
        {views.map(([v, label]) => (
          <button key={v} type="button" role="tab" id={`acc-tab-${v}`} aria-controls="acc-panel" aria-selected={current === v} tabIndex={current === v ? 0 : -1} onClick={() => setView(v)}
            onKeyDown={(e) => { const i = views.findIndex(([x]) => x === v); const step = e.key === "ArrowLeft" ? 1 : e.key === "ArrowRight" ? -1 : 0;   /* RTL: left is next */
              if (step) { e.preventDefault(); const nx = views[(i + step + views.length) % views.length][0]; setView(nx); document.getElementById(`acc-tab-${nx}`)?.focus(); } }}
            className={`min-h-[44px] shrink-0 rounded-xl px-3 text-sm font-semibold transition ${current === v ? "bg-white text-brand-700 shadow-sm" : "text-ink-500 hover:text-ink-700"}`}>{label}</button>
        ))}
      </div>
      <div role="tabpanel" id="acc-panel" aria-labelledby={`acc-tab-${current}`}>
      {current !== "months" && (
        <Card className="mb-4">
          <div className="grid gap-3 sm:grid-cols-3">
            {current !== "balance" && current !== "chart" && <Field label="من"><input type="date" className="input" dir="ltr" max={to} value={from} onChange={(e) => e.target.value && setFrom(e.target.value)} aria-label="من" /></Field>}
            <Field label={current === "balance" || current === "chart" ? "حتى تاريخ" : "إلى"}><input type="date" className="input" dir="ltr" min={current === "balance" || current === "chart" ? undefined : from} max={todayISO()} value={to} onChange={(e) => e.target.value && setTo(e.target.value)} aria-label="إلى" /></Field>
            <label className="flex min-h-[44px] items-center gap-2 self-end text-sm text-ink-700"><input type="checkbox" checked={all} onChange={(e) => setAll(e.target.checked)} /> كل فروعي</label>
          </div>
        </Card>
      )}
      {current === "trial" && <Trial from={from} to={to} branch={scope} />}
      {current === "income" && <Income from={from} to={to} branch={scope} />}
      {current === "balance" && <Balance asOf={to} branch={scope} />}
      {current === "chart" && <Chart asOf={to} branch={scope} />}
      {current === "months" && <Months />}
      </div>
    </div>
  );
}

/** a server read with its spinner and its retry */
function useRead<T>(load: () => Promise<T>, deps: unknown[]) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let alive = true; setData(null); setError(null);
    load().then((d) => { if (alive) setData(d); }, (e) => { if (alive) setError(toArabicError(e)); });
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick]);
  return { data, error, retry: () => setTick((t) => t + 1) };
}
function Loading<T>({ r, children }: { r: { data: T | null; error: string | null; retry: () => void }; children: (d: T) => React.ReactNode }) {
  if (r.error) return <LoadErrorCard message={r.error} onRetry={r.retry} />;
  if (!r.data) return <div className="py-10 text-center"><Spinner /></div>;
  return <>{children(r.data)}</>;
}
const Num = ({ v, testId }: { v: number; testId?: string }) => <span dir="ltr" className="tabular-nums" data-testid={testId}>{v ? sar(v) : "—"}</span>;

function Trial({ from, to, branch }: { from: string; to: string; branch: string | null }) {
  const r = useRead<TrialBalance>(() => glApi.trialBalance(from, to, branch), [from, to, branch]);
  return (
    <Loading r={r}>{(d) => (
      <>
        <Card className="mb-4">
          <AmountGrid testId="trial-totals">
            <AmountBox label="مجموع المدين" value={sar(d.total_debit_halalas)} />
            <AmountBox label="مجموع الدائن" value={sar(d.total_credit_halalas)} />
            <AmountBox label="الفرق" value={<span data-testid="trial-difference">{sar(d.difference_halalas)}</span>} tone={d.difference_halalas === 0 ? "text-success-600" : "text-danger-600"} />
          </AmountGrid>
          {d.locked_months.length > 0 && <p className="mt-3 text-xs text-ink-500">الأشهر المقفلة: <span dir="ltr">{d.locked_months.join("، ")}</span></p>}
        </Card>
        {d.rows.length === 0 ? <EmptyState icon={<Scale className="h-10 w-10" />} title="لا قيود في هذه الفترة" /> : (
          <Card>
            <div className="overflow-x-auto">
              <table className="w-full min-w-[40rem] text-sm" data-testid="trial-rows">
                <thead><tr className="border-b border-ink-100 text-xs text-ink-500"><th className="py-2 text-right font-medium">الحساب</th><th className="py-2 text-left font-medium">أول الفترة</th><th className="py-2 text-left font-medium">مدين</th><th className="py-2 text-left font-medium">دائن</th><th className="py-2 text-left font-medium">آخر الفترة</th></tr></thead>
                <tbody>
                  {d.rows.map((x) => (
                    <tr key={x.account_id} className="border-b border-ink-50" data-testid="trial-row">
                      <td className="py-2"><span className="font-mono text-xs text-ink-400" dir="ltr">{x.code}</span> {x.name}</td>
                      <td className="py-2 text-left"><Num v={x.opening_halalas} /></td>
                      <td className="py-2 text-left"><Num v={x.debit_halalas} /></td>
                      <td className="py-2 text-left"><Num v={x.credit_halalas} /></td>
                      <td className="py-2 text-left font-semibold"><Num v={x.closing_halalas} /></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="mt-3 text-xs text-ink-500">الرصيد موجب للمدين وسالب للدائن. التأمينات (21) التزام على الفندق حتى تُرد أو تُخصم من الإيجار.</p>
          </Card>
        )}
      </>
    )}</Loading>
  );
}

function Income({ from, to, branch }: { from: string; to: string; branch: string | null }) {
  const r = useRead<IncomeStatement>(() => glApi.income(from, to, branch), [from, to, branch]);
  return (
    <Loading r={r}>{(d) => (
      <Card>
        <AmountGrid testId="income-totals">
          <AmountBox label="الإيرادات" value={sar(d.revenue_halalas)} tone="text-success-600" />
          <AmountBox label="المصروفات" value={sar(d.expenses_halalas)} tone="text-danger-600" />
          <AmountBox label="صافي الدخل" value={<span data-testid="income-net">{sar(d.net_income_halalas)}</span>} />
        </AmountGrid>
        {d.rows.length > 0 && (
          <ul className="mt-4 divide-y divide-ink-50 text-sm">
            {d.rows.map((x) => <li key={x.code} className="flex justify-between gap-3 py-2"><span><span className="font-mono text-xs text-ink-400" dir="ltr">{x.code}</span> {x.name}</span><Num v={x.amount_halalas} /></li>)}
          </ul>
        )}
      </Card>
    )}</Loading>
  );
}

function Balance({ asOf, branch }: { asOf: string; branch: string | null }) {
  const r = useRead<BalanceSheet>(() => glApi.balanceSheet(asOf, branch), [asOf, branch]);
  return (
    <Loading r={r}>{(d) => (
      <Card>
        <AmountGrid testId="balance-totals">
          <AmountBox label="الأصول" value={sar(d.assets_halalas)} />
          <AmountBox label="الالتزامات" value={sar(d.liabilities_halalas)} />
          <AmountBox label="حقوق الملكية والأرباح" value={sar(d.equity_halalas + d.retained_income_halalas)} />
          <AmountBox label="الفرق" value={<span data-testid="balance-difference">{sar(d.difference_halalas)}</span>} tone={d.difference_halalas === 0 ? "text-success-600" : "text-danger-600"} />
        </AmountGrid>
        <ul className="mt-4 divide-y divide-ink-50 text-sm">
          {d.rows.map((x) => <li key={x.code} className="flex justify-between gap-3 py-2"><span><span className="font-mono text-xs text-ink-400" dir="ltr">{x.code}</span> {x.name} <span className="text-xs text-ink-400">({TYPE[x.type]})</span></span><Num v={x.amount_halalas} /></li>)}
          <li className="flex justify-between gap-3 py-2"><span>أرباح الفترة غير المرحّلة</span><Num v={d.retained_income_halalas} /></li>
        </ul>
      </Card>
    )}</Loading>
  );
}

function Chart({ asOf, branch }: { asOf: string; branch: string | null }) {
  const r = useRead<GlChartRow[]>(() => glApi.chart(asOf, branch), [asOf, branch]);
  const [open, setOpen] = useState<GlChartRow | null>(null);
  return (
    <Loading r={r}>{(rows) => (
      <Card>
        <ul className="text-sm" data-testid="gl-chart">
          {rows.map((a) => (
            <li key={a.id} className="border-b border-ink-50" style={{ paddingInlineStart: `${(a.code.length - 1) * 0.75}rem` }}>
              {a.is_postable
                ? <button type="button" className="flex min-h-[44px] w-full items-center justify-between gap-3 text-right hover:bg-ink-50" onClick={() => setOpen(a)} data-testid="gl-account">
                    <span><span className="font-mono text-xs text-ink-400" dir="ltr">{a.code}</span> {a.name}</span><Num v={a.balance_halalas} /></button>
                : <div className="flex min-h-[40px] items-center gap-2 font-semibold text-ink-700"><span className="font-mono text-xs text-ink-400" dir="ltr">{a.code}</span> {a.name} <span className="text-xs font-normal text-ink-400">{TYPE[a.type]}</span></div>}
            </li>
          ))}
        </ul>
        <Modal open={!!open} title={open ? `كشف حساب ${open.code} — ${open.name}` : ""} onClose={() => setOpen(null)}>
          {open && <Statement account={open.id} asOf={asOf} branch={branch} />}
        </Modal>
      </Card>
    )}</Loading>
  );
}

function Statement({ account, asOf, branch }: { account: string; asOf: string; branch: string | null }) {
  const from = useMemo(() => asOf.slice(0, 8) + "01", [asOf]);
  const r = useRead<AccountStatement>(() => glApi.statement(account, from, asOf, branch), [account, from, asOf, branch]);
  return (
    <Loading r={r}>{(d) => (
      <div>
        <p className="mb-2 text-xs text-ink-500">من <span dir="ltr">{d.from}</span> إلى <span dir="ltr">{d.to}</span> — الرصيد أول الفترة <Num v={d.opening_halalas} /></p>
        {d.lines.length === 0 ? <EmptyState icon={<BookOpen className="h-8 w-8" />} title="لا حركة في هذا الشهر" /> : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[32rem] text-sm" data-testid="statement-lines">
              <thead><tr className="border-b border-ink-100 text-xs text-ink-500"><th className="py-2 text-right font-medium">القيد</th><th className="py-2 text-right font-medium">البيان</th><th className="py-2 text-left font-medium">مدين</th><th className="py-2 text-left font-medium">دائن</th><th className="py-2 text-left font-medium">الرصيد</th></tr></thead>
              <tbody>{d.lines.map((l, i) => (
                <tr key={l.entry_id + i} className="border-b border-ink-50">
                  <td className="py-2 text-xs"><span className="font-mono" dir="ltr">{l.number}</span><span className="block text-ink-400" dir="ltr">{l.entry_date}</span></td>
                  <td className="py-2 text-ink-600">{l.description}</td>
                  <td className="py-2 text-left"><Num v={l.debit_halalas} /></td>
                  <td className="py-2 text-left"><Num v={l.credit_halalas} /></td>
                  <td className="py-2 text-left font-semibold"><Num v={l.balance_halalas} /></td>
                </tr>))}</tbody>
            </table>
          </div>
        )}
      </div>
    )}</Loading>
  );
}

function Months() {
  const [tick, setTick] = useState(0);
  const r = useRead<{ locked_months: string[]; today: string }>(() => glApi.months(), [tick]);
  const [month, setMonth] = useState(todayISO().slice(0, 7));
  const [pending, setPending] = useState<boolean | null>(null);
  return (
    <Loading r={r}>{(d) => {
      const locked = d.locked_months.includes(month);
      return (
        <Card>
          <p className="mb-3 text-sm text-ink-600">الشهر المقفل لا يُسجَّل فيه أي قيد: لا سند ولا مصروف ولا إلغاء ولا تعديل إقفال بتاريخه، من أي شاشة. يُفتح بسبب ويُسجَّل الفتح والقفل في السجل.</p>
          <div className="flex flex-wrap items-end gap-3">
            <Field label="الشهر"><input type="month" className="input" dir="ltr" max={todayISO().slice(0, 7)} value={month} onChange={(e) => e.target.value && setMonth(e.target.value)} aria-label="الشهر" /></Field>
            <span className={`inline-flex min-h-[44px] items-center gap-1 text-sm font-semibold ${locked ? "text-danger-600" : "text-success-600"}`} data-testid="month-state">{locked ? <><Lock className="h-4 w-4" /> مقفل</> : <><LockOpen className="h-4 w-4" /> مفتوح</>}</span>
            <button type="button" className={locked ? "btn-ghost min-h-[44px]" : "btn-primary min-h-[44px]"} onClick={() => setPending(!locked)}>{locked ? "فتح الشهر" : "قفل الشهر"}</button>
          </div>
          {d.locked_months.length > 0 && <p className="mt-3 text-xs text-ink-500">المقفلة: <span dir="ltr">{d.locked_months.join("، ")}</span></p>}
          <Modal open={pending !== null} title={pending ? `قفل ${month}` : `فتح ${month}`} onClose={() => setPending(null)}>
            {pending !== null && <LockForm month={month} lock={pending} onDone={() => { setPending(null); setTick((t) => t + 1); }} onCancel={() => setPending(null)} />}
          </Modal>
        </Card>
      );
    }}</Loading>
  );
}

function LockForm({ month, lock, onDone, onCancel }: { month: string; lock: boolean; onDone: () => void; onCancel: () => void }) {
  const [reason, setReason] = useState("");
  return (
    <ActionForm onSubmit={async () => { if (!reason.trim()) throw new Error("VALIDATION: reason"); await glApi.lockMonth(month + "-01", lock, reason.trim()); onDone(); }}>
      <p className="mb-3 text-sm text-ink-600">{lock ? "بعد القفل يُرفض كل قيد بتاريخ في هذا الشهر حتى يُفتح." : "بعد الفتح تُقبل القيود بتاريخ هذا الشهر من جديد."}</p>
      <ReasonInput value={reason} onChange={setReason} />
      <Submit label={lock ? "قفل" : "فتح"} onCancel={onCancel} />
    </ActionForm>
  );
}
