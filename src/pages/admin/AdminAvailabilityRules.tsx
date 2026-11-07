import { useState } from "react";
import { supabase } from "../../lib/supabase";
import { inventoryApi, staffApi, toArabicError } from "../../lib/api";
import { Modal, NumberInput } from "../../components/forms";
import { useBranch } from "../../lib/branch";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { SectionTitle, LoadingScreen, Card, Spinner, Badge, ErrorBanner, LoadErrorCard } from "../../components/ui";
import { CalendarRange, Unlock } from "lucide-react";
import { addDaysISO, todayISO } from "../../lib/utils";

interface RuleRow {
  id: string; category_id: string; enabled: boolean; initial_public_release: number; release_increment: number; release_trigger: string;
  category?: { name_ar: string } | { name_ar: string }[] | null;
}
interface SlotRow { date: string; released_count: number; category_id: string }

interface RulesData { rules: RuleRow[]; slots: SlotRow[]; categories: Array<{ id: string; name_ar: string }> }
const NO_RULES: RulesData = { rules: [], slots: [], categories: [] };
const TRIGGERS: Array<[string, string]> = [["access_delivered", "تسليم الرمز"], ["confirmed", "تأكيد الحجز"], ["manual", "يدوي"]];

function catName(r: RuleRow) { const c = Array.isArray(r.category) ? r.category[0] : r.category; return c?.name_ar ?? "—"; }

export default function AdminAvailabilityRules() {
  const { branches, setBranchId } = useBranch();
  const [acting, setActing] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [releaseFor, setReleaseFor] = useState<RuleRow | null>(null);

  // G24 (decision 40): the active branch's rules only
  const q = useBranchQuery<RulesData>(async (branchId) => {
    const [r, s, c] = await Promise.all([
      supabase.from("release_rules").select("id, category_id, enabled, initial_public_release, release_increment, release_trigger, category:room_categories(name_ar)").eq("branch_id", branchId),
      supabase.from("released_slots").select("date, released_count, category_id").eq("branch_id", branchId).gte("date", todayISO()).lte("date", addDaysISO(todayISO(), 14)).order("date"),
      supabase.from("room_categories").select("id, name_ar").eq("branch_id", branchId).is("archived_at", null).order("sort_order"),
    ]);
    return { rules: must(r) as unknown as RuleRow[], slots: must(s) as SlotRow[], categories: must(c) as Array<{ id: string; name_ar: string }> };
  }, [], NO_RULES);
  const { rules, slots, categories } = q.data;
  const [newCat, setNewCat] = useState("");
  const withoutRule = categories.filter((c) => !rules.some((r) => r.category_id === c.id)); const branchId = q.branchId; const load = q.reload;

  // 0055 (SETUP-01): through fn_admin_upsert_release_rule — initial ≥ 0 and ≤ the type's units, increment ≥ 1, a known trigger
  async function saveRule(key: string, p: Parameters<typeof inventoryApi.upsertRule>[0]) {
    setActing(key); setError(null);
    try { await inventoryApi.upsertRule(p); } catch (e) { setError(toArabicError(e)); }
    load();
    setActing(null);
  }
  const toggle = (r: RuleRow) => saveRule(r.id, { id: r.id, enabled: !r.enabled });
  const updateField = (r: RuleRow, field: "initial_public_release" | "release_increment", value: number | null) => {
    if (value === r[field]) return;
    if (value == null) { setError("أدخل عددًا صحيحًا."); return; }
    return saveRule(r.id + field, { id: r.id, [field]: value });
  };

  if (q.loading) return <LoadingScreen />;

  const catOf = (id: string) => { const r = rules.find((x) => x.category_id === id); return r ? catName(r) : id.slice(0, 8); };

  return (
    <div>
      <SectionTitle title="قواعد الكشف التدريجي" subtitle="تحكم في عدد الوحدات المعروضة تدريجيًا" action={
        <select className="input w-auto" value={branchId ?? ""} onChange={(e) => setBranchId(e.target.value)} aria-label="الفرع">
          {branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
        </select>
      } />
      {(error || (q.error && rules.length > 0)) && <div className="mb-4"><ErrorBanner message={(error ?? q.error) as string} /></div>}
      {q.error && rules.length === 0 && <div className="mb-4"><LoadErrorCard message={q.error} onRetry={load} /></div>}
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
                  <NumberInput value={r.initial_public_release} onCommit={(v) => updateField(r, "initial_public_release", v)} className="w-20 text-center" label="الإتاحة الأولية" disabled={acting === r.id + "initial_public_release"} />
                </div>
                <div>
                  <label className="mb-0.5 block text-xs text-ink-400">الزيادة</label>
                  <NumberInput value={r.release_increment} onCommit={(v) => updateField(r, "release_increment", v)} className="w-20 text-center" label="زيادة الإتاحة" disabled={acting === r.id + "release_increment"} />
                </div>
                <div>
                  <label className="mb-0.5 block text-xs text-ink-400">الشرط</label>
                  <select className="input w-auto text-xs" value={r.release_trigger} aria-label="شرط الكشف" disabled={acting === r.id} onChange={(e) => saveRule(r.id, { id: r.id, release_trigger: e.target.value })}>
                    {TRIGGERS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                  </select>
                </div>
                <button onClick={() => toggle(r)} disabled={acting === r.id} className="btn-outline text-sm">
                  {acting === r.id ? <Spinner /> : r.enabled ? "إيقاف" : "تفعيل"}
                </button>
                <button onClick={() => setReleaseFor(r)} className="btn-accent text-sm"><Unlock className="h-4 w-4" /> إفراج يدوي عن وحدة إضافية</button>
              </div>
            </Card>
          ))}
          {rules.length === 0 && !q.error && <p className="text-sm text-ink-400">لا توجد قواعد لهذا الفرع.</p>}
          {withoutRule.length > 0 && (
            <Card className="flex flex-wrap items-end gap-3">
              <div className="flex-1">
                <label className="mb-0.5 block text-xs text-ink-400">قاعدة جديدة لنوع</label>
                <select className="input" value={newCat} onChange={(e) => setNewCat(e.target.value)} aria-label="نوع الوحدة للقاعدة الجديدة">
                  <option value="">اختر النوع…</option>
                  {withoutRule.map((c) => <option key={c.id} value={c.id}>{c.name_ar}</option>)}
                </select>
              </div>
              <button className="btn-primary text-sm" disabled={!newCat || acting === "new"} onClick={async () => { await saveRule("new", { category_id: newCat, initial_public_release: 1, release_increment: 1, release_trigger: "access_delivered" }); setNewCat(""); }}>
                {acting === "new" ? <Spinner /> : "إضافة القاعدة"}
              </button>
              <p className="w-full text-xs text-ink-400">تبدأ القاعدة متوقفة بعدد ابتدائي 1 وزيادة 1 عند تسليم الرمز؛ عدّلها ثم فعّلها.</p>
            </Card>
          )}
        </div>
        <Card>
          <h3 className="mb-3 text-sm font-semibold text-ink-700">الوحدات المُفرج عنها — 14 يومًا القادمة</h3>
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

function ReleaseModal({ rule, branchId, onClose, onDone }: { rule: RuleRow; branchId: string; onClose: () => void; onDone: () => void }) {
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
      onDone();
    } catch (e) { setError(toArabicError(e)); }
    setBusy(false);
  }

  return (
    <Modal open title={`إفراج يدوي — ${catName(rule)}`} onClose={onClose}>
      <div>
        <p className="mb-4 text-xs text-ink-400">يُفتح عدد «الزيادة» ({rule.release_increment}) من الرصيد المتبقي لهذا التاريخ، ويُسجَّل السبب في سجل التدقيق.</p>
        {error && <div className="mb-3"><ErrorBanner message={error} /></div>}
        {result !== null ? (
          <div className="rounded-xl bg-success-500/10 p-4 text-sm text-success-600">إجمالي الوحدات المُفرج عنها لتاريخ {date}: <strong>{result}</strong></div>
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
      </div>
    </Modal>
  );
}
