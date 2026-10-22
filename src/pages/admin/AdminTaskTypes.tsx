import { useCallback, useEffect, useState } from "react";
import { ListChecks, Plus, Pencil } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useBranch } from "../../lib/branch";
import { opsApi, toArabicError } from "../../lib/api";
import { SectionTitle, LoadingScreen, Card, EmptyState, ErrorBanner, Badge } from "../../components/ui";
import { Modal, Field, ActionForm, Submit, DefinitionLifecycle, ArchivedBadge, Toggle } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";

interface TaskType { id: string; code: string | null; name: string; description: string | null; is_active: boolean; archived_at: string | null; version: number; used?: number }

export default function AdminTaskTypes() {
  const { branchId } = useBranch();
  const [rows, setRows] = useState<TaskType[]>([]);
  const [loading, setLoading] = useState(true); const [error, setError] = useState<string | null>(null);
  const [showArchived, setShowArchived] = useState(false);
  const [draft, setDraft] = useState<Partial<TaskType> | null>(null);

  const load = useCallback(async () => {
    if (!branchId) return;
    const [t, u] = await Promise.all([
      supabase.from("task_types").select("id, code, name, description, is_active, archived_at, version").eq("branch_id", branchId).order("name"),
      supabase.from("housekeeping_tasks").select("task_type_id").eq("branch_id", branchId),
    ]);
    if (t.error) setError(toArabicError(t.error));
    const used = new Map<string, number>(); for (const x of (u.data ?? []) as { task_type_id: string }[]) used.set(x.task_type_id, (used.get(x.task_type_id) ?? 0) + 1);
    setRows(((t.data ?? []) as TaskType[]).map((x) => ({ ...x, used: used.get(x.id) ?? 0 })));
    setLoading(false);
  }, [branchId]);
  useEffect(() => { load(); }, [load]);

  if (loading) return <LoadingScreen />;
  const visible = rows.filter((r) => showArchived || !r.archived_at);
  return (
    <div>
      <SectionTitle title="أنواع المهام" subtitle="تعريف قابل لإعادة الاستخدام؛ المهمة الفعلية تُنشأ من شاشة خدمة الغرف" action={
        <div className="flex items-center gap-3"><BranchPicker /><button onClick={() => setDraft({ name: "", description: "" })} className="btn-primary text-sm"><Plus className="h-4 w-4" /> نوع جديد</button></div>} />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      <div className="mb-4"><Toggle checked={showArchived} onChange={setShowArchived} label="إظهار المؤرشف" /></div>
      {visible.length === 0 ? <EmptyState icon={<ListChecks className="h-10 w-10" />} title="لا توجد أنواع مهام" /> : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {visible.map((r) => (
            <Card key={r.id} className={r.archived_at ? "opacity-60" : ""}>
              <div className="flex items-start justify-between gap-2">
                <div>
                  <div className="flex items-center gap-2"><h3 className="font-semibold text-ink-800">{r.name}</h3>{r.code && <Badge className="bg-brand-50 text-brand-700">نظامي</Badge>}<ArchivedBadge archivedAt={r.archived_at} />{!r.is_active && !r.archived_at && <Badge className="bg-warning-500/10 text-warning-600">معطل</Badge>}</div>
                  <p className="text-xs text-ink-400">{r.used} مهمة مسجلة{r.code === "room_cleaning" ? " · يُستخدم تلقائيًا بعد المغادرة" : ""}</p>
                  {r.description && <p className="mt-1 text-sm text-ink-500">{r.description}</p>}
                </div>
                <button onClick={() => setDraft(r)} className="btn-ghost p-1.5"><Pencil className="h-4 w-4" /></button>
              </div>
            </Card>
          ))}
        </div>
      )}
      <Modal open={!!draft} title={draft?.id ? "تعديل نوع مهمة" : "نوع مهمة جديد"} onClose={() => setDraft(null)}>
        {draft && (
          <ActionForm onSubmit={async () => { await opsApi.upsertTaskType({ id: draft.id, branch_id: branchId, name: draft.name, description: draft.description, is_active: draft.is_active, version: draft.version }); setDraft(null); await load(); }}>
            <div className="space-y-3">
              <Field label="الاسم (مطلوب)" hint="تعديل الاسم لا يغير وصف المهام التاريخية"><input className="input" value={draft.name ?? ""} onChange={(e) => setDraft({ ...draft, name: e.target.value })} /></Field>
              <Field label="الوصف"><textarea className="input" rows={2} value={draft.description ?? ""} onChange={(e) => setDraft({ ...draft, description: e.target.value })} /></Field>
              {draft.id && <Toggle checked={draft.is_active ?? true} onChange={(v) => setDraft({ ...draft, is_active: v })} label="فعال" />}
            </div>
            <Submit label="حفظ" onCancel={() => setDraft(null)} />
          </ActionForm>
        )}
        {draft?.id && !draft.code && <DefinitionLifecycle entity="task_type" id={draft.id} archived={!!draft.archived_at} onDone={() => { setDraft(null); load(); }} />}
      </Modal>
    </div>
  );
}
