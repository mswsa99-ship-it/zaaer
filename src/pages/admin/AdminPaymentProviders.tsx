/**
 * «مزودو الدفع» (0056, SETUP-02): each branch's payment provider — the provider, the merchant number, the public key,
 * the secret key (kept encrypted and never shown again, only its last four characters), the POS terminal. Owner only.
 * Saving the settings does not yet take payments: the live link to the provider is built once the owner has the account,
 * and until then payments are recorded by hand with their reference number. The page says so plainly.
 */
import { useEffect, useState } from "react";
import { CreditCard, Check, KeyRound, Info } from "lucide-react";
import { Card, ErrorBanner, LoadErrorCard, LoadingScreen, SectionTitle, Spinner, Badge } from "../../components/ui";
import { Field } from "../../components/forms";
import { branchGuideApi, toArabicError, type PaymentProvider, type PaymentSettings } from "../../lib/api";
import { useBranch } from "../../lib/branch";
import { useAuth } from "../../lib/auth";

const PROVIDERS: Record<PaymentProvider, string> = { moyasar: "ميسّر (Moyasar)", tap: "تاب (Tap)", hyperpay: "هايبر باي (HyperPay)", paytabs: "باي تابس (PayTabs)", other: "مزوّد آخر" };

export default function AdminPaymentProviders() {
  const { can } = useAuth();
  const owner = can("security");
  const { branches, branchId, setBranchId } = useBranch();
  const [s, setS] = useState<PaymentSettings | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [form, setForm] = useState({ provider: "", provider_label: "", merchant_id: "", publishable_key: "", pos_terminal_id: "" });
  const [secret, setSecret] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);

  const load = async () => {
    if (!branchId || !owner) return; setLoadError(null); setS(null);
    try {
      const r = await branchGuideApi.paymentSettings(branchId); setS(r);
      setForm({ provider: r.provider ?? "", provider_label: r.provider_label ?? "", merchant_id: r.merchant_id ?? "", publishable_key: r.publishable_key ?? "", pos_terminal_id: r.pos_terminal_id ?? "" });
      setSecret("");
    } catch (e) { setLoadError(toArabicError(e)); }
  };
  useEffect(() => { void load(); }, [branchId, owner]); // eslint-disable-line react-hooks/exhaustive-deps

  async function save(extra: Record<string, unknown> = {}) {
    if (!branchId) return; setBusy(true); setError(null); setSaved(null);
    try {
      const r = await branchGuideApi.savePaymentSettings({ branch_id: branchId, ...form, ...(secret.trim() ? { secret_key: secret.trim() } : {}), ...extra });
      await load(); setSaved(r.changed.length ? "حُفظت إعدادات الدفع." : "لا تغييرات للحفظ.");
    } catch (e) { setError(toArabicError(e)); }
    setBusy(false);
  }

  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setForm({ ...form, [k]: e.target.value });

  return (
    <div className="space-y-4">
      <SectionTitle title="مزودو الدفع" subtitle="بيانات حساب مزوّد الدفع وجهاز نقاط البيع لكل فرع"
        action={branches.length > 1 ? <select className="input w-auto" value={branchId ?? ""} onChange={(e) => setBranchId(e.target.value)} aria-label="الفرع">{branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}</select> : undefined} />

      <div className="flex items-start gap-2 rounded-xl bg-warning-500/10 p-4 text-sm text-warning-700" role="note">
        <Info className="mt-0.5 h-4 w-4 shrink-0" />
        <p>تُحفظ البيانات هنا جاهزة للربط، لكن <strong>الربط المباشر مع المزوّد لم يُفعَّل بعد</strong>: لا تُنشأ روابط دفع ولا تُستقبل عمليات الجهاز تلقائيًا. حتى ذلك تُسجَّل المدفوعات يدويًا برقم المرجع.</p>
      </div>

      {!owner ? <div className="rounded-xl bg-ink-50 p-3 text-sm text-ink-600">هذه الإعدادات يعدّلها المالك وحده.</div>
        : loadError ? <LoadErrorCard message={loadError} onRetry={load} />
        : !s ? <LoadingScreen /> : (
        <Card className="space-y-4">
          <div className="flex flex-wrap items-center gap-2">
            <h2 className="flex items-center gap-2 text-sm font-semibold text-ink-800"><CreditCard className="h-4 w-4 text-brand-600" /> حساب المزوّد</h2>
            <Badge className={s.complete ? "bg-success-500/10 text-success-600" : "bg-ink-100 text-ink-500"}>{s.complete ? "البيانات مكتملة" : "البيانات غير مكتملة"}</Badge>
            {s.updated_at && <span className="mr-auto text-xs text-ink-400">آخر تعديل {new Date(s.updated_at).toLocaleDateString("ar-SA-u-nu-latn")}{s.updated_by ? ` — ${s.updated_by}` : ""}</span>}
          </div>
          {error && <ErrorBanner message={error} />}
          {saved && <p className="rounded-xl bg-success-500/10 p-3 text-sm text-success-600" role="status">{saved}</p>}
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="المزوّد">
              <select className="input" value={form.provider} onChange={set("provider")}>
                <option value="">— لم يُختر —</option>
                {Object.entries(PROVIDERS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
              </select>
            </Field>
            {form.provider === "other" && <Field label="اسم المزوّد"><input className="input" maxLength={60} value={form.provider_label} onChange={set("provider_label")} /></Field>}
            <Field label="رقم التاجر (Merchant ID)"><input className="input" dir="ltr" maxLength={80} value={form.merchant_id} onChange={set("merchant_id")} autoComplete="off" /></Field>
            <Field label="المفتاح العام (Publishable key)"><input className="input" dir="ltr" maxLength={200} value={form.publishable_key} onChange={set("publishable_key")} autoComplete="off" placeholder="pk_live_…" /></Field>
            <Field label="المفتاح السري (Secret key)" hint={s.has_secret ? `محفوظ ومشفّر — ينتهي بـ ${s.secret_last4}. اكتب مفتاحًا جديدًا لاستبداله فقط.` : "يُحفظ مشفّرًا ولا يُعرض مرة أخرى."}>
              <input className="input" dir="ltr" type="password" maxLength={300} value={secret} onChange={(e) => setSecret(e.target.value)} autoComplete="new-password" placeholder={s.has_secret ? "••••••••" : "sk_live_…"} />
            </Field>
            <Field label="رقم جهاز نقاط البيع (اختياري)"><input className="input" dir="ltr" maxLength={40} value={form.pos_terminal_id} onChange={set("pos_terminal_id")} autoComplete="off" /></Field>
          </div>
          <div className="flex flex-wrap items-center justify-end gap-2">
            {s.has_secret && <button className="btn-ghost min-h-[44px] text-xs text-danger-600" disabled={busy} onClick={() => save({ clear_secret: true })}><KeyRound className="h-3.5 w-3.5" /> إزالة المفتاح السري</button>}
            <button className="btn-primary text-sm" disabled={busy} onClick={() => save()} data-testid="save-payment-settings">{busy ? <Spinner className="h-4 w-4" /> : "حفظ"}</button>
          </div>
        </Card>
      )}

      <Card>
        <h3 className="mb-3 flex items-center gap-2 text-sm font-semibold text-ink-700"><CreditCard className="h-4 w-4 text-brand-600" /> طرق الدفع الآن</h3>
        <div className="space-y-3">
          <div className="rounded-xl border border-ink-100 p-3">
            <p className="text-sm font-medium text-ink-700">الدفع عبر منصة الحجز</p>
            <p className="mt-1 text-xs text-ink-500">تسجيل مصدر الحجز وحالة الدفع ومطابقة إيداعات المنصات — يعمل الآن <Check className="inline h-3 w-3 text-success-600" /></p>
          </div>
          <div className="rounded-xl border border-ink-100 p-3">
            <p className="text-sm font-medium text-ink-700">نقدًا أو بالشبكة أو بالتحويل</p>
            <p className="mt-1 text-xs text-ink-500">يُسجَّل يدويًا برقم المرجع ويُطابَق في المالية — يعمل الآن <Check className="inline h-3 w-3 text-success-600" /></p>
          </div>
          <div className="rounded-xl border border-warning-500/30 p-3">
            <p className="text-sm font-medium text-ink-700">رابط دفع إلكتروني وجهاز نقاط بيع مربوط</p>
            <p className="mt-1 text-xs text-warning-700">لم يُفعَّل بعد — يُبنى بعد فتح الحساب لدى المزوّد وإدخال بياناته أعلاه.</p>
          </div>
        </div>
      </Card>
    </div>
  );
}
