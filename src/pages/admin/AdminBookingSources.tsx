import { useEffect, useState, useCallback } from "react";
import { supabase } from "../../lib/supabase";
import { branchMediaApi, toArabicError } from "../../lib/api";
import { useAuth } from "../../lib/auth";
import { SectionTitle, LoadingScreen, Card, EmptyState, Badge, Spinner, ErrorBanner } from "../../components/ui";
import { Link2 } from "lucide-react";

interface SourceRow { id: string; name: string; code: string; kind: string; external_reference_required: boolean; is_active: boolean }

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

  const load = useCallback(async () => {
    const { data, error: e } = await supabase.from("booking_sources").select("id, name, code, kind, external_reference_required, is_active").order("kind").order("name");
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
      <SectionTitle title="مصادر الحجز" subtitle={`${sources.length} مصدرًا — القائمة ثابتة؛ التفعيل والتعطيل فقط`} />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      {sources.length === 0 ? <EmptyState icon={<Link2 className="h-10 w-10" />} title="لا توجد مصادر" /> : (
        <div className="grid gap-3 md:grid-cols-2">
          {sources.map((s) => (
            <Card key={s.id} className="flex items-center justify-between gap-3" data-testid={`source-${s.code}`}>
              <div className="flex items-center gap-3">
                <Link2 className="h-5 w-5 text-brand-600" />
                <div>
                  <p className="text-sm font-semibold text-ink-800">{s.name}</p>
                  <p className="text-xs text-ink-400">{s.kind === "direct" ? "مباشر" : "منصة خارجية (بسعر المنصات)"}{s.external_reference_required ? " · يلزم رقم الحجز في المنصة" : " · رقم المنصة اختياري"} · <span className="font-mono" dir="ltr">{s.code}</span></p>
                </div>
              </div>
              <div className="flex items-center gap-2">
                <Badge className={s.is_active ? "bg-success-500/10 text-success-600" : "bg-ink-100 text-ink-400"}>{s.is_active ? "نشط" : "متوقف"}</Badge>
                {canToggle && <button onClick={() => toggle(s)} disabled={acting === s.id} className="btn-outline text-xs">{acting === s.id ? <Spinner className="h-3 w-3" /> : s.is_active ? "إيقاف" : "تفعيل"}</button>}
              </div>
            </Card>
          ))}
        </div>
      )}
      <p className="mt-3 text-xs text-ink-400">رابط الحجز الذي يُرسل للضيف هو «رابط منصة الحجز» في إعدادات الفرع، لا هنا. «Booking Engine» حجز مباشر معطّل لأن المنشأة ليست نقطة تأجير مباشرة (القرار 23). إن كان «جذر إن» و«Gathern» منصة واحدة عندكم فعطّلوا أحدهما حتى لا يُدخل الحجز مرتين.</p>
    </div>
  );
}
