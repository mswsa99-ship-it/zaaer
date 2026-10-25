import { useState } from "react";
import { ConciergeBell, Plus, Pencil } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { opsApi } from "../../lib/api";
import { SectionTitle, LoadingScreen, Card, EmptyState, ErrorBanner, Badge, LoadErrorCard } from "../../components/ui";
import { Modal, Field, ActionForm, Submit, DefinitionLifecycle, ArchivedBadge, Toggle, MoneyInput } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { BILLING_UNIT_LABELS } from "../../lib/types";
import { formatCurrency } from "../../lib/utils";

interface Service { id: string; name_ar: string; name_en: string | null; description: string | null; billing_unit: string; price_halalas: number; is_free: boolean; taxable: boolean; task_type_id: string | null; late_checkout_until: string | null; is_active: boolean; archived_at: string | null; version: number }

const NO_DATA: { rows: Service[]; taskTypes: { id: string; name: string }[] } = { rows: [], taskTypes: [] };

export default function AdminServices() {
  const [showArchived, setShowArchived] = useState(false);
  const [draft, setDraft] = useState<Partial<Service> | null>(null);

  // G24 (decision 40): the definitions of the active branch only
  const q = useBranchQuery(async (branchId) => {
    const [s, t] = await Promise.all([
      supabase.from("service_definitions").select("id, name_ar, name_en, description, billing_unit, price_halalas, is_free, taxable, task_type_id, late_checkout_until, is_active, archived_at, version").eq("branch_id", branchId).order("name_ar"),
      supabase.from("task_types").select("id, name").eq("branch_id", branchId).is("archived_at", null).order("name"),
    ]);
    return { rows: must(s) as Service[], taskTypes: (t.data as { id: string; name: string }[]) ?? [] };
  }, [], NO_DATA);
  const { rows, taskTypes } = q.data; const load = q.reload; const branchId = q.branchId;

  if (q.loading) return <LoadingScreen />;
  const visible = rows.filter((r) => showArchived || !r.archived_at);
  return (
    <div>
      <SectionTitle title="الخدمات" subtitle="كتالوج الخدمات الاختيارية على الحجز — يُحفظ الاسم والسعر لحظة الإضافة ولا تتغير الحجوزات السابقة بتعديله" action={
        <div className="flex items-center gap-3"><BranchPicker /><button onClick={() => setDraft({ name_ar: "", billing_unit: "once", price_halalas: 0, is_free: false, taxable: true })} className="btn-primary text-sm"><Plus className="h-4 w-4" /> خدمة جديدة</button></div>} />
      {q.error && rows.length > 0 && <div className="mb-4"><ErrorBanner message={q.error} /></div>}
      <div className="mb-4"><Toggle checked={showArchived} onChange={setShowArchived} label="إظهار المؤرشف" /></div>
      {q.error && rows.length === 0 ? <LoadErrorCard message={q.error} onRetry={load} /> : visible.length === 0 ? <EmptyState icon={<ConciergeBell className="h-10 w-10" />} title="لا توجد خدمات" description="أضف خدمات مثل الإفطار أو التنظيف الإضافي أو الدخول المبكر." /> : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {visible.map((r) => (
            <Card key={r.id} className={r.archived_at ? "opacity-60" : ""}>
              <div className="flex items-start justify-between gap-2">
                <div>
                  <div className="flex items-center gap-2"><h3 className="font-semibold text-ink-800">{r.name_ar}</h3><ArchivedBadge archivedAt={r.archived_at} />{!r.is_active && !r.archived_at && <Badge className="bg-warning-500/10 text-warning-600">معطلة</Badge>}</div>
                  <p className="text-sm text-ink-700">{r.is_free ? "مجانية" : formatCurrency(r.price_halalas / 100)} <span className="text-xs text-ink-400">· {BILLING_UNIT_LABELS[r.billing_unit]} · {r.taxable ? "خاضعة للضريبة" : "بدون ضريبة"}</span></p>
                  {r.late_checkout_until && <p className="mt-1 text-xs text-brand-700">مغادرة متأخرة: تنقل المغادرة إلى الساعة <span dir="ltr">{r.late_checkout_until.slice(0, 5)}</span></p>}
                  {r.description && <p className="mt-1 text-xs text-ink-500">{r.description}</p>}
                </div>
                <button onClick={() => setDraft(r)} className="btn-ghost p-1.5"><Pencil className="h-4 w-4" /></button>
              </div>
            </Card>
          ))}
        </div>
      )}
      <Modal open={!!draft} title={draft?.id ? "تعديل خدمة" : "خدمة جديدة"} onClose={() => setDraft(null)}>
        {draft && (
          <ActionForm onSubmit={async () => { await opsApi.upsertService({ id: draft.id, branch_id: branchId, name_ar: draft.name_ar, name_en: draft.name_en, description: draft.description, billing_unit: draft.billing_unit, price_halalas: draft.price_halalas, is_free: draft.is_free, taxable: draft.taxable, task_type_id: draft.task_type_id || null, late_checkout_until: (draft.billing_unit ?? "once") === "once" ? draft.late_checkout_until || null : null, is_active: draft.is_active, version: draft.version }); setDraft(null); await load(); }}>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="الاسم العربي (مطلوب)"><input className="input" value={draft.name_ar ?? ""} onChange={(e) => setDraft({ ...draft, name_ar: e.target.value })} /></Field>
              <Field label="الاسم الإنجليزي"><input className="input" dir="ltr" value={draft.name_en ?? ""} onChange={(e) => setDraft({ ...draft, name_en: e.target.value })} /></Field>
              <Field label="وحدة الاحتساب"><select className="input" value={draft.billing_unit ?? "once"} onChange={(e) => setDraft({ ...draft, billing_unit: e.target.value })}>{Object.entries(BILLING_UNIT_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></Field>
              <Field label="السعر"><MoneyInput valueHalalas={draft.price_halalas ?? 0} onChange={(h) => setDraft({ ...draft, price_halalas: h ?? 0 })} disabled={draft.is_free} /></Field>
              {(draft.billing_unit ?? "once") === "once" && (
                <Field label="مغادرة متأخرة حتى الساعة (اختياري)" className="sm:col-span-2" hint="خدمة مغادرة متأخرة: تنقل موعد مغادرة الإقامة إلى هذه الساعة، وتكون بعد موعد المغادرة في الفرع. تُحتسب مرة واحدة.">
                  <input type="time" className="input" dir="ltr" value={draft.late_checkout_until?.slice(0, 5) ?? ""} onChange={(e) => setDraft({ ...draft, late_checkout_until: e.target.value || null })} aria-label="مغادرة متأخرة حتى الساعة" />
                </Field>
              )}
              <Field label="نوع المهمة المرتبط (اختياري)" className="sm:col-span-2"><select className="input" value={draft.task_type_id ?? ""} onChange={(e) => setDraft({ ...draft, task_type_id: e.target.value || null })}><option value="">—</option>{taskTypes.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</select></Field>
              <Field label="الوصف" className="sm:col-span-2"><textarea className="input" rows={2} value={draft.description ?? ""} onChange={(e) => setDraft({ ...draft, description: e.target.value })} /></Field>
            </div>
            <div className="mt-3 flex flex-wrap gap-4"><Toggle checked={draft.is_free ?? false} onChange={(v) => setDraft({ ...draft, is_free: v })} label="مجانية" /><Toggle checked={draft.taxable ?? true} onChange={(v) => setDraft({ ...draft, taxable: v })} label="خاضعة للضريبة" />{draft.id && <Toggle checked={draft.is_active ?? true} onChange={(v) => setDraft({ ...draft, is_active: v })} label="فعالة" />}</div>
            <Submit label="حفظ" onCancel={() => setDraft(null)} />
          </ActionForm>
        )}
        {draft?.id && <DefinitionLifecycle entity="service" id={draft.id} archived={!!draft.archived_at} onDone={() => { setDraft(null); load(); }} />}
      </Modal>
    </div>
  );
}
