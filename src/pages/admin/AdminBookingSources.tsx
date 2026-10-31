import { useEffect, useState, useCallback } from "react";
import { supabase } from "../../lib/supabase";
import { branchMediaApi, toArabicError } from "../../lib/api";
import { useAuth } from "../../lib/auth";
import { SectionTitle, LoadingScreen, Card, EmptyState, Badge, Spinner, ErrorBanner } from "../../components/ui";
import { Modal, Field, ActionForm, Submit } from "../../components/forms";
import { Link2, Percent } from "lucide-react";
import { bpToPercent, percentToBp } from "../../lib/money";

interface SourceRow { id: string; name: string; code: string; kind: string; external_reference_required: boolean; is_active: boolean; commission_bp: number | null }


/**
 * Booking sources (decision 22): the twelve sources of Zaaer, fixed in the migration (a code, a kind, whether the
 * platform's number is needed). The screen only switches a source on or off (owner or manager; audited). A switched-off
 * source stays readable: old bookings keep showing it.
 */
export default function AdminBookingSources() {
  const { can } = useAuth();
  const canToggle = can("definitions");
  const [sources, setSources] = useState<SourceRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [acting, setActing] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<SourceRow | null>(null);
  const [pct, setPct] = useState("");

  const load = useCallback(async () => {
    const { data, error: e } = await supabase.from("booking_sources").select("id, name, code, kind, external_reference_required, is_active, commission_bp").order("kind").order("name");
    if (e) setError(toArabicError(e));
    setSources((data as SourceRow[]) ?? []);
    setLoading(false);
  }, []);
  useEffect(() => { load(); }, [load]);

  async function toggle(s: SourceRow) {
    setActing(s.id); setError(null);
    try { await branchMediaApi.setSourceActive(s.id, !s.is_active); await load(); } catch (e) { setError(toArabicError(e)); }
    setActing(null);
  }

  if (loading) return <LoadingScreen />;
  return (
    <div>
      <SectionTitle title="مصادر الحجز" subtitle={`${sources.length} مصدرًا — القائمة ثابتة؛ التفعيل والتعطيل ونسبة العمولة`} />
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
                {canToggle && <button onClick={() => { setEditing(s); setPct(bpToPercent(s.commission_bp)); }} className="btn-outline text-xs" aria-label={`عمولة ${s.name}`} data-testid={`edit-commission-${s.code}`}><Percent className="h-3.5 w-3.5" /> العمولة</button>}
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
      <p className="mt-3 text-xs text-ink-400">رابط الحجز الذي يُرسل للضيف هو «رابط منصة الحجز» في إعدادات الفرع، لا هنا. «Booking Engine» حجز مباشر معطّل لأن المنشأة ليست نقطة تأجير مباشرة (القرار 23). إن كان «جذر إن» و«Gathern» منصة واحدة عندكم فعطّلوا أحدهما حتى لا يُدخل الحجز مرتين.</p>
    </div>
  );
}
