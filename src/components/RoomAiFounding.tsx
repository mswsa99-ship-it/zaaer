/**
 * Room AI, phase 1: the founding half of the floating assistant. It proposes defaults for a founding step, lets the
 * user edit them, writes only what the user confirms, then reviews the hotel for gaps. Drafts live in this component's
 * state (a session draft); nothing is written before the confirm button.
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link, useLocation } from "react-router-dom";
import { Sparkles, Check, ShieldAlert } from "lucide-react";
import { useBranch } from "../lib/branch";
import { useAuth } from "../lib/auth";
import { ROOM_AI_CHANGED } from "../lib/useBranchQuery";
import { toArabicError } from "../lib/api";
import { STEP_FIELDS, STEP_INFO, STEP_ORDER } from "../lib/roomAi/defaults";
import { alreadyExists, getRoomAiProvider, uniqueProblems } from "../lib/roomAi/provider";
import { createOpGuard, runBatch, type Outcome } from "../lib/roomAi/batch";
import { loadSnapshot, writeItem } from "../lib/roomAi/write";
import { emptySnapshot, type DraftItem, type Finding, type FieldSpec, type Snapshot, type StepId } from "../lib/roomAi/types";
import "../roomaiFounding.css";

const SEV: Record<Finding["severity"], string> = { risk: "خطر", warn: "تنبيه", note: "ملاحظة" };
const stepCount = (s: Snapshot, step: StepId) => {
  const l = (a: { archived_at: string | null }[]) => a.filter((x) => !x.archived_at).length;
  return step === "policies" ? l(s.policies) : step === "structure" ? l(s.blocks) : step === "categories" ? l(s.categories) : step === "facilities" ? l(s.facilities) : l(s.taskTypes);
};

function FieldInput({ f, value, onChange }: { f: FieldSpec; value: DraftItem["values"][string]; onChange: (v: string | number | boolean | null) => void }) {
  if (f.type === "check") return <label className="rfo-row"><input type="checkbox" checked={!!value} onChange={(e) => onChange(e.target.checked)} /> {f.label}</label>;
  return (
    <label className="rfo-label">{f.label}
      {f.type === "textarea" ? <textarea className="rfo-in" rows={f.key === "content_ar" ? 4 : 2} value={String(value ?? "")} onChange={(e) => onChange(e.target.value)} />
        : f.type === "select" ? <select className="rfo-in" value={String(value ?? "")} onChange={(e) => onChange(e.target.value)}>{Object.entries(f.options ?? {}).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
        : f.type === "number" || f.type === "money_sar" ? <input className="rfo-in" type="number" inputMode="decimal" min={0} dir="ltr" placeholder={f.type === "money_sar" ? "اكتب المبلغ" : undefined} value={value == null ? "" : String(value)} onChange={(e) => onChange(e.target.value === "" ? null : Number(e.target.value))} />
        : <input className="rfo-in" dir={f.ltr ? "ltr" : undefined} value={String(value ?? "")} onChange={(e) => onChange(e.target.value)} />}
      {f.hint && <span className="rfo-muted">{f.hint}</span>}
    </label>
  );
}

export function RoomAiFounding() {
  const { branch, branchId } = useBranch();
  const { profile } = useAuth();
  const { pathname } = useLocation();
  const initial = STEP_ORDER.find((s) => pathname.startsWith(STEP_INFO[s].path)) ?? "policies";
  const [step, setStep] = useState<StepId>(initial);
  const [snap, setSnap] = useState<Snapshot>(emptySnapshot());
  const [loadErr, setLoadErr] = useState<string | null>(null);
  const [drafts, setDrafts] = useState<DraftItem[] | null>(null);
  const [answers, setAnswers] = useState<Record<string, string | number>>({ floors: 3 });
  const [busy, setBusy] = useState(false);
  const [open, setOpen] = useState<string | null>(null);
  const [results, setResults] = useState<Record<string, Outcome>>({});
  const [batchNote, setBatchNote] = useState<string | null>(null);
  const [findings, setFindings] = useState<Finding[] | null>(null);
  const provider = getRoomAiProvider();
  // The branch an operation started for is pinned: a late answer or a running batch checks it against the live branch.
  const branchRef = useRef<string | null>(branchId);
  branchRef.current = branchId;
  const guard = useRef(createOpGuard()).current;   // latest-wins: propose / review / reads
  const lock = useRef({ busy: false }).current;    // synchronous: a double click cannot start two batches

  /** Fresh hotel-scoped read of ONE branch. Null when it failed or the user has moved to another branch meanwhile. */
  const read = useCallback(async (b: NonNullable<typeof branch>): Promise<Snapshot | null> => {
    try {
      const s = await loadSnapshot({ id: b.id, name_ar: b.name_ar, check_in_time: b.check_in_time, check_out_time: b.check_out_time });
      if (branchRef.current !== b.id) return null;
      setSnap(s); setLoadErr(null); return s;
    } catch (e) { if (branchRef.current === b.id) setLoadErr(toArabicError(e)); return null; }
  }, []);
  // a branch change is a new context: drafts, results, review and anything in flight for the old branch are dropped
  useEffect(() => { guard.bump(); setBusy(false); setDrafts(null); setResults({}); setFindings(null); setOpen(null); setBatchNote(null); setSnap(emptySnapshot()); setLoadErr(null); if (branch) void read(branch); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { guard.bump(); setBusy(false); setDrafts(null); setResults({}); setOpen(null); setBatchNote(null); }, [step]); // eslint-disable-line react-hooks/exhaustive-deps

  const fields = STEP_FIELDS[step];
  const isDone = (id: string) => results[id]?.state === "ok" || results[id]?.state === "skipped";
  const ready = useMemo(() => (drafts ?? []).filter((d) => d.include && !isDone(d.id) && uniqueProblems(step, d.values).length === 0), [drafts, results, step]); // eslint-disable-line react-hooks/exhaustive-deps
  const canWrite = profile && (profile.role === "owner" || profile.role === "manager");

  async function propose() {
    if (!branch || busy) return;
    const token = guard.next(); const b = branch; const st = step;
    setBusy(true); setResults({}); setBatchNote(null);
    try {
      const s = await read(b);
      if (!guard.isCurrent(token) || branchRef.current !== b.id) return;
      if (!s) { setDrafts(null); return; }   // no read, no suggestion: never propose from a stale snapshot
      const list = await provider.propose(st, { snapshot: s, answers });
      if (guard.isCurrent(token) && branchRef.current === b.id) setDrafts(list.map((d) => ({ ...d, include: false })));
    } finally { if (guard.isCurrent(token)) setBusy(false); }
  }
  async function applyConfirmed() {
    if (!branch || !branchId || !profile || !canWrite || lock.busy) return;
    const b = branch; const st = step; const items = ready; const who = profile;
    guard.bump(); setBusy(true); setBatchNote(null);
    try {
      const end = await runBatch({
        items, pinnedBranch: b.id, currentBranch: () => branchRef.current, lock,
        refresh: () => read(b),
        exists: (d, s) => alreadyExists(st, d.values, s),
        write: (d, s) => writeItem(st, d, { branchId: b.id, organizationId: who.organization_id, userId: who.id, snapshot: s }),
        onResult: (id, o) => { if (branchRef.current === b.id) setResults((r) => ({ ...r, [id]: o })); },
      });
      if (end === "branch-changed") setBatchNote("تغيّر الفرع أثناء التنفيذ. أُوقف الباقي ولم يُكتب شيء للفرع الجديد.");
      if (end === "no-snapshot") setBatchNote("تعذّرت قراءة الفرع. أعد المحاولة بعد أن يظهر الفرع سليمًا.");
    } finally { window.dispatchEvent(new Event(ROOM_AI_CHANGED)); if (lock.busy === false) setBusy(false); }
  }
  async function review() {
    if (!branch || busy) return;
    const token = guard.next(); const b = branch; setBusy(true);
    try {
      const s = await read(b);
      if (!guard.isCurrent(token) || branchRef.current !== b.id) return;
      if (!s) { setFindings(null); return; }
      const f = await provider.review(s);
      if (guard.isCurrent(token) && branchRef.current === b.id) setFindings(f);
    } finally { if (guard.isCurrent(token)) setBusy(false); }
  }
  const edit = (id: string, patch: Partial<DraftItem> & { value?: [string, string | number | boolean | null] }) =>
    setDrafts((l) => (l ?? []).map((d) => (d.id !== id ? d : { ...d, include: patch.include ?? d.include, values: patch.value ? { ...d.values, [patch.value[0]]: patch.value[1] } : d.values })));
  const itemTitle = (d: DraftItem) => String(d.values.title ?? d.values.name_ar ?? d.values.name ?? "");
  const shown = (f: FieldSpec, v: DraftItem["values"][string]) => (f.type === "check" ? (v ? "عامة" : "داخلية") : f.type === "select" ? (f.options?.[String(v)] ?? String(v)) : f.type === "money_sar" ? (v == null ? "السعر: لم يُكتب" : `${v} ر.س`) : String(v ?? ""));

  return (
    <div className="rfo" data-testid="roomai-founding">
      <p className="rfo-note"><Sparkles className="inline h-3.5 w-3.5" /> هذه قوالب جاهزة ثابتة، وليست محادثة ولا نموذج ذكاء اصطناعي، ولا تفهم نصًا حرًا. أقترح فقط: لا يُكتب شيء قبل أن تحدد البنود وتضغط «تأكيد وإضافة». المسودة تزول بإغلاق الصفحة. نصوص السياسات قوالب عامة وليست استشارة قانونية، راجعها قبل الاعتماد.</p>
      {loadErr && <p className="rfo-bad" role="alert">تعذّرت قراءة بيانات الفرع: {loadErr}. لن أقترح ولن أكتب حتى تنجح القراءة.</p>}
      {!canWrite && <p className="rfo-warn">التأسيس متاح للمالك والمدير فقط. يمكنك المراجعة.</p>}
      <div className="rfo-steps" role="group" aria-label="خطوات التأسيس">
        {STEP_ORDER.map((s, i) => <button key={s} className="rfo-step" aria-pressed={s === step} disabled={busy} onClick={() => setStep(s)} data-testid={`rfo-step-${s}`}>{i + 1}. {STEP_INFO[s].label} ({stepCount(snap, s)})</button>)}
      </div>
      <div className="rfo-card">
        <div className="rfo-row"><span className="rfo-title">{STEP_INFO[step].label}</span><Link className="rfo-muted" to={STEP_INFO[step].path}>افتح الصفحة</Link></div>
        <p className="rfo-muted">{STEP_INFO[step].what}</p>
        {(STEP_INFO[step].ask ?? []).map((a) => <label key={a.key} className="rfo-label">{a.label}<input className="rfo-in" type="number" min={0} max={40} dir="ltr" value={answers[a.key] ?? ""} onChange={(e) => setAnswers({ ...answers, [a.key]: Number(e.target.value) })} /></label>)}
        <div className="rfo-row"><button className="rfo-btn rfo-btn-ai" disabled={busy || !branchId || !canWrite} onClick={propose} data-testid="rfo-propose"><Sparkles className="h-4 w-4" /> {drafts ? "أعد الاقتراح" : "اقترح لهذه الخطوة"}</button></div>
      </div>

      {drafts && drafts.length === 0 && <p className="rfo-ok" data-testid="rfo-nothing">كل ما أقترحه لهذه الخطوة موجود عندك. لا جديد.</p>}
      {drafts && drafts.length > 0 && (
        <>
          <p className="rfo-muted">مسودة ({drafts.length}). اقرأ كل بند كاملًا ثم علّم ما تريد إضافته. لا شيء معلَّم مسبقًا. ما يحتاج إكمالًا لا يُضاف.</p>
          {drafts.map((d) => {
            const pr = uniqueProblems(step, d.values); const res = results[d.id]; const done = isDone(d.id);
            return (
              <div key={d.id} className="rfo-card" data-testid="rfo-draft">
                <div className="rfo-row">
                  <input type="checkbox" checked={d.include} disabled={done || busy} onChange={(e) => edit(d.id, { include: e.target.checked })} aria-label={`إضافة ${itemTitle(d)}`} />
                  <span className="rfo-title">{itemTitle(d)}</span>
                  {done ? <span className="rfo-ok"><Check className="inline h-3.5 w-3.5" /> {res?.state === "skipped" ? "موجود مسبقًا" : "تمت الإضافة"}</span> : res ? <span className="rfo-bad">{res.state === "stopped" ? "أُوقف" : "فشل"}: {res.msg}</span> : pr.length ? <span className="rfo-warn">يحتاج إكمالك</span> : <span className="rfo-ok">جاهز للمراجعة</span>}
                  {!done && <button className="rfo-btn" style={{ marginInlineStart: "auto" }} disabled={busy} onClick={() => setOpen(open === d.id ? null : d.id)} aria-expanded={open === d.id}>{open === d.id ? "إخفاء التعديل" : "تعديل"}</button>}
                </div>
                {d.note && <p className="rfo-muted">{d.note}</p>}
                {/* the whole content is always on screen: what is confirmed is what was read */}
                <div data-testid="rfo-content">{fields.filter((f) => f.type !== "check" || step === "policies").map((f) => <p key={f.key} className="rfo-muted"><b>{f.label.split(" (")[0]}:</b> <span style={{ whiteSpace: "pre-line" }}>{shown(f, d.values[f.key])}</span></p>)}</div>
                {!done && pr.map((p) => <p key={p} className="rfo-warn">{p}</p>)}
                {open === d.id && !done && fields.map((f) => <FieldInput key={f.key} f={f} value={d.values[f.key]} onChange={(v) => edit(d.id, { value: [f.key, v] })} />)}
              </div>
            );
          })}
          {batchNote && <p className="rfo-warn" role="alert" data-testid="rfo-batch-note">{batchNote}</p>}
          <button className="rfo-btn rfo-btn-primary" disabled={busy || ready.length === 0} onClick={applyConfirmed} data-testid="rfo-confirm"><Check className="h-4 w-4" /> تأكيد وإضافة المعلَّم ({ready.length})</button>
        </>
      )}

      <div className="rfo-card">
        <div className="rfo-row"><ShieldAlert className="h-4 w-4" /><span className="rfo-title">مراجعة التأسيس</span></div>
        <p className="rfo-muted">قراءة فقط لفرع «{branch?.name_ar}». قواعد ثابتة تكشف النواقص والمخاطر.</p>
        <div className="rfo-row"><button className="rfo-btn" disabled={busy || !branchId} onClick={review} data-testid="rfo-review">راجع التأسيس</button></div>
        {findings && findings.length === 0 && <p className="rfo-ok" data-testid="rfo-clean">لا نواقص ظاهرة في المرحلة 1.</p>}
        {findings?.map((f) => (
          <div key={f.id} data-testid="rfo-finding"><div className="rfo-row"><span className={`rfo-sev rfo-sev-${f.severity}`}>{SEV[f.severity]}</span><span className="rfo-title">{f.title}</span></div><p className="rfo-muted">{f.detail} {f.to && <Link to={f.to}>افتح</Link>}</p></div>
        ))}
      </div>
    </div>
  );
}
