import { useCallback, useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";
import { aiHealth, staffApi, toArabicError } from "../../lib/api";
import { useAuth } from "../../lib/auth";
import { SectionTitle, LoadingScreen, Card, Badge, Spinner, ErrorBanner } from "../../components/ui";
import { Bot, Check, KeyRound, ShieldCheck, Activity, Gauge } from "lucide-react";
import { BarChart, Bar, XAxis, YAxis, ResponsiveContainer, Tooltip, Legend } from "recharts";
import { formatDateTime } from "../../lib/utils";
import { isFreeTierError, providerErrorHint } from "../../lib/providerErrors";

interface AiSettings {
  enabled: boolean;
  provider: "gemini" | "none";
  model: string;
  fallback_models: string[];
  temperature: number;
  max_output_tokens: number;
  timeout_ms: number;
  daily_request_limit: number;
  daily_token_budget: number;
  per_session_message_limit: number;
  strict_scope: boolean;
  ops_enabled: boolean;
  ops_daily_request_limit: number;
  briefing_with_insights: boolean;
  guard_repeat_limit: number;
  guard_burst_messages: number;
  guard_burst_minutes: number;
  guard_conversation_tokens: number;
  extra_instructions: string | null;
  updated_at?: string | null;
}

const DEFAULTS: AiSettings = {
  enabled: false, provider: "gemini", model: "gemini-3.8-flash", fallback_models: ["gemini-3.6-flash", "gemini-3.5-flash-lite"], temperature: 0.2, max_output_tokens: 400, timeout_ms: 12000,
  daily_request_limit: 2000, daily_token_budget: 500000, per_session_message_limit: 40, strict_scope: true, extra_instructions: "", ops_enabled: true, ops_daily_request_limit: 500, briefing_with_insights: true,
  guard_repeat_limit: 3, guard_burst_messages: 15, guard_burst_minutes: 10, guard_conversation_tokens: 40000,
};

interface UsageRow { day: string; requests: number; tokens_in: number; tokens_out: number; fallbacks: number; guardrail_blocks: number }
interface GuardEvent { id: string; stage: string; rule: string; created_at: string }
interface ToolExec { id: string; tool_name: string; result_status: string; latency_ms: number | null; created_at: string }
type Health = Awaited<ReturnType<typeof aiHealth>>;

const TOOLS = [
  "get_public_room_types", "get_public_availability", "get_booking_sources",
  "request_booking_verification", "get_verified_booking_summary",
  "create_registration_session", "get_registration_progress",
  "create_payment_request", "get_payment_status",
  "submit_checkin_request", "get_public_property_policies", "search_knowledge_base",
  "open_supervisor_ticket", "request_human_assistance",
];

// current GA models (Gemini 2.x is not available to new API keys); any other model id can still be typed
const MODEL_HINTS = ["gemini-3.8-flash", "gemini-3.6-flash", "gemini-3.5-flash-lite"];
const MODEL_ID = /^[a-z0-9][a-z0-9.-]{0,62}$/;

/** "gemini-3.6-flash، gemini-3.5-flash-lite" → ids in order, lower-case, without blanks or repeats (same rules as the server) */
function parseModelList(text: string): string[] {
  return [...new Set(text.split(/[\s,،]+/).map((m) => m.trim().toLowerCase()).filter(Boolean))];
}

export default function AdminAiSettings() {
  const { can } = useAuth();
  const isOwner = can("security");
  const [form, setForm] = useState<AiSettings>(DEFAULTS);
  const [usage, setUsage] = useState<UsageRow[]>([]);
  const [guards, setGuards] = useState<GuardEvent[]>([]);
  const [tools, setTools] = useState<ToolExec[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [health, setHealth] = useState<Health | null>(null);
  const [testing, setTesting] = useState(false);
  const [fallbackText, setFallbackText] = useState(DEFAULTS.fallback_models.join(", "));

  const load = useCallback(async () => {
    setError(null);
    try {
      const since = new Date(); since.setDate(since.getDate() - 13);
      const sinceIso = since.toISOString().slice(0, 10);
      const [s, u, g, t] = await Promise.all([
        supabase.from("ai_settings").select("*").maybeSingle(),
        supabase.from("ai_usage_daily").select("day, requests, tokens_in, tokens_out, fallbacks, guardrail_blocks").gte("day", sinceIso).order("day"),
        supabase.from("ai_guardrail_events").select("id, stage, rule, created_at").order("created_at", { ascending: false }).limit(30),
        supabase.from("ai_tool_executions").select("id, tool_name, result_status, latency_ms, created_at").order("created_at", { ascending: false }).limit(30),
      ]);
      if (s.error) throw s.error;
      if (s.data) {
        const d = s.data as Partial<AiSettings>;
        const fallbacks = Array.isArray(d.fallback_models) ? d.fallback_models : DEFAULTS.fallback_models;
        setForm({ ...DEFAULTS, ...d, fallback_models: fallbacks, temperature: Number(d.temperature ?? DEFAULTS.temperature), extra_instructions: d.extra_instructions ?? "" });
        setFallbackText(fallbacks.join(", "));
      }
      setUsage((u.data as UsageRow[]) ?? []);
      setGuards((g.data as GuardEvent[]) ?? []);
      setTools((t.data as ToolExec[]) ?? []);
    } catch (e) {
      setError(toArabicError(e));
    }
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const [dirty, setDirty] = useState(false);
  function set<K extends keyof AiSettings>(k: K, v: AiSettings[K]) { setForm((f) => ({ ...f, [k]: v })); setSaved(false); setDirty(true); }
  // OWNER-19: leaving with unsaved changes asks first (closing or reloading the tab)
  useEffect(() => {
    if (!dirty) return;
    const warn = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = ""; };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [dirty]);

  const fallbackList = parseModelList(fallbackText);
  const fallbackError = fallbackList.length > 3 ? "ثلاثة نماذج احتياطية كحد أقصى." : fallbackList.some((m) => !MODEL_ID.test(m)) ? "اكتب معرّفات نماذج فقط (حروف لاتينية صغيرة وأرقام و . -) مفصولة بفواصل." : null;

  async function save() {
    if (!isOwner) return;
    if (fallbackError) { setError(fallbackError); return; }
    // OWNER-19: every number within the range its field states, before anything is sent
    const bad = (Object.entries(NUMBER_RANGES) as Array<[keyof AiSettings, [number, number, string]]>).find(([k, [lo, hi]]) => { const v = Number(form[k]); return !Number.isFinite(v) || v < lo || v > hi; });
    if (bad) { setError(`«${bad[1][2]}» خارج النطاق المسموح (${bad[1][0].toLocaleString("en-US")}–${bad[1][1].toLocaleString("en-US")}).`); return; }
    setSaving(true); setError(null); setSaved(false);
    try {
      const patch: Record<string, unknown> = {
        enabled: form.enabled, provider: form.provider, model: form.model.trim(), fallback_models: fallbackList, temperature: form.temperature,
        max_output_tokens: form.max_output_tokens, timeout_ms: form.timeout_ms, daily_request_limit: form.daily_request_limit,
        daily_token_budget: form.daily_token_budget, per_session_message_limit: form.per_session_message_limit,
        strict_scope: form.strict_scope, extra_instructions: (form.extra_instructions ?? "").slice(0, 1500),
        ops_enabled: form.ops_enabled, ops_daily_request_limit: form.ops_daily_request_limit, briefing_with_insights: form.briefing_with_insights,
        guard_repeat_limit: form.guard_repeat_limit, guard_burst_messages: form.guard_burst_messages, guard_burst_minutes: form.guard_burst_minutes,
        guard_conversation_tokens: form.guard_conversation_tokens,
      };
      await staffApi.updateAiSettings(patch);
      setSaved(true); setDirty(false);
      await load();
    } catch (e) { setError(toArabicError(e)); }
    setSaving(false);
  }

  async function test() {
    setTesting(true);
    try { setHealth(await aiHealth()); } catch (e) { setHealth({ configured: false, ok: false, error: String((e as Error).message ?? e) }); }
    setTesting(false);
  }

  if (loading) return <LoadingScreen />;

  const usageChart = usage.map((u) => ({ day: u.day.slice(5), requests: u.requests, tokens: Number(u.tokens_in) + Number(u.tokens_out), fallbacks: u.fallbacks, blocks: u.guardrail_blocks }));
  const extraLen = (form.extra_instructions ?? "").length;

  return (
    <div>
      <SectionTitle title="إعدادات الذكاء الاصطناعي" subtitle="محرك مساعد الاستقبال (Gemini عبر Edge Function). عند التعطيل أو الفشل يعمل المسار الحواري التقليدي تلقائيًا." />
      {error && <div className="mb-4"><ErrorBanner message={error} /></div>}
      {!isOwner && <div className="mb-4 rounded-xl bg-ink-50 p-3 text-xs text-ink-500">العرض فقط — يحفظ الإعدادات من يملك صلاحية «السجل الأمني ومسح البيانات وإعدادات المساعد».</div>}

      <div className="grid gap-4 lg:grid-cols-3 [&>*]:min-w-0">
        {/* Settings form */}
        <Card className="lg:col-span-2">
          <h3 className="mb-4 flex items-center gap-2 text-sm font-semibold text-ink-700"><Bot className="h-4 w-4 text-brand-600" /> إعدادات المحرك</h3>
          <div className="grid gap-4 sm:grid-cols-2">
            <Toggle label="تفعيل المساعد الذكي" checked={form.enabled} onChange={(v) => set("enabled", v)} disabled={!isOwner} hint="عند الإيقاف يُستخدم المسار الحواري التقليدي فقط." />
            <Toggle label="النطاق الصارم" checked={form.strict_scope} onChange={(v) => set("strict_scope", v)} disabled={!isOwner} hint="يُبقي المساعد داخل نطاق الاستقبال فقط (حجوزات، تسجيل، دفع، دخول، سياسات) ويرفض أي موضوع خارجه." />
            <Toggle label="مساعد العمليات للموظفين" checked={form.ops_enabled} onChange={(v) => set("ops_enabled", v)} disabled={!isOwner} hint="يقرأ بيانات الفرع بصلاحية الموظف نفسه ويقترح إجراءات تتطلب تأكيدًا بشريًا. عند الإيقاف تبقى الإحاطة والإجابات المباشرة من بيانات النظام." />
            <Toggle label="توصيات ذكية في إحاطة اليوم" checked={form.briefing_with_insights} onChange={(v) => set("briefing_with_insights", v)} disabled={!isOwner} hint="3 توصيات مرتبة بالأولوية تُولَّد من السياق التشغيلي؛ للمراجعة البشرية فقط." />
            <div>
              <label className="label">المزود</label>
              <select className="input" value={form.provider} onChange={(e) => set("provider", e.target.value as AiSettings["provider"])} disabled={!isOwner}>
                <option value="gemini">gemini</option>
                <option value="none">none (مسار تقليدي فقط)</option>
              </select>
            </div>
            <div>
              <label className="label">النموذج</label>
              <input className="input" dir="ltr" list="ai-models" value={form.model} onChange={(e) => set("model", e.target.value)} disabled={!isOwner} />
              <datalist id="ai-models">{MODEL_HINTS.map((m) => <option key={m} value={m} />)}</datalist>
              <p className="mt-1 text-xs text-ink-400" dir="ltr">{MODEL_HINTS.join(" · ")}</p>
            </div>
            <div className="sm:col-span-2">
              <label className="label" htmlFor="ai-fallbacks">النماذج الاحتياطية (حتى 3، بالترتيب)</label>
              <input id="ai-fallbacks" className="input" dir="ltr" value={fallbackText} onChange={(e) => { setFallbackText(e.target.value); setSaved(false); }} disabled={!isOwner} placeholder="gemini-3.6-flash, gemini-3.5-flash-lite" />
              {fallbackError
                ? <p className="mt-1 text-xs text-danger-600">{fallbackError}</p>
                : <p className="mt-1 text-xs text-ink-400">إن تعذّر النموذج الأساسي (ضغط على المزود، تجاوز حصته، أو إيقافه) يُجرَّب التالي ضمن نفس المهلة، ويُسجَّل حدث provider_fallback. اتركه فارغًا لإيقاف ذلك.</p>}
            </div>
            <NumberField label={`تنوّع الردود (${form.temperature.toFixed(2)}) — 0 ثابت، 1 متنوّع`} value={form.temperature} min={0} max={1} step={0.05} onChange={(v) => set("temperature", v)} disabled={!isOwner} range />
            <NumberField label="أقصى طول للرد بالوحدات النصية (50–2000)" value={form.max_output_tokens} min={50} max={2000} step={10} onChange={(v) => set("max_output_tokens", v)} disabled={!isOwner} />
            <NumberField label="مهلة الرد بالمللي ثانية (2000–60000)" value={form.timeout_ms} min={2000} max={60000} step={500} onChange={(v) => set("timeout_ms", v)} disabled={!isOwner} />
            <NumberField label="حد الطلبات اليومي" value={form.daily_request_limit} min={0} step={50} onChange={(v) => set("daily_request_limit", v)} disabled={!isOwner} />
            <NumberField label="حد طلبات مساعد العمليات اليومي" value={form.ops_daily_request_limit} min={0} step={50} onChange={(v) => set("ops_daily_request_limit", v)} disabled={!isOwner} />
            <NumberField label="الحد اليومي للوحدات النصية" value={form.daily_token_budget} min={0} step={1000} onChange={(v) => set("daily_token_budget", v)} disabled={!isOwner} />
            <NumberField label="حد الرسائل لكل جلسة" value={form.per_session_message_limit} min={1} max={500} step={1} onChange={(v) => set("per_session_message_limit", v)} disabled={!isOwner} />
            {/* 0052 (SEC-02): the conversation's rhythm — past any of these the AI stops on that conversation and the supervisor gets it */}
            <div className="sm:col-span-2 rounded-xl border border-ink-100 bg-ink-50/50 p-3" data-testid="ai-guard">
              <p className="text-sm font-semibold text-ink-800">إيقاف المساعد عند نمط غير طبيعي</p>
              <p className="mb-3 mt-0.5 text-xs text-ink-500">إذا تجاوزت المحادثة أيًّا من هذه الحدود يتوقف الذكاء الاصطناعي عليها، وتُحوَّل إلى المشرف بطلب تحويل واحدة، ويُسجَّل السبب.</p>
              <div className="grid gap-3 sm:grid-cols-2">
                <NumberField label="الرسالة نفسها متتالية (2–20 مرة)" value={form.guard_repeat_limit} min={2} max={20} step={1} onChange={(v) => set("guard_repeat_limit", v)} disabled={!isOwner} />
                <NumberField label="أكثر من هذا العدد من الرسائل (3–200)" value={form.guard_burst_messages} min={3} max={200} step={1} onChange={(v) => set("guard_burst_messages", v)} disabled={!isOwner} />
                <NumberField label="خلال هذه الدقائق (1–120)" value={form.guard_burst_minutes} min={1} max={120} step={1} onChange={(v) => set("guard_burst_minutes", v)} disabled={!isOwner} />
                <NumberField label="الوحدات النصية للمحادثة الواحدة (1000–1000000)" value={form.guard_conversation_tokens} min={1000} max={1000000} step={1000} onChange={(v) => set("guard_conversation_tokens", v)} disabled={!isOwner} />
              </div>
            </div>
            <div className="sm:col-span-2">
              <label className="label">تعليمات إضافية (اختياري)</label>
              <textarea className="input min-h-[96px]" maxLength={1500} value={form.extra_instructions ?? ""} onChange={(e) => set("extra_instructions", e.target.value)} disabled={!isOwner} placeholder="مثال: استخدم لهجة رسمية مختصرة، واذكر اسم المنشأة في التحية." />
              <p className="mt-1 text-xs text-ink-400">{extraLen}/1500 — هذه التعليمات تُضاف لأسلوب الرد فقط ولا يمكنها تجاوز القواعد الصلبة (النطاق، حماية البيانات، الأدوات المصرح بها).</p>
            </div>
          </div>
          <div className="mt-4 flex items-center gap-3">
            <button onClick={save} disabled={!isOwner || saving} className="btn-primary text-sm">{saving ? <Spinner className="h-4 w-4" /> : "حفظ الإعدادات"}</button>
            {saved && <Badge className="bg-success-500/10 text-success-600"><Check className="h-3 w-3" /> تم الحفظ</Badge>}
            {dirty && !saved && <Badge className="bg-warning-500/10 text-warning-700" testId="ai-unsaved">تغييرات غير محفوظة</Badge>}
            {form.updated_at && <span className="text-xs text-ink-400">آخر تحديث: {formatDateTime(form.updated_at)}</span>}
          </div>
        </Card>

        {/* API key card */}
        <Card className="border-brand-100 bg-brand-50/40">
          <h3 className="mb-3 flex items-center gap-2 text-sm font-semibold text-ink-700"><KeyRound className="h-4 w-4 text-brand-600" /> مفتاح Gemini API</h3>
          <p className="text-sm text-ink-600 leading-relaxed">المفتاح <strong>لا يُخزَّن أبدًا</strong> في قاعدة البيانات ولا في المتصفح. يُضبط كسرّ في Edge Functions على الخادم فقط:</p>
          <pre className="mt-3 overflow-x-auto rounded-lg bg-ink-800 p-3 text-xs text-white" dir="ltr">{`supabase secrets set GEMINI_API_KEY=AIza...
supabase secrets set APP_BASE_URL=https://your-domain`}</pre>
          <button onClick={test} disabled={testing} className="btn-outline mt-4 w-full text-sm">{testing ? <Spinner className="h-4 w-4" /> : "اختبار الاتصال"}</button>
          {health && (
            <div className="mt-3 space-y-1 text-xs">
              <Row k="المفتاح مضبوط" v={health.configured ? "نعم" : "لا"} ok={health.configured} />
              <Row k="الاتصال" v={health.ok ? "ناجح" : "فشل"} ok={health.ok} />
              {health.model && <Row k="النموذج المستخدم الآن" v={health.model} />}
              {health.ok && health.primary && health.model !== health.primary && (
                <p className="text-warning-700">النموذج الأساسي {health.primary} لا يجيب حاليًا؛ المساعد يعمل عبر النموذج الاحتياطي.</p>
              )}
              {typeof health.latency_ms === "number" && <Row k="زمن الاستجابة" v={`${health.latency_ms} ms`} />}
              {health.checked && health.checked.length > 1 && health.checked.map((c) => (
                <div key={c.model}>
                  <Row k={c.model} v={c.ok ? `يعمل · ${c.latency_ms ?? "—"} ms` : "لا يجيب"} ok={c.ok} />
                  {!c.ok && providerErrorHint(c.error) && <p className="px-3 pt-0.5 text-danger-600">{providerErrorHint(c.error)}</p>}
                </div>
              ))}
              {health.error && (
                <div className="text-danger-600">
                  {providerErrorHint(health.error) && <p>{health.primary ?? "النموذج الأساسي"}: {providerErrorHint(health.error)}</p>}
                  <p className="break-words text-ink-400" dir="ltr">{health.error}</p>
                </div>
              )}
              {[health.error, ...(health.checked ?? []).map((c) => c.error)].some(isFreeTierError) && (
                <p className="rounded-lg bg-warning-500/10 px-3 py-2 text-warning-700">مفتاح Gemini الحالي على <strong>الخطة المجانية</strong> لدى Google: حدودها منخفضة لكل نموذج (عدد الطلبات في الدقيقة وفي اليوم)، والنماذج الاحتياطية تخفّف أثرها. للتشغيل الفعلي فعّل الفوترة لمشروع المفتاح في Google AI Studio.</p>
              )}
            </div>
          )}
        </Card>
      </div>

      {/* Usage */}
      <Card className="mt-4">
        <h3 className="mb-4 flex items-center gap-2 text-sm font-semibold text-ink-700"><Gauge className="h-4 w-4 text-brand-600" /> الاستهلاك — آخر 14 يومًا</h3>
        <p className="-mt-2 mb-3 text-xs text-ink-500">«طلبات» كل ما وصل إلى المساعد، و«تقليدي» ما أُجيب بالمسار الثابت دون الذكاء الاصطناعي (وهو كل الطلبات حين يكون المساعد متوقفًا).</p>
        {usage.length === 0 ? <p className="text-sm text-ink-400">لا يوجد استهلاك مسجّل بعد.</p> : (
          <div className="grid gap-4 lg:grid-cols-2 [&>*]:min-w-0">
            <ResponsiveContainer width="100%" height={220}>
              <BarChart data={usageChart}>
                <XAxis dataKey="day" tick={{ fontSize: 11, fill: "#6f83a3" }} />
                <YAxis tick={{ fontSize: 11, fill: "#6f83a3" }} allowDecimals={false} />
                <Tooltip contentStyle={{ borderRadius: 12, border: "1px solid #e9edf3", fontSize: 12 }} />
                <Legend wrapperStyle={{ fontSize: 11 }} />
                <Bar dataKey="requests" fill="#1f5f74" radius={[6, 6, 0, 0]} name="طلبات" />
                <Bar dataKey="fallbacks" fill="#d98a1b" radius={[6, 6, 0, 0]} name="مسار تقليدي" />
                <Bar dataKey="blocks" fill="#c0392b" radius={[6, 6, 0, 0]} name="حجب" />
              </BarChart>
            </ResponsiveContainer>
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead><tr className="border-b border-ink-100 text-ink-400"><th className="py-1.5 text-right font-medium">اليوم</th><th className="py-1.5 text-center font-medium">طلبات</th><th className="py-1.5 text-center font-medium">وحدات نصية</th><th className="py-1.5 text-center font-medium">تقليدي</th><th className="py-1.5 text-center font-medium">حجب</th></tr></thead>
                <tbody>{usage.map((u) => (
                  <tr key={u.day} className="border-b border-ink-50"><td className="py-1.5 text-ink-700" dir="ltr">{u.day}</td><td className="py-1.5 text-center">{u.requests}</td><td className="py-1.5 text-center">{(Number(u.tokens_in) + Number(u.tokens_out)).toLocaleString("en")}</td><td className="py-1.5 text-center">{u.fallbacks}</td><td className="py-1.5 text-center">{u.guardrail_blocks}</td></tr>
                ))}</tbody>
              </table>
            </div>
          </div>
        )}
      </Card>

      {/* Guardrails */}
      <Card className="mt-4">
        <h3 className="mb-3 flex items-center gap-2 text-sm font-semibold text-ink-700"><ShieldCheck className="h-4 w-4 text-brand-600" /> طبقات الحماية المفروضة على الخادم</h3>
        <ul className="grid gap-2 text-sm text-ink-600 sm:grid-cols-2">
          <li className="rounded-lg bg-ink-50 px-3 py-2"><strong>بوابة الإدخال:</strong> كشف محاولات الحقن (prompt injection)، رفض المواضيع خارج النطاق، وحجب/إخفاء البيانات الشخصية (PII) قبل وصولها للنموذج.</li>
          <li className="rounded-lg bg-ink-50 px-3 py-2"><strong>قائمة الأدوات المسموحة:</strong> {TOOLS.length} أداة فقط، لا وصول مباشر لقاعدة البيانات ولا تعديل للهوية أو الدفع أو رموز الصناديق.</li>
          <li className="rounded-lg bg-ink-50 px-3 py-2"><strong>بوابة الإخراج:</strong> منع تسريب الرموز، أرقام الوثائق، أرقام الجوال، الروابط غير المصرح بها، إعادة طباعة التعليمات (prompt echo)، وفرض اللغة.</li>
          <li className="rounded-lg bg-ink-50 px-3 py-2"><strong>الميزانيات:</strong> حد الطلبات اليومي، الحد اليومي للوحدات النصية، وحد الرسائل لكل جلسة.</li>
          <li className="rounded-lg bg-ink-50 px-3 py-2"><strong>النماذج الاحتياطية:</strong> إن تعذّر النموذج الأساسي يُجرَّب التالي في القائمة ضمن نفس المهلة، ويُؤجَّل النموذج المتعثر لدقائق حتى لا ينتظره كل نزيل.</li>
          <li className="rounded-lg bg-ink-50 px-3 py-2"><strong>المسار الاحتياطي:</strong> عند أي فشل أو تجاوز للحدود يرد النظام بمسار حواري مكتوب مسبقًا (scripted fallback) ويُسجَّل الحدث.</li>
        </ul>
        <div className="mt-4 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          {TOOLS.map((t) => (
            <div key={t} className="flex items-center gap-2 rounded-lg bg-ink-50 px-3 py-1.5 text-xs">
              <Check className="h-3.5 w-3.5 text-success-600" />
              <code className="text-ink-600" dir="ltr">{t}</code>
            </div>
          ))}
        </div>

        <div className="mt-6 grid gap-4 lg:grid-cols-2">
          <div>
            <h4 className="mb-2 flex items-center gap-2 text-xs font-semibold text-ink-600"><ShieldCheck className="h-3.5 w-3.5" /> آخر 30 حدثًا أمنيًا</h4>
            {guards.length === 0 ? <p className="text-xs text-ink-400">لا توجد أحداث.</p> : (
              <div className="max-h-72 overflow-y-auto">
                <table className="w-full text-xs">
                  <thead><tr className="border-b border-ink-100 text-ink-400"><th className="py-1.5 text-right font-medium">المرحلة</th><th className="py-1.5 text-right font-medium">القاعدة</th><th className="py-1.5 text-right font-medium">الوقت</th></tr></thead>
                  <tbody>{guards.map((g) => (
                    <tr key={g.id} className="border-b border-ink-50"><td className="py-1.5"><Badge className="bg-warning-500/10 text-warning-700">{g.stage}</Badge></td><td className="py-1.5 text-ink-600" dir="ltr">{g.rule}</td><td className="py-1.5 text-ink-400">{formatDateTime(g.created_at)}</td></tr>
                  ))}</tbody>
                </table>
              </div>
            )}
          </div>
          <div>
            <h4 className="mb-2 flex items-center gap-2 text-xs font-semibold text-ink-600"><Activity className="h-3.5 w-3.5" /> آخر 30 تنفيذ أداة</h4>
            {tools.length === 0 ? <p className="text-xs text-ink-400">لا توجد تنفيذات.</p> : (
              <div className="max-h-72 overflow-y-auto">
                <table className="w-full text-xs">
                  <thead><tr className="border-b border-ink-100 text-ink-400"><th className="py-1.5 text-right font-medium">الأداة</th><th className="py-1.5 text-right font-medium">النتيجة</th><th className="py-1.5 text-center font-medium">ms</th></tr></thead>
                  <tbody>{tools.map((t) => (
                    <tr key={t.id} className="border-b border-ink-50"><td className="py-1.5 text-ink-600" dir="ltr">{t.tool_name}</td><td className="py-1.5"><Badge className={t.result_status === "ok" ? "bg-success-500/10 text-success-600" : "bg-danger-500/10 text-danger-600"}>{t.result_status}</Badge></td><td className="py-1.5 text-center text-ink-500">{t.latency_ms ?? "—"}</td></tr>
                  ))}</tbody>
                </table>
              </div>
            )}
          </div>
        </div>
      </Card>
    </div>
  );
}

function Toggle({ label, checked, onChange, disabled, hint }: { label: string; checked: boolean; onChange: (v: boolean) => void; disabled?: boolean; hint?: string }) {
  return (
    <div>
      <label className="flex cursor-pointer items-center gap-3">
        <input type="checkbox" className="h-4 w-4 accent-brand-600" checked={checked} onChange={(e) => onChange(e.target.checked)} disabled={disabled} />
        <span className="text-sm font-medium text-ink-700">{label}</span>
        <Badge className={checked ? "bg-success-500/10 text-success-600" : "bg-ink-100 text-ink-400"}>{checked ? "مفعّل" : "متوقف"}</Badge>
      </label>
      {hint && <p className="mt-1 text-xs text-ink-400">{hint}</p>}
    </div>
  );
}

/** OWNER-19: the ranges the server keeps (0005), checked before saving; the field names them */
const NUMBER_RANGES: Partial<Record<keyof AiSettings, [number, number, string]>> = {
  temperature: [0, 1, "تنوّع الردود"], max_output_tokens: [50, 2000, "أقصى طول للرد"], timeout_ms: [2000, 60000, "مهلة الرد"],
  daily_request_limit: [0, 1000000, "حد الطلبات اليومي"], ops_daily_request_limit: [0, 1000000, "حد طلبات مساعد العمليات اليومي"],
  daily_token_budget: [0, 1000000000, "الحد اليومي للوحدات النصية"], per_session_message_limit: [1, 500, "حد الرسائل لكل جلسة"],
  guard_repeat_limit: [2, 20, "الرسالة نفسها متتالية"], guard_burst_messages: [3, 200, "عدد الرسائل"], guard_burst_minutes: [1, 120, "الدقائق"],
  guard_conversation_tokens: [1000, 1000000, "الوحدات النصية للمحادثة الواحدة"],
};

function NumberField({ label, value, onChange, min, max, step, disabled, range }: { label: string; value: number; onChange: (v: number) => void; min?: number; max?: number; step?: number; disabled?: boolean; range?: boolean }) {
  const bad = !range && (!Number.isFinite(value) || (min != null && value < min) || (max != null && value > max));
  return (
    <div>
      <label className="label">{label}</label>
      <input type={range ? "range" : "number"} className={range ? "w-full accent-brand-600" : "input"} dir="ltr" value={Number.isFinite(value) ? value : ""} min={min} max={max} step={step} disabled={disabled}
        aria-invalid={bad || undefined} onChange={(e) => onChange(e.target.value === "" ? NaN : Number(e.target.value))} />
      {bad && <p className="mt-1 text-xs text-danger-600" role="alert">خارج النطاق المسموح{min != null ? ` (${min.toLocaleString("en-US")}${max != null ? `–${max.toLocaleString("en-US")}` : " فأكثر"})` : ""}.</p>}
    </div>
  );
}

function Row({ k, v, ok }: { k: string; v: string; ok?: boolean }) {
  return (
    <div className="flex items-center justify-between rounded-lg bg-white px-3 py-1.5">
      <span className="text-ink-500">{k}</span>
      <span className={ok === undefined ? "text-ink-700" : ok ? "text-success-600" : "text-danger-600"} dir="ltr">{v}</span>
    </div>
  );
}
