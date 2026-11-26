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
import { DateRangePicker } from "../../components/DateRangePicker";
import { mergeRows } from "../../lib/allBranches";

const sar = (h: number) => formatCurrency(h / 100);
/** money that came in (+) or went back out (−); applying the deposit moves money between the guest's two balances */
const SIGN: Record<string, 1 | -1 | 0> = { receipt: 1, deposit: 1, refund: -1, deposit_refund: -1, deposit_apply: 0 };
/** recorded «آجل عبر المنصة»: the platform holds it, nothing moved in the drawer */
const PLATFORM = ["ota_deferred", "booking_platform"];

export default function DaySummary() {
  const [from, setFrom] = useState(todayISO());
  const [to, setTo] = useState(todayISO());
  const q = useBranchQuery<Summary | null>((branchId) => stayApi.daySummaryRange(branchId, from, to), [from, to], null, {
    // «جميع الفروع» (owner): each employee's rows from every branch add up by kind and method
    merge: (parts) => {
      const ok = parts.filter((x): x is NonNullable<Summary> => !!x);
      if (ok.length === 0) return null;
      return { ...ok[0], everyone: ok.every((x) => x.everyone), rows: mergeRows(ok.map((x) => x.rows as unknown as Record<string, unknown>[]), (r) => [r.staff_name, r.kind, r.method].join("|"), ["count", "total"]) as unknown as NonNullable<Summary>["rows"] };
    },
  });
  if (q.loading) return <LoadingScreen />;
  const sum = q.data;
  const staff = new Map<string, NonNullable<Summary>["rows"]>();
  for (const r of sum?.rows ?? []) { const k = r.staff_name; staff.set(k, [...(staff.get(k) ?? []), r]); }
  return (
    <div>
      <SectionTitle title="ملخص اليوم للموظفين" subtitle="ما قبضه كل موظف وما ردّه في يوم الفرع، بالنوع والطريقة" action={<BranchPicker allowAll />} />
      <div className="mb-4 flex flex-wrap items-end gap-3">
        <div className="text-sm text-ink-600">اليوم أو الفترة <DateRangePicker className="mt-1" label="اليوم أو الفترة: يوم أو من تاريخ إلى تاريخ" from={from} to={to} max={todayISO()} onChange={(a, b) => { const f = a || todayISO(); setFrom(f); setTo(b || f); }} /></div>
        {sum && !sum.everyone && <p className="text-xs text-ink-500">تظهر هنا سنداتك أنت؛ يرى المالك والمدير والمالية سندات الجميع.</p>}
      </div>
      {q.error && !sum ? <LoadErrorCard message={q.error} onRetry={q.reload} /> : q.error ? <ErrorBanner message={q.error} /> : null}
      {sum && staff.size === 0 && <EmptyState icon={<ClipboardList className="h-10 w-10" />} title={from === to ? "لا سندات في هذا اليوم" : "لا سندات في هذه الفترة"} />}
      <div className="grid gap-4 lg:grid-cols-2" data-testid="day-summary">
        {[...staff.entries()].map(([name, rows]) => {
          // OWNER-04: the drawer's movement — deposits in and out included, what a platform holds left out
          const net = rows.reduce((a, r) => a + (PLATFORM.includes(r.method ?? "") ? 0 : (SIGN[r.kind] ?? 0) * r.total), 0);
          const cash = rows.reduce((a, r) => a + (r.method === "cash" ? (SIGN[r.kind] ?? 0) * r.total : 0), 0);   // finance review: the all-methods net is not the cash in the drawer
          return (
            <Card key={name}>
              <div className="mb-2 flex items-center justify-between"><h2 className="text-sm font-semibold text-ink-800">{name}</h2><span className="text-end text-xs text-ink-500">صافي الحركة (نقد وشبكة وتحويل، يشمل التأمين) <span dir="ltr" className="font-medium text-ink-800">{sar(net)}</span><br />منه نقدًا في الصندوق <span dir="ltr" data-testid="day-summary-cash" className="font-medium">{sar(cash)}</span></span></div>
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
