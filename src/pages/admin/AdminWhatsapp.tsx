import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { MessageCircle, Copy, Check, RefreshCw, PlugZap, Power, ChevronDown, ShieldCheck, AlertTriangle, Monitor, Cloud, Download, KeyRound, Bot, Smartphone, Wifi, WifiOff, QrCode } from "lucide-react";
import { whatsappApi, toArabicError, bridgeConfig, BRIDGE_DOWNLOAD_PATH, type WaChannelRow, type WaCheck, type WaMode } from "../../lib/api";
import { isDemo } from "../../lib/supabase";
import { SectionTitle, LoadingScreen, Card, Badge, Spinner, ErrorBanner } from "../../components/ui";
import { formatDateTime } from "../../lib/utils";

/**
 * WhatsApp per branch (owner): each branch has its own WhatsApp number, answered one of two ways —
 *   - from the reception computer (WhatsApp Web, no Meta account or fees): a small program there reads new guest
 *     messages and types the answers; set up here with a branch key (bridge-config.json, shown once)
 *   - through Meta's WhatsApp Cloud API: access token and app secret, stored encrypted and never shown again
 */
const STATUS: Record<WaChannelRow["status"], { label: string; cls: string }> = {
  not_configured: { label: "غير مكتمل", cls: "bg-ink-100 text-ink-500" },
  configured: { label: "مكتمل — بانتظار اختبار الاتصال", cls: "bg-warning-500/10 text-warning-600" },
  active: { label: "متصل", cls: "bg-success-500/10 text-success-600" },
  error: { label: "خطأ في الاتصال", cls: "bg-danger-500/10 text-danger-600" },
};
const SUPABASE_URL = String(import.meta.env.VITE_SUPABASE_URL ?? "").replace(/\/$/, "");
const WEBHOOK_URL = isDemo ? "https://<project>.supabase.co/functions/v1/whatsapp-webhook" : `${SUPABASE_URL}/functions/v1/whatsapp-webhook`;
const PROGRAM_URL = `${import.meta.env.BASE_URL}${BRIDGE_DOWNLOAD_PATH}`;
const PAUSES = [15, 30, 60, 120, 240];

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

function download(name: string, content: string) {
  try {
    const url = URL.createObjectURL(new Blob([content], { type: "application/json" }));
    const a = document.createElement("a");
    a.href = url; a.download = name; document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
  } catch { /* the key box below still shows the content */ }
}

/** what the program on the reception computer last said, in words */
function bridgeLine(live: WaChannelRow): { icon: JSX.Element; text: string; cls: string } {
  if (!live.has_bridge_key) return { icon: <KeyRound className="h-4 w-4" />, text: "لم يُنشأ مفتاح الربط بعد.", cls: "bg-ink-50 text-ink-500" };
  if (!live.bridge_online) {
    return live.bridge_last_seen
      ? { icon: <WifiOff className="h-4 w-4" />, text: `كمبيوتر الاستقبال غير متصل — آخر اتصال ${formatDateTime(live.bridge_last_seen)}. تأكد أنه يعمل وأن البرنامج مفتوح.`, cls: "bg-warning-500/10 text-warning-600" }
      : { icon: <WifiOff className="h-4 w-4" />, text: "لم يتصل البرنامج بعد. شغّله على كمبيوتر الاستقبال بملف الإعداد الذي نزّلته.", cls: "bg-ink-50 text-ink-500" };
  }
  if (live.bridge_status === "connected") return { icon: <Wifi className="h-4 w-4" />, text: `متصل — ${live.bridge_phone ? `واتساب مربوط بالرقم +${live.bridge_phone}` : "واتساب الفرع مربوط"}${live.bridge_name ? ` (${live.bridge_name})` : ""}.`, cls: "bg-success-500/10 text-success-600" };
  if (live.bridge_status === "qr") return { icon: <QrCode className="h-4 w-4" />, text: "البرنامج يعمل وينتظر مسح رمز QR من جوال الفرع: واتساب ← الأجهزة المرتبطة ← ربط جهاز.", cls: "bg-warning-500/10 text-warning-600" };
  if (live.bridge_status === "disconnected") return { icon: <AlertTriangle className="h-4 w-4" />, text: `واتساب غير مربوط${live.last_error ? ` (${live.last_error})` : ""}. امسح الرمز من جديد في نافذة البرنامج.`, cls: "bg-danger-500/10 text-danger-600" };
  return { icon: <Spinner className="h-4 w-4" />, text: "البرنامج يبدأ التشغيل…", cls: "bg-ink-50 text-ink-500" };
}

function BridgePanel({ row, live, busy, run, newKey, setNewKey }: { row: WaChannelRow; live: WaChannelRow; busy: string | null; run: (kind: string, fn: () => Promise<unknown>, ok: string) => Promise<void>; newKey: string | null; setNewKey: (v: string | null) => void }) {
  const [phone, setPhone] = useState(row.display_phone ?? "");
  const [confirmKey, setConfirmKey] = useState<"new" | "revoke" | null>(null);
  const [program, setProgram] = useState<"checking" | "available" | "missing">("checking");
  useEffect(() => {
    let alive = true;
    fetch(PROGRAM_URL, { method: "HEAD" }).then((r) => alive && setProgram(r.ok ? "available" : "missing")).catch(() => alive && setProgram("missing"));
    return () => { alive = false; };
  }, []);

  const line = bridgeLine(live);
  const mismatch = live.bridge_online && live.bridge_phone && row.display_phone && live.bridge_phone !== row.display_phone;

  const createKey = () => run("key", async () => {
    const r = await whatsappApi.save(row.branch_id, { regenerate_bridge_key: true });
    if (!r.bridge_key) throw new Error("تعذّر إنشاء المفتاح");
    const cfg = JSON.stringify(bridgeConfig(row.branch_name, row.display_phone, r.bridge_key, isDemo ? "https://demo.invalid" : SUPABASE_URL), null, 2);
    setNewKey(cfg); setConfirmKey(null);
    download("bridge-config.json", cfg);
  }, "أُنشئ مفتاح الربط ونُزّل ملف bridge-config.json — ضعه داخل مجلد البرنامج على كمبيوتر الاستقبال.");

  return (
    <div className="space-y-4">
      <p className={`flex items-start gap-2 rounded-xl px-3 py-2 text-sm ${line.cls}`} data-testid="bridge-status">{line.icon}<span>{line.text}</span></p>
      {mismatch && <p className="flex items-start gap-1.5 rounded-xl bg-warning-500/10 px-3 py-2 text-xs text-warning-600"><AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" /> الرقم المربوط في البرنامج (+{live.bridge_phone}) يختلف عن رقم الفرع المكتوب هنا (+{row.display_phone}).</p>}

      <div className="grid gap-3 sm:grid-cols-2">
        <label className="block min-w-0"><span className="label">رقم واتساب الفرع (يراه النزلاء في رمز QR)</span>
          <div className="flex gap-2"><input className="input" dir="ltr" placeholder="05xxxxxxxx" value={phone} onChange={(e) => setPhone(e.target.value)} />
            <button type="button" className="btn-outline shrink-0" disabled={!!busy || phone === (row.display_phone ?? "")} onClick={() => run("phone", () => whatsappApi.save(row.branch_id, { display_phone: phone }), "تم حفظ الرقم.")}>{busy === "phone" ? <Spinner /> : "حفظ"}</button></div>
        </label>
        <div className="min-w-0">
          <span className="label">مفتاح ربط كمبيوتر الاستقبال</span>
          {row.has_bridge_key && confirmKey === null && (
            <div className="flex flex-wrap items-center gap-2">
              <span className="rounded-lg bg-ink-50 px-2 py-1.5 font-mono text-xs text-ink-600" dir="ltr">••••{row.bridge_key_last4}</span>
              {row.bridge_key_created_at && <span className="text-[11px] text-ink-400">أُنشئ {formatDateTime(row.bridge_key_created_at)}</span>}
              <button type="button" className="btn-ghost text-xs" disabled={!!busy} onClick={() => setConfirmKey("new")}><RefreshCw className="h-3.5 w-3.5" /> مفتاح جديد</button>
              <button type="button" className="btn-ghost text-xs text-danger-600" disabled={!!busy} onClick={() => setConfirmKey("revoke")}>إلغاء الربط</button>
            </div>
          )}
          {!row.has_bridge_key && (
            <button type="button" className="btn-primary w-full justify-center" disabled={!!busy || !row.display_phone} onClick={createKey} title={row.display_phone ? "" : "احفظ رقم الفرع أولًا"}>
              {busy === "key" ? <Spinner /> : <><KeyRound className="h-4 w-4" /> إنشاء مفتاح الربط وتنزيل ملف الإعداد</>}
            </button>
          )}
          {confirmKey && (
            <div className="space-y-2 rounded-xl border border-warning-500/30 bg-warning-500/5 p-3 text-xs text-ink-600">
              <p>{confirmKey === "new" ? "المفتاح الجديد يوقف البرنامج الحالي حتى تضع ملف الإعداد الجديد في مجلده." : "إلغاء الربط يوقف الرد عبر كمبيوتر الاستقبال ويُخفي رمز QR حتى تنشئ مفتاحًا جديدًا."}</p>
              <div className="flex gap-2">
                <button type="button" className={confirmKey === "new" ? "btn-primary text-xs" : "btn-outline text-xs text-danger-600"} disabled={!!busy}
                  onClick={() => (confirmKey === "new" ? createKey() : run("revoke", async () => { await whatsappApi.save(row.branch_id, { revoke_bridge_key: true }); setConfirmKey(null); }, "أُلغي الربط."))}>
                  {busy ? <Spinner /> : confirmKey === "new" ? "نعم، أنشئ مفتاحًا جديدًا" : "نعم، ألغِ الربط"}
                </button>
                <button type="button" className="btn-ghost text-xs" onClick={() => setConfirmKey(null)}>تراجع</button>
              </div>
            </div>
          )}
        </div>
      </div>

      {newKey && (
        <div className="space-y-2 rounded-xl border border-brand-200 bg-brand-50/50 p-3" data-testid="bridge-config">
          <p className="text-xs font-semibold text-ink-700">ملف الإعداد (يظهر هذه المرة فقط — نُزّل باسم bridge-config.json؛ إن لم يُنزَّل انسخه واحفظه بهذا الاسم في مجلد البرنامج):</p>
          <pre className="max-h-40 overflow-auto rounded-lg bg-white p-2 text-[11px] text-ink-700" dir="ltr">{newKey}</pre>
          <div className="flex flex-wrap gap-2">
            <button type="button" className="btn-outline text-xs" onClick={() => download("bridge-config.json", newKey)}><Download className="h-3.5 w-3.5" /> تنزيل مرة أخرى</button>
            <button type="button" className="btn-ghost text-xs" onClick={async () => { try { await navigator.clipboard.writeText(newKey); } catch { /* select the text */ } }}><Copy className="h-3.5 w-3.5" /> نسخ</button>
            <button type="button" className="btn-ghost text-xs" onClick={() => setNewKey(null)}>تم الحفظ — إخفاء</button>
          </div>
        </div>
      )}

      <div className="grid gap-3 sm:grid-cols-2">
        <div className="rounded-xl border border-ink-100 p-3">
          <p className="flex items-center gap-1.5 text-sm font-semibold text-ink-700"><Bot className="h-4 w-4 text-brand-600" /> الرد الآلي</p>
          <p className="mt-1 text-xs text-ink-500">{row.auto_reply ? "يعمل: المساعد يرد على كل رسالة جديدة مثل موظف الاستقبال." : "متوقف (مراقبة فقط): الرسائل تصل إلى الوارد وتبقى غير مقروءة في واتساب للموظف."}</p>
          <button type="button" className={`mt-2 text-xs ${row.auto_reply ? "btn-outline" : "btn-accent"}`} disabled={!!busy}
            onClick={() => run("auto", () => whatsappApi.save(row.branch_id, { auto_reply: !row.auto_reply }), row.auto_reply ? "أُوقف الرد الآلي؛ الرسائل تُسجل للموظفين فقط." : "عاد الرد الآلي.")}>
            {busy === "auto" ? <Spinner /> : row.auto_reply ? "إيقاف الرد الآلي" : "تشغيل الرد الآلي"}
          </button>
        </div>
        <label className="block rounded-xl border border-ink-100 p-3">
          <span className="flex items-center gap-1.5 text-sm font-semibold text-ink-700"><Smartphone className="h-4 w-4 text-brand-600" /> عندما يرد موظف بنفسه</span>
          <span className="mt-1 block text-xs text-ink-500">إذا كتب الموظف للنزيل من جوال الفرع أو من الوارد، يصمت المساعد في تلك المحادثة لمدة:</span>
          <select className="input mt-2" value={row.human_pause_minutes} disabled={!!busy} aria-label="مدة توقف الرد الآلي"
            onChange={(e) => run("pause", () => whatsappApi.save(row.branch_id, { human_pause_minutes: Number(e.target.value) }), "تم الحفظ.")}>
            {[...new Set([...PAUSES, row.human_pause_minutes])].sort((a, b) => a - b).map((m) => <option key={m} value={m}>{m < 60 ? `${m} دقيقة` : m === 60 ? "ساعة" : `${m / 60} ساعات`}</option>)}
          </select>
        </label>
      </div>

      <details className="rounded-xl border border-ink-100 p-3 text-sm text-ink-600" open={!row.has_bridge_key || !live.bridge_last_seen}>
        <summary className="cursor-pointer font-semibold text-ink-800">التشغيل على كمبيوتر الاستقبال (مرة واحدة)</summary>
        <ol className="mt-3 list-decimal space-y-1.5 pr-5 text-xs leading-6">
          <li>
            نزّل البرنامج وفك الضغط في مجلد ثابت (مثل <span dir="ltr">C:\zaaer-whatsapp</span>):{" "}
            {program === "available" ? <a className="font-semibold text-brand-600 underline" href={PROGRAM_URL} download data-testid="bridge-download"><Download className="inline h-3.5 w-3.5" /> تنزيل البرنامج (ويندوز)</a>
              : program === "missing" ? <span className="text-ink-400" data-testid="bridge-download-missing">{isDemo ? "متاح للتنزيل في النسخة الفعلية من النظام." : "تُجهَّز الحزمة مع النشر القادم."}</span>
              : <Spinner className="inline h-3 w-3" />}
          </li>
          <li>أنشئ مفتاح الربط من الأعلى؛ يُنزَّل ملف <b dir="ltr">bridge-config.json</b> — ضعه داخل مجلد البرنامج (أو اتركه في «التنزيلات» وسيجده البرنامج).</li>
          <li>شغّل <b dir="ltr">start.bat</b> (إن ظهر تحذير ويندوز: «More info» ثم «Run anyway»). تفتح نافذة واتساب ويب.</li>
          <li>من جوال الفرع: واتساب ← الأجهزة المرتبطة ← ربط جهاز، وامسح الرمز في النافذة. تظهر الحالة هنا «متصل».</li>
          <li>في تطبيق واتساب للأعمال على جوال الفرع: أوقف «رسالة الترحيب» و«رسالة الغياب» حتى لا يتكرر الرد.</li>
          <li>اختياري: شغّل <b dir="ltr">install-startup.bat</b> ليبدأ البرنامج مع تشغيل الكمبيوتر. اترك الكمبيوتر يعمل؛ يمكن تصغير النافذة لا إغلاقها.</li>
        </ol>
        <p className="mt-3 flex items-start gap-1.5 rounded-lg bg-ink-50 px-3 py-2 text-[11px] text-ink-500"><ShieldCheck className="mt-0.5 h-3.5 w-3.5 shrink-0" /> هذا الربط غير رسمي من واتساب (مثل فتح واتساب ويب). لتقليل خطر تقييد الرقم يرد البرنامج فقط على من يراسل الفرع، بسرعة كتابة بشرية، ولا يرسل رسائل جماعية. الطريق الرسمي هو WhatsApp Cloud API.</p>
      </details>
      {isDemo && <p className="text-xs text-ink-500">في العرض التجريبي: <Link to="/whatsapp-demo" className="font-semibold text-brand-600">افتح محاكي واتساب</Link> — يقوم مقام برنامج كمبيوتر الاستقبال ويشغّل منطق الخادم نفسه.</p>}
    </div>
  );
}

function CloudPanel({ row, busy, run, onChecked }: { row: WaChannelRow; busy: string | null; run: (kind: string, fn: () => Promise<unknown>, ok: string) => Promise<void>; onChecked: (c: WaCheck) => void }) {
  const [form, setForm] = useState({ display_phone: row.display_phone ?? "", phone_number_id: row.phone_number_id ?? "", waba_id: row.waba_id ?? "", access_token: "", app_secret: "", otp_template: row.otp_template ?? "", template_lang: row.template_lang || "ar" });
  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) => setForm((f) => ({ ...f, [k]: e.target.value }));
  const save = () => run("save", async () => {
    const patch: Record<string, unknown> = { display_phone: form.display_phone, phone_number_id: form.phone_number_id, waba_id: form.waba_id, otp_template: form.otp_template, template_lang: form.template_lang };
    if (form.access_token.trim()) patch.access_token = form.access_token.trim();
    if (form.app_secret.trim()) patch.app_secret = form.app_secret.trim();
    await whatsappApi.save(row.branch_id, patch);
    setForm((f) => ({ ...f, access_token: "", app_secret: "" }));
  }, "تم الحفظ. اضغط «اختبار الاتصال» للتأكد من البيانات.");
  const regen = () => run("regen", () => whatsappApi.save(row.branch_id, { regenerate_verify_token: true }), "أُنشئ رمز تحقق جديد — حدّثه في إعدادات Webhook لدى Meta.");
  const test = () => run("check", async () => onChecked(await whatsappApi.check(row.branch_id)), "");

  return (
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
        <button type="button" className="btn-ghost text-xs" onClick={regen} disabled={!!busy}><RefreshCw className="h-3.5 w-3.5" /> رمز تحقق جديد</button>
      </div>
      <details className="rounded-xl border border-ink-100 p-3 text-sm text-ink-600">
        <summary className="cursor-pointer font-semibold text-ink-800">طريقة الربط مع Meta (مرة واحدة لكل فرع)</summary>
        <ol className="mt-3 list-decimal space-y-1.5 pr-5 text-xs leading-6">
          <li>في <span dir="ltr">developers.facebook.com</span>: أنشئ تطبيقًا من نوع Business وأضف له منتج WhatsApp، وأضف رقم الفرع وفعّله.</li>
          <li>انسخ <b>Phone Number ID</b> من WhatsApp ← API Setup.</li>
          <li>من Business Settings ← System users: أنشئ مستخدم نظام بصلاحية <span dir="ltr">whatsapp_business_messaging</span> واستخرج <b>رمز وصول دائم</b>.</li>
          <li>من App settings ← Basic انسخ <b>App Secret</b>.</li>
          <li>احفظها هنا، ثم في WhatsApp ← Configuration ← Webhook ضع Callback URL وVerify token المعروضين، واشترك في حقل <span dir="ltr">messages</span>.</li>
          <li>اضغط «اختبار الاتصال» ثم «تفعيل للنزلاء».</li>
        </ol>
        <p className="mt-3 flex items-center gap-1.5 text-[11px] text-ink-400"><ShieldCheck className="h-3.5 w-3.5" /> الرمز وApp Secret يُحفظان مشفّرين ولا يظهران مرة أخرى لأي أحد، وكل تعديل مسجل في سجل الإجراءات.</p>
      </details>
    </div>
  );
}

/** messages of the last action on a branch — kept by the page, so they survive the refresh after saving */
interface Flash { notice?: string; error?: string; check?: WaCheck; config?: string | null }

function BranchChannel({ row, live, onSaved, flash, setFlash }: { row: WaChannelRow; live: WaChannelRow; onSaved: () => void; flash: Flash; setFlash: (f: (x: Flash) => Flash) => void }) {
  const [view, setView] = useState<WaMode>(row.mode);
  const [busy, setBusy] = useState<string | null>(null);
  const [open, setOpen] = useState(row.status !== "active" || row.mode === "web_bridge");
  const { notice, error, check } = flash;
  const setCheck = (c: WaCheck) => setFlash((x) => ({ ...x, check: c }));

  async function run(kind: string, fn: () => Promise<unknown>, ok: string) {
    setBusy(kind); setFlash((x) => ({ config: x.config }));
    try { await fn(); if (ok) setFlash((x) => ({ ...x, notice: ok })); onSaved(); } catch (e) { setFlash((x) => ({ ...x, error: toArabicError(e) })); }
    setBusy(null);
  }
  const toggle = () => run("toggle", () => whatsappApi.save(row.branch_id, { enabled: !row.enabled }), row.enabled ? "تم إيقاف واتساب لهذا الفرع؛ يظهر للنزلاء «قريبًا» ورقم الهاتف." : "تم التفعيل؛ يظهر رمز QR للنزلاء في الموقع.");
  const st = STATUS[row.status];
  const modeLabel = row.mode === "web_bridge" ? "كمبيوتر الاستقبال" : "Cloud API";

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
          <Badge className="bg-brand-50 text-brand-700">{modeLabel}</Badge>
          {row.mode === "web_bridge"
            ? <Badge className={live.bridge_online && live.bridge_status === "connected" ? "bg-success-500/10 text-success-600" : row.status === "not_configured" ? "bg-ink-100 text-ink-500" : "bg-warning-500/10 text-warning-600"}>
                {row.status === "not_configured" ? "غير مكتمل" : live.bridge_online && live.bridge_status === "connected" ? "متصل" : live.bridge_online ? "بانتظار الربط" : "الكمبيوتر غير متصل"}
              </Badge>
            : <Badge className={st.cls}>{st.label}</Badge>}
          <Badge className={row.enabled ? "bg-success-500/10 text-success-600" : "bg-ink-100 text-ink-500"}>{row.enabled ? "مفعّل للنزلاء" : "غير مفعّل"}</Badge>
          <button type="button" onClick={() => setOpen((o) => !o)} className="rounded-lg p-1.5 text-ink-400 hover:bg-ink-50" aria-label="الإعدادات"><ChevronDown className={`h-4 w-4 transition ${open ? "rotate-180" : ""}`} /></button>
        </div>
      </div>

      {row.mode === "cloud_api" && row.last_error && <p className="flex items-start gap-1.5 rounded-xl bg-danger-500/10 px-3 py-2 text-xs text-danger-600" dir="auto"><AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" /> {row.last_error}</p>}
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
          <div className="grid grid-cols-2 gap-2 rounded-2xl bg-ink-50 p-1" role="tablist" aria-label="طريقة الربط">
            {([["web_bridge", "واتساب ويب — كمبيوتر الاستقبال", "كمبيوتر الاستقبال", Monitor], ["cloud_api", "WhatsApp Cloud API — Meta", "Cloud API — Meta", Cloud]] as const).map(([m, label, short, Icon]) => (
              <button key={m} type="button" role="tab" aria-selected={view === m} aria-label={label} onClick={() => setView(m)}
                className={`flex min-w-0 items-center justify-center gap-1.5 rounded-xl px-2 py-2 text-xs font-semibold transition ${view === m ? "bg-white text-brand-700 shadow-sm" : "text-ink-500 hover:text-ink-700"}`}>
                <Icon className="h-4 w-4 shrink-0" /><span className="truncate sm:hidden">{short}</span><span className="hidden truncate sm:inline">{label}</span>
              </button>
            ))}
          </div>
          {view !== row.mode && (
            <div className="flex flex-wrap items-center justify-between gap-2 rounded-xl border border-brand-200 bg-brand-50/50 px-3 py-2 text-xs text-ink-600">
              <span>{view === "web_bridge" ? "هذا الفرع يرد الآن عبر Cloud API." : "هذا الفرع يرد الآن عبر كمبيوتر الاستقبال."} اعتماد الطريقة الأخرى يوقف الحالية فورًا.</span>
              <button type="button" className="btn-primary text-xs" disabled={!!busy} onClick={() => run("mode", () => whatsappApi.save(row.branch_id, { mode: view }), "اعتُمدت طريقة الربط لهذا الفرع.")}>{busy === "mode" ? <Spinner /> : "اعتماد هذه الطريقة"}</button>
            </div>
          )}
          {view === "web_bridge"
            ? <BridgePanel row={row} live={live} busy={busy} run={run} newKey={flash.config ?? null} setNewKey={(v) => setFlash((x) => ({ ...x, config: v }))} />
            : <CloudPanel row={row} busy={busy} run={run} onChecked={setCheck} />}
          <div className="flex flex-wrap items-center gap-2 border-t border-ink-50 pt-3">
            <button type="button" className={row.enabled ? "btn-outline" : "btn-accent"} onClick={toggle} disabled={!!busy || (!row.enabled && row.status === "not_configured")}>{busy === "toggle" ? <Spinner /> : <><Power className="h-4 w-4" /> {row.enabled ? "إيقاف" : "تفعيل للنزلاء"}</>}</button>
            <span className="text-[11px] text-ink-400">{row.enabled ? "رمز QR لهذا الفرع ظاهر في الموقع." : "عند التفعيل يظهر رمز QR لهذا الفرع في الموقع."}</span>
            {row.mode === "cloud_api" && row.last_checked_at && <span className="text-[11px] text-ink-400">· آخر فحص: {formatDateTime(row.last_checked_at)}</span>}
          </div>
        </div>
      )}
    </Card>
  );
}

export default function AdminWhatsapp() {
  const [rows, setRows] = useState<WaChannelRow[] | null>(null);
  const [live, setLive] = useState<WaChannelRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [flash, setFlash] = useState<Record<string, Flash>>({});
  const load = useCallback(() => { whatsappApi.channels().then((r) => { setRows(r); setLive(r); }).catch((e) => setError(toArabicError(e))); }, []);
  useEffect(load, [load]);
  // the reception computer's state changes on its own: refreshed quietly (forms keep what is being typed)
  const anyBridge = !!rows?.some((r) => r.mode === "web_bridge" && r.has_bridge_key);
  useEffect(() => {
    if (!anyBridge) return;
    const t = setInterval(() => { whatsappApi.channels().then(setLive).catch(() => {}); }, 15000);
    return () => clearInterval(t);
  }, [anyBridge]);

  if (!rows && !error) return <LoadingScreen />;
  return (
    <div className="space-y-4">
      <SectionTitle title="واتساب الفروع" subtitle="رقم واتساب لكل فرع: النزيل يمسح رمز QR في الموقع ويُنجز كل شيء في المحادثة" />
      {error && <ErrorBanner message={error} />}
      {(rows ?? []).map((r) => (
        <BranchChannel key={r.branch_id + (r.updated_at ?? "") + r.status + r.enabled + r.mode} row={r} live={live?.find((x) => x.branch_id === r.branch_id) ?? r} onSaved={load}
          flash={flash[r.branch_id] ?? {}} setFlash={(f) => setFlash((all) => ({ ...all, [r.branch_id]: f(all[r.branch_id] ?? {}) }))} />
      ))}
      {rows && rows.length === 0 && <Card><p className="text-sm text-ink-500">لا توجد فروع بعد. أضف فرعًا من <Link to="/admin/branches" className="text-brand-600">الفروع</Link>.</p></Card>}
      <p className="text-xs text-ink-400">لتجربة ردود المساعد قبل الربط: <Link to="/admin/assistant" className="text-brand-600">تجربة المساعد</Link>{isDemo && <> · <Link to="/whatsapp-demo" className="text-brand-600">محاكي واتساب</Link></>}.</p>
    </div>
  );
}
