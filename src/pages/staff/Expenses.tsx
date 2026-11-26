/**
 * «المصروفات» (the accounting stage, A4; migration 0064): the expense voucher (سند صرف) from the branch's cash box or bank
 * account, with a category from the owner's list, a description and its receipt (1–5 images or PDF, 2 MB each). The
 * list shows each voucher with its files; the management cancels one only with a reason, which is recorded and sent to
 * «بحاجة لمراجعة». The categories are the owner's list (a setting, edited here by who holds «التعريفات»).
 */
import { useEffect, useRef, useState } from "react";
import { Receipt, Paperclip, Plus, Ban, Tags } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { expenseApi, newIdempotencyKey, toArabicError, type CashAccount, type ExpenseCategory, type ExpenseRow } from "../../lib/api";
import { useBranch } from "../../lib/branch";
import { useAuth } from "../../lib/auth";
import { individualAllows } from "../../lib/individualPermissions";
import { SectionTitle, Card, Badge, Spinner, LoadErrorCard, EmptyState, AmountBox, AmountGrid } from "../../components/ui";
import { Field, MoneyInput, Modal, ActionForm, Submit, ReasonInput } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";
import { formatCurrency, formatDateTime, todayISO, addDaysISO } from "../../lib/utils";
import { DateRangePicker } from "../../components/DateRangePicker";

const sar = (h: number) => formatCurrency(h / 100);
const MAX_FILES = 5, MAX_BYTES = 2 * 1024 * 1024;

/** open one file of an expense in a new tab (it is read through the server, in its branch) */
export async function openAttachment(id: string) {
  const f = await expenseApi.attachment(id);
  const bin = atob(f.data_base64); const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const url = URL.createObjectURL(new Blob([bytes], { type: f.mime }));
  window.open(url, "_blank", "noopener");
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}

export default function Expenses() {
  const { branchId, branches, allBranches } = useBranch();
  const { can, permissions, profile: me } = useAuth();
  // expense categories (candidate, UNADOPTED): an individual non-owner follows the /staff/expenses page grant (add = new category, edit = rename/stop), every other account keeps the 'definitions' capability
  const pageAccess = permissions.pageAccess;
  const individualCats = !!pageAccess && pageAccess.mode === "individual" && me?.role !== "owner";
  const catAdd = individualCats && pageAccess ? individualAllows(pageAccess, "/staff/expenses", "add") : can("definitions");
  const catEdit = individualCats && pageAccess ? individualAllows(pageAccess, "/staff/expenses", "edit") : can("definitions");
  const [from, setFrom] = useState(addDaysISO(todayISO(), -6));
  const [to, setTo] = useState(todayISO());
  const [rows, setRows] = useState<(ExpenseRow & { branch_name?: string })[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [creating, setCreating] = useState(false);
  const [cancelling, setCancelling] = useState<ExpenseRow | null>(null);
  const [reason, setReason] = useState("");
  const [cats, setCats] = useState(false);
  const [openErr, setOpenErr] = useState<string | null>(null);

  useEffect(() => {
    if (!branchId) return;
    let alive = true; setError(null); setRows(null);
    // «جميع الفروع» (owner): every branch's expenses for the period in one list, newest first; read-only (no new voucher here)
    const load = allBranches
      ? Promise.all(branches.map((b) => expenseApi.list(b.id, from, to).then((r) => r.map((x) => ({ ...x, branch_name: b.name_ar }))))).then((l) => l.flat().sort((x, y) => (x.occurred_at < y.occurred_at ? 1 : -1)))
      : expenseApi.list(branchId, from, to);
    load.then((r) => { if (alive) setRows(r); }, (e) => { if (alive) setError(toArabicError(e)); });
    return () => { alive = false; };
  }, [branchId, from, to, tick, allBranches, branches]);

  const live = (rows ?? []).filter((r) => r.status === "approved");
  const total = live.reduce((s, r) => s + r.amount_halalas, 0);
  const cash = live.filter((r) => r.account_kind === "cash_box").reduce((s, r) => s + r.amount_halalas, 0);

  return (
    <div>
      <SectionTitle title="المصروفات" subtitle="سندات الصرف من صندوق الفرع أو حسابه البنكي، بتصنيفها ومرفقها" action={
        <div className="flex min-w-0 flex-wrap items-center gap-2"><BranchPicker allowAll />
          {(catAdd || catEdit) && <button type="button" className="btn-outline text-sm" onClick={() => setCats(true)}><Tags className="h-4 w-4" /> التصنيفات</button>}
          {can("expense.create") && !allBranches && <button type="button" className="btn-primary text-sm" onClick={() => setCreating(true)}><Plus className="h-4 w-4" /> سند صرف</button>}
        </div>} />
      <Card className="mb-4">
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="اليوم أو الفترة" className="sm:col-span-2"><DateRangePicker label="اليوم أو الفترة" from={from} to={to} max={todayISO()} onChange={(a, b) => { setFrom(a); setTo(b); }} /></Field>
        </div>
        <AmountGrid className="mt-3" testId="expense-totals">
          <AmountBox label="مجموع المصروفات" value={sar(total)} />
          <AmountBox label="من الصندوق" value={sar(cash)} />
          <AmountBox label="من الحساب البنكي" value={sar(total - cash)} />
          <AmountBox label="عدد السندات" value={live.length} />
        </AmountGrid>
      </Card>
      {openErr && <p className="mb-3 text-sm text-danger-600" role="alert">{openErr}</p>}
      {error ? <LoadErrorCard message={error} onRetry={() => setTick((t) => t + 1)} /> : rows == null ? <div className="py-10 text-center"><Spinner /></div> : rows.length === 0 ? (
        <EmptyState icon={<Receipt className="h-10 w-10" />} title="لا مصروفات في هذه الفترة" description={can("expense.create") ? "أضف سند صرف بزر «سند صرف» مع صورة الفاتورة." : undefined} />
      ) : (
        <Card>
          <div className="divide-y divide-ink-50" data-testid="expense-list">
            {rows.map((r) => (
              <div key={r.id} className={`py-3 ${r.status === "cancelled" ? "opacity-60" : ""}`} data-testid="expense-row">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <span className="font-semibold text-ink-800">{r.description}</span>
                  <span dir="ltr" className={`font-bold tabular-nums ${r.status === "cancelled" ? "line-through" : "text-danger-600"}`}>{sar(r.amount_halalas)}</span>
                </div>
                <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-ink-500">
                  <span className="font-mono" dir="ltr">{r.number}</span>
                  {allBranches && r.branch_name && <Badge className="bg-rai-spark-tint text-rai-spark-text">{r.branch_name}</Badge>}
                  <span>{formatDateTime(r.occurred_at)}</span>
                  <Badge className="bg-ink-100 text-ink-600">{r.category ?? "—"}</Badge>
                  <span>{r.account_kind === "cash_box" ? "من الصندوق" : "من الحساب البنكي"}{r.reference ? <> · <span dir="ltr">{r.reference}</span></> : null}</span>
                  {r.payee && <span>المستفيد: {r.payee}</span>}
                  {r.created_by && <span>{r.created_by}</span>}
                  {r.status === "cancelled" && <Badge className="bg-danger-500/10 text-danger-600">ملغى: {r.cancel_reason}</Badge>}
                </div>
                <div className="mt-2 flex flex-wrap items-center gap-2">
                  {r.attachments.map((a, i) => (
                    <button key={a.id} type="button" className="btn-ghost min-h-[44px] text-xs" onClick={() => { setOpenErr(null); openAttachment(a.id).catch((e) => setOpenErr(toArabicError(e))); }}>
                      <Paperclip className="h-3.5 w-3.5" /> {a.file_name ?? `المرفق ${i + 1}`}
                    </button>
                  ))}
                  {r.status === "approved" && can("expense.cancel") && <button type="button" className="btn-ghost min-h-[44px] text-xs text-danger-600" onClick={() => { setReason(""); setCancelling(r); }}><Ban className="h-3.5 w-3.5" /> إلغاء</button>}
                </div>
              </div>
            ))}
          </div>
        </Card>
      )}
      <Modal open={creating} title="سند صرف جديد" onClose={() => setCreating(false)} wide>
        {creating && branchId && <ExpenseForm branchId={branchId} onDone={() => { setCreating(false); setTick((t) => t + 1); }} onCancel={() => setCreating(false)} />}
      </Modal>
      <Modal open={!!cancelling} title="إلغاء سند صرف" onClose={() => setCancelling(null)}>
        {cancelling && (
          <ActionForm onSubmit={async () => { if (!reason.trim()) throw new Error("VALIDATION: reason"); await expenseApi.cancel(cancelling.id, reason.trim()); setCancelling(null); setTick((t) => t + 1); }}>
            <p className="mb-3 text-sm text-ink-600">يبقى السند <span dir="ltr" className="font-mono">{cancelling.number}</span> ظاهرًا بحالة «ملغى»، ويخرج من دفتر الحركة، ويصل الإلغاء للمراجعة.</p>
            <ReasonInput value={reason} onChange={setReason} />
            <Submit label="إلغاء السند" danger onCancel={() => setCancelling(null)} cancelLabel="رجوع" />
          </ActionForm>
        )}
      </Modal>
      <Modal open={cats} title="تصنيفات المصروفات" onClose={() => setCats(false)}>
        {cats && <Categories canAdd={catAdd} canEdit={catEdit} />}
      </Modal>
    </div>
  );
}

function ExpenseForm({ branchId, onDone, onCancel }: { branchId: string; onDone: () => void; onCancel: () => void }) {
  const { profile } = useAuth();
  const [accounts, setAccounts] = useState<CashAccount[]>([]);
  const [cats, setCats] = useState<ExpenseCategory[]>([]);
  const [accountId, setAccountId] = useState("");
  const [categoryId, setCategoryId] = useState("");
  const [amount, setAmount] = useState<number | null>(null);
  const [day, setDay] = useState(todayISO());
  const [payee, setPayee] = useState("");
  const [desc, setDesc] = useState("");
  const [reference, setReference] = useState("");
  const [files, setFiles] = useState<File[]>([]);
  const [fileErr, setFileErr] = useState<string | null>(null);
  const [amountErr, setAmountErr] = useState<string | null>(null);   // an empty save marks every missing field, not only the first one thrown
  const [key] = useState(newIdempotencyKey());

  // 6.5 (U4): what is typed survives a reload (this tab, per branch) and the form offers to restore it; the receipt file is never stored
  const draftKey = profile?.id && profile.organization_id ? `zaaer:expense-draft:${profile.id}:${profile.organization_id}:${branchId}` : null;
  type ExpenseDraft = { accountId: string; categoryId: string; amount: number | null; day: string; payee: string; desc: string; reference: string };
  const [draft, setDraft] = useState<ExpenseDraft | null>(null);
  const typed = !!(desc.trim() || payee.trim() || amount || reference.trim());
  useEffect(() => {
    try { sessionStorage.removeItem(`zaaer:expense-draft:${branchId}`); if (!draftKey) { setDraft(null); return; } const raw = sessionStorage.getItem(draftKey); const d = raw ? JSON.parse(raw) as ExpenseDraft : null; setDraft(d && (d.desc || d.payee || d.amount || d.reference) ? d : null); } catch { setDraft(null); }
  }, [draftKey]);
  useEffect(() => {
    if (!typed || !draftKey) return;
    const t = window.setTimeout(() => { try { sessionStorage.setItem(draftKey, JSON.stringify({ accountId, categoryId, amount, day, payee, desc, reference })); } catch { /* storage off */ } }, 300);
    return () => window.clearTimeout(t);
  }, [typed, draftKey, accountId, categoryId, amount, day, payee, desc, reference]);
  const clearDraft = () => { try { if (draftKey) sessionStorage.removeItem(draftKey); } catch { /* storage off */ } setDraft(null); };

  useEffect(() => {
    Promise.all([
      supabase.from("cash_accounts").select("id, branch_id, kind, name, bank_name, account_last4, account_prefix, account_suffix, is_default, is_active, archived_at, archive_reason, version").eq("branch_id", branchId).is("archived_at", null).eq("is_active", true).order("kind", { ascending: false }),
      supabase.from("expense_categories").select("id, name, sort_order, is_active, version").eq("is_active", true).order("sort_order"),
    ]).then(([a, c]) => {
      if (a.error || c.error) { setFileErr(toArabicError(a.error ?? c.error)); return; }
      const accs = (a.data ?? []) as CashAccount[]; setAccounts(accs); setAccountId(accs.find((x) => x.kind === "cash_box")?.id ?? accs[0]?.id ?? "");
      setCats((c.data ?? []) as ExpenseCategory[]);
    });
  }, [branchId]);
  const isBank = accounts.find((a) => a.id === accountId)?.kind === "bank_account";

  function pick(list: FileList | null) {
    setFileErr(null);
    const next = [...files, ...Array.from(list ?? [])];
    if (next.length > MAX_FILES) { setFileErr("خمسة مرفقات على الأكثر."); return; }
    if (next.some((f) => f.size > MAX_BYTES)) { setFileErr("حجم المرفق أكبر من 10 ميجابايت."); return; }
    if (next.some((f) => !/^(image\/(png|jpeg|webp)|application\/pdf)$/.test(f.type))) { setFileErr("المرفق صورة (PNG أو JPEG أو WebP) أو ملف PDF فقط."); return; }
    setFiles(next);
  }
  const toBase64 = (f: File) => new Promise<string>((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result)); r.onerror = () => rej(r.error); r.readAsDataURL(f); });

  return (
    <ActionForm onSubmit={async () => {
      const noFile = !files.length, noAmount = !amount || amount <= 0;
      if (noFile || noAmount) {
        // the rules and the thrown message stay as they were (attachment first); the fields now say what is missing and focus goes to the first one on the page
        setAmountErr(noAmount ? "اكتب مبلغًا أكبر من صفر." : null);
        setFileErr(noFile ? "المرفق مطلوب." : null);   // short field text; the banner keeps the full sentence
        document.querySelector<HTMLInputElement>(noAmount ? 'input[aria-label="المبلغ"]' : 'input[aria-label="المرفق"]')?.focus();
        throw new Error(noFile ? "VALIDATION: attachment_required" : "VALIDATION: amount");
      }
      const attachments = await Promise.all(files.map(async (f) => ({ data_base64: await toBase64(f), file_name: f.name })));
      await expenseApi.create({ branch_id: branchId, account_id: accountId, category_id: categoryId, amount_halalas: amount, description: desc.trim(), payee: payee.trim() || null,
                                reference: isBank ? reference.trim() || null : null, occurred_on: day, idempotency_key: key, attachments });
      clearDraft();
      onDone();
    }}>
      {draft && !typed && (
        <div className="mb-3 flex flex-wrap items-center gap-2 rounded-xl bg-brand-50 px-3 py-2 text-sm text-brand-700" data-testid="expense-draft">
          مسودة سند لم تُحفظ{draft.desc ? `: ${draft.desc}` : ""}. (المرفق يُرفع من جديد)
          <button type="button" className="btn-primary px-3 py-1 text-xs" onClick={() => { setAccountId(draft.accountId || accountId); setCategoryId(draft.categoryId); setAmount(draft.amount); setDay(draft.day || day); setPayee(draft.payee); setDesc(draft.desc); setReference(draft.reference); setDraft(null); }}>استعادة المسودة</button>
          <button type="button" className="btn-ghost px-3 py-1 text-xs" onClick={clearDraft}>تجاهلها</button>
        </div>
      )}
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="يُصرف من"><select className="input" value={accountId} onChange={(e) => setAccountId(e.target.value)} aria-label="يُصرف من">{accounts.map((a) => <option key={a.id} value={a.id}>{a.kind === "cash_box" ? "الصندوق" : "الحساب البنكي"} — {a.name}</option>)}</select></Field>
        <Field label="التصنيف"><select className="input" value={categoryId} onChange={(e) => setCategoryId(e.target.value)} aria-label="التصنيف"><option value="">اختر…</option>{cats.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>
        <Field label="المبلغ" error={amountErr}><MoneyInput valueHalalas={amount} onChange={(h) => { setAmount(h); setAmountErr(null); }} label="المبلغ" invalid={!!amountErr} /></Field>
        <Field label="التاريخ" hint="اليوم أو خلال 31 يومًا مضت."><input type="date" className="input" dir="ltr" max={todayISO()} min={addDaysISO(todayISO(), -31)} value={day} onChange={(e) => e.target.value && setDay(e.target.value)} aria-label="التاريخ" /></Field>
        <Field label="الوصف" className="sm:col-span-2"><input className="input" value={desc} onChange={(e) => setDesc(e.target.value)} maxLength={500} aria-label="الوصف" placeholder="مثال: قطع غيار للمكيف" /></Field>
        <Field label="المستفيد (اختياري)"><input className="input" value={payee} onChange={(e) => setPayee(e.target.value)} maxLength={120} aria-label="المستفيد" /></Field>
        {isBank && <Field label="رقم العملية البنكية (اختياري)"><input className="input" dir="ltr" value={reference} onChange={(e) => setReference(e.target.value.toUpperCase())} maxLength={60} aria-label="رقم العملية" /></Field>}
        <Field label="المرفق (إلزامي)" hint="صورة الفاتورة أو الإيصال: صورة أو PDF، حتى 5 ملفات، 10 ميجابايت للملف." className="sm:col-span-2" error={fileErr}>
          <input type="file" className="input" aria-invalid={!!fileErr || undefined} accept="image/png,image/jpeg,image/webp,application/pdf" multiple onChange={(e) => { pick(e.target.files); e.target.value = ""; }} aria-label="المرفق" />
        </Field>
        {files.length > 0 && <ul className="sm:col-span-2 space-y-1 text-sm" data-testid="expense-files">{files.map((f, i) => <li key={i} className="flex items-center justify-between gap-2"><span className="truncate"><Paperclip className="ml-1 inline h-3.5 w-3.5" />{f.name}</span><button type="button" className="btn-ghost text-xs" onClick={() => setFiles(files.filter((_, k) => k !== i))}>إزالة</button></li>)}</ul>}
      </div>
      <Submit label="حفظ السند" onCancel={onCancel} />
    </ActionForm>
  );
}

function Categories({ canAdd, canEdit }: { canAdd: boolean; canEdit: boolean }) {
  const [rows, setRows] = useState<ExpenseCategory[] | null>(null);
  const [name, setName] = useState("");
  const [tick, setTick] = useState(0);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => { supabase.from("expense_categories").select("id, name, sort_order, is_active, version").order("sort_order").then(({ data }) => setRows((data ?? []) as ExpenseCategory[])); }, [tick]);
  // 6.7 (U7): one request at a time; the ref closes the same-tick double press, the state disables and shows the buttons
  const inFlight = useRef(false);
  const [busy, setBusy] = useState(false);
  const run = async (fn: () => Promise<unknown>) => {
    if (inFlight.current) return;
    inFlight.current = true; setBusy(true); setErr(null);
    try { await fn(); setTick((t) => t + 1); } catch (e) { setErr(toArabicError(e)); } finally { inFlight.current = false; setBusy(false); }
  };
  if (!rows) return <Spinner />;
  return (
    <div>
      <div className="divide-y divide-ink-50 text-sm" data-testid="expense-categories">
        {rows.map((c) => (
          <div key={c.id} className="flex items-center justify-between gap-2 py-2">
            <span className={c.is_active ? "text-ink-800" : "text-ink-400 line-through"}>{c.name}</span>
            {canEdit && <button type="button" disabled={busy} className="btn-ghost min-h-[44px] text-xs" onClick={() => run(() => expenseApi.upsertCategory({ id: c.id, name: c.name, is_active: !c.is_active, version: c.version }))}>{c.is_active ? "إيقاف" : "تفعيل"}</button>}
          </div>
        ))}
      </div>
      {canAdd && <form className="mt-3 flex gap-2" onSubmit={(e) => { e.preventDefault(); if (name.trim()) run(async () => { await expenseApi.upsertCategory({ name: name.trim() }); setName(""); }); }}>
        <input className="input" value={name} onChange={(e) => setName(e.target.value)} maxLength={60} placeholder="تصنيف جديد" aria-label="تصنيف جديد" />
        <button type="submit" disabled={busy} className="btn-primary text-sm">{busy ? <Spinner className="h-4 w-4" /> : null} إضافة</button>
      </form>}
      {err && <p className="mt-2 text-sm text-danger-600" role="alert">{err}</p>}
    </div>
  );
}
