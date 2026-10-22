import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";
import { SectionTitle, LoadingScreen, Card, EmptyState } from "../../components/ui";
import { ScrollText } from "lucide-react";
import { formatDateTime } from "../../lib/utils";

interface AuditRow {
  id: string; action: string; entity_type: string | null; created_at: string;
  details: Record<string, unknown> | null;
}

export default function AdminAuditLogs() {
  const [logs, setLogs] = useState<AuditRow[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    (async () => {
      const { data } = await supabase.from("audit_events").select("id, action, entity_type, created_at, details").order("created_at", { ascending: false }).limit(100);
      setLogs((data as AuditRow[]) ?? []);
      setLoading(false);
    })();
  }, []);

  if (loading) return <LoadingScreen />;

  return (
    <div>
      <SectionTitle title="سجل الإجراءات" subtitle={`${logs.length} حدث — يوضح من اعتمد كل عملية ومتى`} />
      {logs.length === 0 ? (
        <EmptyState icon={<ScrollText className="h-10 w-10" />} title="لا توجد أحداث مسجّلة" description="تظهر هنا كل عمليات الاعتماد والرفض والتسليم." />
      ) : (
        <Card className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead><tr className="border-b border-ink-100 text-xs text-ink-400">
              <th className="py-2 text-right font-medium">الإجراء</th>
              <th className="py-2 text-right font-medium">الكيان</th>
              <th className="py-2 text-right font-medium">الوقت</th>
            </tr></thead>
            <tbody>
              {logs.map((l) => (
                <tr key={l.id} className="border-b border-ink-50">
                  <td className="py-2.5 text-ink-700 font-medium">{l.action}</td>
                  <td className="py-2.5 text-ink-500">{l.entity_type ?? "—"}</td>
                  <td className="py-2.5 text-xs text-ink-400">{formatDateTime(l.created_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}
    </div>
  );
}
