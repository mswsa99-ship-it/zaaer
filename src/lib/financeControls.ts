import { latinDigits } from "./validation";
export const EXPENSE_ROLES = ["supervisor", "finance", "housekeeping"] as const;
export const FINANCE_FIELDS = [
  ["discount_review_threshold_bp", "عتبة الخصم (نقطة أساس، ١٠٠ = ١٪)"],
  ["anomaly_receipt_threshold_halalas", "تنبيه القبض فوق (هللة)"],
  ["anomaly_expense_threshold_halalas", "تنبيه المصروف فوق (هللة)"],
  ["operational_refund_threshold_halalas", "اعتماد الاسترداد فوق (هللة)"],
  ["operational_closing_diff_alert_halalas", "تنبيه فرق الإقفال فوق (هللة)"],
] as const;
export interface FinanceControls {
  organization_id: string;
  operational_refund_threshold_halalas: number | null;
  operational_closing_diff_alert_halalas: number | null;
  expense_role_limits: Record<string, number>;
  effective_expense_limits: Record<string, number | null>;
  discount_review_threshold_bp: number | null;
  anomaly_receipt_threshold_halalas: number;
  anomaly_expense_threshold_halalas: number;
}
export function parseFinanceThreshold(value: string, max = 999999999999): number | null {
  value = latinDigits(value).trim();
  if (value.trim() === "") return null;
  if (!/^\d{1,12}$/.test(value)) throw new Error("اكتب عددًا صحيحًا غير سالب");
  const n = Number(value);
  if (n > max) throw new Error("القيمة أكبر من الحد المسموح");
  return n;
}
