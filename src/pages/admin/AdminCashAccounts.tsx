/**
 * «الصناديق والحسابات» (decision 25): the cash boxes and bank accounts of a branch, a default for each kind.
 * Every receipt or refund records the box or account it went through: cash → a cash box; the terminal and transfers →
 * a bank account; the platform → none. Entries only — no running balance, no stock-taking, no ledger; an accounting
 * system completes that later. An account that was used is archived, never removed, and keeps its vouchers.
 */
import { useState } from "react";
import { Landmark, Wallet, Plus, Pencil, Archive, RotateCcw, Star } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { useBranchQuery, must } from "../../lib/useBranchQuery";
import { moneyApi, type CashAccount } from "../../lib/api";
import { useAuth } from "../../lib/auth";
import { accountLabel, last4Text } from "../../lib/useCashAccounts";
import { SectionTitle, LoadingScreen, Card, EmptyState, ErrorBanner, Badge, LoadErrorCard } from "../../components/ui";
import { Modal, Field, ActionForm, Submit, ArchivedBadge, Toggle, ReasonInput } from "../../components/forms";
import { BranchPicker } from "../../components/BranchPicker";

const NO_ACCOUNTS: CashAccount[] = [];
const KIND_LABEL = { cash_box: "صندوق نقد", bank_account: "حساب بنكي" } as const;
type Draft = Partial<CashAccount> & { kind: CashAccount["kind"]; name: string };

export default function AdminCashAccounts() {
  const { profile } = useAuth();
  const canEdit = profile?.role === "owner" || profile?.role === "manager";
  const [showArchived, setShowArchived] = useState(false);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [lifecycle, setLifecycle] = useState<{ a: CashAccount; archive: boolean } | null>(null);
  const [reason, setReason] = useState("");
  const [notice, setNotice] = useState<string | null>(null);

  // G24 (decision 40): the accounts of the active branch only
  const q = useBranchQuery<CashAccount[]>(async (branchId) => must(await supabase.from("cash_accounts")
    .select("id, branch_id, kind, name, bank_name, account_last4, is_default, is_active, archived_at, archive_reason, version")
    .eq("branch_id", branchId).order("kind").order("name")) as CashAccount[], [], NO_ACCOUNTS);
  const rows = q.data; const load = q.reload; const branchId = q.branchId;

  if (q.loading) return <LoadingScreen />;
  const visible = rows.filter((r) => showArchived || !r.archived_at);
  const missingDefault = (["cash_box", "bank_account"] as const).filter((k) => !rows.some((r) => r.kind === k && r.is_default && !r.archived_at));

  const group = (kind: CashAccount["kind"]) => {
    const list = visible.filter((r) => r.kind === kind);
    return (
      <div>
        <h3 className="mb-2 flex items-center gap-2 text-sm font-semibold text-ink-700">{kind === "cash_box" ? <Wallet className="h-4 w-4 text-brand-600" /> : <Landmark className="h-4 w-4 text-brand-600" />}{kind === "cash_box" ? "صناديق النقد" : "الحسابات البنكية"}</h3>
        <p className="mb-3 text-xs text-ink-400">{kind === "cash_box" ? "يُقيَّد فيها القبض والرد النقدي." : "يُقيَّد فيها ما يُدفع بالشبكة أو بالتحويل البنكي، مع رقم العملية."}</p>
        {list.length === 0 ? <p className="text-sm text-ink-400">لا يوجد.</p> : (
          <div className="space-y-2">
            {list.map((a) => (
              <Card key={a.id} className={a.archived_at ? "opacity-60" : ""} >
                <div className="flex flex-wrap items-start justify-between gap-2" data-testid="cash-account">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="font-semibold text-ink-800">{a.name}</span>
                      {a.is_default && !a.archived_at && <Badge className="bg-brand-50 text-brand-700"><Star className="ml-1 inline h-3 w-3" />الافتراضي</Badge>}
                      <ArchivedBadge archivedAt={a.archived_at} />
                      {!a.is_active && !a.archived_at && <Badge className="bg-warning-500/10 text-warning-600">موقوف</Badge>}
                    </div>
                    {(a.bank_name || a.account_last4) && <p className="mt-0.5 text-xs text-ink-500">{[a.bank_name, last4Text(a.account_last4)].filter(Boolean).join(" · ")}</p>}
                    {a.archive_reason && <p className="mt-0.5 text-xs text-ink-400">سبب الأرشفة: {a.archive_reason}</p>}
                  </div>
                  {canEdit && (
                    <div className="flex gap-1">
                      {!a.archived_at && <button onClick={() => setDraft({ ...a })} className="btn-ghost p-1.5" title="تعديل"><Pencil className="h-4 w-4" /></button>}
                      <button onClick={() => { setReason(""); setLifecycle({ a, archive: !a.archived_at }); }} className="btn-ghost p-1.5 text-ink-400" title={a.archived_at ? "استعادة" : "أرشفة"}>{a.archived_at ? <RotateCcw className="h-4 w-4" /> : <Archive className="h-4 w-4" />}</button>
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
      <SectionTitle title="الصناديق والحسابات" subtitle="أين يُقيَّد كل قبض ورد في هذا الفرع — قيود فقط، يكمّلها النظام المحاسبي لاحقًا" action={
        <div className="flex items-center gap-3"><BranchPicker />{canEdit && <button onClick={() => setDraft({ kind: "cash_box", name: "", is_default: false })} className="btn-primary text-sm"><Plus className="h-4 w-4" /> صندوق أو حساب</button>}</div>} />
      {q.error && rows.length > 0 && <div className="mb-4"><ErrorBanner message={q.error} /></div>}
      {notice && <p className="mb-4 rounded-xl bg-warning-500/10 px-3 py-2 text-sm text-warning-600">{notice}</p>}
      {missingDefault.length > 0 && rows.length > 0 && <p className="mb-4 rounded-xl bg-warning-500/10 px-3 py-2 text-sm text-warning-600">لا يوجد {missingDefault.map((k) => KIND_LABEL[k]).join(" ولا ")} افتراضي: كل سند بهذه الطريقة يحتاج اختيار الحساب يدويًا.</p>}
      <div className="mb-4"><Toggle checked={showArchived} onChange={setShowArchived} label="إظهار المؤرشف" /></div>
      {q.error && rows.length === 0 ? <LoadErrorCard message={q.error} onRetry={load} /> : rows.length === 0 ? <EmptyState icon={<Wallet className="h-10 w-10" />} title="لا توجد صناديق ولا حسابات" description="لكل فرع صندوق وحساب بنكي من البداية؛ أضف ما تحتاج." /> : (
        <div className="grid gap-6 lg:grid-cols-2">{group("cash_box")}{group("bank_account")}</div>
      )}

      <Modal open={!!draft} title={draft?.id ? "تعديل" : "صندوق أو حساب جديد"} onClose={() => setDraft(null)}>
        {draft && (
          <ActionForm onSubmit={async () => {
            if (!branchId) return;
            await moneyApi.upsertAccount({ id: draft.id, branch_id: branchId, kind: draft.kind, name: draft.name, bank_name: draft.kind === "bank_account" ? draft.bank_name ?? null : null,
              account_last4: draft.kind === "bank_account" ? draft.account_last4 ?? null : null, is_default: !!draft.is_default, is_active: draft.is_active, version: draft.version });
            setDraft(null); load();
          }}>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="النوع"><select className="input" aria-label="النوع" value={draft.kind} disabled={!!draft.id} onChange={(e) => setDraft({ ...draft, kind: e.target.value as CashAccount["kind"] })}><option value="cash_box">{KIND_LABEL.cash_box}</option><option value="bank_account">{KIND_LABEL.bank_account}</option></select></Field>
              <Field label="الاسم (مطلوب)"><input className="input" aria-label="الاسم" value={draft.name} onChange={(e) => setDraft({ ...draft, name: e.target.value })} placeholder={draft.kind === "cash_box" ? "مثال: صندوق الاستقبال" : "مثال: حساب الشبكة"} /></Field>
              {draft.kind === "bank_account" && <>
                <Field label="البنك"><input className="input" aria-label="البنك" value={draft.bank_name ?? ""} onChange={(e) => setDraft({ ...draft, bank_name: e.target.value })} /></Field>
                <Field label="آخر أربعة أرقام من الحساب" hint="للتمييز فقط؛ لا يُحفظ رقم الحساب كاملًا."><input className="input" aria-label="آخر أربعة أرقام" dir="ltr" inputMode="numeric" maxLength={4} value={draft.account_last4 ?? ""} onChange={(e) => setDraft({ ...draft, account_last4: e.target.value.replace(/\D/g, "") })} /></Field>
              </>}
            </div>
            <div className="mt-3 flex flex-wrap gap-4">
              <Toggle checked={!!draft.is_default} onChange={(v) => setDraft({ ...draft, is_default: v })} label={`الافتراضي لكل ${draft.kind === "cash_box" ? "قبض نقدي" : "شبكة وتحويل"}`} />
              {draft.id && <Toggle checked={draft.is_active ?? true} onChange={(v) => setDraft({ ...draft, is_active: v })} label="فعّال" />}
            </div>
            <Submit label="حفظ" onCancel={() => setDraft(null)} />
          </ActionForm>
        )}
      </Modal>

      <Modal open={!!lifecycle} title={lifecycle?.archive ? "أرشفة" : "استعادة"} onClose={() => setLifecycle(null)}>
        {lifecycle && (
          <ActionForm onSubmit={async () => {
            if (!reason.trim()) throw new Error("VALIDATION: reason");
            const r = await moneyApi.archiveAccount(lifecycle.a.id, lifecycle.archive, reason.trim());
            setNotice(lifecycle.archive && r.default_missing ? `أُرشف «${accountLabel(lifecycle.a)}» وكان الافتراضي؛ اختر افتراضيًا جديدًا.` : null);
            setLifecycle(null); load();
          }}>
            <p className="mb-3 text-sm text-ink-600">{lifecycle.archive ? "تبقى السندات التي استُخدم فيها كما هي، ولا يظهر للسندات الجديدة." : "يعود متاحًا للسندات الجديدة."}</p>
            <ReasonInput value={reason} onChange={setReason} />
            <Submit label={lifecycle.archive ? "أرشفة" : "استعادة"} onCancel={() => setLifecycle(null)} danger={lifecycle.archive} />
          </ActionForm>
        )}
      </Modal>
    </div>
  );
}
