import { useCallback, useEffect, useState } from "react";
import { Building2, Plus, Pencil } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../lib/auth";
import { opsApi, toArabicError } from "../../lib/api";
import { SectionTitle, LoadingScreen, Card, EmptyState, Badge, ErrorBanner } from "../../components/ui";
import { formatCurrency } from "../../lib/utils";
import { Modal, Field, ActionForm, Submit, DefinitionLifecycle, ArchivedBadge, Toggle, MoneyInput } from "../../components/forms";

interface Branch { id: string; name_ar: string; name_en: string | null; city: string | null; address: string | null; phone: string | null; email: string | null; is_active: boolean; check_in_time: string; check_out_time: string; timezone: string; tax_rate_bp: number; prices_include_tax: boolean; default_deposit_halalas: number; tax_number: string | null; commercial_register: string | null; archived_at: string | null; version: number; rooms?: number }

const EMPTY: Partial<Branch> = { name_ar: "", name_en: "", city: "", address: "", phone: "", email: "", check_in_time: "16:00", check_out_time: "12:00", timezone: "Asia/Riyadh", tax_rate_bp: 0, prices_include_tax: false, default_deposit_halalas: 5000, is_active: true };
const taxText = (b: Pick<Branch, "tax_rate_bp" | "prices_include_tax">) => b.tax_rate_bp === 0 ? "بلا ضريبة" : `ضريبة ${(b.tax_rate_bp / 100).toFixed(2)}% ${b.prices_include_tax ? "(شاملة)" : "(غير شاملة)"}`;

export default function AdminBranches() {
  const { profile } = useAuth();
  const isOwner = profile?.role === "owner";
  const [rows, setRows] = useState<Branch[]>([]);
  const [loading, setLoading] = useState(true); const [error, setError] = useState<string | null>(null);
  const [draft, setDraft] = useState<Partial<Branch> | null>(null);
  const [showArchived, setShowArchived] = useState(false);

  const load = useCallback(async () => {
    const [b, r] = await Promise.all([
      supabase.from("branches").select("id, name_ar, name_en, city, address, phone, email, is_active, check_in_time, check_out_time, timezone, tax_rate_bp, prices_include_tax, default_deposit_halalas, tax_number, commercial_register, archived_at, version").order("name_ar"),
      supabase.from("rooms").select("branch_id").is("archived_at", null),
    ]);
    if (b.error) setError(toArabicError(b.error));
    const count = new Map<string, number>(); for (const x of (r.data ?? []) as { branch_id: string }[]) count.set(x.branch_id, (count.get(x.branch_id) ?? 0) + 1);
    setRows(((b.data ?? []) as Branch[]).map((x) => ({ ...x, rooms: count.get(x.id) ?? 0 })));
    setLoading(false);
  }, []);
  useEffect(() => { load(); }, [load]);

  if (loading) return <LoadingScreen />;
  const visible = rows.filter((b) => showArchived || !b.archived_at);
  return (
    <div>
      <SectionTitle title="الفروع" subtitle={`${visible.length} فرع — الضريبة والمنطقة الزمنية إعدادات معتمدة لكل فرع`} action={isOwner ? <button onClick={() => setDraft({ ...EMPTY })} className="btn-primary text-sm"><Plus className="h-4 w-4" /> فرع جديد</button> : undefined} />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      <div className="mb-4"><Toggle checked={showArchived} onChange={setShowArchived} label="إظهار المؤرشف" /></div>
      {visible.length === 0 ? <EmptyState icon={<Building2 className="h-10 w-10" />} title="لا توجد فروع" /> : (
        <div className="grid gap-3 md:grid-cols-2">
          {visible.map((b) => (
            <Card key={b.id} className={b.archived_at ? "opacity-60" : ""}>
              <div className="flex items-start justify-between gap-3">
                <div>
                  <div className="flex items-center gap-2"><h3 className="text-base font-semibold text-ink-800">{b.name_ar}</h3><ArchivedBadge archivedAt={b.archived_at} />{!b.is_active && !b.archived_at && <Badge className="bg-warning-500/10 text-warning-600">معطل</Badge>}</div>
                  {b.name_en && <p className="text-xs text-ink-400" dir="ltr">{b.name_en}</p>}
                  <p className="mt-1 text-sm text-ink-500">{[b.city, b.address].filter(Boolean).join(" · ") || "—"}</p>
                  <p className="mt-1 text-xs text-ink-400">{b.rooms} وحدة · وصول {b.check_in_time?.slice(0, 5)} / مغادرة {b.check_out_time?.slice(0, 5)} · {taxText(b)} · التأمين {formatCurrency(b.default_deposit_halalas / 100)} لكل وحدة · {b.timezone}</p>
                </div>
                <button onClick={() => setDraft(b)} className="btn-ghost p-1.5" title="تعديل" aria-label={`تعديل ${b.name_ar}`}><Pencil className="h-4 w-4" /></button>
              </div>
            </Card>
          ))}
        </div>
      )}
      <Modal open={!!draft} title={draft?.id ? "تعديل فرع" : "فرع جديد"} onClose={() => setDraft(null)} wide>
        {draft && (
          <ActionForm onSubmit={async () => { await opsApi.upsertBranch({ ...draft, rooms: undefined }); setDraft(null); await load(); }}>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="الاسم العربي (مطلوب)"><input className="input" value={draft.name_ar ?? ""} onChange={(e) => setDraft({ ...draft, name_ar: e.target.value })} /></Field>
              <Field label="الاسم الإنجليزي"><input className="input" dir="ltr" value={draft.name_en ?? ""} onChange={(e) => setDraft({ ...draft, name_en: e.target.value })} /></Field>
              <Field label="المدينة"><input className="input" value={draft.city ?? ""} onChange={(e) => setDraft({ ...draft, city: e.target.value })} /></Field>
              <Field label="العنوان"><input className="input" value={draft.address ?? ""} onChange={(e) => setDraft({ ...draft, address: e.target.value })} /></Field>
              <Field label="الهاتف"><input className="input" dir="ltr" value={draft.phone ?? ""} onChange={(e) => setDraft({ ...draft, phone: e.target.value })} /></Field>
              <Field label="البريد"><input className="input" dir="ltr" value={draft.email ?? ""} onChange={(e) => setDraft({ ...draft, email: e.target.value })} /></Field>
              <Field label="وقت الوصول"><input type="time" className="input" dir="ltr" value={draft.check_in_time?.slice(0, 5) ?? "16:00"} onChange={(e) => setDraft({ ...draft, check_in_time: e.target.value })} /></Field>
              <Field label="وقت المغادرة"><input type="time" className="input" dir="ltr" value={draft.check_out_time?.slice(0, 5) ?? "12:00"} onChange={(e) => setDraft({ ...draft, check_out_time: e.target.value })} /></Field>
              <Field label="المنطقة الزمنية"><input className="input" dir="ltr" value={draft.timezone ?? "Asia/Riyadh"} onChange={(e) => setDraft({ ...draft, timezone: e.target.value })} /></Field>
              <Field label="التأمين لكل وحدة" hint="المبلغ المقترح عند قبض التأمين، وهو منفصل عن الإيراد ويُرد بعد فحص المغادرة."><MoneyInput valueHalalas={draft.default_deposit_halalas ?? 0} onChange={(h) => setDraft({ ...draft, default_deposit_halalas: h ?? 0 })} /></Field>
              <Field label="السجل التجاري"><input className="input" dir="ltr" value={draft.commercial_register ?? ""} onChange={(e) => setDraft({ ...draft, commercial_register: e.target.value })} /></Field>
            </div>
            {/* decision 68: the tax policy is the owner's alone (the server refuses anyone else's change too) */}
            <fieldset className="mt-4 rounded-xl border border-ink-100 p-3" disabled={!isOwner} data-testid="branch-tax">
              <legend className="px-1 text-xs font-semibold text-ink-600">الضريبة {isOwner ? "" : "— يعدّلها المالك فقط"}</legend>
              <div className="grid gap-3 sm:grid-cols-2">
                <Field label="نسبة الضريبة %" hint="صفر يعني لا ضريبة على الحجوزات الجديدة؛ أي تغيير يسري على الحجوزات الجديدة فقط، ويُسجَّل."><input type="number" step="0.01" min={0} max={100} className="input" dir="ltr" aria-label="نسبة الضريبة" value={((draft.tax_rate_bp ?? 0) / 100).toString()} onChange={(e) => setDraft({ ...draft, tax_rate_bp: Math.round(Number(e.target.value) * 100) })} /></Field>
                <Field label="الرقم الضريبي"><input className="input" dir="ltr" value={draft.tax_number ?? ""} onChange={(e) => setDraft({ ...draft, tax_number: e.target.value })} /></Field>
                {(draft.tax_rate_bp ?? 0) > 0 && <div className="sm:col-span-2"><Toggle checked={draft.prices_include_tax ?? false} onChange={(v) => setDraft({ ...draft, prices_include_tax: v })} label="الأسعار شاملة الضريبة" /></div>}
              </div>
            </fieldset>
            {draft.id && <div className="mt-3"><Toggle checked={draft.is_active ?? true} onChange={(v) => setDraft({ ...draft, is_active: v })} label="فرع فعال (التعطيل يمنع حجوزات جديدة ولا يخفي التاريخ)" /></div>}
            <Submit label="حفظ" onCancel={() => setDraft(null)} />
          </ActionForm>
        )}
        {draft?.id && isOwner && <DefinitionLifecycle entity="branch" id={draft.id} archived={!!draft.archived_at} onDone={() => { setDraft(null); load(); }} />}
      </Modal>
    </div>
  );
}
