/**
 * «ملخص اليوم للموظفين» (decision 5): what each employee received and paid back on one day of the branch, by kind and
 * method — for the shift handover and the cash count. The supervisor sees their own vouchers only; the owner, a
 * manager and finance see everyone's. Read from fn_staff_day_summary (the branch's calendar day).
 */
import { useState } from "react";
import { ClipboardList } from "lucide-react";
import { stayApi, type DaySummary as Summary } from "../../lib/api";
import { useBranchQuery } from "../../lib/useBranchQuery";
import { SectionTitle, LoadingScreen, Card, EmptyState, LoadErrorCard, ErrorBanner } from "../../components/ui";
import { BranchPicker } from "../../components/BranchPicker";
import { PAYMENT_METHOD_LABELS, VOUCHER_KIND_LABELS, type PaymentMethod, type VoucherKind } from "../../lib/types";
import { formatCurrency, todayISO, COUNT } from "../../lib/utils";

const sar = (h: number) => formatCurrency(h / 100);
/** money that came in (+) or went back out (−); applying the deposit moves money between the guest's two balances */
const SIGN: Record<string, 1 | -1 | 0> = { receipt: 1, deposit: 1, refund: -1, deposit_refund: -1, deposit_apply: 0 };

export default function DaySummary() {
  const [date, setDate] = useState(todayISO());
  const q = useBranchQuery<Summary | null>((branchId) => stayApi.daySummary(branchId, date), [date], null);
  if (q.loading) return <LoadingScreen />;
  const sum = q.data;
  const staff = new Map<string, NonNullable<Summary>["rows"]>();
  for (const r of sum?.rows ?? []) { const k = r.staff_name; staff.set(k, [...(staff.get(k) ?? []), r]); }
  return (
    <div>
      <SectionTitle title="ملخص اليوم للموظفين" subtitle="ما قبضه كل موظف وما ردّه في يوم الفرع، بالنوع والطريقة" action={<BranchPicker />} />
      <div className="mb-4 flex flex-wrap items-end gap-3">
        <label className="text-sm text-ink-600">اليوم <input type="date" className="input mt-1" dir="ltr" value={date} max={todayISO()} onChange={(e) => setDate(e.target.value || todayISO())} aria-label="اليوم" /></label>
        {sum && !sum.everyone && <p className="text-xs text-ink-500">تظهر هنا سنداتك أنت؛ يرى المالك والمدير والمالية سندات الجميع.</p>}
      </div>
      {q.error && !sum ? <LoadErrorCard message={q.error} onRetry={q.reload} /> : q.error ? <ErrorBanner message={q.error} /> : null}
      {sum && staff.size === 0 && <EmptyState icon={<ClipboardList className="h-10 w-10" />} title="لا سندات في هذا اليوم" />}
      <div className="grid gap-4 lg:grid-cols-2" data-testid="day-summary">
        {[...staff.entries()].map(([name, rows]) => {
          const net = rows.reduce((a, r) => a + (SIGN[r.kind] ?? 0) * r.total, 0);
          return (
            <Card key={name}>
              <div className="mb-2 flex items-center justify-between"><h2 className="text-sm font-semibold text-ink-800">{name}</h2><span className="text-xs text-ink-500">الصافي <span dir="ltr" className="font-medium text-ink-800">{sar(net)}</span></span></div>
              <div className="divide-y divide-ink-50 text-sm">
                {rows.map((r, i) => (
                  <div key={i} className="flex items-center justify-between gap-3 py-1.5">
                    <span>{VOUCHER_KIND_LABELS[r.kind as VoucherKind] ?? r.kind} <span className="text-xs text-ink-400">· {r.method ? PAYMENT_METHOD_LABELS[r.method as PaymentMethod] ?? r.method : "من رصيد التأمين"} · {COUNT.voucher(r.count)}</span></span>
                    <span dir="ltr" className={(SIGN[r.kind] ?? 0) < 0 ? "text-danger-600" : ""}>{sar(r.total)}</span>
                  </div>
                ))}
              </div>
            </Card>
          );
        })}
      </div>
    </div>
  );
}
