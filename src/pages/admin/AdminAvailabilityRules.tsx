import { useEffect, useState, useCallback } from "react";
import { supabase } from "../../lib/supabase";
import { staffApi, toArabicError } from "../../lib/api";
import { useBranch } from "../../lib/branch";
import { SectionTitle, LoadingScreen, Card, Spinner, Badge, ErrorBanner } from "../../components/ui";
import { CalendarRange, Unlock } from "lucide-react";
import { addDaysISO, todayISO } from "../../lib/utils";

interface RuleRow {
  id: string; category_id: string; enabled: boolean; initial_public_release: number; release_increment: number; release_trigger: string;
  category?: { name_ar: string } | { name_ar: string }[] | null;
}
interface SlotRow { date: string; released_count: number; category_id: string }

function catName(r: RuleRow) { const c = Array.isArray(r.category) ? r.category[0] : r.category; return c?.name_ar ?? "—"; }

export default function AdminAvailabilityRules() {
  const { branchId, branches, setBranchId } = useBranch();
  const [rules, setRules] = useState<RuleRow[]>([]);
  const [slots, setSlots] = useState<SlotRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [acting, setActing] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [releaseFor, setReleaseFor] = useState<RuleRow | null>(null);

  const load = useCallback(async () => {
    if (!branchId) return;
    setError(null);
    const [r, s] = await Promise.all([
      supabase.from("release_rules").select("id, category_id, enabled, initial_public_release, release_increment, release_trigger, category:room_categories(name_ar)").eq("branch_id", branchId),
      supabase.from("released_slots").select("date, released_count, category_id").eq("branch_id", branchId).gte("date", todayISO()).lte("date", addDaysISO(todayISO(), 14)).order("date"),
    ]);
    if (r.error) setError(toArabicError(r.error));
    setRules((r.data as unknown as RuleRow[]) ?? []);
    setSlots((s.data as SlotRow[]) ?? []);
    setLoading(false);
  }, [branchId]);

  useEffect(() => { load(); }, [load]);

  async function toggle(r: RuleRow) {
    setActing(r.id); setError(null);
    const { error: e } = await supabase.from("release_rules").update({ enabled: !r.enabled }).eq("id", r.id);
    if (e) setError(toArabicError(e));
    await load();
    setActing(null);
  }

  async function updateField(id: string, field: "initial_public_release" | "release_increment", value: number) {
    setActing(id + field); setError(null);
    const { error: e } = await supabase.from("release_rules").update({ [field]: value }).eq("id", id);
    if (e) setError(toArabicError(e));
    await load();
    setActing(null);
  }

  if (loading && branchId) return <LoadingScreen />;

  const catOf = (id: string) => { const r = rules.find((x) => x.category_id === id); return r ? catName(r) : id.slice(0, 8); };

  return (
    <div>
      <SectionTitle title="قواعد الكشف التدريجي" subtitle="Sequential Room Release — تحكم في عدد الغرف المعروضة تدريجيًا" action={
        <select className="input w-auto" value={branchId ?? ""} onChange={(e) => setBranchId(e.target.value)}>
          {branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
        </select>
      } />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      <div className="mb-4 rounded-xl bg-brand-50 p-4 text-sm text-brand-700">
        <p className="font-medium">كيف تعمل القاعدة؟</p>
        <p className="mt-1 text-xs text-brand-600">عند تفعيل القاعدة، يعرض النظام <strong>العدد الابتدائي</strong> فقط من الغرف للعامة. بعد كل تسليم رمز صندوق معتمد، يُفتح <strong>الزيادة</strong> المحددة من الرصيد المتبقي. يمنع ذلك عرض كل الرصيد دفعة واحدة ويساعد على إدارة الطلب. يمكن للإدارة أيضًا الإفراج يدويًا عن غرفة إضافية لتاريخ محدد مع تسجيل السبب في سجل التدقيق.</p>
      </div>
      <div className="grid gap-4 lg:grid-cols-3">
        <div className="space-y-3 lg:col-span-2">
          {rules.map((r) => (
            <Card key={r.id} className="flex flex-wrap items-center justify-between gap-4">
              <div className="flex items-center gap-3">
                <CalendarRange className="h-5 w-5 text-brand-600" />
                <div>
                  <p className="text-sm font-semibold text-ink-800">{catName(r)}</p>
                  <Badge className={r.enabled ? "bg-success-500/10 text-success-600" : "bg-ink-100 text-ink-400"}>{r.enabled ? "مفعّلة" : "متوقفة"}</Badge>
                </div>
              </div>
              <div className="flex flex-wrap items-center gap-4">
                <div>
                  <label className="mb-0.5 block text-xs text-ink-400">العدد الابتدائي</label>
                  <input type="number" min={0} defaultValue={r.initial_public_release} onBlur={(e) => updateField(r.id, "initial_public_release", Number(e.target.value))} className="input w-20 text-center" disabled={acting === r.id + "initial_public_release"} />
                </div>
                <div>
                  <label className="mb-0.5 block text-xs text-ink-400">الزيادة</label>
                  <input type="number" min={1} defaultValue={r.release_increment} onBlur={(e) => updateField(r.id, "release_increment", Number(e.target.value))} className="input w-20 text-center" disabled={acting === r.id + "release_increment"} />
                </div>
                <div>
                  <label className="mb-0.5 block text-xs text-ink-400">الشرط</label>
                  <p className="text-xs text-ink-600">{r.release_trigger === "access_delivered" ? "تسليم الرمز" : r.release_trigger === "confirmed" ? "تأكيد الحجز" : "يدوي"}</p>
                </div>
                <button onClick={() => toggle(r)} disabled={acting === r.id} className="btn-outline text-sm">
                  {acting === r.id ? <Spinner /> : r.enabled ? "إيقاف" : "تفعيل"}
                </button>
                <button onClick={() => setReleaseFor(r)} className="btn-accent text-sm"><Unlock className="h-4 w-4" /> إفراج يدوي عن غرفة إضافية</button>
              </div>
            </Card>
          ))}
          {rules.length === 0 && <p className="text-sm text-ink-400">لا توجد قواعد لهذا الفرع.</p>}
        </div>
        <Card>
          <h3 className="mb-3 text-sm font-semibold text-ink-700">الغرف المُفرج عنها — 14 يومًا القادمة</h3>
          {slots.length === 0 ? <p className="text-xs text-ink-400">لا توجد إفراجات مسجّلة.</p> : (
            <table className="w-full text-xs">
              <thead><tr className="border-b border-ink-100 text-ink-400"><th className="py-1.5 text-right font-medium">التاريخ</th><th className="py-1.5 text-right font-medium">التصنيف</th><th className="py-1.5 text-center font-medium">مُفرج</th></tr></thead>
              <tbody>{slots.map((s, i) => (
                <tr key={i} className="border-b border-ink-50"><td className="py-1.5 text-ink-700" dir="ltr">{s.date}</td><td className="py-1.5 text-ink-600">{catOf(s.category_id)}</td><td className="py-1.5 text-center font-semibold text-brand-700">{s.released_count}</td></tr>
              ))}</tbody>
            </table>
          )}
        </Card>
      </div>
      {releaseFor && branchId && <ReleaseModal rule={releaseFor} branchId={branchId} onClose={() => setReleaseFor(null)} onDone={load} />}
    </div>
  );
}

function ReleaseModal({ rule, branchId, onClose, onDone }: { rule: RuleRow; branchId: string; onClose: () => void; onDone: () => Promise<void> }) {
  const [date, setDate] = useState(todayISO());
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<number | null>(null);

  async function submit() {
    setError(null);
    if (!reason.trim()) { setError("يجب كتابة سبب."); return; }
    setBusy(true);
    try {
      const n = await staffApi.releaseNextSlot(branchId, rule.category_id, date, reason.trim());
      setResult(Number(n));
      await onDone();
    } catch (e) { setError(toArabicError(e)); }
    setBusy(false);
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/40 p-4" role="dialog" aria-modal="true">
      <Card className="w-full max-w-md">
        <h3 className="mb-1 text-base font-semibold text-ink-800">إفراج يدوي — {catName(rule)}</h3>
        <p className="mb-4 text-xs text-ink-400">يُفتح عدد "الزيادة" ({rule.release_increment}) من الرصيد المتبقي لهذا التاريخ، ويُسجَّل السبب في سجل التدقيق.</p>
        {error && <div className="mb-3"><ErrorBanner message={error} /></div>}
        {result !== null ? (
          <div className="rounded-xl bg-success-500/10 p-4 text-sm text-success-600">إجمالي الغرف المُفرج عنها لتاريخ {date}: <strong>{result}</strong></div>
        ) : (
          <div className="space-y-3">
            <div><label className="label">التاريخ</label><input type="date" className="input" value={date} min={todayISO()} onChange={(e) => setDate(e.target.value)} /></div>
            <div><label className="label">السبب</label><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="مثال: طلب مجموعة مؤكد هاتفيًا" /></div>
          </div>
        )}
        <div className="mt-5 flex justify-end gap-2">
          <button onClick={onClose} className="btn-outline text-sm" disabled={busy}>{result !== null ? "إغلاق" : "إلغاء"}</button>
          {result === null && <button onClick={submit} className="btn-primary text-sm" disabled={busy}>{busy ? <Spinner className="h-4 w-4" /> : "تنفيذ الإفراج"}</button>}
        </div>
      </Card>
    </div>
  );
}
