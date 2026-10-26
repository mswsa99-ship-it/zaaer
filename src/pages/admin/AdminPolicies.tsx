import { useState } from "react";
import { supabase } from "../../lib/supabase";
import { toArabicError } from "../../lib/api";
import { useAuth } from "../../lib/auth";
import { useBranch } from "../../lib/branch";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { SectionTitle, Card, LoadingScreen, Badge, Spinner, ErrorBanner, EmptyState, LoadErrorCard } from "../../components/ui";
import { FileText, Plus, Pencil, Trash2, Bot } from "lucide-react";

const TOPICS: Record<string, string> = {
  checkin: "الوصول والمغادرة", cancellation: "الإلغاء", wifi: "الإنترنت", parking: "المواقف", location: "الموقع",
  children: "الأطفال والمرافقون", contact: "التواصل", stay: "شروط الإقامة", privacy: "الخصوصية", other: "أخرى",
};

interface PolicyRow { id: string; topic: string; title: string; content_ar: string; is_public: boolean; sort_order: number | null }
type Draft = Omit<PolicyRow, "id"> & { id?: string };

const EMPTY: Draft = { topic: "checkin", title: "", content_ar: "", is_public: true, sort_order: 0 };
const NO_POLICIES: PolicyRow[] = [];

export default function AdminPolicies() {
  const { profile, can } = useAuth();
  const canEdit = can("policies");
  const { branches, setBranchId } = useBranch();
  const [error, setError] = useState<string | null>(null);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [busy, setBusy] = useState(false);

  // G24 (decision 40): the active branch's policies only
  const q = useBranchQuery<PolicyRow[]>(async (branchId) => must(await supabase.from("property_policies")
    .select("id, topic, title, content_ar, is_public, sort_order").eq("branch_id", branchId).order("sort_order").order("created_at")) as PolicyRow[], [], NO_POLICIES);
  const rows = q.data; const branchId = q.branchId; const load = q.reload;

  async function save() {
    if (!draft || !branchId || !profile) return;
    if (!draft.title.trim() || !draft.content_ar.trim()) { setError("العنوان والمحتوى مطلوبان."); return; }
    setBusy(true); setError(null);
    const payload = { topic: draft.topic, title: draft.title.trim(), content_ar: draft.content_ar.trim(), is_public: draft.is_public, sort_order: draft.sort_order ?? 0, updated_by: profile.id, updated_at: new Date().toISOString() };
    const op = draft.id
      ? supabase.from("property_policies").update(payload).eq("id", draft.id)
      : supabase.from("property_policies").insert({ ...payload, branch_id: branchId, organization_id: profile.organization_id });
    const { error: e } = await op;
    if (e) setError(toArabicError(e)); else { setDraft(null); load(); }
    setBusy(false);
  }

  const [pendingDelete, setPendingDelete] = useState<string | null>(null);
  async function remove(id: string) {
    // two-step confirmation inside the page (native confirm() dialogs are not available in every host)
    if (pendingDelete !== id) { setPendingDelete(id); setError("اضغط «حذف» مرة أخرى لتأكيد حذف السياسة؛ لن يتمكن المساعد الذكي من ذكرها بعد الحذف."); return; }
    setPendingDelete(null);
    setBusy(true); setError(null);
    const { error: e } = await supabase.from("property_policies").delete().eq("id", id);
    if (e) setError(toArabicError(e)); else load();
    setBusy(false);
  }

  if (q.loading) return <LoadingScreen />;

  return (
    <div>
      <SectionTitle title="السياسات" subtitle="قاعدة المعرفة العامة للمنشأة لكل فرع" action={
        <div className="flex items-center gap-2">
          <select className="input w-auto" value={branchId ?? ""} onChange={(e) => setBranchId(e.target.value)}>
            {branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
          </select>
          {canEdit && <button onClick={() => setDraft({ ...EMPTY, sort_order: rows.length + 1 })} className="btn-primary text-sm"><Plus className="h-4 w-4" /> سياسة جديدة</button>}
        </div>
      } />
      {(error || (q.error && rows.length > 0)) && <div className="mb-4"><ErrorBanner message={(error ?? q.error) as string} /></div>}
      <div className="mb-4 flex items-start gap-2 rounded-xl bg-brand-50 p-4 text-sm text-brand-700">
        <Bot className="mt-0.5 h-4 w-4 shrink-0" />
        <p>هذه السياسات (المعلّمة "عامة") هي <strong>المصدر الوحيد</strong> للحقائق التي يُسمح للمساعد الذكي بذكرها عن المنشأة. لا يستنتج المساعد أي سياسة من خارجها، وأي سؤال لا تغطيه يُحوَّل إلى مشرف.</p>
      </div>

      {q.error && rows.length === 0 ? <LoadErrorCard message={q.error} onRetry={load} /> : rows.length === 0 ? (
        <EmptyState icon={<FileText className="h-10 w-10" />} title="لا توجد سياسات لهذا الفرع" description="أضف سياسات الوصول والإلغاء والإنترنت وغيرها ليتمكن المساعد من الإجابة عنها." />
      ) : (
        <div className="space-y-3">
          {rows.map((p) => (
            <Card key={p.id}>
              <div className="mb-2 flex items-center gap-2">
                <FileText className="h-4 w-4 text-brand-600" />
                <h3 className="text-sm font-semibold text-ink-800">{p.title}</h3>
                <Badge className="bg-ink-100 text-ink-500">{TOPICS[p.topic] ?? p.topic}</Badge>
                <Badge className={p.is_public ? "bg-success-500/10 text-success-600" : "bg-warning-500/10 text-warning-600"}>{p.is_public ? "عامة — يراها المساعد" : "داخلية"}</Badge>
                <span className="mr-auto text-xs text-ink-300">#{p.sort_order ?? 0}</span>
                {canEdit && (
                  <>
                    <button onClick={() => setDraft({ ...p })} className="text-ink-400 hover:text-brand-600" title="تعديل"><Pencil className="h-4 w-4" /></button>
                    <button onClick={() => remove(p.id)} disabled={busy} className="text-ink-400 hover:text-danger-600" title="حذف"><Trash2 className="h-4 w-4" /></button>
                  </>
                )}
              </div>
              <p className="whitespace-pre-line text-sm leading-relaxed text-ink-600">{p.content_ar}</p>
            </Card>
          ))}
        </div>
      )}

      {draft && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/40 p-4" role="dialog" aria-modal="true">
          <Card className="w-full max-w-lg">
            <h3 className="mb-4 text-base font-semibold text-ink-800">{draft.id ? "تعديل سياسة" : "سياسة جديدة"}</h3>
            <div className="grid gap-3 sm:grid-cols-2">
              <div>
                <label className="label">الموضوع</label>
                <select className="input" value={draft.topic} onChange={(e) => setDraft({ ...draft, topic: e.target.value })}>
                  {Object.entries(TOPICS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                </select>
              </div>
              <div><label className="label">الترتيب</label><input type="number" className="input" dir="ltr" value={draft.sort_order ?? 0} onChange={(e) => setDraft({ ...draft, sort_order: Number(e.target.value) })} /></div>
              <div className="sm:col-span-2"><label className="label">العنوان</label><input className="input" value={draft.title} onChange={(e) => setDraft({ ...draft, title: e.target.value })} /></div>
              <div className="sm:col-span-2"><label className="label">المحتوى (عربي)</label><textarea className="input min-h-[120px]" value={draft.content_ar} onChange={(e) => setDraft({ ...draft, content_ar: e.target.value })} /></div>
              <label className="flex items-center gap-2 text-sm text-ink-700 sm:col-span-2">
                <input type="checkbox" className="h-4 w-4 accent-brand-600" checked={draft.is_public} onChange={(e) => setDraft({ ...draft, is_public: e.target.checked })} />
                عامة — تُعرض للنزلاء ويُسمح للمساعد الذكي بذكرها
              </label>
            </div>
            <div className="mt-5 flex justify-end gap-2">
              <button onClick={() => setDraft(null)} className="btn-outline text-sm" disabled={busy}>إلغاء</button>
              <button onClick={save} className="btn-primary text-sm" disabled={busy}>{busy ? <Spinner className="h-4 w-4" /> : "حفظ"}</button>
            </div>
          </Card>
        </div>
      )}
    </div>
  );
}
