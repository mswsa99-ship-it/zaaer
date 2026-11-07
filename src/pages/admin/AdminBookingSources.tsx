import { useEffect, useState, useCallback } from "react";
import { supabase } from "../../lib/supabase";
import { branchMediaApi, branchGuideApi, toArabicError } from "../../lib/api";
import { useAuth } from "../../lib/auth";
import { SectionTitle, LoadingScreen, Card, EmptyState, Badge, Spinner, ErrorBanner } from "../../components/ui";
import { Modal, Field, ActionForm, Submit, ReasonInput } from "../../components/forms";
import { Link2, Percent, Plus, Pencil } from "lucide-react";
import { bpToPercent, percentToBp } from "../../lib/money";

interface SourceRow { id: string; name: string; code: string; kind: string; external_reference_required: boolean; is_active: boolean; commission_bp: number | null }


/**
 * Booking sources (decision 22, 0056 SETUP-14): the twelve sources of Zaaer, plus any the owner or a manager adds here
 * (a name, direct or external, whether the platform's number is needed, the commission). A source with bookings keeps
 * its kind. Switching a source off asks for a reason; it stays readable and old bookings keep showing it.
 */
type SourceDraft = { id?: string; name: string; kind: "direct" | "external"; ref: boolean; pct: string; used?: boolean };
export default function AdminBookingSources() {
  const { can } = useAuth();
  const canToggle = can("definitions");
  const [sources, setSources] = useState<SourceRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [acting, setActing] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<SourceRow | null>(null);
  const [pct, setPct] = useState("");
  const [draft, setDraft] = useState<SourceDraft | null>(null);
  const [stopping, setStopping] = useState<SourceRow | null>(null);
  const [reason, setReason] = useState("");

  const load = useCallback(async () => {
    const { data, error: e } = await supabase.from("booking_sources").select("id, name, code, kind, external_reference_required, is_active, commission_bp").order("kind").order("name");
    if (e) setError(toArabicError(e));
    setSources((data as SourceRow[]) ?? []);
    setLoading(false);
  }, []);
  useEffect(() => { load(); }, [load]);

  async function toggle(s: SourceRow) {
    if (s.is_active) { setStopping(s); setReason(""); return; }
    setActing(s.id); setError(null);
    try { await branchMediaApi.setSourceActive(s.id, !s.is_active); await load(); } catch (e) { setError(toArabicError(e)); }
    setActing(null);
  }

  if (loading) return <LoadingScreen />;
  return (
    <div>
      <SectionTitle title="مصادر الحجز" subtitle={`مصادر الحجز: ${sources.length} — الإضافة والتعديل والتفعيل والإيقاف ونسبة العمولة`}
        action={canToggle ? <button className="btn-primary text-sm" data-testid="new-source" onClick={() => setDraft({ name: "", kind: "external", ref: true, pct: "0" })}><Plus className="h-4 w-4" /> مصدر جديد</button> : undefined} />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      {sources.length === 0 ? <EmptyState icon={<Link2 className="h-10 w-10" />} title="لا توجد مصادر" /> : (
        <div className="grid gap-3 md:grid-cols-2">
          {sources.map((s) => (
            <Card key={s.id} className="flex flex-wrap items-center justify-between gap-3" data-testid={`source-${s.code}`}>
              <div className="flex min-w-0 items-center gap-3">
                <Link2 className="h-5 w-5 text-brand-600" />
                <div>
                  <p className="text-sm font-semibold text-ink-800">{s.name}</p>
                  <p className="text-xs text-ink-400">{s.kind === "direct" ? "مباشر" : "منصة خارجية (بسعر المنصات)"}{s.external_reference_required ? " · يلزم رقم الحجز في المنصة" : " · رقم المنصة اختياري"} · <span className="font-mono" dir="ltr">{s.code}</span></p>
                  <p className="mt-0.5 text-xs text-ink-600" data-testid={`commission-${s.code}`}>العمولة: <span dir="ltr">{bpToPercent(s.commission_bp)}%</span></p>
                </div>
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <Badge className={s.is_active ? "bg-success-500/10 text-success-600" : "bg-ink-100 text-ink-400"}>{s.is_active ? "نشط" : "متوقف"}</Badge>
                {canToggle && <button onClick={() => setDraft({ id: s.id, name: s.name, kind: s.kind === "direct" ? "direct" : "external", ref: s.external_reference_required, pct: bpToPercent(s.commission_bp) })} className="btn-outline text-xs" aria-label={`تعديل ${s.name}`}><Pencil className="h-3.5 w-3.5" /> تعديل</button>}
                {canToggle && s.kind !== "direct" && <button onClick={() => { setEditing(s); setPct(bpToPercent(s.commission_bp)); }} className="btn-outline text-xs" aria-label={`عمولة ${s.name}`} data-testid={`edit-commission-${s.code}`}><Percent className="h-3.5 w-3.5" /> العمولة</button>}
                {canToggle && <button onClick={() => toggle(s)} disabled={acting === s.id} className="btn-outline text-xs">{acting === s.id ? <Spinner className="h-3 w-3" /> : s.is_active ? "إيقاف" : "تفعيل"}</button>}
              </div>
            </Card>
          ))}
        </div>
      )}
      <Modal open={!!editing} title={editing ? `عمولة ${editing.name}` : ""} onClose={() => setEditing(null)}>
        {editing && (
          <ActionForm onSubmit={async () => {
            const bp = percentToBp(pct); if (bp == null) throw new Error("VALIDATION: commission");
            await branchMediaApi.setSourceCommission(editing.id, bp); setEditing(null); await load();
          }}>
            <p className="mb-3 text-sm text-ink-600">نسبة ما تقتطعه المنصة من كل دفعة تحصّلها. عند مطابقة إيداعها يُتوقع الإجمالي ناقص العمولة، ولا يُطلب سبب إلا لفرق غير ذلك. التغيير يسري على المطابقات القادمة فقط، ويُسجَّل في سجل الإجراءات.</p>
            <Field label="نسبة العمولة (%)"><input className="input" dir="ltr" inputMode="decimal" value={pct} onChange={(e) => setPct(e.target.value)} placeholder="15" data-testid="commission-input" /></Field>
            <Submit label="حفظ" onCancel={() => setEditing(null)} />
          </ActionForm>
        )}
      </Modal>
      <Modal open={!!draft} title={draft?.id ? `تعديل ${draft.name || "المصدر"}` : "مصدر حجز جديد"} onClose={() => setDraft(null)}>
        {draft && (
          <ActionForm onSubmit={async () => {
            const bp = draft.kind === "direct" ? 0 : percentToBp(draft.pct); if (bp == null) throw new Error("VALIDATION: commission");
            await branchGuideApi.upsertSource({ id: draft.id, name: draft.name, kind: draft.kind, external_reference_required: draft.ref, commission_bp: String(bp) });
            setDraft(null); await load();
          }}>
            <div className="space-y-3">
              <Field label="الاسم"><input className="input" maxLength={80} value={draft.name} onChange={(e) => setDraft({ ...draft, name: e.target.value })} data-testid="source-name" /></Field>
              <Field label="النوع" hint={draft.id ? "لا يتغيّر نوع مصدر عليه حجوزات." : undefined}>
                <select className="input" value={draft.kind} onChange={(e) => { const kind = e.target.value as SourceDraft["kind"]; setDraft({ ...draft, kind, ref: kind === "external" ? draft.ref : false }); }}>
                  <option value="external">منصة خارجية (بسعر المنصات)</option>
                  <option value="direct">مباشر</option>
                </select>
              </Field>
              <label className="flex min-h-[44px] items-center gap-2 text-sm text-ink-700">
                <input type="checkbox" className="h-4 w-4 accent-brand-600" checked={draft.ref} onChange={(e) => setDraft({ ...draft, ref: e.target.checked })} />
                يلزم إدخال رقم الحجز في المنصة
              </label>
              {draft.kind === "external" && <Field label="نسبة العمولة (%)"><input className="input" dir="ltr" inputMode="decimal" value={draft.pct} onChange={(e) => setDraft({ ...draft, pct: e.target.value })} placeholder="15" /></Field>}
            </div>
            <Submit label="حفظ" onCancel={() => setDraft(null)} />
          </ActionForm>
        )}
      </Modal>
      <Modal open={!!stopping} title={stopping ? `إيقاف ${stopping.name}` : ""} onClose={() => setStopping(null)}>
        {stopping && (
          <ActionForm onSubmit={async () => {
            if (!reason.trim()) throw new Error("VALIDATION: reason");
            await branchMediaApi.setSourceActive(stopping.id, false, reason.trim()); setStopping(null); await load();
          }}>
            <p className="mb-3 text-sm text-ink-600">لن يظهر المصدر عند تسجيل حجز جديد. الحجوزات السابقة تبقى كما هي وتظهر في التقارير.</p>
            <ReasonInput value={reason} onChange={setReason} />
            <Submit label="إيقاف" onCancel={() => setStopping(null)} danger />
          </ActionForm>
        )}
      </Modal>
      <p className="mt-3 text-xs text-ink-400">رابط الحجز الذي يُرسل للنزيل هو «رابط منصة الحجز» في إعدادات الفرع، لا هنا. «Booking Engine» حجز مباشر معطّل لأن المنشأة ليست نقطة تأجير مباشرة. إن كان «جذر إن» و«Gathern» منصة واحدة عندكم فعطّلوا أحدهما حتى لا يُدخل الحجز مرتين.</p>
    </div>
  );
}
