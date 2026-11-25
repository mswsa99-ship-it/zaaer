/**
 * «رحلة الضيف» in the administration (migrations 0070–0071; plan «خطة تصحيح ملاحظات التجربة», م٤). Every number of the
 * journey is the branch's setting, and everything the owner still has to enter waits here, not in the code:
 *  - the morning message's hour, the free hour's end, the price of a late hour, the cleaning hour before the next guest,
 *    the time a guest has to pay a held request, the departure instructions, the deposit's hours, the review's delay and
 *    the mark under which the owner is alerted (the owner or the manager);
 *  - the branch's responsible (مأمون or مهيدي) and the fallback (the administration), and the alert rules — who is told,
 *    by which channel, after how long, to whom it climbs (the owner);
 *  - the unit's way in and way out as photos, shown to a guest only once approved (W7);
 *  - what still waits for the owner: the branch's WhatsApp number, the payment provider's name, the real product list.
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { Route, BellRing, Images, ListChecks, Globe, Plus, Archive, RotateCcw, CheckCircle2, ArrowUp, ArrowDown, ShieldCheck, Image as ImageIcon } from "lucide-react";
import { journeyApi, branchGuideApi, productsApi, toArabicError, type JourneySettings, type AlertRule, type AlertRecipient, type AlertChannel, type UnitGuideRow, type MediaItem, type PaymentSettings } from "../../lib/api";
import { useBranch } from "../../lib/branch";
import { useAuth } from "../../lib/auth";
import { individualAllows } from "../../lib/individualPermissions";
import { SectionTitle, Card, Badge, Spinner, LoadErrorCard, ErrorBanner } from "../../components/ui";
import { Field, Modal, MoneyInput, Toggle, ReasonInput } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { DisabledReason } from "../../components/DisabledReason";
import { TimeInput } from "../../components/TimeInput";

const RECIPIENT_AR: Record<AlertRecipient, string> = { responsible: "مسؤول الفرع", fallback: "البديل (الإدارة)", owner: "المالك", manager: "المدير", supervisor: "المشرفون" };
const CHANNEL_AR: Record<AlertChannel, string> = { app: "داخل النظام", whatsapp: "واتساب", both: "النظام وواتساب" };
const ROLE_AR: Record<string, string> = { owner: "المالك", manager: "مدير", supervisor: "مشرف" };

export default function AdminJourney() {
  const { branchId } = useBranch();
  const { profile } = useAuth();
  const owner = profile?.role === "owner";
  const [s, setS] = useState<JourneySettings | null>(null);
  const [form, setForm] = useState<JourneySettings | null>(null);
  const [rules, setRules] = useState<AlertRule[] | null>(null);
  const [units, setUnits] = useState<UnitGuideRow[] | null>(null);
  const [pay, setPay] = useState<PaymentSettings | null>(null);
  const [samples, setSamples] = useState<number | null>(null);
  const [site, setSite] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [unit, setUnit] = useState<UnitGuideRow | null>(null);
  const reload = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    if (!branchId) return;
    let alive = true; setError(null);
    Promise.all([journeyApi.settings(branchId), journeyApi.rules(), journeyApi.unitGuides(branchId)]).then(([a, r, u]) => {
      if (!alive) return; setS(a); setForm(a); setRules(r); setUnits(u); setSite(a.guest_site_url ?? "");
    }, (e) => { if (alive) setError(toArabicError(e)); });
    branchGuideApi.paymentSettings(branchId).then((x) => { if (alive) setPay(x); }, () => { if (alive) setPay(null); });
    productsApi.admin().then((x) => { if (alive) setSamples(x.products.filter((p) => p.is_sample).length); }, () => { if (alive) setSamples(null); });
    return () => { alive = false; };
  }, [branchId, tick]);

  async function run(key: string, fn: () => Promise<unknown>, ok: string) {
    setBusy(key); setSaveError(null); setSaved(null);
    try { await fn(); setSaved(ok); reload(); return true; } catch (e) { setSaveError(toArabicError(e)); return false; } finally { setBusy(null); }
  }
  const set = <K extends keyof JourneySettings>(k: K, v: JourneySettings[K]) => setForm((f) => (f ? { ...f, [k]: v } : f));
  const ready = useMemo(() => (units ?? []).filter((u) => u.checkin_approved > 0 && u.checkout_approved > 0).length, [units]);

  if (error) return <div><SectionTitle title="رحلة الضيف" action={<BranchPicker />} /><LoadErrorCard message={error} onRetry={reload} /></div>;
  if (!s || !form || !rules || !units) return <div><SectionTitle title="رحلة الضيف" action={<BranchPicker />} /><div className="py-10 text-center"><Spinner /></div></div>;
  const staffOpt = (id: string | null) => s.staff.find((x) => x.id === id);

  return (
    <div className="space-y-4">
      <SectionTitle title="رحلة الضيف" subtitle="مواعيد يوم المغادرة وأسعاره، والمغادرة ورد التأمين، والتقييم، وقواعد التنبيه، وصور شرح الوحدات — لكل فرع" action={<BranchPicker />} />
      {saveError && <ErrorBanner message={saveError} />}
      {saved && <p className="rounded-xl bg-success-500/10 px-3 py-2 text-sm text-success-700" role="status">{saved}</p>}

      {/* what still waits for the owner's input: everything is a setting */}
      <Card data-testid="journey-inputs">
        <h2 className="mb-3 flex items-center gap-2 text-base font-semibold text-ink-800"><ListChecks className="h-4 w-4 text-brand-600" /> بيانات تنتظر إدخالك</h2>
        <ul className="grid gap-2 sm:grid-cols-2">
          <InputItem done={s.channel_ready} title="رقم واتساب الفرع وربطه بكمبيوتر الاستقبال" state={s.channel_ready ? "مربوط — تصل الرسائل للنزلاء" : "لم يُربط بعد — لا تصل رسائل الرحلة"} to={owner ? "/admin/whatsapp" : null} />
          <InputItem done={units.length > 0 && ready === units.length} title="صور شرح الدخول والخروج لكل وحدة" state={`${ready} من ${units.length} وحدة جاهزة (صور معتمدة للدخول والخروج)`} href="#unit-guides" />
          <InputItem done={!!pay?.complete} title="اسم مزود الدفع (رابط الدفع ونقطة البيع)" state={pay?.complete ? `${pay.provider_label ?? pay.provider}` : "لم يُحدَّد بعد — الدفع لدى الاستقبال"} to="/admin/payment-providers" />
          <InputItem done={samples === 0} title="قائمة المنتجات الفعلية" state={samples == null ? "—" : samples > 0 ? `القائمة الحالية تجريبية (${samples} منتجًا) — أدخل قائمتك` : "قائمتك مُدخلة"} to="/admin/products" />
        </ul>
        {owner && <p className="mt-3 text-xs text-ink-500">بيانات التجربة باقية في النظام حتى تمسحها من <Link className="font-semibold text-brand-700 hover:underline" to="/admin/data-purge">تفريغ البيانات ← مسح كل بيانات التجربة</Link>.</p>}
      </Card>

      {/* the branch's numbers */}
      <Card data-testid="journey-settings">
        <h2 className="mb-3 flex items-center gap-2 text-base font-semibold text-ink-800"><Route className="h-4 w-4 text-brand-600" /> يوم المغادرة والمغادرة والتقييم</h2>
        <div className="mb-3"><Toggle checked={form.journey_enabled} onChange={(v) => set("journey_enabled", v)} label="إرسال رسائل الرحلة للنزلاء على واتساب الفرع" /></div>
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          <Field label="وقت رسالة صباح المغادرة" hint="يصل النزيلَ المغادرَ اليوم خياراته"><TimeInput label="وقت رسالة صباح المغادرة" value={form.checkout_message_time} onChange={(v) => set("checkout_message_time", v)} /></Field>
          <Field label="الخروج بلا رسوم حتى" hint="من موعد الخروج المعتمد حتى هذه الساعة"><TimeInput label="الخروج بلا رسوم حتى" value={form.free_checkout_until} onChange={(v) => set("free_checkout_until", v)} /></Field>
          <Field label="سعر الساعة بعدها" hint="جزء الساعة ساعة، بلا حد أعلى إلا الضيف التالي"><MoneyInput valueHalalas={form.late_hour_price_halalas} onChange={(h) => set("late_hour_price_halalas", h ?? 0)} label="سعر الساعة" /></Field>
          <Field label="وقت التنظيف قبل الضيف التالي (دقيقة)"><input type="number" min={0} max={240} className="input" value={form.cleaning_buffer_minutes} onChange={(e) => set("cleaning_buffer_minutes", Number(e.target.value))} /></Field>
          <Field label="مهلة الدفع لحجز التمديد (دقيقة)" hint="بعدها يُلغى الطلب غير المدفوع"><input type="number" min={5} max={240} className="input" value={form.hold_minutes} onChange={(e) => set("hold_minutes", Number(e.target.value))} /></Field>
          <Field label="رد التأمين خلال (ساعة)" hint="من تأكيد الخروج"><input type="number" min={1} max={72} className="input" value={form.deposit_refund_hours} onChange={(e) => set("deposit_refund_hours", Number(e.target.value))} data-testid="journey-refund-hours" /></Field>
          <Field label="دعوة التقييم بعد الخروج (دقيقة)"><input type="number" min={10} max={1440} className="input" value={form.review_delay_minutes} onChange={(e) => set("review_delay_minutes", Number(e.target.value))} /></Field>
          <Field label="تنبيه المالك إذا قل التقييم العام عن"><input type="number" min={1} max={10} className="input" value={form.review_alert_below} onChange={(e) => set("review_alert_below", Number(e.target.value))} /></Field>
        </div>
        <Field label="تعليمات المغادرة" className="mt-3" hint="تظهر للنزيل قبل زر «غادرت وسلّمت المفتاح». اتركها فارغة لنص عام.">
          <textarea className="input min-h-[88px]" maxLength={1500} value={form.checkout_instructions ?? ""} onChange={(e) => set("checkout_instructions", e.target.value)} data-testid="journey-instructions" />
        </Field>
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <Field label="مسؤول الفرع" hint="يُبلَّغ أولًا. إن لم يُحدَّد يُبلَّغ مشرفو الفرع.">
            <select className="input" value={form.responsible_staff_id ?? ""} onChange={(e) => set("responsible_staff_id", e.target.value || null)} data-testid="journey-responsible">
              <option value="">مشرفو الفرع</option>
              {s.staff.map((x) => <option key={x.id} value={x.id}>{x.name} — {ROLE_AR[x.role] ?? x.role}{x.has_phone ? "" : " (بلا جوال)"}</option>)}
            </select>
          </Field>
          <Field label="البديل (الإدارة)" hint="يُصعَّد إليه ما لم يُعالَج. إن لم يُحدَّد فالمالك.">
            <select className="input" value={form.fallback_staff_id ?? ""} onChange={(e) => set("fallback_staff_id", e.target.value || null)}>
              <option value="">المالك</option>
              {s.staff.map((x) => <option key={x.id} value={x.id}>{x.name} — {ROLE_AR[x.role] ?? x.role}{x.has_phone ? "" : " (بلا جوال)"}</option>)}
            </select>
          </Field>
        </div>
        {[staffOpt(form.responsible_staff_id), staffOpt(form.fallback_staff_id)].some((x) => x && !x.has_phone) && <p className="mt-2 text-xs text-warning-700">من لا جوال له في «الموظفون» لا يصله تنبيه واتساب؛ يصله داخل النظام فقط.</p>}
        <div className="mt-4 flex justify-end">
          <button type="button" className="btn-primary" disabled={busy !== null} data-testid="journey-save"
            onClick={() => run("settings", () => journeyApi.saveSettings(form.branch_id, {
              version: s.version, journey_enabled: form.journey_enabled, checkout_message_time: form.checkout_message_time, free_checkout_until: form.free_checkout_until,
              late_hour_price_halalas: String(form.late_hour_price_halalas), cleaning_buffer_minutes: String(form.cleaning_buffer_minutes), hold_minutes: String(form.hold_minutes),
              checkout_instructions: form.checkout_instructions ?? "", deposit_refund_hours: String(form.deposit_refund_hours), review_delay_minutes: String(form.review_delay_minutes),
              review_alert_below: String(form.review_alert_below), responsible_staff_id: form.responsible_staff_id ?? "", fallback_staff_id: form.fallback_staff_id ?? "" }), "حُفظت إعدادات رحلة الضيف.")}>
            {busy === "settings" ? <Spinner className="h-4 w-4" /> : "حفظ الإعدادات"}
          </button>
        </div>
      </Card>

      {/* W6: the alert rules (the owner's) */}
      <Card data-testid="journey-rules">
        <h2 className="mb-1 flex items-center gap-2 text-base font-semibold text-ink-800"><BellRing className="h-4 w-4 text-brand-600" /> قواعد التنبيه</h2>
        <p className="mb-3 text-xs text-ink-500">لكل حدث: من يُبلَّغ، وبأي قناة (واتساب بدل الرسائل النصية)، وبعد كم دقيقة، وإلى من يُصعَّد إن لم يُعالَج. {owner ? "" : "تعديلها للمالك وحده."}</p>
        <p className="mb-3 text-xs text-ink-500" data-testid="journey-channel-help">«داخل النظام» شخصي: يُحسب التنبيه في شارة «رحلة الضيف» لمن تسمّيهم القاعدة بأسمائهم (المسؤول أو البديل أو الأدوار المختارة)، ويظهر في الصفحة بعلامة «لك»، ويراه فيها المالك والمديرون ومشرفو الفرع. ومن لم يصله واتساب (بلا جوال أو واتساب الفرع غير مربوط) يجده في النظام. لا تحمل التنبيهات مبالغ؛ المبالغ في «رحلة الضيف» لمن يرى المال.</p>
        <div className="space-y-2">{rules.map((r) => <RuleRow key={r.event} rule={r} editable={owner} busy={busy} onSave={(p) => run("rule:" + r.event, () => journeyApi.saveRule(r.event, { version: r.version, ...p }), `حُفظت قاعدة «${r.label}».`)} />)}</div>
      </Card>

      {/* the guests' site (the links the server writes itself) */}
      <Card>
        <h2 className="mb-1 flex items-center gap-2 text-base font-semibold text-ink-800"><Globe className="h-4 w-4 text-brand-600" /> عنوان صفحات النزلاء</h2>
        <p className="mb-2 text-xs text-ink-500">تُكتب منه روابط التقييم التي يرسلها النظام بنفسه. {owner ? "" : "تعديله للمالك وحده."}</p>
        <div className="flex flex-wrap items-end gap-2">
          <input className="input min-w-0 flex-1 basis-64" dir="ltr" maxLength={200} value={site} disabled={!owner} onChange={(e) => setSite(e.target.value)} placeholder="https://…" aria-label="عنوان صفحات النزلاء" />
          {owner && <><button type="button" className="btn-outline" disabled={busy !== null || site.trim() === (s.guest_site_url ?? "")} aria-describedby={site.trim() === (s.guest_site_url ?? "") ? "dr-journey-site" : undefined} onClick={() => run("site", () => journeyApi.setGuestSite(site.trim() || null), "حُفظ عنوان صفحات النزلاء.")}>{busy === "site" ? <Spinner className="h-4 w-4" /> : "حفظ"}</button><DisabledReason id="dr-journey-site" show={site.trim() === (s.guest_site_url ?? "")} text="لا يوجد تغيير للحفظ" /></>}
        </div>
      </Card>

      {/* W7: the unit's way in and way out */}
      <Card data-testid="unit-guides">
        <h2 id="unit-guides" className="mb-1 flex items-center gap-2 text-base font-semibold text-ink-800"><Images className="h-4 w-4 text-brand-600" /> شرح الوحدات بالصور</h2>
        <p className="mb-3 text-xs text-ink-500">صور خطوات الدخول إلى كل وحدة والمغادرة منها. لا تظهر للنزيل إلا بعد اعتمادها من المالك أو المدير؛ والوحدة بلا صور معتمدة يشرحها الاستقبال.</p>
        {units.length === 0 ? <p className="text-sm text-ink-500">لا وحدات في هذا الفرع.</p> : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[480px] text-sm">
              <thead><tr className="text-right text-xs text-ink-500"><th className="py-2 font-medium">الوحدة</th><th className="font-medium">الدخول (معتمدة/الكل)</th><th className="font-medium">الخروج (معتمدة/الكل)</th><th className="font-medium">الحالة</th><th /></tr></thead>
              <tbody>{units.map((u) => {
                const ok = u.checkin_approved > 0 && u.checkout_approved > 0;
                const waiting = u.checkin > u.checkin_approved || u.checkout > u.checkout_approved;
                return (
                  <tr key={u.room_id} className="border-t border-ink-100" data-testid="unit-guide-row">
                    <td className="py-2 font-semibold text-ink-800">{u.room_number}</td>
                    <td className="tabular-nums">{u.checkin_approved} / {u.checkin}</td>
                    <td className="tabular-nums">{u.checkout_approved} / {u.checkout}</td>
                    <td>{ok ? <Badge className="bg-success-50 text-success-700">جاهزة</Badge> : waiting ? <Badge className="bg-warning-500/10 text-warning-700">بانتظار الاعتماد</Badge> : <Badge className="bg-ink-100 text-ink-600">بلا صور</Badge>}</td>
                    <td className="text-left"><button type="button" className="btn-outline min-h-[44px] text-xs" onClick={() => setUnit(u)} aria-label={`صور الوحدة ${u.room_number}`}>الصور</button></td>
                  </tr>
                );
              })}</tbody>
            </table>
          </div>
        )}
      </Card>

      <Modal open={!!unit} title={unit ? `شرح الوحدة ${unit.room_number}` : ""} onClose={() => { setUnit(null); reload(); }} wide>
        {unit && branchId && <UnitGuideEditor branchId={branchId} room={unit} canApprove={["owner", "manager"].includes(profile?.role ?? "")} />}
      </Modal>
    </div>
  );
}

function InputItem({ done, title, state, to, href }: { done: boolean; title: string; state: string; to?: string | null; href?: string }) {
  const body = (
    <>
      <span className={`mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full ${done ? "bg-success-500/15 text-success-600" : "bg-warning-500/15 text-warning-700"}`}>{done ? <CheckCircle2 className="h-3.5 w-3.5" /> : <span className="text-xs font-bold">!</span>}</span>
      <span className="min-w-0"><span className="block text-sm font-medium text-ink-800">{title}</span><span className="block text-xs text-ink-500">{state}</span></span>
    </>
  );
  const cls = "flex min-h-[44px] items-start gap-2 rounded-xl border border-ink-100 p-3 transition hover:border-brand-200";
  return <li>{to ? <Link to={to} className={cls}>{body}</Link> : href ? <a href={href} className={cls}>{body}</a> : <div className={cls}>{body}</div>}</li>;
}

function RuleRow({ rule, editable, busy, onSave }: { rule: AlertRule; editable: boolean; busy: string | null; onSave: (p: Record<string, unknown>) => Promise<boolean> }) {
  const [r, setR] = useState(rule);
  useEffect(() => setR(rule), [rule]);
  const changed = JSON.stringify(r) !== JSON.stringify(rule);
  const toggleRecipient = (x: AlertRecipient) => setR({ ...r, recipients: r.recipients.includes(x) ? r.recipients.filter((y) => y !== x) : [...r.recipients, x] });
  return (
    <div className={`rounded-xl border p-3 ${r.enabled ? "border-ink-100" : "border-ink-100 bg-ink-50/60"}`} data-testid="alert-rule">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="font-semibold text-ink-800">{rule.label}</p>
        <Toggle checked={r.enabled} onChange={(v) => editable && setR({ ...r, enabled: v })} label={r.enabled ? "مفعّلة" : "متوقفة"} />
      </div>
      <fieldset className="mt-2" disabled={!editable}>
        <legend className="sr-only">المستلمون</legend>
        <div className="flex flex-wrap gap-1.5">
          {(Object.keys(RECIPIENT_AR) as AlertRecipient[]).map((x) => (
            <button key={x} type="button" aria-pressed={r.recipients.includes(x)} onClick={() => toggleRecipient(x)}
              className={`min-h-[36px] rounded-full border px-3 text-xs font-semibold ${r.recipients.includes(x) ? "border-brand-600 bg-brand-50 text-brand-700" : "border-ink-200 text-ink-500"}`}>{RECIPIENT_AR[x]}</button>
          ))}
        </div>
        <div className="mt-2 grid gap-2 sm:grid-cols-4">
          <label className="block text-xs text-ink-500">القناة
            <select className="input mt-1" value={r.channel} onChange={(e) => setR({ ...r, channel: e.target.value as AlertChannel })}>
              {(Object.keys(CHANNEL_AR) as AlertChannel[]).map((c) => <option key={c} value={c}>{CHANNEL_AR[c]}</option>)}
            </select>
          </label>
          <label className="block text-xs text-ink-500">بعد (دقيقة)
            <input type="number" min={0} max={1440} className="input mt-1" value={r.delay_minutes} onChange={(e) => setR({ ...r, delay_minutes: Number(e.target.value) })} />
          </label>
          <label className="block text-xs text-ink-500">يُصعَّد بعد (دقيقة)
            <input type="number" min={1} max={1440} className="input mt-1" placeholder="بلا تصعيد" value={r.escalate_after_minutes ?? ""} onChange={(e) => setR({ ...r, escalate_after_minutes: e.target.value === "" ? null : Number(e.target.value) })} />
          </label>
          <label className="block text-xs text-ink-500">إلى
            <select className="input mt-1" value={r.escalate_to} onChange={(e) => setR({ ...r, escalate_to: e.target.value as "fallback" | "owner" })} disabled={!editable || r.escalate_after_minutes == null} aria-describedby={editable && r.escalate_after_minutes == null ? "dr-journey-esc" : undefined}>
              <option value="fallback">البديل (الإدارة)</option><option value="owner">المالك</option>
            </select><DisabledReason id="dr-journey-esc" show={editable && r.escalate_after_minutes == null} text="حدّد مدة التصعيد أولًا" />
          </label>
        </div>
      </fieldset>
      {editable && changed && (
        <div className="mt-2 flex justify-end gap-2">
          <button type="button" className="btn-outline text-xs" onClick={() => setR(rule)}>تراجع</button>
          <button type="button" className="btn-primary text-xs" disabled={busy !== null || r.recipients.length === 0} aria-describedby={r.recipients.length === 0 ? "dr-journey-rcp" : undefined}
            onClick={() => onSave({ enabled: r.enabled, recipients: r.recipients, channel: r.channel, delay_minutes: String(r.delay_minutes), escalate_after_minutes: r.escalate_after_minutes == null ? null : String(r.escalate_after_minutes), escalate_to: r.escalate_to })}>حفظ القاعدة</button><DisabledReason id="dr-journey-rcp" show={r.recipients.length === 0} text="أضف مستلمًا واحدًا على الأقل" />
        </div>
      )}
    </div>
  );
}

/** W7: the unit's photos for its way in and its way out — added, captioned, ordered, approved, archived */
function UnitGuideEditor({ branchId, room, canApprove }: { branchId: string; room: UnitGuideRow; canApprove: boolean }) {
  const { permissions } = useAuth();
  // archiving a way-in / way-out photo follows Edit on THIS page (0136); an individual account without it does not see the control
  const canArchive = permissions.pageAccess?.mode !== "individual" || individualAllows(permissions.pageAccess, "/admin/journey", "edit");
  const [items, setItems] = useState<MediaItem[]>([]);
  const [thumbs, setThumbs] = useState<Record<string, string | null>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [archiving, setArchiving] = useState<MediaItem | null>(null);
  const [reason, setReason] = useState("");

  const load = useCallback(async () => {
    try {
      const all = (await branchGuideApi.media(branchId, false)).filter((m) => m.room_id === room.room_id && (m.purpose === "checkin" || m.purpose === "checkout"));
      setItems(all);
      const out: Record<string, string | null> = {};
      for (const m of all) out[m.id] = await branchGuideApi.photo(m.id).catch(() => null);
      setThumbs(out);
    } catch (e) { setError(toArabicError(e)); }
  }, [branchId, room.room_id]);
  useEffect(() => { void load(); }, [load]);

  async function run(key: string, fn: () => Promise<unknown>) {
    setBusy(key); setError(null);
    try { await fn(); await load(); return true; } catch (e) { setError(toArabicError(e)); return false; } finally { setBusy(null); }
  }
  const add = (purpose: "checkin" | "checkout") => async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]; e.target.value = ""; if (!file) return;
    if (file.size > 1048576) { setError("حجم الصورة أكبر من 1 ميجابايت."); return; }
    await run("add:" + purpose, async () => {
      const b64 = await new Promise<string>((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result).replace(/^data:[^,]*,/, "")); r.onerror = () => rej(new Error("VALIDATION: image")); r.readAsDataURL(file); });
      await branchGuideApi.upsertMedia({ branch_id: branchId, kind: "photo", data_base64: b64, room_id: room.room_id, purpose });
    });
  };
  const move = (list: MediaItem[], i: number, d: -1 | 1) => run("move:" + list[i].id, async () => {
    const a = list[i], b = list[i + d]; if (!b) return;
    await branchGuideApi.upsertMedia({ id: a.id, sort_order: String(b.sort_order) });
    await branchGuideApi.upsertMedia({ id: b.id, sort_order: String(a.sort_order) });
  });

  const column = (purpose: "checkin" | "checkout", title: string) => {
    const list = items.filter((m) => m.purpose === purpose).sort((a, b) => a.sort_order - b.sort_order);
    return (
      <section className="min-w-0 space-y-2" data-testid={`unit-guide-${purpose}`}>
        <h3 className="text-sm font-semibold text-ink-800">{title}</h3>
        {list.length === 0 && <p className="text-xs text-ink-500">لا صور بعد.</p>}
        <ol className="space-y-2">{list.map((m, i) => (
          <li key={m.id} className="rounded-xl border border-ink-100 p-2">
            <div className="flex gap-2">
              {thumbs[m.id] ? <img src={thumbs[m.id]!} alt={m.caption ?? `الخطوة ${i + 1}`} className="h-20 w-28 shrink-0 rounded-lg object-cover" /> : <div className="flex h-20 w-28 shrink-0 items-center justify-center rounded-lg bg-ink-50 text-ink-400"><ImageIcon className="h-5 w-5" /></div>}
              <div className="min-w-0 flex-1 space-y-1">
                <input className="input py-1 text-xs" maxLength={160} defaultValue={m.caption ?? ""} placeholder={`الخطوة ${i + 1}: ماذا يفعل النزيل؟`} aria-label={`وصف الخطوة ${i + 1}`}
                  onBlur={(e) => { if (e.target.value !== (m.caption ?? "")) void run("cap:" + m.id, () => branchGuideApi.upsertMedia({ id: m.id, caption: e.target.value })); }} />
                {m.approved_at ? <Badge className="bg-success-50 text-success-700">معتمدة{m.approved_by_name ? ` — ${m.approved_by_name}` : ""}</Badge> : <Badge className="bg-warning-500/10 text-warning-700">بانتظار الاعتماد</Badge>}
              </div>
            </div>
            <div className="mt-2 flex flex-wrap gap-1">
              {canApprove && (m.approved_at
                ? <button type="button" className="btn-ghost min-h-[44px] text-xs" disabled={busy !== null} onClick={() => run("ap:" + m.id, () => journeyApi.approvePhoto(m.id, false))}>سحب الاعتماد</button>
                : <button type="button" className="btn-outline min-h-[44px] text-xs" disabled={busy !== null} onClick={() => run("ap:" + m.id, () => journeyApi.approvePhoto(m.id, true))} data-testid="approve-photo"><ShieldCheck className="h-4 w-4" /> اعتماد</button>)}
              <button type="button" className="btn-ghost min-h-[44px] min-w-[44px]" aria-label="تقديم الخطوة" disabled={busy !== null || i === 0} onClick={() => move(list, i, -1)}><ArrowUp className="h-4 w-4" /></button>
              <button type="button" className="btn-ghost min-h-[44px] min-w-[44px]" aria-label="تأخير الخطوة" disabled={busy !== null || i === list.length - 1} onClick={() => move(list, i, 1)}><ArrowDown className="h-4 w-4" /></button>
              {canArchive && <button type="button" className="btn-ghost min-h-[44px] min-w-[44px]" aria-label="أرشفة الصورة" disabled={busy !== null} onClick={() => { setArchiving(m); setReason(""); }}><Archive className="h-4 w-4" /></button>}
            </div>
          </li>))}
        </ol>
        <label className="flex min-h-[44px] cursor-pointer items-center justify-center gap-1 rounded-xl border border-dashed border-ink-200 text-xs text-ink-500">
          {busy === "add:" + purpose ? <Spinner className="h-4 w-4" /> : <><Plus className="h-4 w-4" /> صورة خطوة (حتى 1 ميجابايت)</>}
          <input type="file" accept="image/png,image/jpeg,image/webp" className="hidden" onChange={add(purpose)} disabled={busy !== null} aria-label={purpose === "checkin" ? "إضافة صورة لشرح الدخول" : "إضافة صورة لشرح الخروج"} />
        </label>
      </section>
    );
  };

  return (
    <div className="space-y-3">
      {error && <ErrorBanner message={error} />}
      <p className="text-xs text-ink-500">تعديل وصف صورة معتمدة يعيدها إلى «بانتظار الاعتماد». الترتيب هو ترتيب الخطوات عند النزيل.</p>
      <div className="grid gap-4 md:grid-cols-2">
        {column("checkin", "الدخول إلى الوحدة")}
        {column("checkout", "المغادرة وتسليم المفتاح")}
      </div>
      {archiving && (
        <div className="rounded-lg border border-danger-500/30 p-3" role="group" aria-label="أرشفة">
          <p className="mb-2 text-xs text-ink-600">تختفي الصورة عن النزيل وتبقى في المؤرشفة ضمن صور الفرع.</p>
          <ReasonInput value={reason} onChange={setReason} />
          <div className="flex justify-end gap-2">
            <button type="button" className="btn-outline text-xs" onClick={() => setArchiving(null)}><RotateCcw className="h-3.5 w-3.5" /> إلغاء</button>
            <button type="button" className="btn-danger text-xs" disabled={busy !== null}
              onClick={async () => { if (!reason.trim()) { setError(toArabicError(new Error("VALIDATION: reason"))); return; } if (await run("arch:" + archiving.id, () => branchGuideApi.archiveMedia(archiving.id, reason.trim()))) setArchiving(null); }}>أرشفة</button>
          </div>
        </div>
      )}
    </div>
  );
}
