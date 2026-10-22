import { useCallback, useEffect, useState } from "react";
import { BedDouble, Plus, Pencil } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useBranch } from "../../lib/branch";
import { opsApi, toArabicError } from "../../lib/api";
import { SectionTitle, LoadingScreen, Card, EmptyState, Badge, ErrorBanner } from "../../components/ui";
import { Modal, Field, ActionForm, Submit, DefinitionLifecycle, ArchivedBadge, Toggle, MoneyInput } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { formatCurrency } from "../../lib/utils";

interface Cat { id: string; name_ar: string; name_en: string | null; description: string | null; base_capacity: number; max_capacity: number; base_price_halalas: number; amenities: string[] | null; is_active: boolean; is_public: boolean; sort_order: number; archived_at: string | null; version: number; rooms?: number }

export default function AdminRoomCategories() {
  const { branchId } = useBranch();
  const [cats, setCats] = useState<Cat[]>([]);
  const [loading, setLoading] = useState(true); const [error, setError] = useState<string | null>(null);
  const [showArchived, setShowArchived] = useState(false);
  const [draft, setDraft] = useState<Partial<Cat> | null>(null);

  const load = useCallback(async () => {
    if (!branchId) return;
    const [c, r] = await Promise.all([
      supabase.from("room_categories").select("id, name_ar, name_en, description, base_capacity, max_capacity, base_price_halalas, amenities, is_active, is_public, sort_order, archived_at, version").eq("branch_id", branchId).order("sort_order"),
      supabase.from("rooms").select("category_id").eq("branch_id", branchId).is("archived_at", null),
    ]);
    if (c.error) setError(toArabicError(c.error));
    const count = new Map<string, number>(); for (const x of (r.data ?? []) as { category_id: string }[]) count.set(x.category_id, (count.get(x.category_id) ?? 0) + 1);
    setCats(((c.data ?? []) as Cat[]).map((x) => ({ ...x, rooms: count.get(x.id) ?? 0 })));
    setLoading(false);
  }, [branchId]);
  useEffect(() => { load(); }, [load]);

  if (loading) return <LoadingScreen />;
  const visible = cats.filter((c) => showArchived || !c.archived_at);
  return (
    <div>
      <SectionTitle title="أنواع الوحدات" subtitle="السعة والسعر الأساسي — تغيير السعر لا يعيد تسعير الحجوزات القائمة" action={
        <div className="flex items-center gap-3"><BranchPicker /><button onClick={() => setDraft({ name_ar: "", base_capacity: 2, max_capacity: 4, base_price_halalas: 0, is_public: true, sort_order: cats.length + 1, amenities: [] })} className="btn-primary text-sm"><Plus className="h-4 w-4" /> نوع جديد</button></div>} />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      <div className="mb-4"><Toggle checked={showArchived} onChange={setShowArchived} label="إظهار المؤرشف" /></div>
      {visible.length === 0 ? <EmptyState icon={<BedDouble className="h-10 w-10" />} title="لا توجد أنواع" /> : (
        <div className="grid gap-3 md:grid-cols-2">
          {visible.map((c) => (
            <Card key={c.id} className={c.archived_at ? "opacity-60" : ""}>
              <div className="flex items-start justify-between gap-3">
                <div>
                  <div className="flex items-center gap-2"><h3 className="text-base font-semibold text-ink-800">{c.name_ar}</h3><ArchivedBadge archivedAt={c.archived_at} />{!c.is_public && <Badge className="bg-ink-100 text-ink-500">غير معلن</Badge>}</div>
                  {c.name_en && <p className="text-xs text-ink-400" dir="ltr">{c.name_en}</p>}
                  {c.description && <p className="mt-1 text-sm text-ink-500">{c.description}</p>}
                  <p className="mt-2 text-xs text-ink-500">السعة {c.base_capacity}–{c.max_capacity} · {c.rooms} وحدة · السعر الأساسي <span className="font-medium text-ink-700">{formatCurrency(c.base_price_halalas / 100)}</span> / ليلة</p>
                  {c.amenities && c.amenities.length > 0 && <p className="mt-1 text-xs text-ink-400">{c.amenities.join(" · ")}</p>}
                </div>
                <button onClick={() => setDraft(c)} className="btn-ghost p-1.5"><Pencil className="h-4 w-4" /></button>
              </div>
            </Card>
          ))}
        </div>
      )}
      <Modal open={!!draft} title={draft?.id ? "تعديل نوع" : "نوع جديد"} onClose={() => setDraft(null)}>
        {draft && (
          <ActionForm onSubmit={async () => { await opsApi.upsertRoomCategory({ id: draft.id, branch_id: branchId, name_ar: draft.name_ar, name_en: draft.name_en, description: draft.description, base_capacity: draft.base_capacity, max_capacity: draft.max_capacity, base_price_halalas: draft.base_price_halalas, amenities: draft.amenities ?? [], is_public: draft.is_public, is_active: draft.is_active, sort_order: draft.sort_order, version: draft.version }); setDraft(null); await load(); }}>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="الاسم العربي (مطلوب)"><input className="input" value={draft.name_ar ?? ""} onChange={(e) => setDraft({ ...draft, name_ar: e.target.value })} /></Field>
              <Field label="الاسم الإنجليزي"><input className="input" dir="ltr" value={draft.name_en ?? ""} onChange={(e) => setDraft({ ...draft, name_en: e.target.value })} /></Field>
              <Field label="الوصف" className="sm:col-span-2"><textarea className="input" rows={2} value={draft.description ?? ""} onChange={(e) => setDraft({ ...draft, description: e.target.value })} /></Field>
              <Field label="السعة الأساسية"><input type="number" min={1} className="input" dir="ltr" value={draft.base_capacity ?? 2} onChange={(e) => setDraft({ ...draft, base_capacity: Number(e.target.value) })} /></Field>
              <Field label="السعة القصوى"><input type="number" min={1} className="input" dir="ltr" value={draft.max_capacity ?? 4} onChange={(e) => setDraft({ ...draft, max_capacity: Number(e.target.value) })} /></Field>
              <Field label="السعر الأساسي لليلة"><MoneyInput valueHalalas={draft.base_price_halalas ?? 0} onChange={(h) => setDraft({ ...draft, base_price_halalas: h ?? 0 })} /></Field>
              <Field label="الترتيب"><input type="number" className="input" dir="ltr" value={draft.sort_order ?? 0} onChange={(e) => setDraft({ ...draft, sort_order: Number(e.target.value) })} /></Field>
              <Field label="المزايا (افصل بفاصلة)" className="sm:col-span-2" hint="وصف تسويقي؛ لا يُنشئ مهام أو مرافق"><input className="input" value={(draft.amenities ?? []).join("، ")} onChange={(e) => setDraft({ ...draft, amenities: e.target.value.split(/[،,]/).map((x) => x.trim()).filter(Boolean) })} /></Field>
            </div>
            <div className="mt-3 flex gap-4"><Toggle checked={draft.is_public ?? true} onChange={(v) => setDraft({ ...draft, is_public: v })} label="معلن للنزلاء" />{draft.id && <Toggle checked={draft.is_active ?? true} onChange={(v) => setDraft({ ...draft, is_active: v })} label="فعال" />}</div>
            <Submit label="حفظ" onCancel={() => setDraft(null)} />
          </ActionForm>
        )}
        {draft?.id && <DefinitionLifecycle entity="room_category" id={draft.id} archived={!!draft.archived_at} onDone={() => { setDraft(null); load(); }} />}
      </Modal>
    </div>
  );
}
