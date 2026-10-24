import { useEffect, useState } from "react";
import { supabase } from "./supabase";
import type { CashAccount } from "./api";

const COLS = "id, branch_id, kind, name, bank_name, account_last4, is_default, is_active, archived_at, archive_reason, version";

/**
 * The cash boxes and bank accounts of one branch (decision 25), archived ones included so old vouchers keep showing
 * the account they used. `active` is what a new voucher may use. Readable by the money roles only (0028 RLS).
 */
export function useCashAccounts(branchId: string | null | undefined, tick = 0) {
  const [all, setAll] = useState<CashAccount[]>([]);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (!branchId) { setAll([]); return; }
    let alive = true;
    supabase.from("cash_accounts").select(COLS).eq("branch_id", branchId).order("kind").order("name").then(({ data, error: e }) => {
      if (!alive) return;
      if (e) { setError(e.message); setAll([]); } else { setError(null); setAll((data as CashAccount[]) ?? []); }
    });
    return () => { alive = false; };
  }, [branchId, tick]);
  const active = all.filter((a) => !a.archived_at && a.is_active);
  const nameOf = (id: string | null | undefined) => (id ? all.find((a) => a.id === id)?.name ?? null : null);
  return { all, active, error, nameOf };
}

/** "••1234", kept left-to-right inside Arabic text (an isolate, so the dots stay before the digits). */
export const last4Text = (last4: string | null | undefined) => (last4 ? `\u2066••${last4}\u2069` : null);

/** "اسم الحساب · البنك · ••1234" */
export function accountLabel(a: Pick<CashAccount, "name" | "bank_name" | "account_last4">): string {
  return [a.name, a.bank_name, last4Text(a.account_last4)].filter(Boolean).join(" · ");
}
