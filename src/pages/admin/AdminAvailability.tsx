import { useEffect, useState, useCallback } from "react";
import { supabase } from "../../lib/supabase";
import { SectionTitle, LoadingScreen, Card, ErrorBanner } from "../../components/ui";
import { todayISO } from "../../lib/utils";
import { useBranch } from "../../lib/branch";
import { toArabicError } from "../../lib/api";

interface InventoryRow {
  id: string; date: string; total_units: number; publicly_visible_units: number; blocked_units: number;
  category?: { name_ar: string };
}

export default function AdminAvailability() {
  const { branchId, branches, setBranchId } = useBranch();
  const [error, setError] = useState<string | null>(null);
  const [rows, setRows] = useState<InventoryRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [acting, setActing] = useState<string | null>(null);
  const [startDate, setStartDate] = useState(todayISO());

  const load = useCallback(async () => {
    if (!branchId) return;
    const { data, error: e } = await supabase
      .from("inventory_periods")
      .select("id, date, total_units, publicly_visible_units, blocked_units, category:room_categories(name_ar)")
      .eq("branch_id", branchId)
      .gte("date", startDate)
      .order("date", { ascending: true })
      .limit(60);
    if (e) setError(toArabicError(e));
    setRows((data as unknown as InventoryRow[]) ?? []);
    setLoading(false);
  }, [startDate, branchId]);

  useEffect(() => { load(); }, [load]);

  async function updateField(id: string, field: "total_units" | "publicly_visible_units" | "blocked_units", value: number) {
    setActing(id + field); setError(null);
    const { error: e } = await supabase.from("inventory_periods").update({ [field]: value }).eq("id", id);
    if (e) setError(toArabicError(e));
    await load();
    setActing(null);
  }

  if (loading && branchId) return <LoadingScreen />;

  return (
    <div>
      <SectionTitle title="التحكم بالتوفر" subtitle="إدارة الرصيد اليومي لكل تصنيف" action={
        <div className="flex items-center gap-2">
          <select className="input w-auto" value={branchId ?? ""} onChange={(e) => setBranchId(e.target.value)}>
            {branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
          </select>
          <input type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)} className="input w-auto" />
        </div>
      } />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      <Card className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-ink-100 text-xs text-ink-400">
              <th className="py-2 text-right font-medium">التاريخ</th>
              <th className="py-2 text-right font-medium">التصنيف</th>
              <th className="py-2 text-center font-medium">الإجمالي</th>
              <th className="py-2 text-center font-medium">المعروض للعامة</th>
              <th className="py-2 text-center font-medium">المحجوب</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id} className="border-b border-ink-50">
                <td className="py-2.5 text-ink-700">{r.date}</td>
                <td className="py-2.5 text-ink-600">{r.category?.name_ar}</td>
                <td className="py-2.5 text-center">
                  <input type="number" defaultValue={r.total_units} onBlur={(e) => updateField(r.id, "total_units", Number(e.target.value))} className="input mx-auto w-16 text-center" disabled={acting === r.id + "total_units"} />
                </td>
                <td className="py-2.5 text-center">
                  <input type="number" defaultValue={r.publicly_visible_units} onBlur={(e) => updateField(r.id, "publicly_visible_units", Number(e.target.value))} className="input mx-auto w-16 text-center" disabled={acting === r.id + "publicly_visible_units"} />
                </td>
                <td className="py-2.5 text-center">
                  <input type="number" defaultValue={r.blocked_units} onBlur={(e) => updateField(r.id, "blocked_units", Number(e.target.value))} className="input mx-auto w-16 text-center" disabled={acting === r.id + "blocked_units"} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {rows.length === 0 && <div className="py-8 text-center text-sm text-ink-400">لا توجد سجلات توفر لهذه الفترة.</div>}
      </Card>
      <p className="mt-3 text-xs text-ink-400">عدّل القيم مباشرة — تُحفظ تلقائيًا عند الخروج من الحقل. لتعديل قاعدة الكشف التدريجي انتقل إلى صفحة "قواعد الكشف".</p>
    </div>
  );
}
