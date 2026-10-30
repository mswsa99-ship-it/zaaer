import { useMemo, useState } from "react";
import { DoorClosed, Plus, Pencil } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { opsApi } from "../../lib/api";
import { SectionTitle, LoadingScreen, Card, EmptyState, Badge, ErrorBanner, LoadErrorCard } from "../../components/ui";
import { Modal, Field, ActionForm, Submit, DefinitionLifecycle, ArchivedBadge, Toggle } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { ROOM_STATUS_LABELS, ROOM_STATUS_COLORS, CLEANLINESS_LABELS, CLEANLINESS_COLORS, type RoomStatus } from "../../lib/types";

interface RoomRow { id: string; room_number: string; status: RoomStatus; cleanliness: string; is_active: boolean; archived_at: string | null; version: number; notes: string | null; category_id: string; block_id: string | null; floor_id: string | null; category?: { name_ar: string } | null; block?: { name: string } | null; floor?: { name: string } | null }
interface Opt { id: string; name: string; block_id?: string }

const NO_DATA: { rooms: RoomRow[]; cats: Opt[]; blocks: Opt[]; floors: Opt[] } = { rooms: [], cats: [], blocks: [], floors: [] };

export default function AdminRooms() {
  const [filter, setFilter] = useState({ status: "all", block: "all", category: "all", archived: false, q: "" });
  const [draft, setDraft] = useState<Partial<RoomRow> | null>(null);

  // G24 (decision 40): the units of the active branch only
  const q = useBranchQuery(async (branchId) => {
    const [r, c, b, f] = await Promise.all([
      supabase.from("rooms").select("id, room_number, status, cleanliness, is_active, archived_at, version, notes, category_id, block_id, floor_id, category:room_categories(name_ar), block:blocks(name), floor:floors(name)").eq("branch_id", branchId).order("room_number"),
      supabase.from("room_categories").select("id, name_ar").eq("branch_id", branchId).is("archived_at", null).order("sort_order"),
      supabase.from("blocks").select("id, name").eq("branch_id", branchId).is("archived_at", null).order("sort_order"),
      supabase.from("floors").select("id, name, block_id").eq("branch_id", branchId).is("archived_at", null).order("sort_order"),
    ]);
    return {
      rooms: must(r) as unknown as RoomRow[],
      cats: ((c.data ?? []) as { id: string; name_ar: string }[]).map((x) => ({ id: x.id, name: x.name_ar })),
      blocks: (b.data as Opt[]) ?? [], floors: (f.data as Opt[]) ?? [],
    };
  }, [], NO_DATA);
  const { rooms, cats, blocks, floors } = q.data; const load = q.reload; const branchId = q.branchId;

  const visible = useMemo(() => rooms.filter((r) => (filter.archived || !r.archived_at) && (filter.status === "all" || r.status === filter.status) && (filter.block === "all" || r.block_id === filter.block) && (filter.category === "all" || r.category_id === filter.category) && (!filter.q || r.room_number.includes(filter.q))), [rooms, filter]);
  const counts = useMemo(() => ({ active: rooms.filter((r) => r.is_active && !r.archived_at).length, total: rooms.filter((r) => !r.archived_at).length }), [rooms]);
  const draftFloors = floors.filter((f) => !draft?.block_id || f.block_id === draft.block_id);

  if (q.loading) return <LoadingScreen />;
  return (
    <div>
      <SectionTitle title="الوحدات" subtitle={`${counts.active} فعالة من ${counts.total} — النشاط الإداري مستقل عن النظافة والإشغال`} action={
        <div className="flex items-center gap-3"><BranchPicker /><button onClick={() => setDraft({ room_number: "", is_active: true, category_id: cats[0]?.id })} className="btn-primary text-sm"><Plus className="h-4 w-4" /> وحدة جديدة</button></div>} />
      {q.error && rooms.length > 0 && <div className="mb-4"><ErrorBanner message={q.error} /></div>}
      <div className="mb-4 flex flex-wrap items-center gap-2">
        <input className="input w-36" aria-label="بحث برقم الوحدة" placeholder="بحث برقم الوحدة" value={filter.q} onChange={(e) => setFilter({ ...filter, q: e.target.value })} />
        <select className="input w-auto" value={filter.category} onChange={(e) => setFilter({ ...filter, category: e.target.value })} aria-label="النوع"><option value="all">كل الأنواع</option>{cats.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select>
        <select className="input w-auto" value={filter.block} onChange={(e) => setFilter({ ...filter, block: e.target.value })} aria-label="البلوك"><option value="all">كل البلوكات</option>{blocks.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select>
        <select className="input w-auto" value={filter.status} onChange={(e) => setFilter({ ...filter, status: e.target.value })} aria-label="الحالة"><option value="all">كل الحالات</option>{Object.entries(ROOM_STATUS_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
        <Toggle checked={filter.archived} onChange={(v) => setFilter({ ...filter, archived: v })} label="إظهار المؤرشف" />
      </div>
      {q.error && rooms.length === 0 ? <LoadErrorCard message={q.error} onRetry={load} /> : visible.length === 0 ? <EmptyState icon={<DoorClosed className="h-10 w-10" />} title="لا توجد وحدات مطابقة" /> : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          {visible.map((r) => (
            <Card key={r.id} className={r.archived_at ? "opacity-60" : ""}>
              <div className="flex items-start justify-between">
                <div>
                  <p className="text-base font-semibold text-ink-800">{r.room_number}</p>
                  <p className="text-xs text-ink-400">{r.category?.name_ar} · {r.block?.name ?? "—"} / {r.floor?.name ?? "—"}</p>
                </div>
                <button onClick={() => setDraft(r)} className="btn-ghost p-1.5" aria-label={`تعديل الوحدة ${r.room_number}`} title="تعديل"><Pencil className="h-4 w-4" /></button>
              </div>
              <div className="mt-3 flex flex-wrap gap-1.5">
                <Badge className={ROOM_STATUS_COLORS[r.status]}>{ROOM_STATUS_LABELS[r.status]}</Badge>
                <Badge className={CLEANLINESS_COLORS[r.cleanliness]}>{CLEANLINESS_LABELS[r.cleanliness]}</Badge>
                {!r.is_active && !r.archived_at && <Badge className="bg-warning-500/10 text-warning-700">معطلة</Badge>}
                <ArchivedBadge archivedAt={r.archived_at} />
              </div>
            </Card>
          ))}
        </div>
      )}

      <Modal open={!!draft} title={draft?.id ? `تعديل الوحدة ${draft.room_number}` : "وحدة جديدة"} onClose={() => setDraft(null)}>
        {draft && (
          <ActionForm onSubmit={async () => { await opsApi.upsertRoom({ id: draft.id, branch_id: branchId, room_number: draft.room_number, category_id: draft.category_id, block_id: draft.block_id || null, floor_id: draft.floor_id || null, notes: draft.notes, is_active: draft.is_active, version: draft.version }); setDraft(null); await load(); }}>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="رقم / اسم الوحدة (مطلوب)"><input className="input" value={draft.room_number ?? ""} onChange={(e) => setDraft({ ...draft, room_number: e.target.value })} dir="ltr" /></Field>
              <Field label="نوع الوحدة (مطلوب)"><select className="input" value={draft.category_id ?? ""} onChange={(e) => setDraft({ ...draft, category_id: e.target.value })}>{cats.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>
              <Field label="البلوك"><select className="input" value={draft.block_id ?? ""} onChange={(e) => setDraft({ ...draft, block_id: e.target.value || null, floor_id: null })}><option value="">—</option>{blocks.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select></Field>
              <Field label="الطابق"><select className="input" value={draft.floor_id ?? ""} onChange={(e) => setDraft({ ...draft, floor_id: e.target.value || null })}><option value="">—</option>{draftFloors.map((f) => <option key={f.id} value={f.id}>{f.name}</option>)}</select></Field>
              <Field label="ملاحظات" className="sm:col-span-2"><input className="input" value={draft.notes ?? ""} onChange={(e) => setDraft({ ...draft, notes: e.target.value })} /></Field>
            </div>
            {draft.id && <div className="mt-3"><Toggle checked={draft.is_active ?? true} onChange={(v) => setDraft({ ...draft, is_active: v })} label="وحدة فعالة (التعطيل يُرفض إذا كانت عليها حجوزات مستقبلية)" /></div>}
            <Submit label="حفظ" onCancel={() => setDraft(null)} />
          </ActionForm>
        )}
        {draft?.id && <DefinitionLifecycle entity="room" id={draft.id} archived={!!draft.archived_at} onDone={() => { setDraft(null); load(); }} />}
      </Modal>
    </div>
  );
}
