/**
 * «المنشأة» (0055, SETUP-04 and SETUP-12): the organisation's own record, the owner's.
 *  - the Arabic and English name, the licence number and the logo: every screen, printout and guest page reads them;
 *  - the price range of each role: for the supervisor and for the manager, the lowest and the highest nightly price as a
 *    percentage of the unit type's base price. The owner is not limited; an empty box sets no bound.
 */
import { useEffect, useState } from "react";
import { Building, Image as ImageIcon, Percent } from "lucide-react";
import { Card, ErrorBanner, LoadErrorCard, LoadingScreen, SectionTitle, Spinner } from "../../components/ui";
import { Field, NumberInput } from "../../components/forms";
import { organizationApi, toArabicError, type OrganizationSettings } from "../../lib/api";
import { refreshOrganization } from "../../lib/organization";
import { useAuth } from "../../lib/auth";

type Band = { min: number | null; max: number | null };
const pct = (bp: number | null) => (bp == null ? null : bp / 100);
const bp = (p: number | null) => (p == null ? "" : String(Math.round(p * 100)));
const sar = (h: number) => (h / 100).toLocaleString("en-US", { minimumFractionDigits: 0, maximumFractionDigits: 2 });

export default function AdminOrganization() {
  const { profile } = useAuth();
  const owner = profile?.role === "owner";
  const [org, setOrg] = useState<OrganizationSettings | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [nameAr, setNameAr] = useState(""); const [nameEn, setNameEn] = useState(""); const [license, setLicense] = useState("");
  const [sup, setSup] = useState<Band>({ min: null, max: null }); const [mgr, setMgr] = useState<Band>({ min: null, max: null });
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);

  const load = async () => {
    setLoadError(null);
    try {
      const o = await organizationApi.info(); if (!o) throw new Error("NOT_FOUND");
      setOrg(o); setNameAr(o.name_ar); setNameEn(o.name_en ?? ""); setLicense(o.license_number ?? "");
      setSup({ min: pct(o.price_min_bp_supervisor), max: pct(o.price_max_bp_supervisor) });
      setMgr({ min: pct(o.price_min_bp_manager), max: pct(o.price_max_bp_manager) });
    } catch (e) { setLoadError(toArabicError(e)); }
  };
  useEffect(() => { void load(); }, []);

  async function save(what: "names" | "prices", p: Record<string, unknown>) {
    if (!org) return;
    setBusy(what); setError(null); setSaved(null);
    try {
      await organizationApi.update({ ...p, version: org.version });
      await load(); await refreshOrganization();
      setSaved(what === "names" ? "حُفظت بيانات المنشأة." : "حُفظ نطاق الأسعار.");
    } catch (e) { setError(toArabicError(e)); }
    setBusy(null);
  }

  async function pickLogo(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]; e.target.value = ""; if (!file) return;
    if (file.size > 204800) { setError("حجم الشعار أكبر من 200 كيلوبايت."); return; }
    try {
      const b64 = await new Promise<string>((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result)); r.onerror = () => rej(new Error("VALIDATION: image")); r.readAsDataURL(file); });
      await save("names", { logo_base64: b64 });
    } catch (err) { setError(toArabicError(err)); }
  }

  if (loadError) return <LoadErrorCard message={loadError} onRetry={load} />;
  if (!org) return <LoadingScreen />;

  const example = 20000;   // a 200 SAR base price, to read the percentages as amounts
  const range = (b: Band) => b.min == null && b.max == null ? "بلا حد"
    : `${b.min == null ? "بلا حد أدنى" : `من ${sar(Math.ceil(example * b.min / 100))}`} ${b.max == null ? "وبلا حد أعلى" : `إلى ${sar(Math.floor(example * b.max / 100))}`} ر.س`;

  return (
    <div className="space-y-4">
      <SectionTitle title="المنشأة" subtitle="اسم المنشأة وشعارها كما تظهر في كل الشاشات والمطبوعات وصفحات الضيوف، ونطاق الأسعار المسموح لكل دور" />
      {!owner && <div className="rounded-xl bg-ink-50 p-3 text-sm text-ink-600">هذه الإعدادات يعدّلها المالك وحده.</div>}
      {error && <ErrorBanner message={error} />}
      {saved && <p className="rounded-xl bg-success-500/10 p-3 text-sm text-success-600" role="status">{saved}</p>}

      <Card className="space-y-4">
        <h2 className="flex items-center gap-2 text-sm font-semibold text-ink-800"><Building className="h-4 w-4 text-brand-600" /> بيانات المنشأة</h2>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="الاسم بالعربية"><input className="input" value={nameAr} maxLength={120} disabled={!owner} onChange={(e) => setNameAr(e.target.value)} /></Field>
          <Field label="الاسم بالإنجليزية"><input className="input" dir="ltr" value={nameEn} maxLength={120} disabled={!owner} onChange={(e) => setNameEn(e.target.value)} /></Field>
          <Field label="رقم الترخيص" hint="أحرف إنجليزية وأرقام فقط"><input className="input" dir="ltr" value={license} maxLength={40} disabled={!owner} onChange={(e) => setLicense(e.target.value)} /></Field>
        </div>
        {owner && (
          <div className="flex justify-end">
            <button className="btn-primary text-sm" disabled={busy !== null || !nameAr.trim()} onClick={() => save("names", { name_ar: nameAr, name_en: nameEn, license_number: license })}>
              {busy === "names" ? <Spinner className="h-4 w-4" /> : "حفظ البيانات"}
            </button>
          </div>
        )}
        <div className="flex flex-wrap items-center gap-3 rounded-xl bg-ink-50 p-3">
          {org.logo ? <img src={org.logo} alt="شعار المنشأة" className="h-12 max-w-[140px] rounded-md object-contain" /> : <div className="flex h-12 w-16 items-center justify-center rounded-md bg-white text-ink-400"><ImageIcon className="h-5 w-5" /></div>}
          <p className="flex-1 text-xs text-ink-500">الشعار — PNG أو JPG أو WebP حتى 200 كيلوبايت. يظهر في رأس الشاشات وصفحات النزلاء.</p>
          {owner && <label className="btn-outline min-h-[44px] cursor-pointer text-xs">{org.logo ? "استبدال" : "رفع"}<input type="file" accept="image/png,image/jpeg,image/webp" className="hidden" onChange={pickLogo} disabled={busy !== null} aria-label="رفع شعار المنشأة" /></label>}
          {owner && org.logo && <button className="btn-ghost min-h-[44px] text-xs text-danger-600" disabled={busy !== null} onClick={() => save("names", { logo_base64: "" })}>إزالة</button>}
        </div>
      </Card>

      <Card className="space-y-4">
        <h2 className="flex items-center gap-2 text-sm font-semibold text-ink-800"><Percent className="h-4 w-4 text-brand-600" /> نطاق سعر الليلة لكل دور</h2>
        <p className="text-xs leading-6 text-ink-500">
          نسبة من السعر الأساسي لنوع الوحدة. يُرفض أي سعر خارج نطاق الدور: سعر في التقويم، سعر ليلة يُكتب للحجز، خصم ينزل بالليلة تحت الأدنى، أو تسوية تتجاوز الأعلى.
          الأدنى بين 1% و100%، والأعلى بين 100% و1000%. اترك الخانة فارغة لعدم وضع حد. المالك غير مقيد.
        </p>
        {([["المشرف", sup, setSup], ["المدير", mgr, setMgr]] as const).map(([label, band, set]) => (
          <div key={label} className="grid items-end gap-3 rounded-xl border border-ink-100 p-3 sm:grid-cols-[8rem_1fr_1fr]">
            <p className="text-sm font-medium text-ink-700">{label}</p>
            <Field label="أدنى سعر (% من الأساسي)"><NumberInput decimals value={band.min} disabled={!owner} label={`أدنى سعر — ${label}`} placeholder="بلا حد" onChange={(v) => set({ ...band, min: v })} /></Field>
            <Field label="أعلى سعر (% من الأساسي)"><NumberInput decimals value={band.max} disabled={!owner} label={`أعلى سعر — ${label}`} placeholder="بلا حد" onChange={(v) => set({ ...band, max: v })} /></Field>
            <p className="text-xs text-ink-400 sm:col-span-3">مثال: نوع سعره الأساسي 200 ر.س — {range(band)} لليلة.</p>
          </div>
        ))}
        {owner && (
          <div className="flex justify-end">
            <button className="btn-primary text-sm" disabled={busy !== null} data-testid="save-price-limits"
              onClick={() => save("prices", { price_min_bp_supervisor: bp(sup.min), price_max_bp_supervisor: bp(sup.max), price_min_bp_manager: bp(mgr.min), price_max_bp_manager: bp(mgr.max) })}>
              {busy === "prices" ? <Spinner className="h-4 w-4" /> : "حفظ النطاق"}
            </button>
          </div>
        )}
      </Card>
    </div>
  );
}
