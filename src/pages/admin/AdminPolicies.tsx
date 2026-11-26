/**
 * «السياسات» — the branch's knowledge for guests and the assistant (0056, SETUP-16): a policy is archived with a reason,
 * never erased, and can be restored; an archived policy is never public. «أخرى» carries its own topic name.
 */
import { useCallback, useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../lib/auth";
import { useBranch } from "../../lib/branch";
import { BranchPicker } from "../../components/BranchPicker";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { toArabicError } from "../../lib/api";
import { SectionTitle, Card, LoadingScreen, Badge, ErrorBanner, EmptyState, LoadErrorCard } from "../../components/ui";
import { Modal, Field, ActionForm, Submit, ReasonInput, NumberInput, useFormDraft, DraftRestoreBanner } from "../../components/forms";
import { FileText, Plus, Pencil, Archive, RotateCcw, Bot } from "lucide-react";
import { inheritanceApi, type PolicyMasterRow, type PolicyMasterDraft, type PolicyPreview } from "../../lib/inheritance";
import { InheritancePreviewDialog } from "../../components/InheritancePreviewDialog";
import { policyPlanRows, classifyError, FIELD_LABELS, type PlanRow } from "../../lib/inheritanceView";
import { POLICY_TOPICS, policyTopic } from "../../lib/policies";


interface PolicyRow { branch_id?: string; id: string; topic: string; topic_label: string | null; title: string; content_ar: string; is_public: boolean; sort_order: number | null; archived_at: string | null; archive_reason: string | null }
type Draft = Omit<PolicyRow, "id" | "archived_at" | "archive_reason"> & { id?: string };

const EMPTY: Draft = { topic: "checkin", topic_label: null, title: "", content_ar: "", is_public: true, sort_order: 0 };
const NO_POLICIES: PolicyRow[] = [];

export default function AdminPolicies() {
  const { profile, can } = useAuth();
  const { branches, allBranches, setBranchId } = useBranch();
  const canEdit = can("policies") && !allBranches; // «جميع الفروع»: read-only; a policy is changed inside one branch
  const [draft, setDraft] = useState<Draft | null>(null);
  const [archiving, setArchiving] = useState<PolicyRow | null>(null);
  const [reason, setReason] = useState("");
  const [showArchived, setShowArchived] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // lane 7 (0149): hotel-level policies the branches inherit. Best effort: if it cannot load, the page is as before.
  const [masters, setMasters] = useState<PolicyMasterRow[]>([]);
  const [mDraft, setMDraft] = useState<(PolicyMasterDraft & { topic: NonNullable<PolicyMasterDraft["topic"]> }) | null>(null);
  const [plan, setPlan] = useState<{ draft: PolicyMasterDraft; preview: PolicyPreview; rows: PlanRow[] } | null>(null);
  // hotel-level writes: server rule is owner/manager + policies cap + all-branch access (lane 7 grounding); old branch writes keep their own gate
  const canEditHotel = can("policies") && allBranches && ["owner", "manager"].includes(profile?.role ?? "");
  // a refusal hides inheritance quietly (the page stays usable); a network/server failure is shown with a retry, never as "no hotel policies"
  const [mastersError, setMastersError] = useState<string | null>(null);
  const loadMasters = useCallback(async () => {
    try {
      const r = await inheritanceApi.policyMasters();
      if (!Array.isArray(r?.masters)) throw new Error("bad inheritance response");
      setMasters(r.masters); setMastersError(null);
    } catch (e) { setMasters([]); setMastersError(classifyError(e) === "denied" ? null : toArabicError(e)); }
  }, []);
  useEffect(() => { loadMasters(); }, [loadMasters]);

  // G24 (decision 40): the active branch's policies only
  const q = useBranchQuery<PolicyRow[]>(async (branchId) => (must(await supabase.from("property_policies")
    .select("id, topic, topic_label, title, content_ar, is_public, sort_order, archived_at, archive_reason").eq("branch_id", branchId).order("sort_order").order("created_at")) as PolicyRow[]).map((x) => ({ ...x, branch_id: branchId })), [], NO_POLICIES, { merge: (parts) => parts.flat() });
  const all = q.data; const branchId = q.branchId; const load = q.reload;
  // policy id -> what it inherits and which of its fields the branch changed itself
  const linked = new Map(masters.flatMap((m) => m.branches.map((b) => [b.policy_id, b.override_fields] as const)));
  const live = all.filter((p) => !p.archived_at); const archived = all.filter((p) => p.archived_at);
  const rows = showArchived ? archived : live;
  // 6.5 (U4): a new policy survives a reload; offered back, restored only on click
  const polPristine = (d: Draft) => !d.title.trim() && !d.content_ar.trim() && !String(d.topic_label ?? "").trim();
  const fd = useFormDraft<Draft>({ storageKey: !!draft && !draft.id && branchId ? `zaaer:policy-draft:${profile?.id}:${branchId}` : null, open: !!draft && !draft.id, value: draft ?? EMPTY, pristine: polPristine, apply: (v) => setDraft(v) });

  async function save() {
    if (!draft || !branchId || !profile) return;
    if (!draft.title.trim() || !draft.content_ar.trim()) throw new Error("VALIDATION: policy_required");
    if (draft.topic === "other" && !String(draft.topic_label ?? "").trim()) throw new Error("VALIDATION: topic_label");
    const payload = { topic: draft.topic, topic_label: draft.topic === "other" ? String(draft.topic_label ?? "").trim() : null, title: draft.title.trim(), content_ar: draft.content_ar.trim(), is_public: draft.is_public, sort_order: draft.sort_order ?? 0, updated_by: profile.id, updated_at: new Date().toISOString() };
    must(draft.id
      ? await supabase.from("property_policies").update(payload).eq("id", draft.id)
      : await supabase.from("property_policies").insert({ ...payload, branch_id: branchId, organization_id: profile.organization_id }));
    fd.clearSaved(); setDraft(null); load();
  }

  async function archive() {
    if (!archiving || !profile) return;
    if (!reason.trim()) throw new Error("VALIDATION: reason");
    must(await supabase.from("property_policies").update({ archived_at: new Date().toISOString(), archived_by: profile.id, archive_reason: reason.trim(), updated_by: profile.id, updated_at: new Date().toISOString() }).eq("id", archiving.id));
    setArchiving(null); setReason(""); load();
  }

  async function previewHotel() {
    if (!mDraft) return;
    if (!mDraft.title.trim() || !mDraft.content_ar.trim()) throw new Error("VALIDATION: policy_required");
    const draft = { ...mDraft, title: mDraft.title.trim(), content_ar: mDraft.content_ar.trim() };
    const preview = await inheritanceApi.policyPreview(draft);
    setPlan({ draft, preview, rows: policyPlanRows(preview) }); setMDraft(null);
  }
  async function revertToHotel(p: PolicyRow) {
    setError(null);
    try { await inheritanceApi.policyRevert(p.id); load(); loadMasters(); } catch (e) { setError(toArabicError(e)); }
  }

  async function restore(p: PolicyRow) {
    if (!profile) return; setError(null);
    try { must(await supabase.from("property_policies").update({ archived_at: null, updated_by: profile.id, updated_at: new Date().toISOString() }).eq("id", p.id)); load(); }
    catch (e) { setError(toArabicError(e)); }
  }

  if (q.loading) return <LoadingScreen />;

  return (
    <div>
      <SectionTitle title="السياسات" subtitle="ما يقرؤه النزيل ويُسمح للمساعد الذكي بذكره، لكل فرع" action={
        <div className="flex flex-wrap items-center gap-2">
          <BranchPicker allowAll />
          {canEdit && <button onClick={() => setDraft({ ...EMPTY, sort_order: live.length + 1 })} className="btn-primary text-sm"><Plus className="h-4 w-4" /> سياسة جديدة</button>}
        </div>
      } />
      {(error || (q.error && all.length > 0)) && <div className="mb-4"><ErrorBanner message={(error ?? q.error) as string} /></div>}
      <div className="mb-4 flex items-start gap-2 rounded-xl bg-brand-50 p-4 text-sm text-brand-700">
        <Bot className="mt-0.5 h-4 w-4 shrink-0" />
        <p>السياسات المعلّمة «عامة» هي <strong>المصدر الوحيد</strong> لما يذكره المساعد الذكي عن المنشأة، وتظهر للنزيل في الشروط. أي سؤال لا تغطيه يُحوَّل إلى مشرف.</p>
      </div>
      {mastersError && !q.error && (
        <div className="mb-4 flex flex-wrap items-center gap-2 rounded-xl bg-rai-warning-tint p-3 text-sm text-rai-warning" role="alert" data-testid="masters-error">
          <p className="min-w-0 flex-1">تعذّر تحميل سياسات الفندق وحالة وراثتها: {mastersError}. سياسات الفرع أدناه سليمة وقابلة للتعديل.</p>
          <button type="button" className="btn-outline min-h-[44px] text-xs" onClick={loadMasters}>إعادة المحاولة</button>
        </div>
      )}
      {allBranches && !mastersError && (masters.length > 0 || canEditHotel) && (
        <section className="mb-6" aria-label="سياسات الفندق" data-testid="hotel-policies">
          <div className="mb-2 flex flex-wrap items-center gap-2">
            <h2 className="text-sm font-semibold text-rai-ink">سياسات الفندق (تصل إلى كل الفروع)</h2>
            {canEditHotel && <button className="btn-primary min-h-[44px] text-sm" onClick={() => setMDraft({ topic: "checkin", title: "", content_ar: "", is_public: true })}><Plus className="h-4 w-4" /> سياسة للفندق</button>}
          </div>
          <div className="space-y-2">
            {masters.map((m) => {
              const custom = m.branches.filter((b) => b.override_fields.length > 0).length;
              return (
                <Card key={m.id} data-testid={`master-${m.id}`}>
                  <div className="mb-1 flex flex-wrap items-center gap-2">
                    <h3 className="text-sm font-semibold text-rai-ink">{m.title}</h3>
                    {custom > 0 && <Badge className="bg-rai-spark-tint text-rai-spark-text">{custom} فرع بنص خاص</Badge>}
                    {canEditHotel && <button className="btn-ghost mr-auto min-h-[44px] min-w-[44px] text-rai-ink-muted" aria-label={`تعديل ${m.title} للفندق`} onClick={() => setMDraft({ id: m.id, version: m.version, topic: m.topic, topic_label: m.topic_label, title: m.title, content_ar: m.content_ar, content_en: m.content_en, is_public: m.is_public, sort_order: m.sort_order })}><Pencil className="h-4 w-4" /></button>}
                  </div>
                  <p className="whitespace-pre-line break-words text-sm text-rai-ink">{m.content_ar}</p>
                </Card>
              );
            })}
          </div>
        </section>
      )}
      <div className="mb-3 flex gap-2" role="tablist" aria-label="عرض السياسات">
        <button role="tab" aria-selected={!showArchived} className={!showArchived ? "btn-primary text-xs" : "btn-outline text-xs"} onClick={() => setShowArchived(false)}>النشطة ({live.length})</button>
        <button role="tab" aria-selected={showArchived} className={showArchived ? "btn-primary text-xs" : "btn-outline text-xs"} onClick={() => setShowArchived(true)}>المؤرشفة ({archived.length})</button>
      </div>

      {q.error && all.length === 0 ? <LoadErrorCard message={q.error} onRetry={() => { load(); loadMasters(); }} /> : rows.length === 0 ? (
        showArchived ? <EmptyState icon={<Archive className="h-10 w-10" />} title="لا توجد سياسات مؤرشفة" />
          : <EmptyState icon={<FileText className="h-10 w-10" />} title="لا توجد سياسات لهذا الفرع" description="أضف سياسات الوصول والإلغاء والإنترنت وغيرها ليقرأها النزيل ويجيب عنها المساعد." action={canEdit ? <button className="btn-primary text-sm" onClick={() => setDraft({ ...EMPTY, sort_order: 1 })}><Plus className="h-4 w-4" /> سياسة جديدة</button> : undefined} />
      ) : (
        <div className="space-y-3">
          {rows.map((p) => (
            <Card key={`${p.branch_id}:${p.id}`} data-testid={`policy-${p.id}`}>
              <div className="mb-2 flex flex-wrap items-center gap-2">
                <FileText className="h-4 w-4 text-brand-600" />
                <h3 className="text-sm font-semibold text-ink-800">{p.title}</h3>
                {allBranches && <Badge testId="admin-row-branch">{branches.find((x) => x.id === p.branch_id)?.name_ar}</Badge>}
                <Badge className="bg-ink-100 text-ink-500">{policyTopic(p)}</Badge>
                {p.archived_at ? <Badge className="bg-ink-100 text-ink-500">مؤرشفة</Badge>
                  : <Badge className={p.is_public ? "bg-success-500/10 text-success-600" : "bg-warning-500/10 text-warning-700"}>{p.is_public ? "عامة — يراها النزيل والمساعد" : "داخلية"}</Badge>}
                {linked.has(p.id) && <Badge testId={`pd-badge-${p.id}`} className={linked.get(p.id)!.length ? "bg-rai-spark-tint text-rai-spark-text" : "bg-rai-surface-sunken text-rai-ink-muted"}>{linked.get(p.id)!.length ? `مخصص: ${linked.get(p.id)!.map((f) => FIELD_LABELS[f]).join("، ")}` : "من الفندق"}</Badge>}
                <span className="mr-auto text-xs text-ink-400">#{p.sort_order ?? 0}</span>
                {canEdit && !p.archived_at && (linked.get(p.id)?.length ?? 0) > 0 && <button onClick={() => revertToHotel(p)} className="btn-ghost min-h-[44px] text-xs" data-testid="policy-revert"><RotateCcw className="h-4 w-4" /> إعادة لنص الفندق</button>}
                {allBranches && p.branch_id && <button onClick={() => setBranchId(p.branch_id!)} className="btn-ghost shrink-0 whitespace-nowrap p-1.5 text-xs" data-testid="admin-row-open-branch" aria-label={`فتح فرع ${p.title} لتعديل السياسة`}>فتح الفرع للتعديل</button>}
                {canEdit && !p.archived_at && (
                  <>
                    <button onClick={() => setDraft({ ...p })} className="btn-ghost min-h-[44px] min-w-[44px] text-ink-500" aria-label={`تعديل ${p.title}`}><Pencil className="h-4 w-4" /></button>
                    <button onClick={() => { setArchiving(p); setReason(""); }} className="btn-ghost min-h-[44px] min-w-[44px] text-ink-500" aria-label={`أرشفة ${p.title}`}><Archive className="h-4 w-4" /></button>
                  </>
                )}
                {canEdit && p.archived_at && <button onClick={() => restore(p)} className="btn-outline text-xs"><RotateCcw className="h-3.5 w-3.5" /> استعادة</button>}
              </div>
              <p className="whitespace-pre-line text-sm leading-relaxed text-ink-600">{p.content_ar}</p>
              {p.archived_at && p.archive_reason && <p className="mt-2 text-xs text-ink-400">سبب الأرشفة: {p.archive_reason}</p>}
            </Card>
          ))}
        </div>
      )}

      <Modal open={!!draft} title={draft?.id ? "تعديل سياسة" : "سياسة جديدة"} onClose={() => setDraft(null)}>
        {draft && (
          <ActionForm onSubmit={save}>
            {fd.saved && <DraftRestoreBanner label="مسودة سياسة لم تُحفظ" summary={fd.saved.title.trim() || null} onRestore={fd.restoreSaved} />}
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="الموضوع">
                <select className="input" value={draft.topic} onChange={(e) => setDraft({ ...draft, topic: e.target.value })}>
                  {Object.entries(POLICY_TOPICS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                </select>
              </Field>
              <Field label="الترتيب"><NumberInput value={draft.sort_order ?? 0} label="الترتيب" onChange={(v) => setDraft({ ...draft, sort_order: v ?? 0 })} /></Field>
              {draft.topic === "other" && <Field label="اسم الموضوع" className="sm:col-span-2" hint="مثل: الحيوانات الأليفة، التدخين"><input className="input" maxLength={60} value={draft.topic_label ?? ""} onChange={(e) => setDraft({ ...draft, topic_label: e.target.value })} /></Field>}
              <Field label="العنوان" className="sm:col-span-2"><input className="input" maxLength={120} value={draft.title} onChange={(e) => setDraft({ ...draft, title: e.target.value })} /></Field>
              <Field label="النص" className="sm:col-span-2" hint={`${draft.content_ar.length} / 4000`}><textarea className="input min-h-[120px]" maxLength={4000} value={draft.content_ar} onChange={(e) => setDraft({ ...draft, content_ar: e.target.value })} /></Field>
              <label className="flex min-h-[44px] items-center gap-2 text-sm text-ink-700 sm:col-span-2">
                <input type="checkbox" className="h-4 w-4 accent-brand-600" checked={draft.is_public} onChange={(e) => setDraft({ ...draft, is_public: e.target.checked })} />
                عامة — تظهر للنزيل ويُسمح للمساعد الذكي بذكرها
              </label>
            </div>
            <Submit label="حفظ" onCancel={() => setDraft(null)} />
          </ActionForm>
        )}
      </Modal>

      <Modal open={!!mDraft} title={mDraft?.id ? "تعديل سياسة الفندق" : "سياسة جديدة للفندق"} onClose={() => setMDraft(null)}>
        {mDraft && (
          <ActionForm onSubmit={previewHotel}>
            <div className="grid gap-3">
              <Field label="الموضوع"><select className="input" disabled={!!mDraft.id} value={mDraft.topic} onChange={(e) => setMDraft({ ...mDraft, topic: e.target.value as typeof mDraft.topic })}>{Object.entries(POLICY_TOPICS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></Field>
              {mDraft.topic === "other" && <Field label="اسم الموضوع"><input className="input" maxLength={60} value={mDraft.topic_label ?? ""} onChange={(e) => setMDraft({ ...mDraft, topic_label: e.target.value })} /></Field>}
              <Field label="العنوان"><input className="input" maxLength={120} value={mDraft.title} onChange={(e) => setMDraft({ ...mDraft, title: e.target.value })} /></Field>
              <Field label="النص"><textarea className="input min-h-[120px]" maxLength={4000} value={mDraft.content_ar} onChange={(e) => setMDraft({ ...mDraft, content_ar: e.target.value })} /></Field>
              <label className="flex min-h-[44px] items-center gap-2 text-sm text-rai-ink"><input type="checkbox" className="h-4 w-4" checked={mDraft.is_public ?? true} onChange={(e) => setMDraft({ ...mDraft, is_public: e.target.checked })} /> عامة: يراها النزيل ويذكرها المساعد</label>
            </div>
            <Submit label="متابعة: معاينة الأثر على الفروع" onCancel={() => setMDraft(null)} />
          </ActionForm>
        )}
      </Modal>
      <InheritancePreviewDialog open={!!plan} title={plan ? `تطبيق «${plan.draft.title}» على الفروع` : ""} rows={plan?.rows ?? []} onCancel={() => setPlan(null)}
        onConfirm={async (overwrite) => { if (!plan) return; try { await inheritanceApi.policyApply(plan.draft, plan.preview, overwrite); setPlan(null); loadMasters(); load(); } catch (e) { setPlan(null); setError(toArabicError(e)); } }} />

      <Modal open={!!archiving} title={archiving ? `أرشفة «${archiving.title}»` : ""} onClose={() => setArchiving(null)}>
        {archiving && (
          <ActionForm onSubmit={archive}>
            <p className="mb-3 text-sm text-ink-600">تختفي السياسة عن النزيل والمساعد الذكي فورًا، وتبقى في «المؤرشفة» ويمكن استعادتها.</p>
            <ReasonInput value={reason} onChange={setReason} />
            <Submit label="أرشفة" onCancel={() => setArchiving(null)} danger />
          </ActionForm>
        )}
      </Modal>
    </div>
  );
}
