import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";
import { SectionTitle, LoadingScreen, Card, EmptyState } from "../../components/ui";
import { Users } from "lucide-react";
import { maskName, maskId } from "../../lib/utils";
import { IDENTITY_TYPE_LABELS } from "../../lib/types";

interface GuestRow {
  id: string; full_name: string; identity_type: string | null; identity_number_last4: string | null; nationality: string | null; phone: string | null;
}

export default function AdminGuests() {
  const [guests, setGuests] = useState<GuestRow[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    (async () => {
      const { data } = await supabase.from("reservation_guests").select("id, full_name, identity_type, identity_number_last4, nationality, phone").order("created_at", { ascending: false });
      setGuests((data as GuestRow[]) ?? []);
      setLoading(false);
    })();
  }, []);

  if (loading) return <LoadingScreen />;

  return (
    <div>
      <SectionTitle title="النزلاء" subtitle={`${guests.length} سجل`} />
      {guests.length === 0 ? (
        <EmptyState icon={<Users className="h-10 w-10" />} title="لا يوجد نزلاء" />
      ) : (
        <Card className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead><tr className="border-b border-ink-100 text-xs text-ink-400">
              <th className="py-2 text-right font-medium">الاسم</th>
              <th className="py-2 text-right font-medium">نوع الوثيقة</th>
              <th className="py-2 text-right font-medium">رقم الوثيقة</th>
              <th className="py-2 text-right font-medium">الجنسية</th>
              <th className="py-2 text-right font-medium">الجوال</th>
            </tr></thead>
            <tbody>
              {guests.map((g) => (
                <tr key={g.id} className="border-b border-ink-50">
                  <td className="py-2.5 text-ink-700">{maskName(g.full_name)}</td>
                  <td className="py-2.5 text-ink-600">{g.identity_type ? IDENTITY_TYPE_LABELS[g.identity_type as keyof typeof IDENTITY_TYPE_LABELS] : "—"}</td>
                  <td className="py-2.5 text-ink-600 font-mono">{maskId(g.identity_number_last4 ?? undefined)}</td>
                  <td className="py-2.5 text-ink-600">{g.nationality ?? "—"}</td>
                  <td className="py-2.5 text-ink-400" dir="ltr">{g.phone ? g.phone.slice(0, 6) + "••••" : "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}
      <p className="mt-3 text-xs text-ink-400">تُعرض البيانات مخفّاة لأسباب الخصوصية. الصلاحيات الكاملة لإظهارها محدودة بالدور المصرّح به.</p>
    </div>
  );
}
