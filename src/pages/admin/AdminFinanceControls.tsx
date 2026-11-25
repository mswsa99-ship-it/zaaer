import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../lib/auth";
import { Card, ErrorBanner, LoadingScreen, SectionTitle } from "../../components/ui";
import { ROLE_LABELS } from "../../lib/types";
import { EXPENSE_ROLES, FINANCE_FIELDS, parseFinanceThreshold, type FinanceControls } from "../../lib/financeControls";

export default function AdminFinanceControls() {
  const { profile } = useAuth();
  const [data, setData] = useState<FinanceControls | null>(null);
  const [values, setValues] = useState<Record<string, string>>({});
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);
  const [busy, setBusy] = useState(false);
  function load(d: FinanceControls) {
    setData(d);
    setValues(Object.fromEntries([...EXPENSE_ROLES.map(r => [r, d.expense_role_limits[r]?.toString() ?? ""]),
      ...FINANCE_FIELDS.map(([k]) => [k, d[k]?.toString() ?? ""])]));
  }
  useEffect(() => {
    let active = true;
    supabase.rpc("fn_finance_controls_get").then(({ data: d, error: e }) => {
      if (!active) return;
      if (e) setError("تعذّر تحميل إعدادات الضبط المالي"); else load(d as FinanceControls);
    });
    return () => { active = false; };
  }, []);
  if (profile?.role !== "owner") return <ErrorBanner message="هذه الصفحة للمالك فقط" />;
  if (!data) return error ? <ErrorBanner message={error} /> : <LoadingScreen />;
  async function save(event: React.FormEvent) {
    event.preventDefault(); setError(""); setSaved(false); setBusy(true);
    try {
      const expense_role_limits = Object.fromEntries(EXPENSE_ROLES.map(r => {
        const n = parseFinanceThreshold(values[r]);
        if (n === 0) throw new Error("حد المصروف يجب أن يكون أكبر من صفر");
        return [r, n];
      }));
      const p: Record<string, unknown> = { expense_role_limits };
      for (const [k] of FINANCE_FIELDS) {
        const n = parseFinanceThreshold(values[k], k === "discount_review_threshold_bp" ? 10000 : undefined);
        if (!k.startsWith("operational_") && k !== "discount_review_threshold_bp" && (n === null || n === 0)) throw new Error("عتبة التنبيه يجب أن تكون أكبر من صفر");
        p[k] = n;
      }
      const { data: result, error: e } = await supabase.rpc("fn_finance_controls_set", { p });
      if (e) throw new Error("لم تُحفظ الإعدادات. تحقق من الصلاحية والقيم ثم أعد المحاولة");
      load(result as FinanceControls); setSaved(true);
    } catch (e) { setError(e instanceof Error ? e.message : "تعذّر الحفظ"); }
    finally { setBusy(false); }
  }
  const input = (k: string, label: string, hint?: string) => <label key={k} className="block space-y-2 text-sm">
    <span className="font-medium">{label}</span>
    <input className="input w-full" aria-label={label} inputMode="numeric" value={values[k] ?? ""} disabled={busy || k === "operational_refund_threshold_halalas"}
      onChange={e => { setValues(v => ({ ...v, [k]: e.target.value })); setSaved(false); }} />
    {hint && <span className="block text-ink-600">{hint}</span>}
  </label>;
  return <div className="space-y-5">
    <SectionTitle title="الضبط المالي" subtitle="إعدادات هذا الفندق فقط. كل تغيير يُسجّل في السجل الأمني بالقيمة السابقة والجديدة." />
    <Card className="p-5"><p className="text-sm text-ink-700">حدود المصروف الحالية موروثة من التنفيذ وليست سياسة نهائية معتمدة. الحقل الفارغ يُبقي السلوك الحالي. تغيير الحد هنا يؤثر على المصروف التالي، وما فوقه ينتظر اعتماد الإدارة ولا يُصرف قبله.</p></Card>
    {error && <ErrorBanner message={error} />}
    {saved && <p role="status" className="text-success-600">حُفظت الإعدادات وسُجّل التغيير في أمني</p>}
    <form onSubmit={save} className="space-y-5">
      <Card className="space-y-5 p-5"><h2 className="text-lg font-semibold">حد المصروف لكل دور (هللة)</h2>
        <p className="text-sm text-ink-600">المالك ومدير الفرع بلا حد مبلغ في السلوك الحالي. هذه الحدود لا تمنح صلاحية المصروف لدور لا يملكها.</p>
        <div className="grid gap-5 md:grid-cols-3">{EXPENSE_ROLES.map(r => input(r, ROLE_LABELS[r], `المطبق الآن: ${data.effective_expense_limits[r]?.toLocaleString("ar-SA")} هللة. اتركه فارغًا لاستعادة السلوك الموروث.`))}</div>
      </Card>
      <Card className="space-y-5 p-5"><h2 className="text-lg font-semibold">الاعتماد ورصد الشذوذ</h2>
        <div className="grid gap-5 md:grid-cols-3">{FINANCE_FIELDS.map(([k, label]) => input(k, label, k === "discount_review_threshold_bp" ? "الفراغ يبقي اعتماد الخصم غير مفعّل. فوق العتبة يلزم اعتماد مسبق." : k === "operational_refund_threshold_halalas" ? "غير متاح للتفعيل من هذه الصفحة حتى اكتمال شاشة اعتماد الاسترداد. لا تفعّل قاعدة جديدة الآن." : k === "operational_closing_diff_alert_halalas" ? "فوق العتبة يُنشأ بند مراجعة وتنبيه للمالك. الفراغ يبقي القاعدة غير مفعّلة." : "فوق العتبة يُنشأ بند مراجعة وتنبيه للمالك."))}</div>
        <p className="text-sm text-ink-600">الوصول الآجل: اعتماد المدير أو المالك. الإقامة المجانية: اعتماد المالك. الزيادة على المستحق: سبب وتأكيد ومراجعة. لم تُغيّر قواعد القبض أو التأمين.</p>
        <p className="text-sm text-ink-600">الفراغ في عتبة الاسترداد أو فرق الإقفال يبقي السلوك الحالي. عند تفعيل عتبة الاسترداد، يلزم اعتماد المالك للمبلغ نفسه قبل تنفيذه.</p>
      </Card>
      <button className="btn-primary" type="submit" disabled={busy}>{busy ? "جارٍ الحفظ…" : "حفظ الضبط المالي"}</button>
    </form>
  </div>;
}
