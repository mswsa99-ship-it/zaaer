import { useState } from "react";
import { BedDouble, Plus, Pencil } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { opsApi, ratesApi } from "../../lib/api";
import { SectionTitle, LoadingScreen, Card, EmptyState, Badge, ErrorBanner, LoadErrorCard } from "../../components/ui";
import { Modal, Field, ActionForm, Submit, DefinitionLifecycle, ArchivedBadge, Toggle, MoneyInput } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { formatCurrency, COUNT } from "../../lib/utils";

interface Cat { id: string; name_ar: string; name_en: string | null; description: string | null; base_capacity: number; max_capacity: number; base_price_halalas: number; amenities: string[] | null; is_active: boolean; is_public: boolean; sort_order: number; archived_at: string | null; version: number; rooms?: number;
  /** 0030: weekly and monthly prices (7+ / 30+ nights), the minimum nightly price, and one price or one for the platforms too */
  weekly_price_halalas: number | null; monthly_price_halalas: number | null; min_nightly_halalas: number | null; price_mode: "unified" | "by_channel" }
type Impact = Array<{ id: string; internal_ref: string; check_in: string; check_out: string; guests: number }>;
const sar = (h: number | null | undefined) => (h == null ? "—" : formatCurrency(h / 100));

const NO_CATS: Cat[] = [];

export default function AdminRoomCategories() {
  const [showArchived, setShowArchived] = useState(false);
  const [draft, setDraftRaw] = useState<Partial<Cat> | null>(null);
  // lowering the capacity first lists the upcoming stays that would no longer fit (decision 32)
  const [impact, setImpact] = useState<Impact | null>(null);
  const setDraft = (d: Partial<Cat> | null) => { setDraftRaw(d); setImpact(null); };

  // G24 (decision 40): the definitions of the active branch only
  const q = useBranchQuery<Cat[]>(async (branchId) => {
    const [c, r] = await Promise.all([
      supabase.from("room_categories").select("id, name_ar, name_en, description, base_capacity, max_capacity, base_price_halalas, weekly_price_halalas, monthly_price_halalas, min_nightly_halalas, price_mode, amenities, is_active, is_public, sort_order, archived_at, version").eq("branch_id", branchId).order("sort_order"),
      supabase.from("rooms").select("category_id").eq("branch_id", branchId).is("archived_at", null),
    ]);
    const count = new Map<string, number>(); for (const x of (r.data ?? []) as { category_id: string }[]) count.set(x.category_id, (count.get(x.category_id) ?? 0) + 1);
    return (must(c) as Cat[]).map((x) => ({ ...x, rooms: count.get(x.id) ?? 0 }));
  }, [], NO_CATS);
  const cats = q.data; const load = q.reload; const branchId = q.branchId;

  if (q.loading) return <LoadingScreen />;
  const visible = cats.filter((c) => showArchived || !c.archived_at);
  return (
    <div>
      <SectionTitle title="أنواع الوحدات" subtitle="السعة والأسعار — تغيير أي سعر لا يعيد تسعير الحجوزات القائمة؛ أسعار الليالي في «تقويم الأسعار»" action={
        <div className="flex items-center gap-3"><BranchPicker /><button onClick={() => setDraft({ name_ar: "", base_capacity: 2, max_capacity: 4, base_price_halalas: 0, weekly_price_halalas: null, monthly_price_halalas: null, min_nightly_halalas: null, price_mode: "unified", is_public: true, sort_order: cats.length + 1, amenities: [] })} className="btn-primary text-sm"><Plus className="h-4 w-4" /> نوع جديد</button></div>} />
      {q.error && cats.length > 0 && <div className="mb-4"><ErrorBanner message={q.error} /></div>}
      <div className="mb-4"><Toggle checked={showArchived} onChange={setShowArchived} label="إظهار المؤرشف" /></div>
      {q.error && cats.length === 0 ? <LoadErrorCard message={q.error} onRetry={load} /> : visible.length === 0 ? <EmptyState icon={<BedDouble className="h-10 w-10" />} title="لا توجد أنواع" /> : (
        <div className="grid gap-3 md:grid-cols-2">
          {visible.map((c) => (
            <Card key={c.id} className={c.archived_at ? "opacity-60" : ""}>
              <div className="flex items-start justify-between gap-3">
                <div>
                  <div className="flex items-center gap-2"><h3 className="text-base font-semibold text-ink-800">{c.name_ar}</h3><ArchivedBadge archivedAt={c.archived_at} />{!c.is_public && <Badge className="bg-ink-100 text-ink-500">غير معلن</Badge>}</div>
                  {c.name_en && <p className="text-xs text-ink-400" dir="ltr">{c.name_en}</p>}
                  {c.description && <p className="mt-1 text-sm text-ink-500">{c.description}</p>}
                  <p className="mt-2 text-xs text-ink-500">السعة {c.base_capacity}–{c.max_capacity} · {COUNT.unit(c.rooms ?? 0)} · السعر الأساسي <span className="font-medium text-ink-700">{formatCurrency(c.base_price_halalas / 100)}</span> / ليلة</p>
                  <p className="mt-1 text-xs text-ink-400" data-testid="category-prices">{[c.weekly_price_halalas != null ? `أسبوعي ${sar(c.weekly_price_halalas)}` : null, c.monthly_price_halalas != null ? `شهري ${sar(c.monthly_price_halalas)}` : null, c.min_nightly_halalas != null ? `الأدنى ${sar(c.min_nightly_halalas)}` : null, c.price_mode === "by_channel" ? "مختلف للمنصات" : "سعر موحد"].filter(Boolean).join(" · ")}</p>
                  {c.amenities && c.amenities.length > 0 && <p className="mt-1 text-xs text-ink-400">{c.amenities.join(" · ")}</p>}
                </div>
                <button onClick={() => setDraft(c)} className="btn-ghost p-1.5" title="تعديل" aria-label={`تعديل ${c.name_ar}`}><Pencil className="h-4 w-4" /></button>
              </div>
            </Card>
          ))}
        </div>
      )}
      <Modal open={!!draft} title={draft?.id ? "تعديل نوع" : "نوع جديد"} onClose={() => setDraft(null)}>
        {draft && (
          <ActionForm onSubmit={async () => {
            const orig = cats.find((c) => c.id === draft.id);
            if (orig && draft.max_capacity != null && draft.max_capacity < orig.max_capacity && impact === null) {
              const list = await ratesApi.capacityImpact(orig.id, draft.max_capacity);
              if (list.length > 0) { setImpact(list); return; }   // shown below; saving again confirms
            }
            await opsApi.upsertRoomCategory({ id: draft.id, branch_id: branchId, name_ar: draft.name_ar, name_en: draft.name_en, description: draft.description, base_capacity: draft.base_capacity, max_capacity: draft.max_capacity,
              base_price_halalas: draft.base_price_halalas, weekly_price_halalas: draft.weekly_price_halalas ?? null, monthly_price_halalas: draft.monthly_price_halalas ?? null, min_nightly_halalas: draft.min_nightly_halalas ?? null,
              price_mode: draft.price_mode ?? "unified", amenities: draft.amenities ?? [], is_public: draft.is_public, is_active: draft.is_active, sort_order: draft.sort_order, version: draft.version });
            setDraft(null); await load();
          }}>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="الاسم العربي (مطلوب)"><input className="input" value={draft.name_ar ?? ""} onChange={(e) => setDraft({ ...draft, name_ar: e.target.value })} /></Field>
              <Field label="الاسم الإنجليزي"><input className="input" dir="ltr" value={draft.name_en ?? ""} onChange={(e) => setDraft({ ...draft, name_en: e.target.value })} /></Field>
              <Field label="الوصف" className="sm:col-span-2"><textarea className="input" rows={2} value={draft.description ?? ""} onChange={(e) => setDraft({ ...draft, description: e.target.value })} /></Field>
              <Field label="السعة الأساسية"><input type="number" min={1} className="input" dir="ltr" value={draft.base_capacity ?? 2} onChange={(e) => setDraft({ ...draft, base_capacity: Number(e.target.value) })} /></Field>
              <Field label="السعة القصوى"><input type="number" min={1} className="input" dir="ltr" aria-label="السعة القصوى" value={draft.max_capacity ?? 4} onChange={(e) => setDraft({ ...draft, max_capacity: Number(e.target.value) })} /></Field>
              <Field label="السعر الأساسي لليلة" hint="لكل ليلة ليس لها سعر في التقويم."><MoneyInput valueHalalas={draft.base_price_halalas ?? 0} onChange={(h) => setDraft({ ...draft, base_price_halalas: h ?? 0 })} /></Field>
              <Field label="أدنى سعر لليلة" hint="لا يُسعَّر التقويم تحته، ولا يخصم المشرف تحته."><MoneyInput valueHalalas={draft.min_nightly_halalas ?? null} onChange={(h) => setDraft({ ...draft, min_nightly_halalas: h })} placeholder="بلا حد" /></Field>
              <Field label="السعر الأسبوعي (7 ليالٍ)" hint="يُطبَّق على إقامة 7 ليالٍ فأكثر عند إنشائها."><MoneyInput valueHalalas={draft.weekly_price_halalas ?? null} onChange={(h) => setDraft({ ...draft, weekly_price_halalas: h })} placeholder="بلا سعر أسبوعي" /></Field>
              <Field label="السعر الشهري (30 ليلة)" hint="يُطبَّق على إقامة 30 ليلة فأكثر عند إنشائها."><MoneyInput valueHalalas={draft.monthly_price_halalas ?? null} onChange={(h) => setDraft({ ...draft, monthly_price_halalas: h })} placeholder="بلا سعر شهري" /></Field>
              <Field label="تصنيف السعر"><select className="input" value={draft.price_mode ?? "unified"} onChange={(e) => setDraft({ ...draft, price_mode: e.target.value as Cat["price_mode"] })}><option value="unified">موحد — سعر واحد لكل الحجوزات</option><option value="by_channel">مختلف للمنصات — سعر النظام وسعر المنصات</option></select></Field>
              <Field label="الترتيب"><input type="number" className="input" dir="ltr" value={draft.sort_order ?? 0} onChange={(e) => setDraft({ ...draft, sort_order: Number(e.target.value) })} /></Field>
              <Field label="المزايا (افصل بفاصلة)" className="sm:col-span-2" hint="وصف تسويقي؛ لا يُنشئ مهام أو مرافق"><input className="input" value={(draft.amenities ?? []).join("، ")} onChange={(e) => setDraft({ ...draft, amenities: e.target.value.split(/[،,]/).map((x) => x.trim()).filter(Boolean) })} /></Field>
            </div>
            <div className="mt-3 flex gap-4"><Toggle checked={draft.is_public ?? true} onChange={(v) => setDraft({ ...draft, is_public: v })} label="معلن للنزلاء" />{draft.id && <Toggle checked={draft.is_active ?? true} onChange={(v) => setDraft({ ...draft, is_active: v })} label="فعال" />}</div>
            {impact && impact.length > 0 && (
              <div className="mt-4 rounded-xl bg-warning-500/10 p-3 text-sm text-warning-700" role="alert" data-testid="capacity-impact">
                <p className="font-medium">{impact.length} حجز قادم فيه نزلاء أكثر من السعة الجديدة:</p>
                <ul className="mt-1 list-inside list-disc text-xs">{impact.map((x) => <li key={x.id}><span className="font-mono">{x.internal_ref}</span> · {x.guests} نزلاء · <span dir="ltr">{x.check_in} → {x.check_out}</span></li>)}</ul>
                <p className="mt-1 text-xs">تبقى هذه الحجوزات كما هي. احفظ مرة أخرى لتأكيد السعة الجديدة.</p>
              </div>
            )}
            <Submit label={impact && impact.length > 0 ? "حفظ رغم ذلك" : "حفظ"} onCancel={() => setDraft(null)} />
          </ActionForm>
        )}
        {draft?.id && <DefinitionLifecycle entity="room_category" id={draft.id} archived={!!draft.archived_at} onDone={() => { setDraft(null); load(); }} />}
      </Modal>
    </div>
  );
}
