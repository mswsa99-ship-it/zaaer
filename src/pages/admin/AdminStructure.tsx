import { COUNT } from "../../lib/utils";
import { useState } from "react";
import { Layers, Plus, Pencil, ChevronDown, ChevronUp } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { opsApi } from "../../lib/api";
import { SectionTitle, LoadingScreen, Card, EmptyState, ErrorBanner, LoadErrorCard } from "../../components/ui";
import { Modal, Field, ActionForm, Submit, DefinitionLifecycle, ArchivedBadge, Toggle } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";

interface Floor { id: string; block_id: string; name: string; sort_order: number; is_active: boolean; archived_at: string | null; version: number; rooms: number; facilities: number }
interface Block { id: string; name: string; description: string | null; sort_order: number; is_active: boolean; archived_at: string | null; version: number; floors: Floor[] }

const NO_BLOCKS: Block[] = [];

export default function AdminStructure() {
  const [showArchived, setShowArchived] = useState(false);
  const [blockDraft, setBlockDraft] = useState<Partial<Block> | null>(null);
  const [floorDraft, setFloorDraft] = useState<(Partial<Floor> & { block_id: string }) | null>(null);
  const [open, setOpen] = useState<Record<string, boolean>>({});

  // G24 (decision 40): the structure of the active branch only
  const q = useBranchQuery<Block[]>(async (branchId) => {
    const [b, f, r, fa] = await Promise.all([
      supabase.from("blocks").select("id, name, description, sort_order, is_active, archived_at, version").eq("branch_id", branchId).order("sort_order").order("name"),
      supabase.from("floors").select("id, block_id, name, sort_order, is_active, archived_at, version").eq("branch_id", branchId).order("sort_order").order("name"),
      supabase.from("rooms").select("floor_id").eq("branch_id", branchId).is("archived_at", null),
      supabase.from("facilities").select("floor_id").eq("branch_id", branchId).is("archived_at", null),
    ]);
    const roomCount = new Map<string, number>(); for (const x of (r.data ?? []) as { floor_id: string | null }[]) if (x.floor_id) roomCount.set(x.floor_id, (roomCount.get(x.floor_id) ?? 0) + 1);
    const facCount = new Map<string, number>(); for (const x of (fa.data ?? []) as { floor_id: string | null }[]) if (x.floor_id) facCount.set(x.floor_id, (facCount.get(x.floor_id) ?? 0) + 1);
    const floors = ((f.data ?? []) as Omit<Floor, "rooms" | "facilities">[]).map((x) => ({ ...x, rooms: roomCount.get(x.id) ?? 0, facilities: facCount.get(x.id) ?? 0 }));
    return (must(b) as Omit<Block, "floors">[]).map((x) => ({ ...x, floors: floors.filter((y) => y.block_id === x.id) }));
  }, [], NO_BLOCKS);
  const blocks = q.data; const load = q.reload; const branchId = q.branchId;

  const visible = blocks.filter((b) => showArchived || !b.archived_at);
  if (q.loading) return <LoadingScreen />;

  return (
    <div>
      <SectionTitle title="البلوكات والطوابق" subtitle="هيكل المنشأة: فرع ← بلوك ← طابق ← وحدة / مرفق" action={
        <div className="flex items-center gap-3">
          <BranchPicker />
          <button onClick={() => setBlockDraft({ name: "", description: "", sort_order: blocks.length + 1 })} className="btn-primary text-sm"><Plus className="h-4 w-4" /> بلوك جديد</button>
        </div>
      } />
      {q.error && blocks.length > 0 && <div className="mb-4"><ErrorBanner message={q.error} /></div>}
      <div className="mb-4"><Toggle checked={showArchived} onChange={setShowArchived} label="إظهار المؤرشف" /></div>
      {q.error && blocks.length === 0 ? <LoadErrorCard message={q.error} onRetry={load} /> : visible.length === 0 ? <EmptyState icon={<Layers className="h-10 w-10" />} title="لا توجد بلوكات" description="أضف بلوكًا ثم طوابقه، وبعدها اربط الوحدات والمرافق به." /> : (
        <div className="space-y-3">
          {visible.map((b) => (
            <Card key={b.id} className={b.archived_at ? "opacity-70" : ""}>
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <div className="flex items-center gap-2">
                    <h3 className="text-base font-semibold text-ink-800">{b.name}</h3>
                    <ArchivedBadge archivedAt={b.archived_at} />
                    {!b.is_active && !b.archived_at && <span className="badge bg-warning-500/10 text-warning-700">معطل</span>}
                  </div>
                  {b.description && <p className="mt-0.5 text-sm text-ink-500">{b.description}</p>}
                  <p className="mt-1 text-xs text-ink-400">{COUNT.floor(b.floors.filter((f) => !f.archived_at).length)} · {COUNT.unit(b.floors.reduce((a, f) => a + f.rooms, 0))} · {COUNT.facility(b.floors.reduce((a, f) => a + f.facilities, 0))}</p>
                </div>
                <div className="flex gap-2">
                  <button onClick={() => setBlockDraft(b)} className="btn-outline text-xs"><Pencil className="h-3.5 w-3.5" /> تعديل</button>
                  <button onClick={() => setFloorDraft({ block_id: b.id, name: "", sort_order: b.floors.length + 1 })} className="btn-outline text-xs"><Plus className="h-3.5 w-3.5" /> طابق</button>
                  <button onClick={() => setOpen((o) => ({ ...o, [b.id]: !o[b.id] }))} className="btn-ghost text-xs" aria-label={open[b.id] ? "طي الطوابق" : "عرض الطوابق"} aria-expanded={!!open[b.id]}>{open[b.id] ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}</button>
                </div>
              </div>
              {b.floors.length > 0 && (
                <div className="mt-3 overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead><tr className="text-xs text-ink-400"><th className="py-1 text-right font-medium">الطابق</th><th className="text-right font-medium">الترتيب</th><th className="text-right font-medium">الوحدات</th><th className="text-right font-medium">المرافق</th><th className="text-right font-medium">الحالة</th><th></th></tr></thead>
                    <tbody>
                      {b.floors.filter((f) => showArchived || !f.archived_at).map((f) => (
                        <tr key={f.id} className="border-t border-ink-50">
                          <td className="py-2 font-medium text-ink-700">{f.name}</td><td>{f.sort_order}</td><td>{f.rooms}</td><td>{f.facilities}</td>
                          <td>{f.archived_at ? <ArchivedBadge archivedAt={f.archived_at} /> : f.is_active ? <span className="badge bg-success-500/10 text-success-600">فعال</span> : <span className="badge bg-warning-500/10 text-warning-700">معطل</span>}</td>
                          <td className="text-left"><button onClick={() => setFloorDraft(f)} className="btn-ghost text-xs" aria-label="تعديل الطابق" title="تعديل"><Pencil className="h-3.5 w-3.5" /></button></td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
              {open[b.id] && <DefinitionLifecycle entity="block" id={b.id} archived={!!b.archived_at} onDone={load} />}
            </Card>
          ))}
        </div>
      )}

      <Modal open={!!blockDraft} title={blockDraft?.id ? "تعديل بلوك" : "بلوك جديد"} onClose={() => setBlockDraft(null)}>
        {blockDraft && (
          <ActionForm onSubmit={async () => { await opsApi.upsertBlock({ id: blockDraft.id, branch_id: branchId, name: blockDraft.name, description: blockDraft.description, sort_order: blockDraft.sort_order, is_active: blockDraft.is_active, version: blockDraft.version }); setBlockDraft(null); await load(); }}>
            <div className="space-y-3">
              <Field label="اسم البلوك (مطلوب)"><input className="input" value={blockDraft.name ?? ""} onChange={(e) => setBlockDraft({ ...blockDraft, name: e.target.value })} placeholder="مثال: B أو المبنى الشرقي" /></Field>
              <Field label="الوصف"><input className="input" value={blockDraft.description ?? ""} onChange={(e) => setBlockDraft({ ...blockDraft, description: e.target.value })} /></Field>
              <Field label="الترتيب"><input type="number" className="input" dir="ltr" value={blockDraft.sort_order ?? 0} onChange={(e) => setBlockDraft({ ...blockDraft, sort_order: Number(e.target.value) })} /></Field>
              {blockDraft.id && <Toggle checked={blockDraft.is_active ?? true} onChange={(v) => setBlockDraft({ ...blockDraft, is_active: v })} label="فعال" />}
            </div>
            <Submit label="حفظ" onCancel={() => setBlockDraft(null)} />
          </ActionForm>
        )}
        {blockDraft?.id && <DefinitionLifecycle entity="block" id={blockDraft.id} archived={!!blockDraft.archived_at} onDone={() => { setBlockDraft(null); load(); }} />}
      </Modal>

      <Modal open={!!floorDraft} title={floorDraft?.id ? "تعديل طابق" : "طابق جديد"} onClose={() => setFloorDraft(null)}>
        {floorDraft && (
          <ActionForm onSubmit={async () => { await opsApi.upsertFloor({ id: floorDraft.id, block_id: floorDraft.block_id, name: floorDraft.name, sort_order: floorDraft.sort_order, is_active: floorDraft.is_active, version: floorDraft.version }); setFloorDraft(null); await load(); }}>
            <div className="space-y-3">
              <Field label="اسم الطابق (نصي، مطلوب)" hint="يمكن أن يكون حرفًا أو كلمة: B، الأرضي، 1"><input className="input" value={floorDraft.name ?? ""} onChange={(e) => setFloorDraft({ ...floorDraft, name: e.target.value })} /></Field>
              <Field label="الترتيب"><input type="number" className="input" dir="ltr" value={floorDraft.sort_order ?? 0} onChange={(e) => setFloorDraft({ ...floorDraft, sort_order: Number(e.target.value) })} /></Field>
              {floorDraft.id && <Toggle checked={floorDraft.is_active ?? true} onChange={(v) => setFloorDraft({ ...floorDraft, is_active: v })} label="فعال" />}
            </div>
            <Submit label="حفظ" onCancel={() => setFloorDraft(null)} />
          </ActionForm>
        )}
        {floorDraft?.id && <DefinitionLifecycle entity="floor" id={floorDraft.id} archived={!!floorDraft.archived_at} onDone={() => { setFloorDraft(null); load(); }} />}
      </Modal>
    </div>
  );
}
