/**
 * «الحركات البنكية» (the accounting stage, A6/A7; migration 0066): what the bank's messages said. Every movement in or
 * out of a branch's bank account — deposits, transfers, withdrawals, fees, POS fees and settlements — with its amount,
 * time, reference and the message it came from; the ones whose account could not be told apart wait for the owner.
 * The owner also sees every message as it arrived (kept raw first), why one was refused or not understood, and reads an
 * unread one again after adding a word in «بريد البنك». Matching a movement with the vouchers is the next step (A8).
 */
import { useEffect, useState } from "react";
import { Landmark, RotateCcw } from "lucide-react";
import { Link } from "react-router-dom";
import { bankApi, toArabicError, type BankMovement, type BankMessage, type BankMailSettings, type BankCandidate } from "../../lib/api";
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
        {waiting > 0 && <p className="mt-3 text-sm text-ink-600" data-testid="bank-waiting-money">غير المطابَق: داخل <span dir="ltr" className="tabular-nums">{sar(win)}</span> · خارج <span dir="ltr" className="tabular-nums">{sar(wout)}</span>. هذا الفرق بين كشف البنك وما سُجّل في النظام، ولا يدخل الدفاتر حتى تطابقه أو تحوّله لسند.</p>}
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
                    <button type="button" className="btn-ghost mt-1 min-h-[44px] text-xs" onClick={() => setAct({ m: r, what: "convert" })}>{r.direction === "out" ? "تحويلها لسند صرف" : "تسجيلها إيرادًا"}</button>
                  </>}
                  {owner && r.match && !(r.match.kind === "convert" && r.match.type === "expense") && <button type="button" className="btn-ghost mt-1 min-h-[44px] text-xs" onClick={() => setAct({ m: r, what: "unmatch" })}>فك المطابقة</button>}
                </div>
                {r.text && <details className="mt-1 text-xs text-ink-500"><summary className="cursor-pointer">نص الرسالة{r.channel === "notification" ? " (إشعار)" : ""}</summary><p className="mt-1 whitespace-pre-line">{r.text}</p></details>}
              </li>
            ))}
          </ul>
        </Card>
      )}
      <Modal open={!!act} title={act?.what === "match" ? "مطابقة الحركة" : act?.what === "convert" ? (act.m.direction === "out" ? "تحويل الحركة إلى سند صرف" : "تسجيل الحركة إيرادًا") : "فك المطابقة"} onClose={() => setAct(null)}>
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

function MatchForm({ m, onDone, onCancel }: { m: BankMovement; onDone: () => void; onCancel: () => void }) {
  const [rows, setRows] = useState<BankCandidate[] | null>(null);
  const [pick, setPick] = useState<string>("");
  const [reason, setReason] = useState("");
  const [loadError, setLoadError] = useState<string | null>(null);
  useEffect(() => { bankApi.candidates(m.id).then((c) => { setRows(c); if (c[0]?.exact) setPick(c[0].type + ":" + c[0].id); }, (e) => { setLoadError(toArabicError(e)); setRows([]); }); }, [m.id]);
  const chosen = rows?.find((c) => c.type + ":" + c.id === pick);
  const diff = chosen ? m.amount_halalas - chosen.amount_halalas : 0;
  return (
    <ActionForm onSubmit={async () => { if (!chosen) throw new Error("VALIDATION: target"); await bankApi.match(m.id, chosen.type, chosen.id, reason.trim() || null); onDone(); }}>
      <p className="mb-3 text-sm text-ink-600">{KIND_AR[m.kind]} <span dir="ltr">{sar(m.amount_halalas)}</span> — {formatDateTime(m.occurred_at)}. السجلات المعروضة من نفس الحساب حول يوم الحركة، والمبلغ المطابق أولًا.</p>
      {!rows ? <div className="py-4 text-center"><Spinner /></div> : loadError ? <p role="alert" className="text-sm text-danger-600">تعذّر جلب السجلات: {loadError}</p> : rows.length === 0 ? <p className="text-sm text-ink-500">لا سجل مناسب. يمكنك تحويل الحركة إلى سند بدلًا من ذلك.</p> : (
        <ul className="max-h-72 space-y-1 overflow-y-auto" data-testid="bank-candidates">
          {rows.map((c) => (
            <li key={c.type + c.id}><label className="flex min-h-[44px] cursor-pointer items-center gap-2 rounded-xl border border-ink-100 p-2 text-sm">
              <input type="radio" name="pick" checked={pick === c.type + ":" + c.id} onChange={() => setPick(c.type + ":" + c.id)} />
              <span className="min-w-0 flex-1">{c.label} <span className="font-mono text-xs text-ink-400" dir="ltr">{c.number}</span><span className="block text-xs text-ink-500">{formatDateTime(c.at)}</span></span>
              <span dir="ltr" className={`tabular-nums ${c.exact ? "font-semibold text-success-600" : "text-ink-700"}`}>{sar(c.amount_halalas)}</span>
            </label></li>
          ))}
        </ul>
      )}
      {diff !== 0 && <><p className="mt-3 text-sm text-warning-700">المبلغ يختلف بـ <span dir="ltr">{sar(diff)}</span>؛ يُقيَّد الفرق {(m.direction === "in") === (diff > 0) ? "إيرادًا آخر" : "رسومًا بنكية"}.</p>
        <ReasonInput value={reason} onChange={setReason} label="سبب الفرق (إلزامي)" /></>}
      <Submit label="مطابقة" onCancel={onCancel} />
    </ActionForm>
  );
}

function ConvertForm({ m, onDone, onCancel }: { m: BankMovement; onDone: () => void; onCancel: () => void }) {
  const [cats, setCats] = useState<Array<{ id: string; name: string }>>([]);
  const [cat, setCat] = useState("");
  const [desc, setDesc] = useState("");
  useEffect(() => { if (m.direction === "out") supabase.from("expense_categories").select("id, name").eq("is_active", true).order("sort_order").then(({ data }) => { const c = (data ?? []) as Array<{ id: string; name: string }>; setCats(c); setCat((x) => x || (c.find((y) => y.name.includes("بنك"))?.id ?? c[0]?.id ?? "")); }); }, [m.direction]);
  return (
    <ActionForm onSubmit={async () => { if (!desc.trim()) throw new Error("VALIDATION: description"); await bankApi.convert(m.id, { description: desc.trim(), ...(m.direction === "out" ? { category_id: cat } : {}) }); onDone(); }}>
      <p className="mb-3 text-sm text-ink-600">{m.direction === "out" ? "يصدر سند صرف من الحساب البنكي بمبلغ الحركة وتاريخها، ورسالة البنك إيصاله." : "يُقيَّد المبلغ إيرادًا آخر في الحساب البنكي."} <span dir="ltr">{sar(m.amount_halalas)}</span></p>
      {m.direction === "out" && <Field label="تصنيف المصروف"><select className="input" value={cat} onChange={(e) => setCat(e.target.value)} aria-label="تصنيف المصروف">{cats.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>}
      <Field label="الوصف"><input className="input" value={desc} onChange={(e) => setDesc(e.target.value)} aria-label="الوصف" maxLength={300} /></Field>
      <Submit label={m.direction === "out" ? "إصدار سند الصرف" : "تسجيل الإيراد"} onCancel={onCancel} />
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
