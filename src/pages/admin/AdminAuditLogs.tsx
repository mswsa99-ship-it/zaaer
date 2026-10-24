import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../lib/auth";
import { supportApi, toArabicError, type TraceLookup } from "../../lib/api";
import { SectionTitle, LoadingScreen, Card, EmptyState, ErrorBanner, LoadErrorCard, Spinner } from "../../components/ui";
import { ScrollText, Search, AlertTriangle, CheckCircle2 } from "lucide-react";
import { formatDateTime } from "../../lib/utils";

interface AuditRow {
  id: string; action: string; entity_type: string | null; created_at: string; actor_id: string | null;
  correlation_id: string | null; source: string | null; result: string | null;
}

/** Where an operation came from (0026), in the employee's words. */
const SOURCE_AR: Record<string, string> = {
  "admin-app": "لوحة الإدارة", "staff-app": "شاشات الاستقبال", kiosk: "شاشة الخدمة الذاتية", "guest-app": "صفحة النزيل",
  screen: "الشاشة", system: "النظام", ai_ops: "مساعد العمليات", whatsapp: "واتساب", scheduler: "مهمة مجدولة",
};
const sourceLabel = (s: string | null) => (s ? SOURCE_AR[s] ?? s : "—");

export default function AdminAuditLogs() {
  const { profile } = useAuth();
  const canLookup = profile?.role === "owner" || profile?.role === "manager";
  const [logs, setLogs] = useState<AuditRow[]>([]);
  const [names, setNames] = useState<Map<string, string>>(new Map());
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data, error: e } = await supabase.from("audit_events")
        .select("id, action, entity_type, created_at, actor_id, correlation_id, source, result")
        .order("created_at", { ascending: false }).limit(100);
      if (!alive) return;
      if (e) { setError(toArabicError(e)); setLoading(false); return; }
      const rows = (data as AuditRow[]) ?? [];
      const ids = [...new Set(rows.map((r) => r.actor_id).filter((x): x is string => !!x))];
      const staff = ids.length ? await supabase.from("staff_profiles").select("id, full_name").in("id", ids) : { data: [] };
      if (!alive) return;
      setNames(new Map(((staff.data ?? []) as { id: string; full_name: string }[]).map((s) => [s.id, s.full_name])));
      setLogs(rows); setError(null); setLoading(false);
    })();
    return () => { alive = false; };
  }, [tick]);

  if (loading) return <LoadingScreen />;

  return (
    <div>
      <SectionTitle title="سجل الإجراءات" subtitle={`${logs.length} حدث — يوضح من نفّذ كل عملية ومتى ومن أين`} />
      {canLookup && <TraceSearch />}
      {error && logs.length > 0 && <div className="mb-4"><ErrorBanner message={error} /></div>}
      {error && logs.length === 0 ? <LoadErrorCard message={error} onRetry={() => { setLoading(true); setTick((t) => t + 1); }} /> : logs.length === 0 ? (
        <EmptyState icon={<ScrollText className="h-10 w-10" />} title="لا توجد أحداث مسجّلة" description="تظهر هنا كل عمليات الاعتماد والرفض والتسليم." />
      ) : (
        <Card className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead><tr className="border-b border-ink-100 text-xs text-ink-400">
              <th className="py-2 text-right font-medium">الإجراء</th>
              <th className="py-2 text-right font-medium">الكيان</th>
              <th className="py-2 text-right font-medium">المنفّذ</th>
              <th className="py-2 text-right font-medium">المصدر</th>
              <th className="py-2 text-right font-medium">رمز التتبع</th>
              <th className="py-2 text-right font-medium">الوقت</th>
            </tr></thead>
            <tbody>
              {logs.map((l) => (
                <tr key={l.id} className="border-b border-ink-50">
                  <td className="py-2.5 font-medium text-ink-700">{l.action}</td>
                  <td className="py-2.5 text-ink-500">{l.entity_type ?? "—"}</td>
                  <td className="py-2.5 text-ink-600">{l.actor_id ? names.get(l.actor_id) ?? "—" : "النظام"}</td>
                  <td className="py-2.5 text-xs text-ink-500">{sourceLabel(l.source)}</td>
                  <td className="py-2.5 font-mono text-xs text-ink-500" dir="ltr">{l.correlation_id ?? "—"}</td>
                  <td className="py-2.5 text-xs text-ink-400">{formatDateTime(l.created_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}
    </div>
  );
}

/** Support (decision 60): the employee reads the code next to a failure message; the owner or manager finds it here. */
function TraceSearch() {
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<{ code: string; data: TraceLookup } | null>(null);

  async function search(e: React.FormEvent) {
    e.preventDefault();
    if (!code.trim()) return;
    setBusy(true); setError(null); setResult(null);
    try { setResult({ code: code.trim(), data: await supportApi.lookupTrace(code) }); }
    catch (err) { setError(toArabicError(err)); }
    finally { setBusy(false); }
  }

  const f = result?.data.failure;
  const events = result?.data.events ?? [];
  return (
    <Card className="mb-4">
      <form onSubmit={search} className="flex flex-wrap items-end gap-2">
        <label className="min-w-0 flex-1">
          <span className="label">ابحث برمز التتبع</span>
          <input value={code} onChange={(e) => setCode(e.target.value)} className="input font-mono" dir="ltr" placeholder="K7Q2M9XA" aria-label="رمز التتبع" />
        </label>
        <button type="submit" disabled={busy || !code.trim()} className="btn-primary text-sm">{busy ? <Spinner className="h-4 w-4" /> : <Search className="h-4 w-4" />} بحث</button>
      </form>
      <p className="mt-1.5 text-[11px] text-ink-400">الرمز يظهر للموظف بجانب رسالة أي عملية تعذّر تنفيذها: «رمز التتبع: …». يبيّن هنا ما حدث دون أي بيانات شخصية.</p>
      {error && <div className="mt-3"><ErrorBanner message={error} /></div>}
      {result && (
        <div className="mt-3 space-y-2" data-testid="trace-result">
          {f && (
            <div className="rounded-xl border border-danger-500/30 bg-danger-500/5 p-3 text-sm">
              <p className="flex items-center gap-1.5 font-medium text-danger-600"><AlertTriangle className="h-4 w-4" /> عملية تعذّر تنفيذها</p>
              <p className="mt-1 text-ink-700">{toArabicError(new Error(f.error_code))}</p>
              <p className="mt-1 text-xs text-ink-500">
                <span>رمز الخطأ: </span><span className="font-mono" dir="ltr">{f.error_code}</span>
                {f.context && <> · <span>العملية: </span><span className="font-mono" dir="ltr">{f.context}</span></>}
                {" · "}{f.staff_name ?? "—"} · {formatDateTime(f.created_at)}
              </p>
            </div>
          )}
          {events.length > 0 && (
            <div className="rounded-xl border border-success-500/30 bg-success-500/5 p-3 text-sm">
              <p className="flex items-center gap-1.5 font-medium text-success-600"><CheckCircle2 className="h-4 w-4" /> ما سجّلته العملية ({events.length})</p>
              <ul className="mt-1 space-y-0.5 text-xs text-ink-600">
                {events.map((ev, i) => <li key={i}><span className="font-medium text-ink-700">{ev.action}</span> · {ev.entity_type ?? "—"} · {ev.actor_name ?? "النظام"} · {sourceLabel(ev.source)} · {formatDateTime(ev.created_at)}</li>)}
              </ul>
            </div>
          )}
          {!f && events.length === 0 && <p className="text-sm text-ink-500">لا يوجد شيء بالرمز {result.code}. تأكد من الرمز كما ظهر للموظف؛ العمليات التي تقرأ فقط لا تُسجَّل.</p>}
        </div>
      )}
    </Card>
  );
}
