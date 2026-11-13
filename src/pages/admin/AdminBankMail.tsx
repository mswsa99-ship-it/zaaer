/**
 * «بريد البنك» (the accounting stage, A6/A7; migration 0066): how the bank's messages reach the system. The phone app
 * (A9) relays each SMS or notification of the bank, signed with the relay key, to a mailbox of its own; the system reads
 * that mailbox and accepts only that mail. Here the owner sets the mailbox (address, mail server, the password kept
 * encrypted, never shown again), makes the relay key (shown once, to put in the phone app), names the bank senders the
 * app may relay, switches the reading on, and keeps the words that tell a message's kind. Nothing is pretended: until
 * the mailbox is complete the page says «غير مربوط بعد».
 */
import { useCallback, useEffect, useState } from "react";
import { Mail, KeyRound, Plus, Pencil, RefreshCw, Copy, Smartphone } from "lucide-react";
import { Link } from "react-router-dom";
import { supabase } from "../../lib/supabase";
import { bankApi, toArabicError, type BankMailSettings, type BankRule, type BankKind } from "../../lib/api";
import { SectionTitle, Card, Spinner, LoadErrorCard, Badge } from "../../components/ui";
import { Field, Modal, ActionForm, Submit, Toggle } from "../../components/forms";
import { formatDateTime } from "../../lib/utils";
import { setupText, setupProblem } from "../../lib/relaySetup";

export const KIND_AR: Record<BankKind, string> = {
  deposit: "إيداع", transfer_in: "تحويل وارد", pos_settlement: "تسوية نقاط البيع", other_in: "دخل آخر",
  transfer_out: "تحويل صادر", withdrawal: "سحب", fee: "رسوم", pos_fee: "رسوم نقاط البيع", purchase: "شراء", other_out: "خصم آخر",
};
const STATE: Record<BankMailSettings["state"], [string, string]> = {
  not_configured: ["غير مربوط بعد", "bg-ink-100 text-ink-700"], off: ["متوقف", "bg-warning-50 text-warning-700"],
  error: ["تعذّرت القراءة", "bg-danger-50 text-danger-700"], on: ["يعمل", "bg-success-50 text-success-700"],
};

export default function AdminBankMail() {
  const [s, setS] = useState<BankMailSettings | null>(null);
  const [rules, setRules] = useState<BankRule[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [editing, setEditing] = useState(false);
  const [rule, setRule] = useState<Partial<BankRule> | null>(null);
  const [key, setKey] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [setup, setSetup] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => setTick((t) => t + 1), []);
  useEffect(() => {
    let alive = true; setError(null);
    Promise.all([bankApi.settings(), supabase.from("bank_parse_rules").select("id, keyword, kind, direction, priority, is_active, version").order("priority").order("keyword")])
      .then(([st, r]) => { if (!alive) return; if (r.error) throw r.error; setS(st); setRules((r.data ?? []) as BankRule[]); })
      .catch((e) => { if (alive) setError(toArabicError(e)); });
    return () => { alive = false; };
  }, [tick]);

  const toggle = async (on: boolean) => {
    if (!s) return; setBusy(true); setNotice(null);
    try { await bankApi.save({ version: s.version, enabled: on }); load(); } catch (e) { setNotice(toArabicError(e)); } finally { setBusy(false); }
  };
  const newKey = async () => {
    if (!s) return; setBusy(true); setNotice(null);
    try { const r = await bankApi.save({ version: s.version, new_relay_key: true }); setKey(r.relay_key ?? null); load(); } catch (e) { setNotice(toArabicError(e)); } finally { setBusy(false); }
  };
  const pollNow = async () => {
    setBusy(true); setNotice(null);
    try {
      const r = await bankApi.pollNow();
      setNotice(!r.configured ? "البريد غير مربوط أو متوقف؛ لم يُقرأ شيء." : r.error ? `تعذّرت القراءة من خادم البريد (تحقق من الخادم واسم الدخول وكلمة المرور). التفاصيل: ${r.error}` : r.fetched ? `قُرئت ${r.fetched} رسالة جديدة.` : "لا رسائل جديدة.");
      load();
    } catch (e) { setNotice(toArabicError(e)); } finally { setBusy(false); }
  };

  if (error) return <LoadErrorCard message={error} onRetry={load} />;
  if (!s) return <div className="py-10 text-center"><Spinner /></div>;
  const [stateLabel, stateTone] = STATE[s.state];
  return (
    <div>
      <SectionTitle title="بريد البنك" subtitle="رسائل البنك تصل من تطبيق الجوال إلى بريد مخصّص، والنظام يقرؤه ولا يقبل غيره" />
      {notice && <div className="mb-4 rounded-xl border border-ink-100 bg-ink-50 p-3 text-sm text-ink-700" role="status">{notice}</div>}
      <Card className="mb-4">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-center gap-2"><Mail className="h-5 w-5 text-ink-500" /><span className="font-semibold">صندوق البريد</span>
            <Badge className={stateTone} testId="bank-mail-state">{stateLabel}</Badge></div>
          <div className="flex flex-wrap gap-2">
            <button type="button" className="btn-secondary min-h-[44px]" onClick={() => setEditing(true)}><Pencil className="h-4 w-4" /> تعديل</button>
            <button type="button" className="btn-secondary min-h-[44px]" disabled={busy || s.state === "not_configured"} onClick={pollNow}><RefreshCw className="h-4 w-4" /> اقرأ البريد الآن</button>
          </div>
        </div>
        <dl className="mt-4 grid gap-3 text-sm sm:grid-cols-2">
          <div><dt className="text-xs text-ink-500">البريد المخصّص</dt><dd dir="ltr" className="text-right">{s.mailbox_address ?? "—"}</dd></div>
          <div><dt className="text-xs text-ink-500">خادم البريد</dt><dd dir="ltr" className="text-right">{s.imap_host}:{s.imap_port}</dd></div>
          <div><dt className="text-xs text-ink-500">اسم الدخول</dt><dd dir="ltr" className="text-right">{s.imap_user ?? "—"}</dd></div>
          <div><dt className="text-xs text-ink-500">كلمة مرور البريد</dt><dd>{s.has_password ? "محفوظة مشفّرة" : "لم تُحدَّد"}</dd></div>
          <div><dt className="text-xs text-ink-500">المرسلون المسموحون</dt><dd>{s.allowed_senders.join("، ")}</dd></div>
          <div><dt className="text-xs text-ink-500">آخر قراءة</dt><dd>{s.last_polled_at ? formatDateTime(s.last_polled_at) : "لم يُقرأ بعد"}{s.last_error ? <span className="block text-danger-700">تعذّرت آخر قراءة: <span dir="ltr">{s.last_error}</span></span> : null}</dd></div>
        </dl>
        <div className="mt-4 flex flex-wrap items-center justify-between gap-3 border-t border-ink-100 pt-4">
          <div className="text-sm"><KeyRound className="me-1 inline h-4 w-4 text-ink-500" />مفتاح تطبيق الجوال: {s.has_relay_key ? <>ينتهي بـ <span dir="ltr" className="font-mono">{s.relay_key_last4}</span></> : "لم يُنشأ"}</div>
          <button type="button" className="btn-ghost min-h-[44px]" disabled={busy} onClick={newKey}>{s.has_relay_key ? "مفتاح جديد (يُبطل القديم)" : "إنشاء المفتاح"}</button>
        </div>
        <div className="mt-3 border-t border-ink-100 pt-3">
          <Toggle checked={s.enabled} onChange={toggle} label="قراءة البريد تلقائيًا" />
        </div>
      </Card>

      <Card className="mb-4" data-testid="relay-app">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-center gap-2"><Smartphone className="h-5 w-5 text-ink-500" /><span className="font-semibold">تطبيق الجوال</span></div>
          <button type="button" className="btn-secondary min-h-[44px]" disabled={!!setupProblem(s)} onClick={() => setSetup(true)}>نص الإعداد</button>
        </div>
        <p className="mt-2 text-sm text-ink-600">ينقل رسالة البنك التي تحمل رقم أحد حسابات الفروع كما هي إلى البريد المخصّص، ولا يرسل غير ذلك، ويعيد المحاولة إذا انقطع الإنترنت.</p>
        <ol className="mt-2 list-decimal space-y-1 ps-5 text-sm text-ink-600">
          <li>على جوال الإدارة (أندرويد) افتح ملف التثبيت واسمح بالتثبيت.</li>
          <li>اسمح للتطبيق بقراءة الرسائل. ولإشعارات تطبيق البنك: إن ظهر أن الإعداد مقيّد افتح «معلومات التطبيق» ← ⋮ ← «السماح بالإعدادات المقيدة» ثم اسمح بالإشعارات.</li>
          <li>اجعل البطارية «غير مقيّدة» للتطبيق حتى لا يتأخر الإرسال.</li>
          <li>الصق نص الإعداد واكتب كلمة مرور تطبيق البريد (كلمة مرور التطبيقات، لا كلمة الحساب).</li>
          <li>للإشعارات: يُقبل التطبيق باسم حزمته (مثل com.…). إن ظهر اسمه في التطبيق تحت «لم تُسمح» فأضفه إلى «المرسلون المسموحون» هنا ثم انسخ نص الإعداد من جديد.</li>
        </ol>
        {setupProblem(s) && <p className="mt-2 text-sm text-warning-700">{setupProblem(s) === "mailbox" ? "حدّد البريد المخصّص أولًا." : "حدّد قاعدة رقم الحساب لفرع واحد على الأقل أولًا."}</p>}
        <a href="https://github.com/mswsa99-ship-it/zaaer/actions/workflows/android.yml" target="_blank" rel="noreferrer" className="mt-2 inline-block text-sm text-brand-700 underline">ملف التثبيت (APK): آخر تشغيل ناجح في GitHub ← «fivehours-relay-apk»</a>
      </Card>

      <Card className="mb-4">
        <SectionTitle level={2} title="قاعدة رقم الحساب لكل فرع" subtitle="تُنسب الحركة لحساب الفرع الذي يبدأ رقمه وينتهي بما في الرسالة" />
        <ul className="divide-y divide-ink-50 text-sm" data-testid="bank-account-rules">
          {s.accounts.map((a) => (
            <li key={a.id} className="flex flex-wrap justify-between gap-2 py-2"><span>{a.branch} — {a.name}</span>
              <span dir="ltr" className="font-mono">{a.prefix && a.suffix ? `${a.prefix}…${a.suffix}` : <span className="text-warning-700" dir="rtl">لم تُحدَّد</span>}</span></li>
          ))}
        </ul>
        <Link to="/admin/cash-accounts" className="mt-2 inline-block text-sm text-brand-700 underline">تعديلها من «الصناديق والحسابات»</Link>
      </Card>

      <Card>
        <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
          <SectionTitle level={2} title="كلمات قراءة الرسائل" subtitle="أول كلمة تظهر في الرسالة (بالأولوية) تحدّد نوع الحركة واتجاهها" />
          <button type="button" className="btn-primary min-h-[44px]" onClick={() => setRule({ kind: "deposit", priority: 100 })}><Plus className="h-4 w-4" /> كلمة</button>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full min-w-[30rem] text-sm" data-testid="bank-rules">
            <thead><tr className="border-b border-ink-100 text-xs text-ink-500"><th className="py-2 text-right font-medium">الأولوية</th><th className="py-2 text-right font-medium">الكلمة</th><th className="py-2 text-right font-medium">النوع</th><th className="py-2 text-right font-medium">الاتجاه</th><th /></tr></thead>
            <tbody>{rules.map((r) => (
              <tr key={r.id} className={`border-b border-ink-50 ${r.is_active ? "" : "text-ink-400"}`} data-testid="bank-rule">
                <td className="py-2 tabular-nums">{r.priority}</td><td className="py-2">{r.keyword}</td><td className="py-2">{KIND_AR[r.kind]}</td>
                <td className="py-2">{r.direction === "in" ? "داخل" : "خارج"}{r.is_active ? "" : " (موقوفة)"}</td>
                <td className="py-2 text-left"><button type="button" className="btn-ghost min-h-[44px] text-xs" aria-label={`تعديل ${r.keyword}`} onClick={() => setRule(r)}>تعديل</button></td>
              </tr>))}</tbody>
          </table>
        </div>
      </Card>

      <Modal open={editing} title="صندوق البريد" onClose={() => setEditing(false)}>
        {editing && <SettingsForm s={s} onDone={() => { setEditing(false); load(); }} onCancel={() => setEditing(false)} />}
      </Modal>
      <Modal open={!!rule} title={rule?.id ? "تعديل كلمة" : "كلمة جديدة"} onClose={() => setRule(null)}>
        {rule && <RuleForm r={rule} onDone={() => { setRule(null); load(); }} onCancel={() => setRule(null)} />}
      </Modal>
      <Modal open={setup} title="نص إعداد تطبيق الجوال" onClose={() => setSetup(false)}>
        {setup && <div>
          <p className="mb-3 text-sm text-ink-600">للصقه في التطبيق بعد تعديل حساب أو مرسل. لا يحمل المفتاح، فيبقى التطبيق على مفتاحه؛ ولجوال جديد أنشئ مفتاحًا جديدًا فيظهر النص معه.</p>
          <div className="flex items-start gap-2 rounded-xl bg-ink-50 p-3"><pre dir="ltr" className="min-w-0 flex-1 whitespace-pre-wrap break-all text-left text-sm" data-testid="relay-setup">{setupText(s)}</pre>
            <button type="button" className="btn-ghost min-h-[44px]" aria-label="نسخ نص الإعداد" onClick={() => { navigator.clipboard?.writeText(setupText(s)).catch(() => undefined); }}><Copy className="h-4 w-4" /></button></div>
          <div className="mt-4 text-left"><button type="button" className="btn-primary min-h-[44px]" onClick={() => setSetup(false)}>تم</button></div>
        </div>}
      </Modal>
      <Modal open={!!key} title="مفتاح تطبيق الجوال" onClose={() => setKey(null)}>
        {key && <div>
          <p className="mb-3 text-sm text-ink-600">انسخ نص الإعداد والصقه في تطبيق الجوال الآن؛ فيه المفتاح، ولن يظهر مرة أخرى. من يملكه يستطيع إرسال رسائل يقبلها النظام.</p>
          <div className="flex items-start gap-2 rounded-xl bg-ink-50 p-3"><pre dir="ltr" className="min-w-0 flex-1 whitespace-pre-wrap break-all text-left text-sm" data-testid="relay-setup-with-key">{setupText(s, key)}</pre>
            <button type="button" className="btn-ghost min-h-[44px]" aria-label="نسخ نص الإعداد" onClick={() => { navigator.clipboard?.writeText(setupText(s, key)).catch(() => undefined); }}><Copy className="h-4 w-4" /></button></div>
          <p className="mt-3 text-xs text-ink-500">المفتاح وحده: <code dir="ltr" className="break-all" data-testid="relay-key">{key}</code></p>
          <div className="mt-4 text-left"><button type="button" className="btn-primary min-h-[44px]" onClick={() => setKey(null)}>نسخته</button></div>
        </div>}
      </Modal>
    </div>
  );
}

function SettingsForm({ s, onDone, onCancel }: { s: BankMailSettings; onDone: () => void; onCancel: () => void }) {
  const [address, setAddress] = useState(s.mailbox_address ?? "");
  const [host, setHost] = useState(s.imap_host);
  const [port, setPort] = useState(String(s.imap_port));
  const [user, setUser] = useState(s.imap_user ?? "");
  const [password, setPassword] = useState("");
  const [senders, setSenders] = useState(s.allowed_senders.join("، "));
  return (
    <ActionForm onSubmit={async () => {
      await bankApi.save({ version: s.version, mailbox_address: address, imap_host: host, imap_port: port, imap_user: user, ...(password ? { password } : {}),
        allowed_senders: senders.split(/[،,\n]/).map((x) => x.trim()).filter(Boolean) });
      onDone();
    }}>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="البريد المخصّص" hint="البريد الذي يرسل إليه تطبيق الجوال، ولا تُقبل رسالة من غيره"><input className="input" dir="ltr" type="email" value={address} onChange={(e) => setAddress(e.target.value)} aria-label="البريد المخصّص" /></Field>
        <Field label="اسم الدخول"><input className="input" dir="ltr" value={user} onChange={(e) => setUser(e.target.value)} aria-label="اسم الدخول" autoComplete="off" /></Field>
        <Field label="خادم البريد (IMAP)" hint="تغيير الخادم أو اسم الدخول يمسح كلمة المرور المحفوظة؛ اكتبها من جديد"><input className="input" dir="ltr" value={host} onChange={(e) => setHost(e.target.value)} aria-label="خادم البريد" /></Field>
        <Field label="المنفذ"><input className="input" dir="ltr" inputMode="numeric" value={port} onChange={(e) => setPort(e.target.value)} aria-label="المنفذ" /></Field>
        <Field label="كلمة مرور البريد" hint={s.has_password ? "محفوظة. اتركها فارغة لتبقى كما هي" : "لـ Gmail: كلمة مرور التطبيقات"} className="sm:col-span-2">
          <input className="input" dir="ltr" type="password" value={password} onChange={(e) => setPassword(e.target.value)} aria-label="كلمة مرور البريد" autoComplete="new-password" /></Field>
        <Field label="المرسلون المسموحون" hint="أسماء مرسلي رسائل البنك كما تظهر في الجوال، يفصلها فاصلة" className="sm:col-span-2">
          <input className="input" value={senders} onChange={(e) => setSenders(e.target.value)} aria-label="المرسلون المسموحون" /></Field>
      </div>
      <Submit label="حفظ" onCancel={onCancel} />
    </ActionForm>
  );
}

function RuleForm({ r, onDone, onCancel }: { r: Partial<BankRule>; onDone: () => void; onCancel: () => void }) {
  const [keyword, setKeyword] = useState(r.keyword ?? "");
  const [kind, setKind] = useState<BankKind>(r.kind ?? "deposit");
  const [priority, setPriority] = useState(String(r.priority ?? 100));
  const [active, setActive] = useState(r.is_active ?? true);
  return (
    <ActionForm onSubmit={async () => { await bankApi.upsertRule({ id: r.id, keyword, kind, priority: Number(priority), is_active: active, version: r.version }); onDone(); }}>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="الكلمة كما تظهر في رسالة البنك" className="sm:col-span-2"><input className="input" value={keyword} onChange={(e) => setKeyword(e.target.value)} aria-label="الكلمة" /></Field>
        <Field label="نوع الحركة"><select className="input" value={kind} onChange={(e) => setKind(e.target.value as BankKind)} aria-label="نوع الحركة">
          {(Object.keys(KIND_AR) as BankKind[]).map((k) => <option key={k} value={k}>{KIND_AR[k]}</option>)}</select></Field>
        <Field label="الأولوية (الأصغر أولًا)"><input className="input" dir="ltr" inputMode="numeric" value={priority} onChange={(e) => setPriority(e.target.value)} aria-label="الأولوية" /></Field>
      </div>
      {r.id && <div className="mt-3"><Toggle checked={active} onChange={setActive} label="مفعّلة" /></div>}
      <Submit label="حفظ" onCancel={onCancel} />
    </ActionForm>
  );
}
