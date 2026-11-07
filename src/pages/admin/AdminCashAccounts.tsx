/**
 * «الصناديق والحسابات» (decision 25; A1 of the accounting stage, 0062): one cash box and one bank account per branch.
 * Every receipt or refund records the box or account it went through: cash → the cash box; the terminal and transfers →
 * the bank account; the platform → none. The bank account is known by the start and end of its number (the rule the
 * bank-message monitoring uses to attribute a movement to its branch), and agrees with the IBAN of «دليل الفرع».
 * A closed account is archived with its reason, never removed, keeps its vouchers, and its replacement is added after.
 */
import { useEffect, useState } from "react";
import { Landmark, Wallet, Plus, Pencil, Archive, RotateCcw, Star } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { moneyApi, type CashAccount } from "../../lib/api";
import { useAuth } from "../../lib/auth";
import { accountLabel, last4Text, numberRuleText } from "../../lib/useCashAccounts";
import { latinDigits } from "../../lib/validation";
import { SectionTitle, LoadingScreen, Card, EmptyState, ErrorBanner, Badge, LoadErrorCard } from "../../components/ui";
import { Modal, Field, ActionForm, Submit, ArchivedBadge, Toggle, ReasonInput } from "../../components/forms";
import { Link } from "react-router-dom";
import { BranchPicker } from "../../components/BranchPicker";

const NO_ACCOUNTS: CashAccount[] = [];
const KIND_LABEL = { cash_box: "صندوق نقد", bank_account: "حساب بنكي" } as const;
type Draft = Partial<CashAccount> & { kind: CashAccount["kind"]; name: string };

export default function AdminCashAccounts() {
  const { can } = useAuth();
  const canEdit = can("cash_accounts");
  const [showArchived, setShowArchived] = useState(false);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [lifecycle, setLifecycle] = useState<{ a: CashAccount; archive: boolean } | null>(null);
  const [reason, setReason] = useState("");
  const [notice, setNotice] = useState<string | null>(null);

  // G24 (decision 40): the accounts of the active branch only
  const q = useBranchQuery<CashAccount[]>(async (branchId) => must(await supabase.from("cash_accounts")
    .select("id, branch_id, kind, name, bank_name, account_last4, account_prefix, account_suffix, is_default, is_active, archived_at, archive_reason, version")
    .eq("branch_id", branchId).order("kind").order("name")) as CashAccount[], [], NO_ACCOUNTS);
  const rows = q.data; const load = q.reload; const branchId = q.branchId;
  // the IBAN lives in «دليل الفرع» (0056); shown here beside the account it must agree with
  const [iban, setIban] = useState<string | null>(null);
  useEffect(() => {
    if (!branchId) { setIban(null); return; }
    let alive = true;
    supabase.from("branches").select("bank_iban").eq("id", branchId).maybeSingle().then(({ data }) => { if (alive) setIban((data as { bank_iban: string | null } | null)?.bank_iban ?? null); });
    return () => { alive = false; };
  }, [branchId, q.data]);

  if (q.loading) return <LoadingScreen />;
  const visible = rows.filter((r) => showArchived || !r.archived_at);
  const missingDefault = (["cash_box", "bank_account"] as const).filter((k) => !rows.some((r) => r.kind === k && r.is_default && r.is_active && !r.archived_at));
  // A1: one in use per kind; «إضافة» appears only for the kind the branch lacks
  const inUse = (kind: CashAccount["kind"]) => rows.some((r) => r.kind === kind && !r.archived_at);
  const missing = (["cash_box", "bank_account"] as const).filter((k) => !inUse(k));

  const group = (kind: CashAccount["kind"]) => {
    const list = visible.filter((r) => r.kind === kind);
    return (
      <div>
        <h2 className="mb-2 flex items-center gap-2 text-sm font-semibold text-ink-700">{kind === "cash_box" ? <Wallet className="h-4 w-4 text-brand-600" /> : <Landmark className="h-4 w-4 text-brand-600" />}{kind === "cash_box" ? "صندوق النقد" : "الحساب البنكي"}</h2>
        <p className="mb-3 text-xs text-ink-400">{kind === "cash_box" ? "يُقيَّد فيه القبض والرد النقدي." : "يُقيَّد فيه ما يُدفع بالشبكة أو بالتحويل البنكي، مع رقم العملية."}</p>
        {list.length === 0 ? <p className="text-sm text-ink-400">لا يوجد.</p> : (
          <div className="space-y-2">
            {list.map((a) => (
              <Card key={a.id} className={a.archived_at ? "opacity-60" : ""} >
                <div className="flex flex-wrap items-start justify-between gap-2" data-testid="cash-account">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="font-semibold text-ink-800">{a.name}</span>
                      {a.is_default && a.is_active && !a.archived_at && <Badge className="bg-brand-50 text-brand-700"><Star className="ml-1 inline h-3 w-3" />الافتراضي</Badge>}
                      <ArchivedBadge archivedAt={a.archived_at} />
                      {!a.is_active && !a.archived_at && <Badge className="bg-warning-500/10 text-warning-700">موقوف</Badge>}
                    </div>
                    {(a.bank_name || a.account_last4 || a.account_prefix) && <p className="mt-0.5 text-xs text-ink-500">{[a.bank_name, numberRuleText(a.account_prefix, a.account_suffix) ?? last4Text(a.account_last4)].filter(Boolean).join(" · ")}</p>}
                    {a.kind === "bank_account" && !a.archived_at && <>
                      {a.account_prefix && a.account_suffix
                        ? <p className="mt-0.5 text-xs text-ink-500" data-testid="account-rule">رقم الحساب يبدأ بـ <span dir="ltr">{a.account_prefix}</span> وينتهي بـ <span dir="ltr">{a.account_suffix}</span></p>
                        : <p className="mt-1 rounded-lg bg-warning-500/10 px-2 py-1 text-xs text-warning-700" data-testid="account-rule-missing">لم تُكتب بداية رقم الحساب ونهايته: يحتاجهما رصد الرسائل البنكية لنسبة كل حركة إلى هذا الفرع.</p>}
                      <p className="mt-0.5 text-xs text-ink-500">الآيبان: {iban ? <span dir="ltr" className="font-mono">{iban.replace(/(.{4})/g, "$1 ").trim()}</span> : "غير مُدخل"} · <Link to="/admin/branches" className="text-brand-700 underline">من «دليل الفرع»</Link></p>
                    </>}
                    {a.archive_reason && <p className="mt-0.5 text-xs text-ink-400">سبب الأرشفة: {a.archive_reason}</p>}
                  </div>
                  {canEdit && (
                    <div className="flex gap-1">
                      {!a.archived_at && <button onClick={() => setDraft({ ...a })} className="btn-ghost p-1.5" title="تعديل" aria-label="تعديل"><Pencil className="h-4 w-4" /></button>}
                      {(!a.archived_at || !inUse(a.kind)) && <button onClick={() => { setReason(""); setLifecycle({ a, archive: !a.archived_at }); }} className="btn-ghost p-1.5 text-ink-400" title={a.archived_at ? "استعادة" : "أرشفة"} aria-label={a.archived_at ? "استعادة" : "أرشفة"}>{a.archived_at ? <RotateCcw className="h-4 w-4" /> : <Archive className="h-4 w-4" />}</button>}
                    </div>
                  )}
                </div>
              </Card>
            ))}
          </div>
        )}
      </div>
    );
  };

  return (
    <div>
      <SectionTitle title="الصناديق والحسابات" subtitle="لكل فرع صندوق نقد واحد وحساب بنكي واحد، ولا يُقيَّد فيهما إلا ما يخص هذا الفرع" action={
        <div className="flex min-w-0 flex-wrap items-center gap-3"><BranchPicker />{canEdit && missing.map((k) => <button key={k} onClick={() => setDraft({ kind: k, name: "" })} className="btn-primary text-sm"><Plus className="h-4 w-4" /> {k === "cash_box" ? "إضافة صندوق" : "إضافة حساب بنكي"}</button>)}</div>} />
      {q.error && rows.length > 0 && <div className="mb-4"><ErrorBanner message={q.error} /></div>}
      {notice && <p className="mb-4 rounded-xl bg-warning-500/10 px-3 py-2 text-sm text-warning-700">{notice}</p>}
      {missingDefault.length > 0 && rows.length > 0 && <p className="mb-4 rounded-xl bg-warning-500/10 px-3 py-2 text-sm text-warning-700">لا يوجد {missingDefault.map((k) => KIND_LABEL[k]).join(" ولا ")} مستخدم في هذا الفرع: لا يُقبل قبض أو رد بهذه الطريقة حتى يُضاف.</p>}
      <div className="mb-4"><Toggle checked={showArchived} onChange={setShowArchived} label="إظهار المؤرشف" /></div>
      {q.error && rows.length === 0 ? <LoadErrorCard message={q.error} onRetry={load} /> : rows.length === 0 ? <EmptyState icon={<Wallet className="h-10 w-10" />} title="لا توجد صناديق ولا حسابات" description="لكل فرع صندوق وحساب بنكي من البداية؛ أضف ما تحتاج." /> : (
        <div className="grid gap-6 lg:grid-cols-2">{group("cash_box")}{group("bank_account")}</div>
      )}

      <Modal open={!!draft} title={draft?.id ? "تعديل" : "صندوق أو حساب جديد"} onClose={() => setDraft(null)}>
        {draft && (
          <ActionForm onSubmit={async () => {
            if (!branchId) return;
            const bank = draft.kind === "bank_account";
            await moneyApi.upsertAccount({ id: draft.id, branch_id: branchId, kind: draft.kind, name: draft.name, version: draft.version,
              ...(bank ? { bank_name: draft.bank_name ?? null, account_prefix: draft.account_prefix ?? null, account_suffix: draft.account_suffix ?? null } : {}) });
            setDraft(null); load();
          }}>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="النوع"><input className="input" aria-label="النوع" value={KIND_LABEL[draft.kind]} readOnly /></Field>
              <Field label="الاسم (مطلوب)"><input className="input" aria-label="الاسم" value={draft.name} onChange={(e) => setDraft({ ...draft, name: e.target.value })} placeholder={draft.kind === "cash_box" ? "مثال: صندوق الاستقبال" : "مثال: حساب الشبكة"} /></Field>
              {draft.kind === "bank_account" && <>
                <Field label="البنك"><input className="input" aria-label="البنك" value={draft.bank_name ?? ""} onChange={(e) => setDraft({ ...draft, bank_name: e.target.value })} /></Field>
                <Field label="بداية رقم الحساب" hint="من 2 إلى 6 أرقام، كما تظهر في رسائل البنك."><input className="input" aria-label="بداية رقم الحساب" dir="ltr" inputMode="numeric" maxLength={6} value={draft.account_prefix ?? ""} onChange={(e) => setDraft({ ...draft, account_prefix: latinDigits(e.target.value).replace(/\D/g, "").slice(0, 6) })} /></Field>
                <Field label="نهاية رقم الحساب" hint="من 2 إلى 6 أرقام؛ لا يُحفظ رقم الحساب كاملًا."><input className="input" aria-label="نهاية رقم الحساب" dir="ltr" inputMode="numeric" maxLength={6} value={draft.account_suffix ?? ""} onChange={(e) => setDraft({ ...draft, account_suffix: latinDigits(e.target.value).replace(/\D/g, "").slice(0, 6) })} /></Field>
              </>}
            </div>
            {draft.kind === "bank_account" && <p className="mt-3 text-xs text-ink-500">بهذين الرقمين يُنسب كل إيداع أو تحويل أو سحب في رسائل البنك إلى هذا الفرع، ولا يُسجَّلان لحساب فرع آخر. والآيبان يُكتب في «دليل الفرع» ويجب أن ينتهي بنهاية الرقم.</p>}
            <Submit label="حفظ" onCancel={() => setDraft(null)} />
          </ActionForm>
        )}
      </Modal>

      <Modal open={!!lifecycle} title={lifecycle?.archive ? "أرشفة" : "استعادة"} onClose={() => setLifecycle(null)}>
        {lifecycle && (
          <ActionForm onSubmit={async () => {
            if (!reason.trim()) throw new Error("VALIDATION: reason");
            const r = await moneyApi.archiveAccount(lifecycle.a.id, lifecycle.archive, reason.trim());
            setNotice(lifecycle.archive && r.default_missing ? `أُرشف «${accountLabel(lifecycle.a)}». أضف ${lifecycle.a.kind === "cash_box" ? "الصندوق" : "الحساب البنكي"} البديل من «${lifecycle.a.kind === "cash_box" ? "إضافة صندوق" : "إضافة حساب بنكي"}».` : null);
            setLifecycle(null); load();
          }}>
            <p className="mb-3 text-sm text-ink-600">{lifecycle.archive ? "تبقى السندات التي استُخدم فيها كما هي، ولا يظهر للسندات الجديدة. بعد الأرشفة أضف البديل، فلا يُقبل قبض بهذه الطريقة حتى يُضاف." : "يعود هو المستخدم للسندات الجديدة."}</p>
            <ReasonInput value={reason} onChange={setReason} />
            <Submit label={lifecycle.archive ? "أرشفة" : "استعادة"} onCancel={() => setLifecycle(null)} danger={lifecycle.archive} />
          </ActionForm>
        )}
      </Modal>
    </div>
  );
}
