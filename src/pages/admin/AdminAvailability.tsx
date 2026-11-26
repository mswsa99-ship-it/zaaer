import { useRef, useState } from "react";
import { supabase } from "../../lib/supabase";
import { SectionTitle, LoadingScreen, Card, ErrorBanner, LoadErrorCard, Badge } from "../../components/ui";
import { todayISO } from "../../lib/utils";
import { useBranch } from "../../lib/branch";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { inventoryApi, toArabicError } from "../../lib/api";
import { NumberInput } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";

interface InventoryRow {
  branch_id?: string; id: string; date: string; total_units: number; publicly_visible_units: number; blocked_units: number;
  category?: { name_ar: string };
}
const NO_ROWS: InventoryRow[] = [];

export default function AdminAvailability() {
  const { branches, allBranches, setBranchId } = useBranch(); // «جميع الفروع» (owner): read-only; stock is changed inside one branch
  const [error, setError] = useState<string | null>(null);
  const [acting, setActing] = useState<string | null>(null);
  // 0055 (SETUP-01): what happened to each row's last change — «حُفظ» or the reason it was refused
  const [rowState, setRowState] = useState<Record<string, { ok: boolean; text: string }>>({});
  const [startDate, setStartDate] = useState(todayISO());

  // G24 (decision 40): the active branch's rows only; a failed load shows an error, never an empty table
  const q = useBranchQuery<InventoryRow[]>(async (branchId) => (must(await supabase
      .from("inventory_periods")
      .select("id, date, total_units, publicly_visible_units, blocked_units, category:room_categories(name_ar)")
      .eq("branch_id", branchId)
      .gte("date", startDate)
      .order("date", { ascending: true })
      .limit(60)) as unknown as InventoryRow[]).map((x) => ({ ...x, branch_id: branchId })), [startDate], NO_ROWS,
    { merge: (parts) => parts.flat().sort((a, b) => a.date.localeCompare(b.date) || (a.branch_id ?? "").localeCompare(b.branch_id ?? "")) });
  const rows = q.data; const load = q.reload;
  const branchName = (id?: string) => branches.find((b) => b.id === id)?.name_ar ?? "";

  // 0055 (SETUP-01): through fn_admin_set_inventory — 0 ≤ blocked ≤ total ≤ the type's units, public ≤ total − blocked
  const saveLock = useRef(false);
  async function updateField(r: InventoryRow, field: "total_units" | "publicly_visible_units" | "blocked_units", value: number | null) {
    if (value === r[field]) return;
    if (saveLock.current) return;
    saveLock.current = true;
    setActing(r.id + field); setError(null);
    try {
      if (value == null) throw new Error("VALIDATION: inventory");
      const res = await inventoryApi.set({ id: r.id, [field]: value });
      setRowState((s) => ({ ...s, [r.id]: { ok: true, text: res.unchanged ? "لا تغيير" : "حُفظ" } }));
    } catch (e) { setRowState((s) => ({ ...s, [r.id]: { ok: false, text: toArabicError(e) } })); }
    load();
    saveLock.current = false; setActing(null);
  }

  if (q.loading) return <LoadingScreen />;

  return (
    <div>
      <SectionTitle title="التحكم بالتوفر" subtitle="إدارة الرصيد اليومي لكل تصنيف" action={
        <div className="flex flex-wrap items-center gap-2">
          <BranchPicker allowAll />
          <input type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)} className="input w-auto" aria-label="بداية العرض" />
        </div>
      } />
      {(error || (q.error && rows.length > 0)) && <div className="mb-4"><ErrorBanner message={(error ?? q.error) as string} /></div>}
      {allBranches && !q.error && branches.filter((b) => !rows.some((r) => r.branch_id === b.id)).map((b) => <p key={b.id} data-testid="avail-branch-empty" className="mb-2 rounded-xl border-2 border-dashed px-3 py-2 text-sm">{b.name_ar}: لا توجد سجلات توفر لهذه الفترة.</p>)}
      {q.error && rows.length === 0 ? <LoadErrorCard message={q.error} onRetry={load} /> : allBranches ? (
        <div className="space-y-2" data-testid="avail-all">
          {rows.map((r) => (
            <Card key={r.id}>
              <div className="flex flex-wrap items-center gap-2">
                <span className="font-semibold">{r.category?.name_ar}</span>
                <span dir="ltr" className="text-sm">{r.date}</span>
                <Badge testId="admin-row-branch">{branchName(r.branch_id)}</Badge>
                <button type="button" className="btn-ghost mr-auto shrink-0 whitespace-nowrap p-1 text-xs" data-testid="admin-row-open-branch" onClick={() => setBranchId(r.branch_id!)} aria-label={`فتح فرع ${branchName(r.branch_id)} لتعديل التوفر ${r.date}`}>فتح الفرع للتعديل</button>
              </div>
              <dl className="mt-2 grid grid-cols-3 gap-2 text-center text-xs" data-testid="avail-value">
                <div><dt>الإجمالي</dt><dd className="text-base font-semibold">{r.total_units}</dd></div>
                <div><dt>المعروض للعامة</dt><dd className="text-base font-semibold">{r.publicly_visible_units}</dd></div>
                <div><dt>المحجوب</dt><dd className="text-base font-semibold">{r.blocked_units}</dd></div>
              </dl>
            </Card>
          ))}
          {rows.length === 0 && <div className="py-8 text-center text-sm">لا توجد سجلات توفر لهذه الفترة.</div>}
        </div>
      ) : <Card className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-ink-100 text-xs text-ink-400">
              <th className="py-2 text-right font-medium">التاريخ</th>
              <th className="py-2 text-right font-medium">التصنيف</th>
              <th className="py-2 text-center font-medium">الإجمالي</th>
              <th className="py-2 text-center font-medium">المعروض للعامة</th>
              <th className="py-2 text-center font-medium">المحجوب</th>
              <th className="py-2 text-right font-medium">الحفظ</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id} className="border-b border-ink-50">
                <td className="py-2.5 text-ink-700">{r.date}</td>
                <td className="py-2.5 text-ink-600">{r.category?.name_ar}</td>
                <td className="py-2.5 text-center"><NumberInput value={r.total_units} onCommit={(v) => updateField(r, "total_units", v)} className="mx-auto w-16 text-center" label={`إجمالي الوحدات ${r.date ?? ""}`} disabled={acting !== null} /></td>
                <td className="py-2.5 text-center"><NumberInput value={r.publicly_visible_units} onCommit={(v) => updateField(r, "publicly_visible_units", v)} className="mx-auto w-16 text-center" label={`المعروض للعامة ${r.date ?? ""}`} disabled={acting !== null} /></td>
                <td className="py-2.5 text-center"><NumberInput value={r.blocked_units} onCommit={(v) => updateField(r, "blocked_units", v)} className="mx-auto w-16 text-center" label={`الوحدات المحجوبة ${r.date ?? ""}`} disabled={acting !== null} /></td>
                <td className="py-2.5 text-xs" aria-live="polite">{rowState[r.id] && <span className={rowState[r.id].ok ? "text-success-600" : "text-danger-600"}>{rowState[r.id].text}</span>}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {rows.length === 0 && <div className="py-8 text-center text-sm text-ink-400">لا توجد سجلات توفر لهذه الفترة.</div>}
      </Card>}
      <p className="mt-3 text-xs text-ink-400">عدّل القيم مباشرة — تُحفظ عند الخروج من الحقل، وتظهر نتيجة الحفظ في آخر السطر. المحجوب لا يزيد عن الإجمالي، والمعروض للعامة لا يزيد عن الإجمالي ناقص المحجوب، والإجمالي لا يزيد عن وحدات النوع. لتعديل قاعدة الكشف التدريجي انتقل إلى صفحة «قواعد الكشف».</p>
    </div>
  );
}
