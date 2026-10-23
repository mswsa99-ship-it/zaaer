import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { MessageCircle, Copy, Check, RefreshCw, PlugZap, Power, ChevronDown, ShieldCheck, AlertTriangle } from "lucide-react";
import { whatsappApi, toArabicError, type WaChannelRow, type WaCheck } from "../../lib/api";
import { isDemo } from "../../lib/supabase";
import { SectionTitle, LoadingScreen, Card, Badge, Spinner, ErrorBanner } from "../../components/ui";
import { formatDateTime } from "../../lib/utils";

/**
 * WhatsApp per branch (owner): each branch has its own WhatsApp Business number. Everything is set here — the
 * access token and app secret are stored encrypted and never shown again (only "saved ••••1234").
 */
const STATUS: Record<WaChannelRow["status"], { label: string; cls: string }> = {
  not_configured: { label: "غير مكتمل", cls: "bg-ink-100 text-ink-500" },
  configured: { label: "مكتمل — بانتظار اختبار الاتصال", cls: "bg-warning-500/10 text-warning-600" },
  active: { label: "متصل", cls: "bg-success-500/10 text-success-600" },
  error: { label: "خطأ في الاتصال", cls: "bg-danger-500/10 text-danger-600" },
};

const WEBHOOK_URL = isDemo ? "https://<project>.supabase.co/functions/v1/whatsapp-webhook" : `${String(import.meta.env.VITE_SUPABASE_URL ?? "").replace(/\/$/, "")}/functions/v1/whatsapp-webhook`;

function CopyText({ value, label }: { value: string; label: string }) {
  const [done, setDone] = useState(false);
  return (
    <div className="flex min-w-0 items-center gap-2 rounded-xl border border-ink-100 bg-ink-50 px-3 py-2">
      <div className="min-w-0 flex-1">
        <p className="text-[11px] text-ink-400">{label}</p>
        <p className="truncate font-mono text-xs text-ink-700" dir="ltr">{value}</p>
      </div>
      <button type="button" className="rounded-lg p-1.5 text-ink-400 hover:bg-white hover:text-brand-600" aria-label={`نسخ ${label}`}
        onClick={async () => { try { await navigator.clipboard.writeText(value); setDone(true); setTimeout(() => setDone(false), 1500); } catch { /* select manually */ } }}>
        {done ? <Check className="h-4 w-4 text-success-600" /> : <Copy className="h-4 w-4" />}
      </button>
    </div>
  );
}

function BranchChannel({ row, onSaved }: { row: WaChannelRow; onSaved: () => void }) {
  const [form, setForm] = useState({ display_phone: row.display_phone ?? "", phone_number_id: row.phone_number_id ?? "", waba_id: row.waba_id ?? "", access_token: "", app_secret: "", otp_template: row.otp_template ?? "", template_lang: row.template_lang || "ar" });
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [check, setCheck] = useState<WaCheck | null>(null);
  const [open, setOpen] = useState(row.status !== "active");
  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) => setForm((f) => ({ ...f, [k]: e.target.value }));

  async function run(kind: string, fn: () => Promise<unknown>, ok: string) {
    setBusy(kind); setError(null); setNotice(null);
    try { await fn(); setNotice(ok); onSaved(); } catch (e) { setError(toArabicError(e)); }
    setBusy(null);
  }
  const save = () => run("save", async () => {
    const patch: Record<string, unknown> = { display_phone: form.display_phone, phone_number_id: form.phone_number_id, waba_id: form.waba_id, otp_template: form.otp_template, template_lang: form.template_lang };
    if (form.access_token.trim()) patch.access_token = form.access_token.trim();
    if (form.app_secret.trim()) patch.app_secret = form.app_secret.trim();
    await whatsappApi.save(row.branch_id, patch);
    setForm((f) => ({ ...f, access_token: "", app_secret: "" }));
  }, "تم الحفظ. اضغط «اختبار الاتصال» للتأكد من البيانات.");
  const toggle = () => run("toggle", () => whatsappApi.save(row.branch_id, { enabled: !row.enabled }), row.enabled ? "تم إيقاف واتساب لهذا الفرع؛ يظهر للنزلاء «قريبًا» ورقم الهاتف." : "تم التفعيل؛ يظهر رمز QR للنزلاء في الموقع.");
  const regen = () => run("regen", () => whatsappApi.save(row.branch_id, { regenerate_verify_token: true }), "أُنشئ رمز تحقق جديد — حدّثه في إعدادات Webhook لدى Meta.");
  async function test() {
    setBusy("check"); setError(null); setNotice(null);
    const r = await whatsappApi.check(row.branch_id);
    setCheck(r); setBusy(null); onSaved();
  }

  const st = STATUS[row.status];
  return (
    <Card className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <div className="flex h-10 w-10 items-center justify-center rounded-2xl bg-[#25D366]/10 text-[#128C7E]"><MessageCircle className="h-5 w-5" /></div>
          <div>
            <p className="font-semibold text-ink-800">{row.branch_name}</p>
            <p className="text-xs text-ink-400" dir="ltr">{row.display_phone ? `+${row.display_phone}` : "لا يوجد رقم بعد"}{row.verified_name ? ` · ${row.verified_name}` : ""}</p>
          </div>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Badge className={st.cls}>{st.label}</Badge>
          <Badge className={row.enabled ? "bg-success-500/10 text-success-600" : "bg-ink-100 text-ink-500"}>{row.enabled ? "مفعّل للنزلاء" : "غير مفعّل"}</Badge>
          <button type="button" onClick={() => setOpen((o) => !o)} className="rounded-lg p-1.5 text-ink-400 hover:bg-ink-50" aria-label="الإعدادات"><ChevronDown className={`h-4 w-4 transition ${open ? "rotate-180" : ""}`} /></button>
        </div>
      </div>

      {row.last_error && <p className="flex items-start gap-1.5 rounded-xl bg-danger-500/10 px-3 py-2 text-xs text-danger-600" dir="auto"><AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" /> {row.last_error}</p>}
      {error && <ErrorBanner message={error} />}
      {notice && <p className="rounded-xl bg-success-500/10 px-3 py-2 text-xs text-success-600">{notice}</p>}
      {check && (
        <p className={`rounded-xl px-3 py-2 text-xs ${check.ok ? "bg-success-500/10 text-success-600" : "bg-danger-500/10 text-danger-600"}`} dir="auto">
          {check.ok
            ? `متصل: ${check.verified_name ?? ""} ${check.display_phone_number ?? ""}${check.quality_rating ? ` · الجودة ${check.quality_rating}` : ""}${check.matches_number === false ? " — تنبيه: الرقم لدى Meta يختلف عن الرقم المكتوب هنا" : ""}`
            : `فشل الاختبار: ${check.error === "channel_incomplete" ? "أكمل البيانات أولًا" : check.error}`}
        </p>
      )}

      {open && (
        <div className="space-y-4">
          <div className="grid gap-3 sm:grid-cols-2">
            <label className="block min-w-0"><span className="label">رقم واتساب الفرع (يراه النزلاء)</span><input className="input" dir="ltr" placeholder="05xxxxxxxx" value={form.display_phone} onChange={set("display_phone")} /></label>
            <label className="block min-w-0"><span className="label">Phone Number ID</span><input className="input" dir="ltr" inputMode="numeric" placeholder="1234567890…" value={form.phone_number_id} onChange={set("phone_number_id")} /></label>
            <label className="block min-w-0"><span className="label">رمز الوصول الدائم (Access Token)</span><input className="input" dir="ltr" type="password" autoComplete="off" placeholder={row.has_token ? `محفوظ ••••${row.token_last4 ?? ""} — اتركه فارغًا للإبقاء عليه` : "EAAG…"} value={form.access_token} onChange={set("access_token")} /></label>
            <label className="block min-w-0"><span className="label">App Secret (للتحقق من رسائل Meta)</span><input className="input" dir="ltr" type="password" autoComplete="off" placeholder={row.has_app_secret ? "محفوظ — اتركه فارغًا للإبقاء عليه" : "من إعدادات التطبيق ← Basic"} value={form.app_secret} onChange={set("app_secret")} /></label>
            <label className="block min-w-0"><span className="label">WhatsApp Business Account ID (اختياري)</span><input className="input" dir="ltr" inputMode="numeric" value={form.waba_id} onChange={set("waba_id")} /></label>
            <label className="block min-w-0"><span className="label">قالب رمز «حجوزاتي» في الموقع (اختياري)</span><input className="input" dir="ltr" placeholder="booking_code" value={form.otp_template} onChange={set("otp_template")} /></label>
          </div>
          <div className="grid gap-2 sm:grid-cols-2">
            <CopyText label="Callback URL (في Meta ← WhatsApp ← Configuration ← Webhook)" value={WEBHOOK_URL} />
            {row.verify_token ? <CopyText label="Verify token (نفس الشاشة)" value={row.verify_token} /> : <p className="rounded-xl border border-dashed border-ink-200 px-3 py-2 text-xs text-ink-400">Verify token يظهر هنا بعد أول «حفظ» لهذا الفرع.</p>}
          </div>
          <div className="flex flex-wrap gap-2">
            <button type="button" className="btn-primary" onClick={save} disabled={!!busy}>{busy === "save" ? <Spinner /> : "حفظ"}</button>
            <button type="button" className="btn-outline" onClick={test} disabled={!!busy || row.status === "not_configured"}>{busy === "check" ? <Spinner /> : <><PlugZap className="h-4 w-4" /> اختبار الاتصال</>}</button>
            <button type="button" className={row.enabled ? "btn-outline" : "btn-accent"} onClick={toggle} disabled={!!busy || (!row.enabled && row.status === "not_configured")}>{busy === "toggle" ? <Spinner /> : <><Power className="h-4 w-4" /> {row.enabled ? "إيقاف" : "تفعيل للنزلاء"}</>}</button>
            <button type="button" className="btn-ghost text-xs" onClick={regen} disabled={!!busy}><RefreshCw className="h-3.5 w-3.5" /> رمز تحقق جديد</button>
          </div>
          {row.last_checked_at && <p className="text-[11px] text-ink-400">آخر فحص: {formatDateTime(row.last_checked_at)}</p>}
        </div>
      )}
    </Card>
  );
}

export default function AdminWhatsapp() {
  const [rows, setRows] = useState<WaChannelRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(() => { whatsappApi.channels().then(setRows).catch((e) => setError(toArabicError(e))); }, []);
  useEffect(load, [load]);

  if (!rows && !error) return <LoadingScreen />;
  return (
    <div className="space-y-4">
      <SectionTitle title="واتساب الفروع" subtitle="رقم واتساب لكل فرع: النزيل يمسح رمز QR في الموقع ويُنجز كل شيء في المحادثة" />
      {error && <ErrorBanner message={error} />}

      <details className="card p-4 text-sm text-ink-600">
        <summary className="cursor-pointer font-semibold text-ink-800">طريقة الربط (مرة واحدة لكل فرع)</summary>
        <ol className="mt-3 list-decimal space-y-1.5 pr-5">
          <li>في <span dir="ltr">developers.facebook.com</span>: أنشئ تطبيقًا من نوع Business وأضف له منتج WhatsApp، وأضف رقم الفرع وفعّله.</li>
          <li>انسخ <b>Phone Number ID</b> من WhatsApp ← API Setup.</li>
          <li>من Business Settings ← System users: أنشئ مستخدم نظام بصلاحية <span dir="ltr">whatsapp_business_messaging</span> واستخرج <b>رمز وصول دائم</b>.</li>
          <li>من App settings ← Basic انسخ <b>App Secret</b>.</li>
          <li>احفظها هنا، ثم في WhatsApp ← Configuration ← Webhook ضع Callback URL وVerify token المعروضين، واشترك في حقل <span dir="ltr">messages</span>.</li>
          <li>اضغط «اختبار الاتصال» ثم «تفعيل للنزلاء». يظهر رمز QR للفرع في الصفحة الرئيسية للموقع فورًا.</li>
          <li>اختياري لصفحة «حجوزاتي» في الموقع: قالب من فئة Authentication بالعربية، واكتب اسمه في حقل القالب.</li>
        </ol>
        <p className="mt-3 flex items-center gap-1.5 text-xs text-ink-400"><ShieldCheck className="h-3.5 w-3.5" /> الرمز وApp Secret يُحفظان مشفّرين ولا يظهران مرة أخرى لأي أحد، وكل تعديل مسجل في سجل الإجراءات.</p>
      </details>

      {(rows ?? []).map((r) => <BranchChannel key={r.branch_id + (r.updated_at ?? "") + r.status + r.enabled} row={r} onSaved={load} />)}
      {rows && rows.length === 0 && <Card><p className="text-sm text-ink-500">لا توجد فروع بعد. أضف فرعًا من <Link to="/admin/branches" className="text-brand-600">الفروع</Link>.</p></Card>}
      <p className="text-xs text-ink-400">لتجربة ردود المساعد قبل الربط: <Link to="/admin/assistant" className="text-brand-600">تجربة المساعد</Link>.</p>
    </div>
  );
}
