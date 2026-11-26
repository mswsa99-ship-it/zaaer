/**
 * قاعدة المعرفة — what the reception assistant is allowed to say.
 * Three sources, one page: (1) Q&A entries managed here, (2) the fixed policy topics (/admin/policies),
 * (3) branch settings (times/address/phone — /admin/branches). Questions the assistant could not
 * answer land in the "بلا إجابة" tab; answering one from there creates the entry and closes it.
 */
import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { toArabicError } from "../../lib/api";
import { useAuth } from "../../lib/auth";
import { useBranchQuery } from "../../lib/useBranchQuery";
import { knowledgeApi, suggestKeywords, KNOWLEDGE_CATEGORY_LABELS, type KnowledgeRow, type UnansweredRow, type KnowledgeDraft, type KnowledgeCategory } from "../../lib/knowledgeApi";
import { SectionTitle, Card, LoadingScreen, Badge, Spinner, ErrorBanner, EmptyState, LoadErrorCard } from "../../components/ui";
import { Modal, Field, ActionForm, Submit, Toggle, ReasonInput, ArchivedBadge , NumberInput, useFormDraft, useEditDraft, DraftRestoreBanner } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { useBranch } from "../../lib/branch";
import { formatDateTime, COUNT } from "../../lib/utils";
import { inheritanceApi, type KnowledgePreview, type KnowledgeEdit } from "../../lib/inheritance";
import { InheritancePreviewDialog } from "../../components/InheritancePreviewDialog";
import { knowledgePlanRows, hiddenBranchesNote, classifyError, type PlanRow } from "../../lib/inheritanceView";
import { BookOpen, Plus, Pencil, Search, MessageCircleQuestion, Archive, RotateCcw, FileText, Building2, Globe, Lock, Sparkles } from "lucide-react";

type Tab = "entries" | "unanswered";
interface KbData { rows: KnowledgeRow[]; open: UnansweredRow[] }
const NO_KB: KbData = { rows: [], open: [] };

const EMPTY = (branchId: string | null): KnowledgeDraft => ({ branch_id: branchId, category: "general", question: "", keywords: [], answer: "", is_public: true, is_active: true, priority: 0 });

export default function AdminKnowledge() {
  const { profile, can } = useAuth();
  const role = profile?.role ?? "";
  const { branches, allBranches, setBranchId } = useBranch();
  const canEdit = can("knowledge") && !allBranches; // «جميع الفروع»: read-only; an answer is changed inside one branch
  const canOrgWide = ["owner", "manager"].includes(role);

  const [tab, setTab] = useState<Tab>("entries");
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [showArchived, setShowArchived] = useState(false);
  const [draft, setDraft] = useState<KnowledgeDraft | null>(null);
  const [kwInput, setKwInput] = useState("");
  const [lifecycle, setLifecycle] = useState<{ row: KnowledgeRow; reason: string } | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  // lane 7 (0149): where each answer comes from in the active branch, and the server preview of a hotel-level change
  const [origins, setOrigins] = useState<Map<string, string>>(new Map());
  const [originsError, setOriginsError] = useState<string | null>(null);
  // which branch and which rows list the origins were computed for: stale origins never hide a row (see `filtered`)
  const [originsFor, setOriginsFor] = useState<{ branch: string; rows: unknown } | null>(null);
  const [hotelPlan, setHotelPlan] = useState<{ id: string; edit: KnowledgeEdit; preview: KnowledgePreview; rows: PlanRow[] } | null>(null);

  // G24 (decision 40): the active branch's answers (and the organisation-wide ones) only
  const q = useBranchQuery<KbData>(async (branchId) => {
    const [rows, open] = await Promise.all([knowledgeApi.list(branchId, showArchived), knowledgeApi.unanswered(branchId, "open")]);
    return { rows, open };
  }, [showArchived], NO_KB, { merge: (parts) => {
    // an organisation-wide answer comes back with every branch: keep it once
    const uniq = <T extends { id: string }>(l: T[]) => [...new Map(l.map((x) => [x.id, x])).values()];
    return { rows: uniq(parts.flatMap((x) => x.rows)), open: uniq(parts.flatMap((x) => x.open)) };
  } });
  const branchName = (id: string | null) => branches.find((b) => b.id === id)?.name_ar ?? "";
  const { rows, open } = q.data; const branchId = q.branchId; const load = q.reload;
  // best effort: without it the page behaves exactly as before (no badges, hotel-level edits are refused by the server)
  useEffect(() => {
    let live = true;
    setOriginsFor(null);
    if (allBranches || !branchId) { setOrigins(new Map()); setOriginsError(null); return; }
    (async () => {
      try {
        const l = await inheritanceApi.knowledgeEffective(branchId);
        if (!Array.isArray(l)) throw new Error("bad inheritance response");
        if (live) { setOrigins(new Map(l.map((x) => [x.id, x.origin]))); setOriginsError(null); setOriginsFor({ branch: branchId, rows }); }
      } catch (e) { if (live) { setOrigins(new Map()); setOriginsError(classifyError(e) === "denied" ? null : toArabicError(e)); } }
    })();
    return () => { live = false; };
  }, [allBranches, branchId, rows]);

  const filtered = useMemo(() => {
    const q = search.trim();
    // a shared answer the branch overrode (or switched off with an inactive override) must not show next to the branch's own:
    // the server's effective list is the truth for what this branch actually says (archived view is left as is)
    const originsLoaded = !!originsFor && originsFor.branch === branchId && originsFor.rows === rows;
    const base = originsLoaded && !showArchived && !allBranches ? rows.filter((r) => r.branch_id !== null || origins.has(r.id)) : rows;
    if (!q) return base;
    return base.filter((r) => r.question.includes(q) || r.answer.includes(q) || r.keywords.some((k) => k.includes(q)));
  }, [rows, search, origins, originsFor, branchId, showArchived, allBranches]);

  // 0055 (SETUP-13, the owner's decision): a contradicting answer is refused; the existing entry opens for editing instead
  const [conflict, setConflict] = useState<KnowledgeRow | null>(null);
  // 6.5 (U4): a new answer survives a reload (session storage, offered back, restored only on click)
  const kbPristine = (d: KnowledgeDraft) => !d.question.trim() && !d.answer.trim() && d.keywords.length === 0;
  const fd = useFormDraft<KnowledgeDraft>({ storageKey: !!draft && !draft.id && profile?.organization_id ? `zaaer:knowledge-draft:${profile.id}:${profile.organization_id}:${draft.branch_id ?? "all"}` : null, open: !!draft && !draft.id, value: draft ?? EMPTY(null), pristine: kbPristine, apply: (v) => setDraft(v) });
  // Match startEdit's form shape, not the row's extra audit metadata. The pending keyword input is part of the edit.
  const originalRow = draft?.id ? rows.find((r) => r.id === draft.id) : null;
  const editOriginal = originalRow ? {
    id: originalRow.id, version: originalRow.version, branch_id: originalRow.branch_id,
    category: originalRow.category, question: originalRow.question, keywords: originalRow.keywords,
    answer: originalRow.answer, answer_en: originalRow.answer_en, is_public: originalRow.is_public,
    is_active: originalRow.is_active, priority: originalRow.priority, pending_keywords: "",
  } : null;
  const ed = useEditDraft<KnowledgeDraft & { pending_keywords: string }>({
    storageKey: draft?.id && profile?.id && profile.organization_id ? `zaaer:knowledge-edit:${profile.id}:${profile.organization_id}:${draft.id}` : null,
    open: !!draft?.id, value: { ...(draft ?? EMPTY(null)), pending_keywords: kwInput }, original: editOriginal,
    version: originalRow?.version,
    apply: ({ pending_keywords, ...v }) => { setDraft(v); setKwInput(pending_keywords); },
  });
  const startNew = (prefill?: Partial<KnowledgeDraft>) => { setConflict(null); setDraft({ ...EMPTY(branchId), ...prefill }); setKwInput(""); };
  const startEdit = (r: KnowledgeRow) => { setConflict(null); setDraft({ id: r.id, version: r.version, branch_id: r.branch_id, category: r.category, question: r.question, keywords: r.keywords, answer: r.answer, answer_en: r.answer_en, is_public: r.is_public, is_active: r.is_active, priority: r.priority }); setKwInput(""); };
  const answerUnanswered = (u: UnansweredRow) => startNew({ question: u.question, keywords: suggestKeywords(u.question), unanswered_id: u.id });

  const addKeyword = () => {
    if (!draft) return;
    const parts = kwInput.split(/[,،\n]/).map((s) => s.trim()).filter(Boolean);
    if (parts.length === 0) return;
    setDraft({ ...draft, keywords: [...new Set([...draft.keywords, ...parts])] });
    setKwInput("");
  };

  const act = async (id: string, fn: () => Promise<unknown>) => { setBusyId(id); setError(null); try { await fn(); load(); } catch (e) { setError(toArabicError(e)); } finally { setBusyId(null); } };

  if (q.loading) return <LoadingScreen />;

  return (
    <div>
      <SectionTitle title="قاعدة المعرفة" subtitle="كل ما يحق للمساعد قوله للنزلاء — من هذه السجلات فقط، ولا يخترع شيئًا" action={
        <div className="flex items-center gap-2"><BranchPicker allowAll />{canEdit && <button onClick={() => startNew()} className="btn-primary text-sm"><Plus className="h-4 w-4" /> سؤال وجواب</button>}</div>} />

      {/* the three sources, in one line */}
      <div className="mb-4 grid gap-2 sm:grid-cols-3">
        <div className="card flex items-center gap-3 p-3"><BookOpen className="h-5 w-5 text-brand-600" /><div><p className="text-sm font-semibold text-ink-800">الأسئلة والأجوبة</p><p className="text-[11px] text-ink-400">{COUNT.answer(rows.filter((r) => !r.archived_at).length)} فعّالة · {COUNT.question(open.length)} بلا إجابة</p></div></div>
        <Link to="/admin/policies" className="card flex items-center gap-3 p-3 hover:bg-ink-50"><FileText className="h-5 w-5 text-brand-600" /><div><p className="text-sm font-semibold text-ink-800">السياسات الأساسية</p><p className="text-[11px] text-ink-400">الإلغاء، الإنترنت، المواقف، الأطفال، شروط الإقامة ↗</p></div></Link>
        <Link to="/admin/branches" className="card flex items-center gap-3 p-3 hover:bg-ink-50"><Building2 className="h-5 w-5 text-brand-600" /><div><p className="text-sm font-semibold text-ink-800">بيانات الفرع</p><p className="text-[11px] text-ink-400">مواعيد الوصول والمغادرة، العنوان، الهاتف ↗</p></div></Link>
      </div>

      {allBranches && <div className="mb-3 rounded-xl border-2 border-dashed px-3 py-2 text-sm" role="note" data-testid="kb-readonly-note"><b>عرض جميع الفروع للقراءة فقط.</b> لتعديل إجابة خاصة بفرع اضغط «فتح الفرع للتعديل». الإجابات المعلّمة «كل الفروع» تُعدَّل من أي فرع.</div>}
      {originsError && !q.error && <div className="mb-4 rounded-xl bg-rai-warning-tint p-3 text-sm text-rai-warning" role="alert" data-testid="origins-error">تعذّر تحميل حالة وراثة الإجابات من الفندق: {originsError}. الإجابات أدناه قابلة للتعديل كالمعتاد، لكن علامة «مخصص» غير ظاهرة.</div>}
      {(error || (q.error && rows.length + open.length > 0)) && <div className="mb-4"><ErrorBanner message={(error ?? q.error) as string} /></div>}

      <div className="mb-4 flex flex-wrap items-center gap-2">
        <div className="flex gap-1 rounded-xl bg-ink-50 p-1 text-sm">
          <button onClick={() => setTab("entries")} className={`rounded-lg px-4 py-1.5 ${tab === "entries" ? "bg-white font-medium text-ink-800 shadow-sm" : "text-ink-500"}`}>الأسئلة والأجوبة</button>
          <button onClick={() => setTab("unanswered")} className={`flex items-center gap-1.5 rounded-lg px-4 py-1.5 ${tab === "unanswered" ? "bg-white font-medium text-ink-800 shadow-sm" : "text-ink-500"}`}>بلا إجابة {open.length > 0 && <span className="rounded-full bg-warning-500/15 px-1.5 text-[11px] font-semibold text-warning-700">{open.length}</span>}</button>
        </div>
        {tab === "entries" && <>
          <div className="relative"><Search className="pointer-events-none absolute right-3 top-2.5 h-4 w-4 text-ink-400" /><input value={search} onChange={(e) => setSearch(e.target.value)} className="input w-64 pr-9" aria-label="بحث في قاعدة المعرفة" placeholder="ابحث في الأسئلة أو الكلمات المفتاحية…" /></div>
          <Toggle checked={showArchived} onChange={setShowArchived} label="إظهار المؤرشف" />
        </>}
      </div>

      {tab === "entries" && (q.error && rows.length === 0 ? <LoadErrorCard message={q.error} onRetry={load} /> : filtered.length === 0 ? <EmptyState icon={<BookOpen className="h-10 w-10" />} title="لا توجد إجابات" description="أضف أول سؤال وجواب، أو راجع تبويب «بلا إجابة»." /> : (
        <div className="grid gap-3 lg:grid-cols-2">
          {filtered.map((r) => (
            <Card key={r.id} className={r.archived_at ? "opacity-60" : ""}>
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <h3 className="font-semibold text-ink-800">{r.question}</h3>
                    <ArchivedBadge archivedAt={r.archived_at} />
                    {!r.is_active && !r.archived_at && <Badge className="bg-warning-500/10 text-warning-700">معطل</Badge>}
                    {r.is_public ? <Badge className="bg-success-500/10 text-success-600"><Globe className="ml-1 inline h-3 w-3" />للنزلاء</Badge> : <Badge className="bg-ink-100 text-ink-600"><Lock className="ml-1 inline h-3 w-3" />للموظفين فقط</Badge>}
                  </div>
                  <p className="mt-1.5 whitespace-pre-line text-sm text-ink-600">{r.answer}</p>
                  <div className="mt-2 flex flex-wrap items-center gap-1.5">
                    <Badge className="bg-brand-50 text-brand-700">{KNOWLEDGE_CATEGORY_LABELS[r.category] ?? r.category}</Badge>
                    {origins.get(r.id) === "branch_override" && <Badge className="bg-rai-spark-tint text-rai-spark-text" testId="kb-override-badge">مخصص لهذا الفرع</Badge>}
                    <Badge className="bg-ink-50 text-ink-500" testId="admin-row-branch">{r.branch_id ? (allBranches ? branchName(r.branch_id) : "هذا الفرع") : "كل الفروع"}</Badge>
                    {allBranches && r.branch_id && <button type="button" onClick={() => setBranchId(r.branch_id!)} className="btn-ghost shrink-0 whitespace-nowrap p-1 text-xs" data-testid="admin-row-open-branch" aria-label={`فتح فرع ${branchName(r.branch_id)} لتعديل الإجابة`}>فتح الفرع للتعديل</button>}
                    {r.keywords.map((k) => <span key={k} className="rounded-md border border-ink-100 px-1.5 py-0.5 text-[11px] text-ink-500">{k}</span>)}
                  </div>
                  <p className="mt-2 text-[11px] text-ink-400">{r.used_count ? `استُخدمت ${COUNT.times(r.used_count)}` : "لم تُستخدم بعد"}{r.last_used_at ? ` · آخر مرة ${formatDateTime(r.last_used_at)}` : ""}{r.archive_reason ? ` · سبب الأرشفة: ${r.archive_reason}` : ""}</p>
                </div>
                {canEdit && (
                  <div className="flex shrink-0 flex-col gap-1">
                    {!r.archived_at && !r.branch_id && branchId && <button disabled={busyId === r.id} onClick={() => act(r.id, () => inheritanceApi.knowledgeOverride(r.id, branchId))} className="btn-outline min-h-[44px] text-xs" data-testid="kb-override">تخصيص لهذا الفرع</button>}
                    {!r.archived_at && origins.get(r.id) === "branch_override" && <button disabled={busyId === r.id} onClick={() => act(r.id, () => inheritanceApi.knowledgeRevert(r.id))} className="btn-ghost min-h-[44px] text-xs" data-testid="kb-revert"><RotateCcw className="h-4 w-4" /> إعادة لإجابة الفندق</button>}
                    {!r.archived_at && <button onClick={() => startEdit(r)} className="btn-ghost p-2.5" title="تعديل" aria-label={`تعديل: ${r.question}`}><Pencil className="h-4 w-4" /></button>}
                    {!r.archived_at && <button onClick={() => setLifecycle({ row: r, reason: "" })} className="btn-ghost p-2.5 text-ink-400" title="أرشفة" aria-label={`أرشفة: ${r.question}`}><Archive className="h-4 w-4" /></button>}
                    {r.archived_at && <button disabled={busyId === r.id} onClick={() => act(r.id, () => knowledgeApi.archive(r.id, "استعادة", false))} className="btn-ghost p-1.5" title="استعادة">{busyId === r.id ? <Spinner className="h-4 w-4" /> : <RotateCcw className="h-4 w-4" />}</button>}
                  </div>
                )}
              </div>
            </Card>
          ))}
        </div>
      ))}

      {tab === "unanswered" && (q.error && open.length === 0 ? <LoadErrorCard message={q.error} onRetry={load} /> : open.length === 0 ? <EmptyState icon={<MessageCircleQuestion className="h-10 w-10" />} title="لا توجد أسئلة معلّقة" description="كل سؤال لا يجد إجابة في القاعدة يظهر هنا تلقائيًا." /> : (
        <div className="space-y-2">
          <p className="text-xs text-ink-500"><Sparkles className="ml-1 inline h-3.5 w-3.5 text-brand-600" />أسئلة سألها النزلاء ولم يجد المساعد لها إجابة معتمدة. الأرقام الطويلة تُخفى تلقائيًا.</p>
          {open.map((u) => (
            <Card key={u.id}>
              <div className="flex flex-wrap items-center justify-between gap-3">
                <div className="min-w-0">
                  <p className="font-medium text-ink-800">{u.question}</p>
                  {allBranches && <p className="flex items-center gap-1 text-[11px]"><Badge testId="admin-row-branch">{u.branch_id ? branchName(u.branch_id) : "كل الفروع"}</Badge>{u.branch_id && <button type="button" onClick={() => setBranchId(u.branch_id!)} className="btn-ghost shrink-0 whitespace-nowrap p-1 text-xs" data-testid="admin-row-open-branch" aria-label={`فتح فرع ${branchName(u.branch_id)} للإجابة على السؤال`}>فتح الفرع للتعديل</button>}</p>}
                  <p className="text-[11px] text-ink-400">سُئل {COUNT.times(u.asked_count)} · آخر مرة {formatDateTime(u.last_asked_at)}</p>
                </div>
                {canEdit && (
                  <div className="flex gap-2">
                    <button onClick={() => answerUnanswered(u)} className="btn-primary text-xs"><Plus className="h-3.5 w-3.5" /> إضافة إجابة</button>
                    <button disabled={busyId === u.id} onClick={() => act(u.id, () => knowledgeApi.resolveUnanswered(u.id, "ignored", "غير ذي صلة"))} className="btn-outline text-xs">تجاهل</button>
                  </div>
                )}
              </div>
            </Card>
          ))}
        </div>
      ))}

      {/* ---------- entry editor ---------- */}
      <Modal open={!!draft} title={draft?.id ? "تعديل إجابة" : "سؤال وجواب جديد"} onClose={() => setDraft(null)} wide>
        {draft && (
          <ActionForm onSubmit={async () => {
            const pending = kwInput.trim() ? [...new Set([...draft.keywords, ...kwInput.split(/[,،\n]/).map((s) => s.trim()).filter(Boolean)])] : draft.keywords;
            if (!draft.question.trim() || draft.question.trim().length < 3) throw new Error("VALIDATION: question");
            if (!draft.answer.trim()) throw new Error("VALIDATION: answer");
            if (draft.id && !draft.branch_id) {   // a hotel-level answer: the server previews the effect on every branch first
              const edit: KnowledgeEdit = { question: draft.question.trim(), answer: draft.answer.trim(), answer_en: draft.answer_en ?? null, keywords: pending, category: draft.category, is_public: draft.is_public, is_active: draft.is_active, priority: draft.priority, version: draft.version ?? 0, reason: draft.reason };
              const preview = await inheritanceApi.knowledgePreview(draft.id, edit);
              setHotelPlan({ id: draft.id, edit, preview, rows: knowledgePlanRows(preview) });
              return;
            }
            try {
              await knowledgeApi.upsert({ ...draft, keywords: pending, question: draft.question.trim(), answer: draft.answer.trim() });
            } catch (e) {
              const id = String((e as Error)?.message ?? "").match(/KNOWLEDGE_CONFLICT:\s*([0-9a-f-]{36})/)?.[1];
              setConflict(id ? rows.find((r) => r.id === id) ?? null : null);
              throw e;
            }
            fd.clearSaved(); ed.clearSaved(); setDraft(null); setConflict(null); load();
          }}>
            {fd.saved && <DraftRestoreBanner label="مسودة إجابة لم تُحفظ" summary={fd.saved.question.trim() || null} onRestore={fd.restoreSaved} />}
            {ed.saved && <DraftRestoreBanner label="تعديل الإجابة لم يُحفظ" summary={ed.saved.question || null} onRestore={ed.restoreSaved} />}
            <div className="space-y-3">
              {conflict && (
                <div className="rounded-xl border border-warning-500/40 bg-warning-500/10 p-3 text-sm text-ink-700" data-testid="knowledge-conflict">
                  <p>الإجابة الموجودة لهذا السؤال: «{conflict.answer}»</p>
                  <button type="button" className="btn-outline mt-2 min-h-[44px] text-xs" onClick={() => startEdit(conflict)}>تعديل الإجابة الموجودة</button>
                </div>
              )}
              <Field label="السؤال كما يطرحه النزيل (مطلوب)"><input className="input" value={draft.question} onChange={(e) => setDraft({ ...draft, question: e.target.value })} placeholder="مثال: هل يوجد مسبح؟" /></Field>
              <Field label="الكلمات المفتاحية والمرادفات" hint="يُطابق المساعد سؤال النزيل بهذه الكلمات (مع مراعاة الهمزة والتاء المربوطة). افصل بينها بفاصلة.">
                <div className="flex flex-wrap gap-1.5 rounded-xl border border-ink-200 p-2">
                  {draft.keywords.map((k) => <span key={k} className="flex items-center gap-1 rounded-md bg-brand-50 px-2 py-0.5 text-xs text-brand-700">{k}<button type="button" onClick={() => setDraft({ ...draft, keywords: draft.keywords.filter((x) => x !== k) })} className="text-brand-400 hover:text-danger-500" aria-label="إزالة">×</button></span>)}
                  <input value={kwInput} onChange={(e) => setKwInput(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); addKeyword(); } }} onBlur={addKeyword} aria-label="أضف كلمة مفتاحية" className="min-w-[8rem] flex-1 border-0 bg-transparent text-sm outline-none" placeholder={draft.keywords.length ? "" : "مسبح، سباحة، pool"} />
                </div>
                {draft.keywords.length === 0 && draft.question.trim().length >= 3 && <button type="button" onClick={() => setDraft({ ...draft, keywords: suggestKeywords(draft.question) })} className="mt-1 text-xs text-brand-600 hover:underline">اقترح كلمات من السؤال</button>}
              </Field>
              <Field label="الإجابة التي تُرسل للنزيل حرفيًا (مطلوب)"><textarea className="input" rows={4} value={draft.answer} onChange={(e) => setDraft({ ...draft, answer: e.target.value })} /></Field>
              <div className="grid gap-3 sm:grid-cols-3">
                <Field label="التصنيف"><select className="input" value={draft.category} onChange={(e) => setDraft({ ...draft, category: e.target.value as KnowledgeCategory })}>{(Object.keys(KNOWLEDGE_CATEGORY_LABELS) as KnowledgeCategory[]).map((c) => <option key={c} value={c}>{KNOWLEDGE_CATEGORY_LABELS[c]}</option>)}</select></Field>
                <Field label="النطاق"><select className="input" value={draft.branch_id ? "branch" : "org"} disabled={!canOrgWide && !draft.branch_id} onChange={(e) => setDraft({ ...draft, branch_id: e.target.value === "org" ? null : branchId })}><option value="branch">هذا الفرع فقط</option>{canOrgWide && <option value="org">كل الفروع</option>}</select></Field>
                <Field label="الأولوية" hint="تحسم التعارض بين إجابتين"><NumberInput value={draft.priority} onChange={(v) => setDraft({ ...draft, priority: (v ?? 0) })} /></Field>
              </div>
              <div className="flex flex-wrap gap-4">
                <Toggle checked={draft.is_public} onChange={(v) => setDraft({ ...draft, is_public: v })} label="تُرسل للنزلاء (وإلا فللموظفين فقط)" />
                {draft.id && <Toggle checked={draft.is_active} onChange={(v) => setDraft({ ...draft, is_active: v })} label="فعّالة" />}
              </div>
              {draft.id && <ReasonInput value={draft.reason ?? ""} onChange={(v) => setDraft({ ...draft, reason: v })} label="سبب التعديل (يُسجَّل في سجل العمليات)" />}
            </div>
            <Submit label={draft.unanswered_id ? "حفظ وإغلاق السؤال" : "حفظ"} onCancel={() => setDraft(null)} />
          </ActionForm>
        )}
      </Modal>

      <InheritancePreviewDialog open={!!hotelPlan} title="تطبيق الإجابة على الفروع" rows={hotelPlan?.rows ?? []} hiddenNote={hotelPlan ? hiddenBranchesNote(hotelPlan.preview.hidden_branches) : null} onCancel={() => setHotelPlan(null)}
        onConfirm={async (overwrite) => {
          if (!hotelPlan) return;
          try { await inheritanceApi.knowledgeApply(hotelPlan.id, hotelPlan.edit, hotelPlan.preview, overwrite); fd.clearSaved(); ed.clearSaved(); setHotelPlan(null); setDraft(null); load(); }
          catch (e) { setHotelPlan(null); setError(toArabicError(e)); }
        }} />

      {/* ---------- archive (two-step, in-page) ---------- */}
      <Modal open={!!lifecycle} title="أرشفة الإجابة" onClose={() => setLifecycle(null)}>
        {lifecycle && (
          <ActionForm onSubmit={async () => { if (!lifecycle.reason.trim()) throw new Error("VALIDATION: reason"); await knowledgeApi.archive(lifecycle.row.id, lifecycle.reason.trim(), true); setLifecycle(null); load(); }}>
            <p className="mb-3 text-sm text-ink-600">«{lifecycle.row.question}» — الأرشفة تخفي الإجابة عن النزلاء فورًا وتبقي سجلها وإحصاءاتها. يمكن استعادتها لاحقًا.</p>
            <ReasonInput value={lifecycle.reason} onChange={(v) => setLifecycle({ ...lifecycle, reason: v })} label="سبب الأرشفة (إلزامي)" />
            <Submit label="تأكيد الأرشفة" onCancel={() => setLifecycle(null)} danger />
          </ActionForm>
        )}
      </Modal>
    </div>
  );
}
