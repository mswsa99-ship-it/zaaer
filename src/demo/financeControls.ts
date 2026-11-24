import type { FinanceControls } from "../lib/financeControls";
import { EXPENSE_ROLES, FINANCE_FIELDS, parseFinanceThreshold } from "../lib/financeControls";

// UI demo only. SQL tests, not this adapter, are enforcement evidence.
export function financeControlRpcs(c: { org: () => string | undefined; role: () => string | undefined; read: (org: string) => FinanceControls | undefined; write: (d: FinanceControls) => void; audit: (before: FinanceControls, after: FinanceControls) => void }) {
  function get(): FinanceControls {
    const org = c.org();
    if (!org) throw new Error("FORBIDDEN");
    const d = c.read(org) ?? { organization_id: org, operational_refund_threshold_halalas: null, operational_closing_diff_alert_halalas: null, expense_role_limits: {}, effective_expense_limits: {}, discount_review_threshold_bp: null, anomaly_receipt_threshold_halalas: 500000, anomaly_expense_threshold_halalas: 500000 };
    return { ...d, effective_expense_limits: { owner: null, manager: null, supervisor: d.expense_role_limits.supervisor ?? 500000, finance: d.expense_role_limits.finance ?? 2000000, housekeeping: d.expense_role_limits.housekeeping ?? 100000 } };
  }
  return {
    fn_finance_controls_get: get,
    fn_finance_controls_set: ({ p }: { p: Record<string, unknown> }) => {
      if (c.role() !== "owner") throw new Error("FORBIDDEN");
      const before = get(); const after = structuredClone(before);
      for (const [k,v] of Object.entries(p)) {
        if (k === "expense_role_limits") {
          if (!v || Array.isArray(v) || typeof v !== "object") throw new Error("VALIDATION");
          for (const [r,n] of Object.entries(v)) {
            if (!EXPENSE_ROLES.includes(r as typeof EXPENSE_ROLES[number])) throw new Error("VALIDATION");
            if (n === null) delete after.expense_role_limits[r];
            else { const x = parseFinanceThreshold(String(n)); if (!x) throw new Error("VALIDATION"); after.expense_role_limits[r] = x; }
          }
        } else if (FINANCE_FIELDS.some(([field]) => field === k)) {
          const x = v === null ? null : parseFinanceThreshold(String(v), k === "discount_review_threshold_bp" ? 10000 : undefined);
          if (k === "discount_review_threshold_bp") after.discount_review_threshold_bp = x;
          else if (k === "operational_refund_threshold_halalas") after.operational_refund_threshold_halalas = x;
          else if (k === "operational_closing_diff_alert_halalas") after.operational_closing_diff_alert_halalas = x;
          else { if (!x) throw new Error("VALIDATION"); if (k === "anomaly_receipt_threshold_halalas") after.anomaly_receipt_threshold_halalas = x; else after.anomaly_expense_threshold_halalas = x; }
        } else throw new Error("VALIDATION: unknown_key");
      }
      c.write(after); c.audit(before,after); return get();
    },
  };
}
