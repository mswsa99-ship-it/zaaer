/**
 * «سجل الإجراءات» (decision 14, 10.3): readable Arabic names for every action, filters (day, branch, action, kind of
 * entity, who, source, result, category), real pages over the whole log, and exports that state the branch, the
 * period, the filters and the scope (decision 43, X09). Read through fn_audit_list: security rows reach the owner
 * only, the manager's and supervisor's rows are their branches', the details column is management's.
 */
import { useEffect, useMemo, useState } from "react";
import { useAuth } from "../../lib/auth";
import { useBranch } from "../../lib/branch";
import { listsApi, supportApi, toArabicError, type AuditList, type AuditListFilters, type AuditRow, type TraceLookup } from "../../lib/api";
import { AUDIT_ACTION_LABELS, AUDIT_ENTITY_LABELS } from "../../lib/auditLabels";
import { SectionTitle, Card, ErrorBanner, Spinner, DataState, Badge } from "../../components/ui";
import { ExportMenu } from "../../components/ExportMenu";
import { fetchAllPages } from "../../lib/api";
import { ScrollText, Search, AlertTriangle, CheckCircle2, X } from "lucide-react";
import { formatDateTime, todayISO } from "../../lib/utils";
import type { ExportScope, ExportStatement } from "../../lib/exports";

/** Where an operation came from (0026), in the employee's words. */
const SOURCE_AR: Record<string, string> = {
  "admin-app": "لوحة الإدارة", "staff-app": "شاشات الاستقبال", kiosk: "شاشة الخدمة الذاتية", "guest-app": "صفحة النزيل",
  screen: "الشاشة", system: "النظام", ops_assistant: "مساعد العمليات", ai_ops: "مساعد العمليات", whatsapp: "واتساب", scheduler: "مهمة مجدولة", migration: "ترحيل", legacy: "قبل التتبع",
};
const sourceLabel = (s: string | null) => (s ? SOURCE_AR[s] ?? s : "—");
const ACTOR_TYPE_AR: Record<string, string> = { staff: "موظف", guest: "ضيف", user: "مستخدم", system: "النظام" };
const PAGE = 50;
const EMPTY: AuditList = { total: 0, rows: [], limit: PAGE, offset: 0, tz: "Asia/Riyadh" };

export default function AdminAuditLogs() {
  const { profile } = useAuth();
  const { branches } = useBranch();
  const isOwner = profile?.role === "owner";
  const canLookup = isOwner || profile?.role === "manager";
  const [f, setF] = useState<AuditListFilters>({ from: todayISO(), to: todayISO() });
  const [page, setPage] = useState(0);
  const [data, setData] = useState<AuditList>(EMPTY);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [open, setOpen] = useState<AuditRow | null>(null);

  useEffect(() => {
    let alive = true; setLoading(true);
    listsApi.audit({ ...f, limit: PAGE, offset: page * PAGE }).then((d) => { if (!alive) return; setData(d); setError(null); setLoading(false); }, (e) => { if (!alive) return; setError(toArabicError(e)); setLoading(false); });
    return () => { alive = false; };
  }, [f, page, tick]);

  const set = (k: keyof AuditListFilters, v: string | boolean | undefined) => { setPage(0); setF((x) => { const n: Record<string, unknown> = { ...x, [k]: v }; if (v === "" || v === undefined || v === false) delete n[k]; return n as AuditListFilters; }); };
  const pages = Math.max(1, Math.ceil(data.total / PAGE));
  const actionOptions = useMemo(() => Object.entries(AUDIT_ACTION_LABELS).sort((a, b) => a[1].localeCompare(b[1], "ar")), []);
  const entityOptions = useMemo(() => Object.entries(AUDIT_ENTITY_LABELS).sort((a, b) => a[1].localeCompare(b[1], "ar")), []);
  const branchName = (id: string | undefined) => branches.find((b) => b.id === id)?.name_ar ?? null;

  const words = useMemo(() => {
    const w: string[] = [];
    if (f.branch_id) w.push(`الفرع: ${branchName(f.branch_id) ?? f.branch_id}`);
    if (f.action) w.push(`الإجراء: ${f.action_prefix ? `يبدأ بـ ${f.action}` : AUDIT_ACTION_LABELS[f.action] ?? f.action}`);
    if (f.entity_type) w.push(`الكيان: ${AUDIT_ENTITY_LABELS[f.entity_type] ?? f.entity_type}`);
    if (f.category) w.push(f.category === "security" ? "الفئة: أمني" : "الفئة: تشغيلي");
    if (f.result) w.push(f.result === "rejected" ? "النتيجة: مرفوض" : "النتيجة: ناجح");
    if (f.source) w.push(`المصدر: ${sourceLabel(f.source)}`);
    if (f.actor_id) w.push(`المنفّذ: ${data.rows.find((r) => r.actor_id === f.actor_id)?.actor_name ?? f.actor_id}`);
    if (f.entity_id) w.push(`المعرّف: ${f.entity_id}`);
    if (f.correlation_id) w.push(`رمز التتبع: ${f.correlation_id}`);
    if (f.q) w.push(`بحث: ${f.q}`);
    return w;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [f, branches, data.rows]);

  const COLS = ["الوقت", "الإجراء", "الكيان", "المرجع", "المنفّذ", "الفرع", "السبب", "المصدر", "النتيجة", "رمز التتبع"];
  const rowOut = (r: AuditRow) => [formatDateTime(r.created_at), r.action_label, r.entity_label, r.entity_ref ?? "", r.actor_name ?? "", r.branch_name ?? "", r.reason ?? "", sourceLabel(r.source), r.result === "rejected" ? "مرفوض" : "ناجح", r.correlation_id ?? ""];
  const statement = (scope: ExportScope): ExportStatement => ({ title: "سجل الإجراءات", branch: f.branch_id ? branchName(f.branch_id) : "كل الفروع المخوّلة", period: { from: f.from, to: f.to }, filters: words, scope, generatedAt: formatDateTime(new Date().toISOString()), by: profile?.full_name ?? null });
  const table = async (scope: ExportScope) => {
    const rows = scope.kind === "page" ? data.rows : (await fetchAllPages((limit, offset) => listsApi.audit({ ...f, limit, offset }), 500)).rows;
    return { columns: COLS, rows: rows.map(rowOut), widths: [18, 28, 14, 18, 18, 18, 30, 14, 10, 16] };
  };

  return (
    <div>
      <SectionTitle title="سجل الإجراءات" subtitle={`${data.total} حدث مطابق — من نفّذ كل عملية ومتى ومن أين ولماذا${isOwner ? "" : " (الأحداث الأمنية للمالك وحده)"}`} action={<ExportMenu source={{ statement, table, pageCount: data.rows.length, total: data.total }} />} />
      {canLookup && <TraceSearch />}
      <Card className="mb-4 p-3">
        <div className="flex flex-wrap items-center gap-2 text-xs text-ink-600">
          <label className="flex items-center gap-1.5">من <input type="date" className="input w-auto py-1 text-xs" dir="ltr" value={f.from ?? ""} onChange={(e) => set("from", e.target.value)} aria-label="من" /></label>
          <label className="flex items-center gap-1.5">إلى <input type="date" className="input w-auto py-1 text-xs" dir="ltr" value={f.to ?? ""} onChange={(e) => set("to", e.target.value)} aria-label="إلى" /></label>
          <button type="button" className="btn-ghost py-1 text-xs" onClick={() => { setPage(0); setF((x) => ({ ...x, from: todayISO(), to: todayISO() })); }}>اليوم</button>
          <button type="button" className="btn-ghost py-1 text-xs" onClick={() => { setPage(0); setF((x) => { const n = { ...x }; delete n.from; delete n.to; return n; }); }}>كل الفترات</button>
          <select className="input w-auto py-1 text-xs" value={f.branch_id ?? ""} onChange={(e) => set("branch_id", e.target.value)} aria-label="الفرع"><option value="">كل الفروع المخوّلة</option>{branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}</select>
          <select className="input w-auto max-w-[16rem] py-1 text-xs" value={f.action_prefix ? "" : f.action ?? ""} onChange={(e) => { set("action_prefix", undefined); set("action", e.target.value); }} aria-label="الإجراء"><option value="">كل الإجراءات</option>{actionOptions.map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
          <select className="input w-auto py-1 text-xs" value={f.entity_type ?? ""} onChange={(e) => set("entity_type", e.target.value)} aria-label="الكيان"><option value="">كل الكيانات</option>{entityOptions.map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
          {isOwner && <select className="input w-auto py-1 text-xs" value={f.category ?? ""} onChange={(e) => set("category", e.target.value)} aria-label="الفئة"><option value="">تشغيلي وأمني</option><option value="business">تشغيلي</option><option value="security">أمني</option></select>}
          <select className="input w-auto py-1 text-xs" value={f.result ?? ""} onChange={(e) => set("result", e.target.value)} aria-label="النتيجة"><option value="">كل النتائج</option><option value="success">ناجح</option><option value="rejected">مرفوض</option></select>
          <select className="input w-auto py-1 text-xs" value={f.source ?? ""} onChange={(e) => set("source", e.target.value)} aria-label="المصدر"><option value="">كل المصادر</option>{Object.entries(SOURCE_AR).filter(([k]) => k !== "ai_ops").map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
          <div className="relative"><Search className="pointer-events-none absolute right-2.5 top-2 h-3.5 w-3.5 text-ink-400" /><input className="input w-52 py-1 pr-8 text-xs" placeholder="اسم الإجراء / رمز التتبع / المعرّف" value={f.q ?? ""} onChange={(e) => set("q", e.target.value)} aria-label="بحث" /></div>
          {(f.actor_id || f.entity_id || f.correlation_id) && <button type="button" className="btn-ghost py-1 text-xs text-ink-500" onClick={() => { set("actor_id", undefined); set("entity_id", undefined); set("correlation_id", undefined); }}><X className="h-3 w-3" /> إلغاء تثبيت المنفّذ/المعرّف</button>}
        </div>
        {words.length > 0 && <p className="mt-2 text-[11px] text-ink-400">المرشحات: {words.join(" · ")}</p>}
      </Card>
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      <DataState loading={loading && data.rows.length === 0} error={!loading && data.rows.length === 0 ? error : null} empty={!loading && !error && data.rows.length === 0} onRetry={() => setTick((t) => t + 1)} emptyIcon={<ScrollText className="h-10 w-10" />} emptyTitle="لا أحداث مطابقة" emptyDescription="وسّع الفترة أو خفف المرشحات.">
        <Card className="overflow-x-auto p-0">
          <table className="w-full text-sm" data-testid="audit-table">
            <thead className="bg-ink-50 text-xs text-ink-500"><tr>{COLS.map((h) => <th key={h} className="whitespace-nowrap px-3 py-2 text-right font-medium">{h}</th>)}</tr></thead>
            <tbody>
              {data.rows.map((l) => (
                <tr key={l.id} className={`border-t border-ink-50 hover:bg-ink-50/60 ${l.category === "security" ? "bg-warning-500/5" : ""}`} data-testid="audit-row" onClick={() => setOpen(l)}>
                  <td className="whitespace-nowrap px-3 py-2 text-xs text-ink-500">{formatDateTime(l.created_at)}</td>
                  <td className="px-3 py-2 font-medium text-ink-700" data-testid="audit-action">{l.action_label}{l.category === "security" && <Badge className="mr-1 bg-warning-500/10 text-warning-600">أمني</Badge>}</td>
                  <td className="px-3 py-2 text-ink-600">{l.entity_label}</td>
                  <td className="px-3 py-2 font-mono text-xs text-ink-600">{l.entity_ref ?? "—"}{l.entity_id && <button type="button" className="mr-1 text-[10px] text-brand-600 hover:underline" onClick={(e) => { e.stopPropagation(); set("entity_id", l.entity_id ?? undefined); }} title="كل أحداث هذا الكيان">تتبّع</button>}</td>
                  <td className="px-3 py-2 text-ink-600">{l.actor_name ?? "—"}{l.actor_id && <button type="button" className="mr-1 text-[10px] text-brand-600 hover:underline" onClick={(e) => { e.stopPropagation(); set("actor_id", l.actor_id ?? undefined); }} title="كل ما نفّذه">فقط هو</button>}</td>
                  <td className="px-3 py-2 text-xs text-ink-500">{l.branch_name ?? "—"}</td>
                  <td className="max-w-[16rem] truncate px-3 py-2 text-xs text-ink-600" title={l.reason ?? ""}>{l.reason ?? "—"}</td>
                  <td className="px-3 py-2 text-xs text-ink-500">{sourceLabel(l.source)}</td>
                  <td className="px-3 py-2 text-xs">{l.result === "rejected" ? <Badge className="bg-danger-500/10 text-danger-600">مرفوض</Badge> : <span className="text-success-600">ناجح</span>}</td>
                  <td className="px-3 py-2 font-mono text-xs text-ink-400" dir="ltr">{l.correlation_id ?? "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <div className="flex items-center justify-between border-t border-ink-50 px-3 py-2 text-xs text-ink-500">
            <span>صفحة {page + 1} من {pages} · {data.total} حدث{loading && <Spinner className="mr-2 inline h-3 w-3" />}</span>
            <div className="flex gap-2"><button disabled={page === 0} onClick={() => setPage(page - 1)} className="btn-ghost px-2 py-1 text-xs">السابق</button><button disabled={page + 1 >= pages} onClick={() => setPage(page + 1)} className="btn-ghost px-2 py-1 text-xs">التالي</button></div>
          </div>
        </Card>
      </DataState>
      {open && (
        <div className="fixed inset-0 z-50 flex items-end justify-center bg-ink-900/50 p-0 sm:items-center sm:p-4" onMouseDown={(e) => { if (e.target === e.currentTarget) setOpen(null); }}>
          <div className="card max-h-[92vh] w-full overflow-y-auto p-5 sm:max-w-2xl" role="dialog" aria-modal="true" data-testid="audit-detail">
            <div className="mb-3 flex items-center justify-between"><h3 className="text-base font-semibold text-ink-800">{open.action_label}</h3><button onClick={() => setOpen(null)} className="rounded-lg p-1 text-ink-400 hover:bg-ink-50" aria-label="إغلاق"><X className="h-4 w-4" /></button></div>
            <dl className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-sm">
              <dt className="text-ink-400">الوقت</dt><dd>{formatDateTime(open.created_at)}</dd>
              <dt className="text-ink-400">الكيان</dt><dd>{open.entity_label}{open.entity_ref ? ` · ${open.entity_ref}` : ""}</dd>
              <dt className="text-ink-400">المنفّذ</dt><dd>{open.actor_name ?? "—"} <span className="text-xs text-ink-400">({ACTOR_TYPE_AR[open.actor_type ?? ""] ?? open.actor_type ?? "—"})</span></dd>
              <dt className="text-ink-400">الفرع</dt><dd>{open.branch_name ?? "—"}</dd>
              <dt className="text-ink-400">المصدر</dt><dd>{sourceLabel(open.source)}</dd>
              <dt className="text-ink-400">النتيجة</dt><dd>{open.result === "rejected" ? "مرفوض" : "ناجح"} · {open.category === "security" ? "أمني" : "تشغيلي"}</dd>
              <dt className="text-ink-400">رمز التتبع</dt><dd className="font-mono text-xs" dir="ltr">{open.correlation_id ?? "—"}</dd>
              <dt className="text-ink-400">السبب</dt><dd>{open.reason ?? "—"}</dd>
              <dt className="text-ink-400">الرمز التقني</dt><dd className="font-mono text-xs" dir="ltr">{open.action}</dd>
            </dl>
            {open.details && <details className="mt-3 text-xs" open><summary className="cursor-pointer text-ink-500">ما قبل وما بعد (التفاصيل كما سُجّلت؛ الأرقام الحساسة مقنّعة)</summary><pre className="mt-2 max-h-64 overflow-auto rounded-xl bg-ink-50 p-3 text-[11px] leading-relaxed" dir="ltr">{JSON.stringify(open.details, null, 2)}</pre></details>}
          </div>
        </div>
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
                {events.map((ev, i) => <li key={i}><span className="font-medium text-ink-700">{AUDIT_ACTION_LABELS[ev.action] ?? ev.action}</span> · {ev.entity_type ? AUDIT_ENTITY_LABELS[ev.entity_type] ?? ev.entity_type : "—"} · {ev.actor_name ?? "النظام"} · {sourceLabel(ev.source)} · {formatDateTime(ev.created_at)}</li>)}
              </ul>
            </div>
          )}
          {!f && events.length === 0 && <p className="text-sm text-ink-500">لا يوجد شيء بالرمز {result.code}. تأكد من الرمز كما ظهر للموظف؛ العمليات التي تقرأ فقط لا تُسجَّل.</p>}
        </div>
      )}
    </Card>
  );
}
