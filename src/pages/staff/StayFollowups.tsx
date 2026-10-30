/**
 * «متابعة الإقامات» — the supervisor's daily follow-up (0033, decisions 3, 8, 59): nights unpaid past their deadline,
 * departures not yet «مغلق» with what each still needs, and guests past their departure time. Read from
 * fn_stay_followups for the active branch; every row opens the stay, where the action is taken.
 */
import { Link } from "react-router-dom";
import { Moon, LogOut, Clock, CheckCircle2 } from "lucide-react";
import type { ReactNode } from "react";
import { stayApi, type StayFollowups as Followups } from "../../lib/api";
import { useBranchQuery } from "../../lib/useBranchQuery";
import { SectionTitle, LoadingScreen, Card, Badge, LoadErrorCard, ErrorBanner } from "../../components/ui";
import { BranchPicker } from "../../components/BranchPicker";
import { formatCurrency, formatDateTime } from "../../lib/utils";

const sar = (h: number) => formatCurrency(h / 100);
const NONE: Followups = { generated_at: "", overdue: [], departed_open: [], late_departures: [] };

export default function StayFollowups() {
  const q = useBranchQuery<Followups>((branchId) => stayApi.followups(branchId), [], NONE);
  if (q.loading) return <LoadingScreen />;
  if (q.error && !q.data.generated_at) return <div><SectionTitle title="متابعة الإقامات" action={<BranchPicker />} /><LoadErrorCard message={q.error} onRetry={q.reload} /></div>;
  const f = q.data;
  return (
    <div>
      <SectionTitle title="متابعة الإقامات" subtitle="ما ينتظر قرارًا اليوم: ليالٍ لم تُدفع بعد موعدها، ومغادرات لم تُغلق، ونزلاء تجاوزوا موعد المغادرة" action={<BranchPicker />} />
      {q.error && <div className="mb-4"><ErrorBanner message={q.error} /></div>}
      <div className="space-y-6">
        <Group icon={Moon} title="ليالٍ غير مدفوعة بعد موعدها" count={f.overdue.length} empty="لا ليالي متأخرة السداد." testId="followups-overdue">
          {f.overdue.map((x) => (
            <Row key={x.id} id={x.id} title={`${x.internal_ref} · وحدة ${x.room_number ?? "—"}`} sub={`${x.guest ?? "—"} · المغادرة ${x.check_out}${x.overdue_since ? ` · متأخرة منذ ${formatDateTime(x.overdue_since)}` : ""}`}
              side={<><span className="font-medium text-danger-600" dir="ltr">{sar(x.overdue_amount)}</span>{x.excused ? <Badge className="bg-ink-100 text-ink-500">سُجِّل سبب الاستمرار</Badge> : <Badge className="bg-danger-500/10 text-danger-600">التمديد والخدمات موقوفة</Badge>}</>} />
          ))}
        </Group>
        <Group icon={LogOut} title="غادر ولم يُغلق" count={f.departed_open.length} empty="كل المغادرات مغلقة." testId="followups-departed">
          {f.departed_open.map((x) => (
            <Row key={x.id} id={x.id} title={`${x.internal_ref} · وحدة ${x.room_number ?? "—"}`} sub={`${x.guest ?? "—"} · غادر ${x.checked_out_at ? formatDateTime(x.checked_out_at) : "—"} · ${x.missing.join(" · ") || "—"}`}
              side={<>{x.inspected ? <Badge className="bg-success-500/10 text-success-600">فُحصت</Badge> : <Badge className="bg-warning-500/10 text-warning-700">بلا فحص</Badge>}{x.deposit_balance > 0 && <span className="text-xs text-ink-500">تأمين <span dir="ltr">{sar(x.deposit_balance)}</span></span>}</>} />
          ))}
        </Group>
        <Group icon={Clock} title="تجاوزوا موعد المغادرة" count={f.late_departures.length} empty="لا أحد تجاوز موعد مغادرته." testId="followups-late">
          {f.late_departures.map((x) => (
            <Row key={x.id} id={x.id} title={`${x.internal_ref} · وحدة ${x.room_number ?? "—"}`} sub={`${x.guest ?? "—"} · كان موعد المغادرة ${x.check_out} الساعة ${x.departure_time}`}
              side={<Badge className="bg-warning-500/10 text-warning-700">مقيم بعد موعده</Badge>} />
          ))}
        </Group>
      </div>
    </div>
  );
}

function Group({ icon: Icon, title, count, empty, testId, children }: { icon: typeof Moon; title: string; count: number; empty: string; testId: string; children: ReactNode }) {
  return (
    <section data-testid={testId}>
      <h2 className="mb-2 flex items-center gap-2 text-sm font-semibold text-ink-700"><Icon className="h-4 w-4 text-brand-600" /> {title} <span className="text-ink-400">({count})</span></h2>
      {count === 0 ? <Card className="flex items-center gap-2 text-sm text-ink-500"><CheckCircle2 className="h-4 w-4 text-success-600" /> {empty}</Card> : <div className="space-y-2">{children}</div>}
    </section>
  );
}

function Row({ id, title, sub, side }: { id: string; title: string; sub: string; side: ReactNode }) {
  return (
    <Link to={`/staff/reservations/${id}`} className="block">
      <Card className="flex flex-wrap items-center justify-between gap-3 transition-all hover:border-brand-300 hover:shadow-md">
        <div className="min-w-0"><p className="font-mono text-sm font-semibold text-ink-800">{title}</p><p className="mt-0.5 text-xs text-ink-500">{sub}</p></div>
        <div className="flex flex-wrap items-center gap-2">{side}</div>
      </Card>
    </Link>
  );
}
