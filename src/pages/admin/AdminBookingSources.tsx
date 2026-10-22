import { useEffect, useState, useCallback } from "react";
import { supabase } from "../../lib/supabase";
import { SectionTitle, LoadingScreen, Card, EmptyState, Badge, Spinner } from "../../components/ui";
import { Link2 } from "lucide-react";

interface SourceRow { id: string; name: string; booking_url: string | null; is_active: boolean; }

export default function AdminBookingSources() {
  const [sources, setSources] = useState<SourceRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [acting, setActing] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data } = await supabase.from("booking_sources").select("id, name, booking_url, is_active").order("name");
    setSources((data as SourceRow[]) ?? []);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  async function toggle(id: string, current: boolean) {
    setActing(id);
    await supabase.from("booking_sources").update({ is_active: !current }).eq("id", id);
    await load();
    setActing(null);
  }

  if (loading) return <LoadingScreen />;

  return (
    <div>
      <SectionTitle title="منصات الحجز" subtitle={`${sources.length} منصة`} />
      {sources.length === 0 ? (
        <EmptyState icon={<Link2 className="h-10 w-10" />} title="لا توجد منصات" />
      ) : (
        <div className="space-y-3">
          {sources.map((s) => (
            <Card key={s.id} className="flex items-center justify-between">
              <div className="flex items-center gap-3">
                <Link2 className="h-5 w-5 text-brand-600" />
                <div>
                  <p className="text-sm font-semibold text-ink-800">{s.name}</p>
                  {s.booking_url && <p className="text-xs text-brand-600" dir="ltr">{s.booking_url}</p>}
                </div>
              </div>
              <div className="flex items-center gap-2">
                <Badge className={s.is_active ? "bg-success-500/10 text-success-600" : "bg-ink-100 text-ink-400"}>{s.is_active ? "نشط" : "متوقف"}</Badge>
                <button onClick={() => toggle(s.id, s.is_active)} disabled={acting === s.id} className="btn-outline text-xs">
                  {acting === s.id ? <Spinner className="h-3 w-3" /> : s.is_active ? "إيقاف" : "تفعيل"}
                </button>
              </div>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}
