/**
 * «استعمال القدرات» (decision 55, 11.2; control G26; test D04): the owner's report from the audit log itself — for every
 * capability, the last successful use, the uses this week and in the window, who used it (people, the assistant,
 * automation, guests), the core-administration mark, and an honest «غير محسوم» where the log cannot tell (a capability
 * it sees only partly, or a window it does not cover). Nothing is removed by this report (decision 53).
 */
import { useState } from "react";
import { Activity, Info } from "lucide-react";
import { usageApi, type CapabilityUsage, type CapabilityUsageRow } from "../../lib/api";
import { SectionTitle, Card, Badge, Spinner, LoadErrorCard, EmptyState } from "../../components/ui";
import { ExportMenu } from "../../components/ExportMenu";
import { formatDateTime } from "../../lib/utils";
import { useAuth } from "../../lib/auth";
import { useEffect } from "react";
import { toArabicError } from "../../lib/api";
import type { ExportScope, ExportStatement, ExportTable } from "../../lib/exports";

const STATUS: Record<CapabilityUsageRow["status"], { label: string; cls: string; note: string }> = {
  used: { label: "مستخدم", cls: "bg-success-500/10 text-success-600", note: "استُعمل بنجاح ضمن النافذة" },
  idle: { label: "غير مستخدم", cls: "bg-ink-100 text-ink-600", note: "السجل يغطي النافذة كلها ولا استعمال فيها" },
  undetermined: { label: "غير محسوم", cls: "bg-warning-500/10 text-warning-600", note: "السجل لا يرى كل مسارات هذه القدرة، أو لا يغطي النافذة كلها؛ لا يُدّعى عدم الاستخدام" },
  unmeasured: { label: "غير مقيس", cls: "bg-ink-50 text-ink-400", note: "قراءة فقط: لا تُسجَّل في سجل الإجراءات" },
};
const COVERAGE: Record<string, string> = { full: "كاملة", partial: "جزئية", none: "لا تُسجَّل" };

export default function AdminUsage() {
  const { profile } = useAuth();
  const [weeks, setWeeks] = useState(4);
  const [data, setData] = useState<CapabilityUsage | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [tick, setTick] = useState(0);
  const [area, setArea] = useState("");
  useEffect(() => { let alive = true; setLoading(true); usageApi.capabilities(weeks).then((d) => { if (!alive) return; setData(d); setError(null); setLoading(false); }, (e) => { if (!alive) return; setError(toArabicError(e)); setLoading(false); }); return () => { alive = false; }; }, [weeks, tick]);

  const rows = (data?.rows ?? []).filter((r) => !area || r.area === area);
  const areas = [...new Set((data?.rows ?? []).map((r) => r.area))];
  const counts = (data?.rows ?? []).reduce((a, r) => ((a[r.status] = (a[r.status] ?? 0) + 1), a), {} as Record<string, number>);
  const statement = (scope: ExportScope): ExportStatement => ({ title: "استعمال القدرات", branch: "كل الفروع", period: data ? { from: data.window_start.slice(0, 10), to: data.generated_at.slice(0, 10) } : null, filters: [`النافذة: ${weeks} أسابيع`, ...(area ? [`المجال: ${area}`] : []), data?.log_covers_window ? "السجل يغطي النافذة" : "السجل لا يغطي النافذة كلها"], scope, generatedAt: data ? formatDateTime(data.generated_at) : "", by: profile?.full_name ?? null });
  const table = async (): Promise<ExportTable> => ({ columns: ["المجال", "القدرة", "إدارة أساسية", "التصنيف", "آخر استعمال ناجح", "هذا الأسبوع", "في النافذة", "أشخاص", "المساعد", "أتمتة", "ضيوف", "مرفوض", "تغطية السجل"], rows: rows.map((r) => [r.area, r.label, r.core ? "نعم" : "", STATUS[r.status].label, r.last_success_at ? formatDateTime(r.last_success_at) : "—", r.week_count, r.window_count, r.by.human, r.by.assistant, r.by.automation, r.by.guest, r.rejected, COVERAGE[r.coverage] ?? r.coverage]), widths: [14, 36, 10, 12, 18, 10, 10, 8, 8, 8, 8, 8, 12] });

  return (
    <div>
      <SectionTitle title="استعمال القدرات" subtitle="من سجل الإجراءات وحده: آخر استعمال ناجح لكل قدرة، وعدد مرات الأسبوع، ومن استعملها" action={<ExportMenu allOnly source={{ statement, table, pageCount: rows.length, total: rows.length }} disabled={!data} />} />
      <Card className="mb-4 flex flex-wrap items-center gap-3 p-3 text-sm">
        <span className="text-ink-600">النافذة</span>
        {[1, 4, 8, 13, 26].map((w) => <button key={w} type="button" onClick={() => setWeeks(w)} className={`rounded-lg px-3 py-1 text-xs font-medium ${weeks === w ? "bg-brand-600 text-white" : "bg-ink-100 text-ink-600"}`} data-testid={`weeks-${w}`}>{w === 1 ? "أسبوع" : `${w} أسابيع`}</button>)}
        <select className="input w-auto py-1 text-xs" value={area} onChange={(e) => setArea(e.target.value)} aria-label="المجال"><option value="">كل المجالات</option>{areas.map((a) => <option key={a} value={a}>{a}</option>)}</select>
        {loading && <Spinner className="h-4 w-4" />}
        {data && <span className="mr-auto text-xs text-ink-500" data-testid="usage-summary">مستخدم {counts.used ?? 0} · غير مستخدم {counts.idle ?? 0} · غير محسوم {counts.undetermined ?? 0} · غير مقيس {counts.unmeasured ?? 0}</span>}
      </Card>
      {data && (
        <div className={`mb-4 flex items-start gap-2 rounded-xl border p-3 text-xs ${data.log_covers_window ? "border-success-500/30 bg-success-500/5 text-success-700" : "border-warning-500/30 bg-warning-500/5 text-warning-700"}`} data-testid="usage-coverage" data-covered={data.log_covers_window ? "yes" : "no"}>
          <Info className="mt-0.5 h-4 w-4 shrink-0" />
          <div>
            <p className="font-medium">{data.log_covers_window ? `السجل يغطي النافذة كلها (منذ ${formatDateTime(data.log_since!)})` : data.log_since ? `السجل لا يغطي النافذة كلها (أول حدث ${formatDateTime(data.log_since)}${data.log_since > data.window_start ? "، بعد بداية النافذة" : "؛ أو جرى تفريغ للسجل داخل النافذة"})؛ ما لم يُستعمل يُصنَّف «غير محسوم» لا «غير مستخدم»` : "لا أحداث في السجل بعد"}</p>
            <p className="mt-0.5 opacity-80">{data.note}</p>
          </div>
        </div>
      )}
      {error && !data ? <LoadErrorCard message={error} onRetry={() => setTick((t) => t + 1)} /> : !data ? null : rows.length === 0 ? <EmptyState icon={<Activity className="h-10 w-10" />} title="لا قدرات في هذا المجال" /> : (
        <Card className="overflow-x-auto p-0">
          <table className="w-full text-sm" data-testid="usage-table">
            <thead className="bg-ink-50 text-xs text-ink-500"><tr>{["المجال", "القدرة", "التصنيف", "آخر استعمال ناجح", "هذا الأسبوع", "في النافذة", "من استعملها", "مرفوض", "تغطية السجل"].map((h) => <th key={h} className="whitespace-nowrap px-3 py-2 text-right font-medium">{h}</th>)}</tr></thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.code} className="border-t border-ink-50" data-testid="usage-row" data-code={r.code} data-status={r.status}>
                  <td className="px-3 py-2 text-xs text-ink-500">{r.area}</td>
                  <td className="px-3 py-2 text-ink-800">{r.label}{r.core && <Badge className="mr-1 bg-brand-50 text-brand-700" title="أساسيات الإدارة لا تُحذف ولا تُخفى بقلة الاستعمال (القرار 53)">إدارة أساسية</Badge>}</td>
                  <td className="px-3 py-2"><Badge className={STATUS[r.status].cls} title={STATUS[r.status].note}>{STATUS[r.status].label}</Badge></td>
                  <td className="whitespace-nowrap px-3 py-2 text-xs text-ink-600">{r.last_success_at ? formatDateTime(r.last_success_at) : "—"}</td>
                  <td className="px-3 py-2 text-center">{r.week_count}</td>
                  <td className="px-3 py-2 text-center">{r.window_count}</td>
                  <td className="px-3 py-2 text-xs text-ink-600">{r.window_count === 0 ? "—" : [r.by.human ? `أشخاص ${r.by.human}` : "", r.by.assistant ? `المساعد ${r.by.assistant}` : "", r.by.automation ? `أتمتة ${r.by.automation}` : "", r.by.guest ? `ضيوف ${r.by.guest}` : ""].filter(Boolean).join(" · ")}</td>
                  <td className="px-3 py-2 text-center text-xs text-ink-500">{r.rejected || "—"}</td>
                  <td className="px-3 py-2 text-xs text-ink-500">{COVERAGE[r.coverage] ?? r.coverage}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}
      {data && data.other_actions.length > 0 && (
        <Card className="mt-4">
          <h3 className="mb-1 text-sm font-semibold text-ink-700">أحداث خارج قائمة القدرات ({data.other_actions.length})</h3>
          <p className="mb-2 text-[11px] text-ink-400">إجراءات سُجّلت في النافذة ولا تتبع قدرةً في القائمة؛ تُعرض كما هي حتى لا يختفي شيء.</p>
          <div className="flex flex-wrap gap-1.5 text-xs">{data.other_actions.map((a) => <Badge key={a.action} className="bg-ink-100 text-ink-600" title={a.action}>{a.label} · {a.window_count}</Badge>)}</div>
        </Card>
      )}
    </div>
  );
}
