import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Link2, CheckCircle2, Circle } from "lucide-react";
import { opsApi, toArabicError, type PlatformCheckRow } from "../../lib/api";
import { useBranch } from "../../lib/branch";
import { SectionTitle, Card, EmptyState, Badge, ErrorBanner, Spinner, LoadingScreen } from "../../components/ui";
import { BranchPicker } from "../../components/BranchPicker";
import { RESERVATION_STATUS_LABELS, type ReservationStatus } from "../../lib/types";
import { formatCurrency, formatDateTime, todayISO, COUNT } from "../../lib/utils";

/**
 * The platforms' daily list (decision 4): every platform booking arriving today or tomorrow, to be matched against the
 * platform's own extranet (the number, the dates, who collects). «طابقتُ» keeps who and when; a group's units share the mark.
 */
export default function PlatformCheck() {
  const { branchId } = useBranch();
  const [date, setDate] = useState(todayISO());
  const [rows, setRows] = useState<PlatformCheckRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const load = useCallback(async () => {
    if (!branchId) return;
    try { const r = await opsApi.platformCheckList(branchId, date); setRows(r.rows); setError(null); } catch (e) { setError(toArabicError(e)); setRows([]); }
  }, [branchId, date]);
  useEffect(() => { load(); }, [load]);
  const toggle = async (r: PlatformCheckRow) => { setBusy(r.id); try { await opsApi.platformMarkChecked(r.id, !r.verified_at); await load(); } catch (e) { setError(toArabicError(e)); } finally { setBusy(null); } };
  if (rows === null && !error) return <LoadingScreen />;
  const pending = (rows ?? []).filter((r) => !r.verified_at && !["cancelled", "no_show"].includes(r.status)).length;
  return (
    <div>
      <SectionTitle title="مطابقة المنصات" subtitle={`وصول اليوم والغد من المنصات: ${COUNT.booking(rows?.length ?? 0)}، بانتظار المطابقة: ${pending}`} action={<div className="flex flex-wrap items-center gap-2"><input type="date" className="input" dir="ltr" value={date} onChange={(e) => e.target.value && setDate(e.target.value)} aria-label="اليوم" /><BranchPicker /></div>} />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      {(rows ?? []).length === 0 ? <EmptyState icon={<Link2 className="h-10 w-10" />} title="لا حجوزات من المنصات في هذين اليومين" /> : (
        <Card className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead><tr className="border-b border-ink-100 text-xs text-ink-400">
              <th className="py-2 text-right font-medium">المنصة</th><th className="py-2 text-right font-medium">رقم الحجز في المنصة</th><th className="py-2 text-right font-medium">الضيف</th><th className="py-2 text-right font-medium">الوصول</th><th className="py-2 text-right font-medium">الليالي / الأشخاص</th><th className="py-2 text-right font-medium">من يقبض</th><th className="py-2 text-right font-medium">الإجمالي</th><th className="py-2 text-right font-medium">الحالة</th><th className="py-2 text-right font-medium">المطابقة</th>
            </tr></thead>
            <tbody>
              {(rows ?? []).map((r) => (
                <tr key={r.id} className={`border-b border-ink-50 ${r.verified_at ? "bg-success-500/5" : ""}`} data-testid="platform-row">
                  <td className="py-2 text-ink-700">{r.source_name}</td>
                  <td className="py-2 font-mono text-xs" dir="ltr"><Link to={`/staff/reservations/${r.id}`} className="text-brand-700 hover:underline">{r.external_ref ?? r.internal_ref}</Link>{r.group_ref && <span className="mr-1 text-[10px] text-ink-400">(مجموعة)</span>}</td>
                  <td className="py-2 text-ink-700">{r.guest_name ?? "—"}</td>
                  <td className="py-2 text-xs" dir="ltr">{r.check_in}</td>
                  <td className="py-2 text-xs">{r.nights} / {r.guests}</td>
                  <td className="py-2 text-xs">{r.platform_collects == null ? "—" : r.platform_collects ? "المنصة" : "المنشأة"}</td>
                  <td className="py-2 text-xs" dir="ltr">{formatCurrency(r.total_halalas / 100)}</td>
                  <td className="py-2 text-xs">{RESERVATION_STATUS_LABELS[r.status as ReservationStatus] ?? r.status}{r.cancel_reference ? <span className="block font-mono text-[10px] text-ink-400" dir="ltr">إلغاء {r.cancel_reference}</span> : null}</td>
                  <td className="py-2">
                    {r.verified_at ? <Badge className="bg-success-500/10 text-success-600"><CheckCircle2 className="h-3 w-3" /> {r.verified_by ?? "—"} · {formatDateTime(r.verified_at)}</Badge> : null}
                    {!["cancelled", "no_show"].includes(r.status) && <button onClick={() => toggle(r)} disabled={busy === r.id} className="btn-ghost mr-1 px-2 py-1 text-xs" data-testid="platform-toggle">{busy === r.id ? <Spinner className="h-3 w-3" /> : r.verified_at ? <Circle className="h-3.5 w-3.5" /> : <CheckCircle2 className="h-3.5 w-3.5" />} {r.verified_at ? "إلغاء" : "طابقتُ"}</button>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}
      <p className="mt-3 text-xs text-ink-400">قارن كل سطر مع المنصة: الرقم، التواريخ، عدد الأشخاص، ومن يقبض. حجز لم يُدخل بعد لا يظهر هنا: أدخله من «حجز جديد» برقمه في المنصة.</p>
    </div>
  );
}
