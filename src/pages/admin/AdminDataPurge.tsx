import { useEffect, useState } from "react";
import { Trash2, ShieldAlert, ArrowRight, KeyRound, CheckCircle2, MessagesSquare, BookCheck, Wallet, Users, Wrench, Bell, ScrollText } from "lucide-react";
import { purgeApi, toArabicError, type PurgeCategory, type PurgePreview, type PurgeHistoryRow } from "../../lib/api";
import { supabase } from "../../lib/supabase";
import { useAuth } from "../../lib/auth";
import { useBranch } from "../../lib/branch";
import { SectionTitle, Card, ErrorBanner, Spinner, Badge } from "../../components/ui";
import { todayISO, addDaysISO, formatDateTime } from "../../lib/utils";

/**
 * Data purge by period (owner only). Seven kinds of data to choose from; three confirmations that the server
 * enforces: the exact preview (a rolled-back dry run), the typed phrase, and the password again.
 */
const KINDS: Array<{ key: PurgeCategory; title: string; desc: string; icon: typeof Trash2; warn?: string }> = [
  { key: "conversations", title: "المحادثات والذكاء الاصطناعي", desc: "محادثات النزلاء (واتساب والموقع)، تذاكر التحويل، محادثات مساعد العمليات، الأسئلة بلا إجابة، سجلات المساعد.", icon: MessagesSquare },
  { key: "reservations", title: "الحجوزات المنتهية", desc: "الحجوزات التي يقع وصولها في الفترة وانتهت (غادر، ملغى، عدم حضور، مرفوض، أو فات موعدها). المقيمون والقادمون لا يُمسّون.", icon: BookCheck, warn: "الحجز الذي عليه مبالغ لا يُحذف إلا إذا اخترت «المالية» أيضًا." },
  { key: "finance", title: "المالية", desc: "الفواتير والسندات والمدفوعات المؤرخة في الفترة، للحجوزات المنتهية فقط.", icon: Wallet, warn: "تنبيه نظامي: أنظمة الزكاة والضريبة تُلزم عادةً بحفظ الفواتير والسندات سنوات. صدّر تقاريرك قبل الحذف." },
  { key: "guests", title: "ملفات النزلاء", desc: "ملفات النزلاء التي لم يعد أي حجز يشير إليها.", icon: Users },
  { key: "operations", title: "المهام والصيانة", desc: "مهام التنظيف المنتهية أو الملغاة، تذاكر الصيانة المغلقة، وسجل الكشف التدريجي للفترة الماضية.", icon: Wrench },
  { key: "logs", title: "الإشعارات وسجلات التكامل", desc: "الإشعارات، أحداث التكامل (واتساب وغيره)، ومحاولات البحث ورموز التحقق.", icon: Bell },
  { key: "audit", title: "سجل الإجراءات", desc: "سجل التدقيق للفترة. يبقى دائمًا سجل عملية التفريغ نفسها.", icon: ScrollText, warn: "بعد حذفه لا يمكن معرفة من فعل ماذا في تلك الفترة." },
];
const COUNT_AR: Record<string, string> = {
  conversations: "محادثات", conversation_messages: "رسائل", handoff_tickets: "تذاكر تحويل", staff_assistant_chats: "محادثات مساعد العمليات",
  unanswered_questions: "أسئلة بلا إجابة", reservations: "حجوزات", reservations_skipped_with_money: "حجوزات عليها مبالغ (ستبقى)",
  reservations_kept_active_or_with_money: "حجوزات في الفترة ستبقى (جارية/قادمة أو عليها مبالغ)", vouchers: "سندات", payments: "مدفوعات",
  invoices: "فواتير", guest_profiles: "ملفات نزلاء", housekeeping_tasks: "مهام تنظيف", maintenance_tickets: "تذاكر صيانة", released_slots: "سجلات كشف",
  notifications: "إشعارات", integration_events: "أحداث تكامل", audit_events: "سجلات تدقيق",
};
const KEPT = new Set(["reservations_skipped_with_money", "reservations_kept_active_or_with_money"]);
const PHRASE = "احذف نهائيا";

type Step = "choose" | "preview" | "phrase" | "password" | "done";

export default function AdminDataPurge() {
  const { session } = useAuth();
  const { branches } = useBranch();
  const [branch, setBranch] = useState<string>("");
  const [from, setFrom] = useState(addDaysISO(todayISO(), -90));
  const [to, setTo] = useState(addDaysISO(todayISO(), -1));
  const [cats, setCats] = useState<PurgeCategory[]>([]);
  const [step, setStep] = useState<Step>("choose");
  const [preview, setPreview] = useState<PurgePreview | null>(null);
  const [understood, setUnderstood] = useState(false);
  const [phrase, setPhrase] = useState("");
  const [password, setPassword] = useState("");
  const [result, setResult] = useState<Record<string, number> | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [history, setHistory] = useState<PurgeHistoryRow[]>([]);

  const loadHistory = () => { purgeApi.history().then(setHistory).catch(() => setHistory([])); };
  useEffect(loadHistory, []);

  const toggle = (k: PurgeCategory) => setCats((c) => (c.includes(k) ? c.filter((x) => x !== k) : [...c, k]));
  const reset = () => { setStep("choose"); setPreview(null); setUnderstood(false); setPhrase(""); setPassword(""); setError(null); };

  async function doPreview() {
    setBusy(true); setError(null);
    try { setPreview(await purgeApi.preview(branch || null, from, to, cats)); setStep("preview"); } catch (e) { setError(toArabicError(e)); }
    setBusy(false);
  }
  async function doExecute(e: React.FormEvent) {
    e.preventDefault();
    if (!preview) return;
    setBusy(true); setError(null);
    try {
      const email = session?.user?.email;
      if (!email) throw new Error("FORBIDDEN");
      const { error: authErr } = await supabase.auth.signInWithPassword({ email, password });
      if (authErr) throw new Error("كلمة المرور غير صحيحة.");
      const r = await purgeApi.execute(preview.token, phrase);
      setResult(r.counts); setStep("done"); loadHistory();
    } catch (err) {
      const m = (err as Error).message;
      setError(m === "كلمة المرور غير صحيحة." ? m : toArabicError(err));
    }
    setPassword(""); setBusy(false);
  }

  const countRows = (c: Record<string, number>, withKept = true) => Object.entries(c).filter(([k]) => withKept || !KEPT.has(k));
  const total = preview ? countRows(preview.counts, false).reduce((s, [, v]) => s + Number(v || 0), 0) : 0;
  const branchName = branch ? branches.find((b) => b.id === branch)?.name_ar : "كل الفروع";

  return (
    <div className="space-y-4">
      <SectionTitle title="تفريغ البيانات" subtitle="حذف نهائي لبيانات فترة محددة، بثلاث مراحل تأكيد. للمالك فقط." />
      {error && <ErrorBanner message={error} />}

      {step === "choose" && (
        <Card className="space-y-5">
          <div className="grid gap-3 sm:grid-cols-3">
            <label className="block"><span className="label">الفرع</span>
              <select className="input" value={branch} onChange={(e) => setBranch(e.target.value)}>
                <option value="">كل الفروع</option>
                {branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
              </select>
            </label>
            <label className="block"><span className="label">من تاريخ</span><input type="date" className="input" value={from} max={to} onChange={(e) => setFrom(e.target.value)} /></label>
            <label className="block"><span className="label">إلى تاريخ</span><input type="date" className="input" value={to} min={from} max={todayISO()} onChange={(e) => setTo(e.target.value)} /></label>
          </div>
          <div>
            <p className="label">ماذا تريد أن تحذف؟</p>
            <div className="grid gap-2 sm:grid-cols-2">
              {KINDS.map((k) => {
                const on = cats.includes(k.key);
                return (
                  <label key={k.key} className={`flex cursor-pointer gap-3 rounded-2xl border p-3 transition ${on ? "border-danger-500/50 bg-danger-500/5" : "border-ink-100 hover:border-ink-200"}`}>
                    <input type="checkbox" className="mt-1" checked={on} onChange={() => toggle(k.key)} aria-label={k.title} />
                    <span className="min-w-0">
                      <span className="flex items-center gap-1.5 font-semibold text-ink-800"><k.icon className="h-4 w-4 text-ink-400" /> {k.title}</span>
                      <span className="mt-0.5 block text-xs text-ink-500">{k.desc}</span>
                      {k.warn && <span className="mt-1 block text-xs text-warning-600">{k.warn}</span>}
                    </span>
                  </label>
                );
              })}
            </div>
          </div>
          <p className="text-xs text-ink-400">لا تُحذف أبدًا: الفروع والوحدات والتصنيفات والأسعار والخدمات وأنواع المهام والموظفون والإعدادات (تُؤرشف ولا تُحذف).</p>
          <button type="button" className="btn-primary" onClick={doPreview} disabled={busy || cats.length === 0}>{busy ? <Spinner /> : "معاينة ما سيُحذف"}</button>
        </Card>
      )}

      {preview && step !== "choose" && step !== "done" && (
        <Card className="space-y-4">
          <div className="flex flex-wrap items-center gap-2 text-sm">
            <Badge className="bg-ink-100 text-ink-600">{branchName}</Badge>
            <Badge className="bg-ink-100 text-ink-600" ><span dir="ltr">{from} → {to}</span></Badge>
            {preview.categories.map((c) => <Badge key={c} className="bg-danger-500/10 text-danger-600">{KINDS.find((k) => k.key === c)?.title}</Badge>)}
          </div>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <tbody>
                {countRows(preview.counts).map(([k, v]) => (
                  <tr key={k} className="border-b border-ink-50"><td className={`py-1.5 ${KEPT.has(k) ? "text-ink-400" : "text-ink-700"}`}>{COUNT_AR[k] ?? k}</td><td className={`py-1.5 text-left font-semibold ${KEPT.has(k) ? "text-ink-400" : "text-danger-600"}`} dir="ltr">{Number(v).toLocaleString("en-US")}</td></tr>
                ))}
              </tbody>
            </table>
          </div>

          {step === "preview" && (
            <div className="flex flex-wrap gap-2">
              <button type="button" className="btn-outline" onClick={reset}><ArrowRight className="h-4 w-4" /> رجوع</button>
              <button type="button" className="btn-danger" onClick={() => setStep("phrase")} disabled={total === 0}>
                {total === 0 ? "لا يوجد ما يُحذف" : `التأكيد 1 من 3: متابعة حذف ${total.toLocaleString("en-US")} سجل`}
              </button>
            </div>
          )}

          {step === "phrase" && (
            <div className="space-y-3 rounded-2xl border border-danger-500/30 bg-danger-500/5 p-4">
              <p className="flex items-center gap-2 font-semibold text-danger-600"><ShieldAlert className="h-5 w-5" /> التأكيد 2 من 3</p>
              <label className="flex items-start gap-2 text-sm text-ink-700"><input type="checkbox" className="mt-1" checked={understood} onChange={(e) => setUnderstood(e.target.checked)} /> أفهم أن الحذف نهائي ولا يمكن التراجع عنه، وأني صدّرت ما أحتاجه.</label>
              <label className="block"><span className="label">اكتب العبارة: <b>{PHRASE}</b></span><input className="input" value={phrase} onChange={(e) => setPhrase(e.target.value)} autoComplete="off" /></label>
              <div className="flex flex-wrap gap-2">
                <button type="button" className="btn-outline" onClick={reset}>إلغاء</button>
                <button type="button" className="btn-danger" disabled={!understood || phrase.replace(/[ً-ْ]/g, "").trim() !== PHRASE} onClick={() => setStep("password")}>متابعة</button>
              </div>
            </div>
          )}

          {step === "password" && (
            <form onSubmit={doExecute} className="space-y-3 rounded-2xl border border-danger-500/30 bg-danger-500/5 p-4">
              <p className="flex items-center gap-2 font-semibold text-danger-600"><KeyRound className="h-5 w-5" /> التأكيد 3 من 3: كلمة مرور حسابك</p>
              <input type="password" className="input" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="current-password" placeholder="كلمة المرور" aria-label="كلمة المرور" autoFocus />
              <div className="flex flex-wrap gap-2">
                <button type="button" className="btn-outline" onClick={reset} disabled={busy}>إلغاء</button>
                <button type="submit" className="btn-danger" disabled={busy || !password}>{busy ? <Spinner /> : <><Trash2 className="h-4 w-4" /> احذف نهائيًا</>}</button>
              </div>
            </form>
          )}
        </Card>
      )}

      {step === "done" && result && (
        <Card className="space-y-3">
          <p className="flex items-center gap-2 font-semibold text-success-600"><CheckCircle2 className="h-5 w-5" /> تم التفريغ وسُجّل في سجل الإجراءات.</p>
          <ul className="text-sm text-ink-600">{countRows(result).map(([k, v]) => <li key={k}>{COUNT_AR[k] ?? k}: <b dir="ltr">{Number(v).toLocaleString("en-US")}</b></li>)}</ul>
          <button type="button" className="btn-outline" onClick={() => { reset(); setResult(null); setCats([]); }}>تفريغ آخر</button>
        </Card>
      )}

      {history.length > 0 && (
        <Card>
          <p className="mb-2 text-sm font-semibold text-ink-700">عمليات التفريغ السابقة</p>
          <ul className="space-y-1.5 text-xs text-ink-500">
            {history.map((h) => (
              <li key={h.id}>{formatDateTime(h.executed_at)} · {h.by ?? "—"} · {h.branch_name ?? "كل الفروع"} · <span dir="ltr">{h.from} → {h.to}</span> · {h.categories.map((c) => KINDS.find((k) => k.key === c)?.title ?? c).join("، ")}</li>
            ))}
          </ul>
        </Card>
      )}
    </div>
  );
}
