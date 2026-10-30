import { useState } from "react";
import { Landmark, Plus, Pencil } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { opsApi } from "../../lib/api";
import { SectionTitle, LoadingScreen, Card, EmptyState, ErrorBanner, Badge, LoadErrorCard } from "../../components/ui";
import { Modal, Field, ActionForm, Submit, DefinitionLifecycle, ArchivedBadge, Toggle } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";

interface Facility { id: string; name: string; description: string | null; block_id: string | null; floor_id: string | null; is_active: boolean; archived_at: string | null; version: number; block?: { name: string } | null; floor?: { name: string } | null; open_tasks?: number }
interface Opt { id: string; name: string; block_id?: string }

const NO_DATA: { rows: Facility[]; blocks: Opt[]; floors: Opt[] } = { rows: [], blocks: [], floors: [] };

export default function AdminFacilities() {
  const [showArchived, setShowArchived] = useState(false);
  const [draft, setDraft] = useState<Partial<Facility> | null>(null);

  // G24 (decision 40): the definitions of the active branch only
  const q = useBranchQuery(async (branchId) => {
    const [f, b, fl, t] = await Promise.all([
      supabase.from("facilities").select("id, name, description, block_id, floor_id, is_active, archived_at, version, block:blocks(name), floor:floors(name)").eq("branch_id", branchId).order("name"),
      supabase.from("blocks").select("id, name").eq("branch_id", branchId).is("archived_at", null).order("sort_order"),
      supabase.from("floors").select("id, name, block_id").eq("branch_id", branchId).is("archived_at", null).order("sort_order"),
      supabase.from("housekeeping_tasks").select("facility_id").eq("branch_id", branchId).in("status", ["pending", "in_progress"]).not("facility_id", "is", null),
    ]);
    const open = new Map<string, number>(); for (const x of (t.data ?? []) as { facility_id: string }[]) open.set(x.facility_id, (open.get(x.facility_id) ?? 0) + 1);
    return {
      rows: (must(f) as unknown as Facility[]).map((x) => ({ ...x, open_tasks: open.get(x.id) ?? 0 })),
      blocks: (b.data as Opt[]) ?? [], floors: (fl.data as Opt[]) ?? [],
    };
  }, [], NO_DATA);
  const { rows, blocks, floors } = q.data; const load = q.reload; const branchId = q.branchId;

  if (q.loading) return <LoadingScreen />;
  const visible = rows.filter((r) => showArchived || !r.archived_at);
  const draftFloors = floors.filter((f) => !draft?.block_id || f.block_id === draft.block_id);
  return (
    <div>
      <SectionTitle title="المرافق" subtitle="مساحات وعناصر مشتركة (ممرات، جلسات، دورات مياه، بوابات) — ليست وحدات إيجارية" action={
        <div className="flex items-center gap-3"><BranchPicker /><button onClick={() => setDraft({ name: "", description: "" })} className="btn-primary text-sm"><Plus className="h-4 w-4" /> مرفق جديد</button></div>} />
      {q.error && rows.length > 0 && <div className="mb-4"><ErrorBanner message={q.error} /></div>}
      <div className="mb-4"><Toggle checked={showArchived} onChange={setShowArchived} label="إظهار المؤرشف" /></div>
      {q.error && rows.length === 0 ? <LoadErrorCard message={q.error} onRetry={load} /> : visible.length === 0 ? <EmptyState icon={<Landmark className="h-10 w-10" />} title="لا توجد مرافق" /> : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {visible.map((r) => (
            <Card key={r.id} className={r.archived_at ? "opacity-60" : ""}>
              <div className="flex items-start justify-between gap-2">
                <div>
                  <div className="flex items-center gap-2"><h3 className="font-semibold text-ink-800">{r.name}</h3><ArchivedBadge archivedAt={r.archived_at} />{!r.is_active && !r.archived_at && <Badge className="bg-warning-500/10 text-warning-700">معطل</Badge>}</div>
                  <p className="text-xs text-ink-400">{r.block?.name ?? "—"} / {r.floor?.name ?? "—"}{r.open_tasks ? ` · مهام مفتوحة: ${r.open_tasks}` : ""}</p>
                  {r.description && <p className="mt-1 text-sm text-ink-500">{r.description}</p>}
                </div>
                <button onClick={() => setDraft(r)} className="btn-ghost p-1.5" aria-label="تعديل المرفق" title="تعديل"><Pencil className="h-4 w-4" /></button>
              </div>
            </Card>
          ))}
        </div>
      )}
      <Modal open={!!draft} title={draft?.id ? "تعديل مرفق" : "مرفق جديد"} onClose={() => setDraft(null)}>
        {draft && (
          <ActionForm onSubmit={async () => { await opsApi.upsertFacility({ id: draft.id, branch_id: branchId, name: draft.name, description: draft.description, block_id: draft.block_id || null, floor_id: draft.floor_id || null, is_active: draft.is_active, version: draft.version }); setDraft(null); await load(); }}>
            <div className="space-y-3">
              <Field label="الاسم (مطلوب)"><input className="input" value={draft.name ?? ""} onChange={(e) => setDraft({ ...draft, name: e.target.value })} /></Field>
              <div className="grid gap-3 sm:grid-cols-2">
                <Field label="البلوك"><select className="input" value={draft.block_id ?? ""} onChange={(e) => setDraft({ ...draft, block_id: e.target.value || null, floor_id: null })}><option value="">—</option>{blocks.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select></Field>
                <Field label="الطابق"><select className="input" value={draft.floor_id ?? ""} onChange={(e) => setDraft({ ...draft, floor_id: e.target.value || null })}><option value="">—</option>{draftFloors.map((f) => <option key={f.id} value={f.id}>{f.name}</option>)}</select></Field>
              </div>
              <Field label="الوصف"><textarea className="input" rows={2} value={draft.description ?? ""} onChange={(e) => setDraft({ ...draft, description: e.target.value })} /></Field>
              {draft.id && <Toggle checked={draft.is_active ?? true} onChange={(v) => setDraft({ ...draft, is_active: v })} label="فعال" />}
            </div>
            <Submit label="حفظ" onCancel={() => setDraft(null)} />
          </ActionForm>
        )}
        {draft?.id && <DefinitionLifecycle entity="facility" id={draft.id} archived={!!draft.archived_at} onDone={() => { setDraft(null); load(); }} />}
      </Modal>
    </div>
  );
}
