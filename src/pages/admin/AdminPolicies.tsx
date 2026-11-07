/**
 * «السياسات» — the branch's knowledge for guests and the assistant (0056, SETUP-16): a policy is archived with a reason,
 * never erased, and can be restored; an archived policy is never public. «أخرى» carries its own topic name.
 */
import { useState } from "react";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../lib/auth";
import { useBranch } from "../../lib/branch";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { toArabicError } from "../../lib/api";
import { SectionTitle, Card, LoadingScreen, Badge, ErrorBanner, EmptyState, LoadErrorCard } from "../../components/ui";
import { Modal, Field, ActionForm, Submit, ReasonInput, NumberInput } from "../../components/forms";
import { FileText, Plus, Pencil, Archive, RotateCcw, Bot } from "lucide-react";
import { POLICY_TOPICS, policyTopic } from "../../lib/policies";


interface PolicyRow { id: string; topic: string; topic_label: string | null; title: string; content_ar: string; is_public: boolean; sort_order: number | null; archived_at: string | null; archive_reason: string | null }
type Draft = Omit<PolicyRow, "id" | "archived_at" | "archive_reason"> & { id?: string };

const EMPTY: Draft = { topic: "checkin", topic_label: null, title: "", content_ar: "", is_public: true, sort_order: 0 };
const NO_POLICIES: PolicyRow[] = [];

export default function AdminPolicies() {
  const { profile, can } = useAuth();
  const canEdit = can("policies");
  const { branches, setBranchId } = useBranch();
  const [draft, setDraft] = useState<Draft | null>(null);
  const [archiving, setArchiving] = useState<PolicyRow | null>(null);
  const [reason, setReason] = useState("");
  const [showArchived, setShowArchived] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // G24 (decision 40): the active branch's policies only
  const q = useBranchQuery<PolicyRow[]>(async (branchId) => must(await supabase.from("property_policies")
    .select("id, topic, topic_label, title, content_ar, is_public, sort_order, archived_at, archive_reason").eq("branch_id", branchId).order("sort_order").order("created_at")) as PolicyRow[], [], NO_POLICIES);
  const all = q.data; const branchId = q.branchId; const load = q.reload;
  const live = all.filter((p) => !p.archived_at); const archived = all.filter((p) => p.archived_at);
  const rows = showArchived ? archived : live;

  async function save() {
    if (!draft || !branchId || !profile) return;
    if (!draft.title.trim() || !draft.content_ar.trim()) throw new Error("VALIDATION: policy_required");
    if (draft.topic === "other" && !String(draft.topic_label ?? "").trim()) throw new Error("VALIDATION: topic_label");
    const payload = { topic: draft.topic, topic_label: draft.topic === "other" ? String(draft.topic_label ?? "").trim() : null, title: draft.title.trim(), content_ar: draft.content_ar.trim(), is_public: draft.is_public, sort_order: draft.sort_order ?? 0, updated_by: profile.id, updated_at: new Date().toISOString() };
    must(draft.id
      ? await supabase.from("property_policies").update(payload).eq("id", draft.id)
      : await supabase.from("property_policies").insert({ ...payload, branch_id: branchId, organization_id: profile.organization_id }));
    setDraft(null); load();
  }

  async function archive() {
    if (!archiving || !profile) return;
    if (!reason.trim()) throw new Error("VALIDATION: reason");
    must(await supabase.from("property_policies").update({ archived_at: new Date().toISOString(), archived_by: profile.id, archive_reason: reason.trim(), updated_by: profile.id, updated_at: new Date().toISOString() }).eq("id", archiving.id));
    setArchiving(null); setReason(""); load();
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
          <select className="input w-auto" value={branchId ?? ""} onChange={(e) => setBranchId(e.target.value)} aria-label="الفرع">
            {branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
          </select>
          {canEdit && <button onClick={() => setDraft({ ...EMPTY, sort_order: live.length + 1 })} className="btn-primary text-sm"><Plus className="h-4 w-4" /> سياسة جديدة</button>}
        </div>
      } />
      {(error || (q.error && all.length > 0)) && <div className="mb-4"><ErrorBanner message={(error ?? q.error) as string} /></div>}
      <div className="mb-4 flex items-start gap-2 rounded-xl bg-brand-50 p-4 text-sm text-brand-700">
        <Bot className="mt-0.5 h-4 w-4 shrink-0" />
        <p>السياسات المعلّمة «عامة» هي <strong>المصدر الوحيد</strong> لما يذكره المساعد الذكي عن المنشأة، وتظهر للنزيل في الشروط. أي سؤال لا تغطيه يُحوَّل إلى مشرف.</p>
      </div>
      <div className="mb-3 flex gap-2" role="tablist" aria-label="عرض السياسات">
        <button role="tab" aria-selected={!showArchived} className={!showArchived ? "btn-primary text-xs" : "btn-outline text-xs"} onClick={() => setShowArchived(false)}>النشطة ({live.length})</button>
        <button role="tab" aria-selected={showArchived} className={showArchived ? "btn-primary text-xs" : "btn-outline text-xs"} onClick={() => setShowArchived(true)}>المؤرشفة ({archived.length})</button>
      </div>

      {q.error && all.length === 0 ? <LoadErrorCard message={q.error} onRetry={load} /> : rows.length === 0 ? (
        showArchived ? <EmptyState icon={<Archive className="h-10 w-10" />} title="لا توجد سياسات مؤرشفة" />
          : <EmptyState icon={<FileText className="h-10 w-10" />} title="لا توجد سياسات لهذا الفرع" description="أضف سياسات الوصول والإلغاء والإنترنت وغيرها ليقرأها النزيل ويجيب عنها المساعد." action={canEdit ? <button className="btn-primary text-sm" onClick={() => setDraft({ ...EMPTY, sort_order: 1 })}><Plus className="h-4 w-4" /> سياسة جديدة</button> : undefined} />
      ) : (
        <div className="space-y-3">
          {rows.map((p) => (
            <Card key={p.id} data-testid={`policy-${p.id}`}>
              <div className="mb-2 flex flex-wrap items-center gap-2">
                <FileText className="h-4 w-4 text-brand-600" />
                <h3 className="text-sm font-semibold text-ink-800">{p.title}</h3>
                <Badge className="bg-ink-100 text-ink-500">{policyTopic(p)}</Badge>
                {p.archived_at ? <Badge className="bg-ink-100 text-ink-500">مؤرشفة</Badge>
                  : <Badge className={p.is_public ? "bg-success-500/10 text-success-600" : "bg-warning-500/10 text-warning-700"}>{p.is_public ? "عامة — يراها النزيل والمساعد" : "داخلية"}</Badge>}
                <span className="mr-auto text-xs text-ink-400">#{p.sort_order ?? 0}</span>
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
