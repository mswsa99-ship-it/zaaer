/**
 * «الحركات البنكية» (the accounting stage, A6/A7; migration 0066): what the bank's messages said. Every movement in or
 * out of a branch's bank account — deposits, transfers, withdrawals, fees, POS fees and settlements — with its amount,
 * time, reference and the message it came from; the ones whose account could not be told apart wait for the owner.
 * The owner also sees every message as it arrived (kept raw first), why one was refused or not understood, and reads an
 * unread one again after adding a word in «بريد البنك».
 * A8 (migration 0067): a movement waits «بانتظار المطابقة» until the owner matches it with the records that explain it
 * (a transfer voucher, the card vouchers a terminal deposit covers, an expense, a platform payout) or turns it into a
 * voucher (an expense, the bank's fees, other income); a total that differs needs a reason and is booked.
 */
import { useEffect, useState } from "react";
import { Landmark, RotateCcw } from "lucide-react";
import { Link } from "react-router-dom";
import { bankApi, toArabicError, type BankMovement, type BankMessage, type BankMailSettings, type BankCandidates, type BankConvertAs } from "../../lib/api";
import { candidateKey, posDays, selectedTotal, suggestTargets, type PosDay } from "../../lib/bankMatch";
import { supabase } from "../../lib/supabase";
import { useBranch } from "../../lib/branch";
import { useAuth } from "../../lib/auth";
import { SectionTitle, Card, Spinner, LoadErrorCard, EmptyState, Badge, AmountBox, AmountGrid } from "../../components/ui";
import { Field, Modal, ActionForm, Submit, ReasonInput } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { formatCurrency, formatDateTime, todayISO } from "../../lib/utils";
import { KIND_AR } from "../admin/AdminBankMail";

const sar = (h: number) => formatCurrency(h / 100);
const Notice = ({ text }: { text: string }) => <div className="mb-4 rounded-xl border border-ink-100 bg-ink-50 p-3 text-sm text-ink-700" role="status">{text}</div>;
const MSG_STATUS: Record<BankMessage["status"], [string, string]> = {
  received: ["وصلت", "bg-ink-100 text-ink-700"], parsed: ["قُرئت", "bg-success-50 text-success-700"], duplicate_movement: ["مكررة لحركة سابقة", "bg-ink-100 text-ink-700"],
  unparsed: ["لم تُفهم", "bg-warning-50 text-warning-700"], rejected: ["مرفوضة", "bg-danger-50 text-danger-700"],
};
type View = "branch" | "unassigned" | "messages";

export default function BankMovements() {
  const { branchId } = useBranch();
  const { can } = useAuth();
  const owner = can("bank.manage");
  const [view, setView] = useState<View>("branch");
  const [from, setFrom] = useState(todayISO().slice(0, 8) + "01");
  const [to, setTo] = useState(todayISO());
  const views: Array<[View, string]> = [["branch", "حركات الفرع"], ...(owner ? [["unassigned", "غير المنسوبة"], ["messages", "الرسائل كما وصلت"]] as Array<[View, string]> : [])];

  return (
    <div>
      <SectionTitle title="الحركات البنكية" subtitle="ما قالته رسائل البنك: كل داخل وخارج من حساب الفرع" action={<BranchPicker />} />
      <div className="mb-4 flex gap-1 overflow-x-auto rounded-2xl bg-ink-50 p-1" role="tablist" aria-label="عرض الحركات">
        {views.map(([v, label]) => (
          <button key={v} type="button" role="tab" aria-selected={view === v} onClick={() => setView(v)}
            className={`min-h-[44px] shrink-0 rounded-xl px-3 text-sm font-semibold transition ${view === v ? "bg-white text-brand-700 shadow-sm" : "text-ink-500 hover:text-ink-700"}`}>{label}</button>
        ))}
      </div>
      {view !== "messages" && (
        <Card className="mb-4">
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="من"><input type="date" className="input" dir="ltr" max={to} value={from} onChange={(e) => e.target.value && setFrom(e.target.value)} aria-label="من" /></Field>
            <Field label="إلى"><input type="date" className="input" dir="ltr" min={from} max={todayISO()} value={to} onChange={(e) => e.target.value && setTo(e.target.value)} aria-label="إلى" /></Field>
          </div>
        </Card>
      )}
      {view === "branch" && branchId && <Movements branch={branchId} from={from} to={to} />}
      {view === "unassigned" && <Movements branch={null} from={from} to={to} unassignedOnly />}
      {view === "messages" && <Messages />}
    </div>
  );
}

function Movements({ branch, from, to, unassignedOnly }: { branch: string | null; from: string; to: string; unassignedOnly?: boolean }) {
  const [rows, setRows] = useState<BankMovement[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [assigning, setAssigning] = useState<BankMovement | null>(null);
  const [act, setAct] = useState<{ m: BankMovement; what: "match" | "convert" | "unmatch" } | null>(null);
  const [waitingOnly, setWaitingOnly] = useState(false);
  const { can } = useAuth();
  const owner = can("bank.manage");
  const done = () => { setAct(null); setTick((t) => t + 1); };
  useEffect(() => {
    let alive = true; setRows(null); setError(null);
    bankApi.movements(branch, from, to).then((d) => { if (alive) setRows(unassignedOnly ? d.filter((x) => !x.branch_id) : d); }, (e) => { if (alive) setError(toArabicError(e)); });
    return () => { alive = false; };
  }, [branch, from, to, unassignedOnly, tick]);
  if (error) return <LoadErrorCard message={error} onRetry={() => setTick((t) => t + 1)} />;
  if (!rows) return <div className="py-10 text-center"><Spinner /></div>;
  const waiting = rows.filter((r) => r.status === "pending").length;
  const shown = waitingOnly ? rows.filter((r) => r.status === "pending") : rows;
  const tin = rows.filter((r) => r.direction === "in").reduce((s, r) => s + r.amount_halalas, 0);
  const tout = rows.filter((r) => r.direction === "out").reduce((s, r) => s + r.amount_halalas, 0);
  const win = rows.filter((r) => r.status === "pending" && r.direction === "in").reduce((s, r) => s + r.amount_halalas, 0);
  const wout = rows.filter((r) => r.status === "pending" && r.direction === "out").reduce((s, r) => s + r.amount_halalas, 0);
  return (
    <>
      {!unassignedOnly && <Card className="mb-4"><AmountGrid testId="bank-totals">
        <AmountBox label="الداخل" value={sar(tin)} tone="text-success-600" /><AmountBox label="الخارج" value={sar(tout)} tone="text-danger-600" /><AmountBox label="بانتظار المطابقة" value={<span data-testid="bank-waiting">{waiting}</span>} tone={waiting ? "text-warning-700" : "text-success-600"} />
      </AmountGrid>
        {waiting > 0 && <p className="mt-3 text-sm text-ink-600" data-testid="bank-waiting-money">غير المطابَق: داخل <span dir="ltr" className="tabular-nums">{sar(win)}</span> · خارج <span dir="ltr" className="tabular-nums">{sar(wout)}</span>. ما يحتاج مطابقة مع سنداته أو تحويلًا لسند؛ لا يُقيَّد شيء منه في الدفاتر قبل ذلك.</p>}
        <label className="mt-3 flex min-h-[44px] items-center gap-2 text-sm text-ink-700"><input type="checkbox" checked={waitingOnly} onChange={(e) => setWaitingOnly(e.target.checked)} /> بانتظار المطابقة فقط</label>
      </Card>}
      {unassignedOnly && <p className="mb-3 text-sm text-ink-600">أرقام الحساب في هذه الرسائل لا تطابق حسابًا واحدًا من حسابات الفروع (مثل نهاية يشترك فيها حسابان)، فلا تُنسب تلقائيًا ولا تُدمج. انسب كل حركة لحساب فرعها بسبب. ولتقليل ذلك راجع قاعدة رقم الحساب في <Link to="/admin/cash-accounts" className="text-brand-700 underline">الصناديق والحسابات</Link>.</p>}
      {shown.length === 0 ? <EmptyState icon={<Landmark className="h-10 w-10" />} title={unassignedOnly ? "لا حركات تنتظر النسبة" : "لا حركات في هذه الفترة"} /> : (
        <Card>
          <ul className="divide-y divide-ink-50" data-testid="bank-movements">
            {shown.map((r) => (
              <li key={r.id} className="py-3" data-testid="bank-movement">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <span className="font-semibold">{KIND_AR[r.kind]}{r.reference ? <span className="ms-2 font-mono text-xs text-ink-400" dir="ltr">{r.reference}</span> : null}</span>
                  <span className={`tabular-nums font-semibold ${r.direction === "in" ? "text-success-600" : "text-danger-600"}`} dir="ltr">{r.direction === "in" ? "+" : "−"}{sar(r.amount_halalas)}</span>
                </div>
                <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-xs text-ink-500">
                  <span>{formatDateTime(r.occurred_at)}</span>
                  <span>{r.branch ? `${r.branch} — ${r.account}` : <>غير منسوبة <span dir="ltr" className="font-mono">{r.account_hint ?? ""}</span></>}</span>
                  {r.balance_halalas != null && <span>الرصيد بعدها: <span dir="ltr">{sar(r.balance_halalas)}</span></span>}
                  <span>{r.status === "pending" ? "بانتظار المطابقة" : r.status === "matched" ? "مطابقة" : "حُوّلت لسند"}</span>
                </div>
                {r.match && <p className="mt-1 text-xs text-ink-600" data-testid="bank-match">{r.match.kind === "convert" ? "حُوّلت إلى: " : "طوبقت مع: "}{r.match.label}
                  {r.match.difference_halalas ? <> — فرق <span dir="ltr">{sar(r.match.difference_halalas)}</span>{r.match.reason ? ` (${r.match.reason})` : ""}</> : null}</p>}
                <div className="flex flex-wrap gap-1">
                  {!r.branch_id && owner && <button type="button" className="btn-ghost mt-1 min-h-[44px] text-xs" onClick={() => setAssigning(r)}>نسبتها لحساب فرع</button>}
                  {owner && r.branch_id && r.status === "pending" && <>
                    <button type="button" className="btn-secondary mt-1 min-h-[44px] text-xs" onClick={() => setAct({ m: r, what: "match" })}>مطابقة</button>
                    <button type="button" className="btn-ghost mt-1 min-h-[44px] text-xs" onClick={() => setAct({ m: r, what: "convert" })}>{r.direction === "out" ? "تحويلها لسند" : "تسجيلها إيرادًا"}</button>
                  </>}
                  {owner && r.match && !(r.match.kind === "convert" && r.match.type === "expense") && <button type="button" className="btn-ghost mt-1 min-h-[44px] text-xs" onClick={() => setAct({ m: r, what: "unmatch" })}>فك المطابقة</button>}
                </div>
                {r.text && <details className="mt-1 text-xs text-ink-500"><summary className="cursor-pointer">نص الرسالة{r.channel === "notification" ? " (إشعار)" : ""}</summary><p className="mt-1 whitespace-pre-line">{r.text}</p></details>}
              </li>
            ))}
          </ul>
        </Card>
      )}
      <Modal open={!!act} title={act?.what === "match" ? "مطابقة الحركة" : act?.what === "convert" ? (act.m.direction === "out" ? "تحويل الحركة إلى سند" : "تسجيل الحركة إيرادًا") : "فك المطابقة"} onClose={() => setAct(null)}>
        {act?.what === "match" && <MatchForm m={act.m} onDone={done} onCancel={() => setAct(null)} />}
        {act?.what === "convert" && <ConvertForm m={act.m} onDone={done} onCancel={() => setAct(null)} />}
        {act?.what === "unmatch" && <UnmatchForm m={act.m} onDone={done} onCancel={() => setAct(null)} />}
      </Modal>
      <Modal open={!!assigning} title="نسبة الحركة لحساب فرع" onClose={() => setAssigning(null)}>
        {assigning && <AssignForm m={assigning} onDone={() => { setAssigning(null); setTick((t) => t + 1); }} onCancel={() => setAssigning(null)} />}
      </Modal>
    </>
  );
}

const signed = (h: number) => (h < 0 ? "−" : "") + sar(Math.abs(h));

function MatchForm({ m, onDone, onCancel }: { m: BankMovement; onDone: () => void; onCancel: () => void }) {
  const [data, setData] = useState<BankCandidates | null>(null);
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [reason, setReason] = useState("");
  const [loadError, setLoadError] = useState<string | null>(null);
  useEffect(() => {
    bankApi.candidates(m.id).then((c) => { setData(c); setPicked(new Set(suggestTargets(c.records, m.amount_halalas, m.kind))); },
      (e) => { setLoadError(toArabicError(e)); setData({ records: [], pos_closings: [] }); });
  }, [m.id, m.amount_halalas, m.kind]);
  const records = data?.records ?? [];
  const days = posDays(records);
  const total = selectedTotal(records, picked);
  const diff = picked.size ? m.amount_halalas - total : 0;
  const toggle = (k: string) => setPicked((p) => { const n = new Set(p); if (n.has(k)) n.delete(k); else n.add(k); return n; });
  const allOf = (d: PosDay) => d.keys.every((k) => picked.has(k));
  const toggleDay = (d: PosDay) => setPicked((p) => { const n = new Set(p); const all = d.keys.every((k) => n.has(k)); d.keys.forEach((k) => (all ? n.delete(k) : n.add(k))); return n; });
  const closing = (day: string) => data?.pos_closings.find((c) => c.day === day);
  return (
    <ActionForm onSubmit={async () => {
      if (!picked.size) throw new Error("VALIDATION: targets");
      await bankApi.match(m.id, records.filter((r) => picked.has(candidateKey(r))).map((r) => ({ type: r.type, id: r.id })), reason.trim() || null); onDone();
    }}>
      <p className="mb-3 text-sm text-ink-600">{KIND_AR[m.kind]} <span dir="ltr">{sar(m.amount_halalas)}</span> — {formatDateTime(m.occurred_at)}. حدّد السجل الذي يفسّر الحركة، أو سندات الشبكة التي يغطيها الإيداع. السجلات من نفس الحساب حول يوم الحركة، والمبلغ المطابق أولًا.</p>
      {!data ? <div className="py-4 text-center"><Spinner /></div> : loadError ? <p role="alert" className="text-sm text-danger-600">تعذّر جلب السجلات: {loadError}</p> : records.length === 0 ? <p className="text-sm text-ink-500">لا سجل مناسب. يمكنك تحويل الحركة إلى سند بدلًا من ذلك.</p> : (
        <>
          {days.length > 0 && (
            <details className="mb-3" open={m.kind === "pos_settlement"} data-testid="bank-pos-days">
              <summary className="min-h-[44px] cursor-pointer py-3 text-sm font-semibold text-ink-700">سندات الشبكة حسب اليوم <span className="ms-2 text-xs font-normal text-ink-500">(ضغطة تحدّد سندات اليوم كلها)</span></summary>
              <ul className="max-h-56 space-y-1 overflow-y-auto">
                {days.map((d) => { const c = closing(d.day); return (
                  <li key={d.day}><button type="button" aria-pressed={allOf(d)} onClick={() => toggleDay(d)}
                    className={`flex min-h-[44px] w-full flex-wrap items-center justify-between gap-x-3 rounded-xl border px-3 py-2 text-start text-sm ${allOf(d) ? "border-brand-500 bg-brand-50" : "border-ink-100"}`}>
                    <span>يوم <span dir="ltr">{d.day}</span> · عدد السندات <span dir="ltr">{d.count}</span>
                      <span className="block text-xs text-ink-500">{c ? <>الجهاز في إقفال اليوم: <span dir="ltr">{c.entered_halalas == null ? "—" : sar(c.entered_halalas)}</span></> : "لم يُرسل إقفال هذا اليوم بعد"}</span></span>
                    <span dir="ltr" className={`tabular-nums ${d.total_halalas === m.amount_halalas ? "font-semibold text-success-600" : "text-ink-700"}`}>{signed(d.total_halalas)}</span>
                  </button></li>
                ); })}
              </ul>
            </details>
          )}
          <ul className="max-h-64 space-y-1 overflow-y-auto" data-testid="bank-candidates">
            {records.map((c) => { const k = candidateKey(c); return (
              <li key={k}><label className="flex min-h-[44px] cursor-pointer items-center gap-2 rounded-xl border border-ink-100 p-2 text-sm">
                <input type="checkbox" checked={picked.has(k)} onChange={() => toggle(k)} />
                <span className="min-w-0 flex-1">{c.label} <span className="font-mono text-xs text-ink-400" dir="ltr">{c.number}</span><span className="block text-xs text-ink-500">{formatDateTime(c.at)}</span></span>
                <span dir="ltr" className={`tabular-nums ${c.exact ? "font-semibold text-success-600" : "text-ink-700"}`}>{signed(c.signed_halalas)}</span>
              </label></li>
            ); })}
          </ul>
          <p className="mt-3 text-sm text-ink-700" data-testid="bank-match-total" aria-live="polite">المحدّد: <span dir="ltr" className="tabular-nums font-semibold">{signed(total)}</span> · الحركة: <span dir="ltr" className="tabular-nums">{sar(m.amount_halalas)}</span></p>
        </>
      )}
      {diff !== 0 && <><p className="mt-2 text-sm text-warning-700" data-testid="bank-match-diff">المحدّد {diff > 0 ? "أقل من" : "أكثر من"} الحركة بـ <span dir="ltr">{sar(Math.abs(diff))}</span>؛ يُقيَّد الفرق {(m.direction === "in") === (diff > 0) ? "إيرادًا آخر" : "رسومًا بنكية"}.</p>
        <ReasonInput value={reason} onChange={setReason} label="سبب الفرق (إلزامي)" placeholder="مثال: عمولة الشبكة أو رسوم التحويل" /></>}
      <Submit label="مطابقة" onCancel={onCancel} />
    </ActionForm>
  );
}

function ConvertForm({ m, onDone, onCancel }: { m: BankMovement; onDone: () => void; onCancel: () => void }) {
  const out = m.direction === "out";
  const [as, setAs] = useState<BankConvertAs>(out ? (m.kind === "fee" || m.kind === "pos_fee" ? "fees" : "expense") : "income");
  const [cats, setCats] = useState<Array<{ id: string; name: string }>>([]);
  const [cat, setCat] = useState("");
  const [desc, setDesc] = useState("");
  useEffect(() => { if (out) supabase.from("expense_categories").select("id, name").eq("is_active", true).order("sort_order").then(({ data }) => { const c = (data ?? []) as Array<{ id: string; name: string }>; setCats(c); setCat((x) => x || (c[0]?.id ?? "")); }); }, [out]);
  return (
    <ActionForm onSubmit={async () => {
      if (as !== "fees" && !desc.trim()) throw new Error("VALIDATION: description");
      if (as === "expense" && !cat) throw new Error("VALIDATION: category");
      await bankApi.convert(m.id, { as, ...(desc.trim() ? { description: desc.trim() } : {}), ...(as === "expense" ? { category_id: cat } : {}) }); onDone();
    }}>
      <p className="mb-3 text-sm text-ink-600">{KIND_AR[m.kind]} <span dir="ltr">{sar(m.amount_halalas)}</span> — {formatDateTime(m.occurred_at)}</p>
      {out && (
        <fieldset className="mb-3">
          <legend className="mb-1 text-sm font-semibold text-ink-700">نوع السند</legend>
          <label className="flex min-h-[44px] cursor-pointer items-center gap-2 text-sm"><input type="radio" name="convert-as" checked={as === "fees"} onChange={() => setAs("fees")} /> رسوم بنكية <span className="text-xs text-ink-500">(تُقيَّد في حساب رسوم وفروق المطابقة البنكية؛ ولتصنيف مصروف آخر اختر سند صرف)</span></label>
          <label className="flex min-h-[44px] cursor-pointer items-center gap-2 text-sm"><input type="radio" name="convert-as" checked={as === "expense"} onChange={() => setAs("expense")} /> سند صرف بتصنيف <span className="text-xs text-ink-500">(رسالة البنك إيصاله)</span></label>
        </fieldset>
      )}
      {!out && <p className="mb-3 text-sm text-ink-600">يُقيَّد المبلغ إيرادًا آخر في الحساب البنكي. استعمل هذا لمال دخل البنك ولا سند له في النظام؛ التحويل أو إيداع الشبكة الذي له سندات يُطابَق معها حتى لا يُحسب مرتين.</p>}
      {as === "expense" && <Field label="تصنيف المصروف"><select className="input" value={cat} onChange={(e) => setCat(e.target.value)} aria-label="تصنيف المصروف">{cats.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>}
      <Field label={as === "fees" ? "الوصف (اختياري)" : "الوصف"}><input className="input" value={desc} onChange={(e) => setDesc(e.target.value)} aria-label="الوصف" maxLength={300} placeholder={as === "fees" ? (m.kind === "pos_fee" ? "رسوم نقاط البيع" : "رسوم بنكية") : undefined} /></Field>
      <Submit label={as === "fees" ? "تسجيل الرسوم" : as === "expense" ? "إصدار سند الصرف" : "تسجيل الإيراد"} onCancel={onCancel} />
    </ActionForm>
  );
}

function UnmatchForm({ m, onDone, onCancel }: { m: BankMovement; onDone: () => void; onCancel: () => void }) {
  const [reason, setReason] = useState("");
  return (
    <ActionForm onSubmit={async () => { if (!reason.trim()) throw new Error("VALIDATION: reason"); await bankApi.unmatch(m.id, reason.trim()); onDone(); }}>
      <p className="mb-3 text-sm text-ink-600">تعود الحركة «بانتظار المطابقة»، ويبقى ما جرى في السجل. {m.match?.label}</p>
      <ReasonInput value={reason} onChange={setReason} />
      <Submit label="فك المطابقة" onCancel={onCancel} />
    </ActionForm>
  );
}

function AssignForm({ m, onDone, onCancel }: { m: BankMovement; onDone: () => void; onCancel: () => void }) {
  const [accounts, setAccounts] = useState<BankMailSettings["accounts"]>([]);
  const [account, setAccount] = useState("");
  const [reason, setReason] = useState("");
  useEffect(() => { bankApi.settings().then((s) => { setAccounts(s.accounts); setAccount((a) => a || s.accounts[0]?.id || ""); }, () => setAccounts([])); }, []);
  return (
    <ActionForm onSubmit={async () => { if (!reason.trim()) throw new Error("VALIDATION: reason"); await bankApi.assign(m.id, account, reason.trim()); onDone(); }}>
      <p className="mb-3 text-sm text-ink-600">{KIND_AR[m.kind]} <span dir="ltr">{sar(m.amount_halalas)}</span> — الأرقام في الرسالة: <span dir="ltr" className="font-mono">{m.account_hint ?? "—"}</span></p>
      <Field label="حساب الفرع"><select className="input" value={account} onChange={(e) => setAccount(e.target.value)} aria-label="حساب الفرع">
        {accounts.map((a) => <option key={a.id} value={a.id}>{a.branch} — {a.name}{a.prefix && a.suffix ? ` (${a.prefix}…${a.suffix})` : ""}</option>)}</select></Field>
      <ReasonInput value={reason} onChange={setReason} />
      <Submit label="نسبتها" onCancel={onCancel} />
    </ActionForm>
  );
}

function Messages() {
  const [status, setStatus] = useState<string>("");
  const [rows, setRows] = useState<BankMessage[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let alive = true; setRows(null); setError(null);
    bankApi.messages(status || null).then((d) => { if (alive) setRows(d); }, (e) => { if (alive) setError(toArabicError(e)); });
    return () => { alive = false; };
  }, [status, tick]);
  const reparse = async (id: string) => {
    setNotice(null);
    try { const r = await bankApi.reparse(id); setNotice(r.status === "unparsed" ? "ما زالت غير مفهومة: أضف كلمتها في «بريد البنك»." : r.status === "rejected" ? `ما زالت مرفوضة: ${r.reason ?? ""}` : "قُرئت الرسالة."); setTick((t) => t + 1); }
    catch (e) { setNotice(toArabicError(e)); }
  };
  return (
    <>
      <Card className="mb-4"><div className="flex flex-wrap items-end justify-between gap-3">
        <Field label="الحالة"><select className="input" value={status} onChange={(e) => setStatus(e.target.value)} aria-label="الحالة">
          <option value="">الكل</option>{(Object.keys(MSG_STATUS) as BankMessage["status"][]).map((k) => <option key={k} value={k}>{MSG_STATUS[k][0]}</option>)}</select></Field>
        <Link to="/admin/bank-mail" className="text-sm text-brand-700 underline">إعداد بريد البنك وكلماته</Link>
      </div></Card>
      {notice && <Notice text={notice} />}
      {error ? <LoadErrorCard message={error} onRetry={() => setTick((t) => t + 1)} /> : !rows ? <div className="py-10 text-center"><Spinner /></div> :
        rows.length === 0 ? <EmptyState icon={<Landmark className="h-10 w-10" />} title="لا رسائل" description="تظهر هنا رسائل البنك عند ربط البريد وتطبيق الجوال" /> : (
        <Card>
          <ul className="divide-y divide-ink-50" data-testid="bank-messages">
            {rows.map((m) => (
              <li key={m.id} className="py-3" data-testid="bank-message">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="text-xs text-ink-500">{formatDateTime(m.received_at)} — {m.sms_sender ?? m.mail_from ?? "—"}{m.channel === "notification" ? " (إشعار)" : ""}</span>
                  <Badge className={MSG_STATUS[m.status][1]}>{MSG_STATUS[m.status][0]}</Badge>
                </div>
                <p className="mt-1 whitespace-pre-line text-sm">{m.text}</p>
                {m.reason && <p className="mt-1 text-xs text-ink-500">{m.reason}</p>}
                {(m.status === "unparsed" || m.status === "rejected") && <button type="button" className="btn-ghost mt-1 min-h-[44px] text-xs" onClick={() => reparse(m.id)}><RotateCcw className="h-4 w-4" /> اقرأها من جديد</button>}
              </li>
            ))}
          </ul>
        </Card>
      )}
    </>
  );
}
