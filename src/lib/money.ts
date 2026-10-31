/** The money field's text rules (the owner's note 2; task B2): pure functions, shared by the field and its tests. */
import { latinDigits } from "./validation";

/** Riyals as typed: empty for nothing (or 0), «250» for a whole amount, «250.50» only when it has halalas. */
export function formatMoneyInput(h: number | null | undefined): string {
  if (h == null || h === 0) return "";
  return h % 100 === 0 ? String(h / 100) : (h / 100).toFixed(2);
}

/**
 * What the field accepts while typing (the owner's note 2): riyals; halalas only after the point, two at most;
 * Arabic-Indic digits and the Arabic decimal mark are read; a minus only where the field allows a negative.
 * Returns null when the keystroke would make the text invalid (the field keeps its previous text).
 */
export function sanitizeMoneyText(raw: string, allowNegative: boolean): string | null {
  let t = latinDigits(raw).replace(/[٫]/g, ".").replace(/[٬\s]/g, "");
  // a comma is the decimal point when it ends the number with two digits at most (a keyboard that shows «,» for the
  // point); thousands commas are read only in full groups of three; any other comma is refused, never dropped
  if (t.includes(",")) {
    if (/^-?\d*,\d{0,2}$/.test(t)) t = t.replace(",", ".");
    else if (/^-?\d{1,3}(,\d{3})+(\.\d{0,2})?$/.test(t)) t = t.replace(/,/g, "");
    else return null;
  }
  if (allowNegative && t.startsWith("-")) t = "-" + t.slice(1).replace(/-/g, ""); else t = t.replace(/-/g, "");
  if (!/^-?\d*(\.\d{0,2})?$/.test(t)) return null;
  return t;
}

export function moneyTextToHalalas(t: string): number | null {
  if (t === "" || t === "-" || t === "." || t === "-.") return null;
  const n = Number(t);
  return Number.isFinite(n) ? Math.round(n * 100) : null;
}

// 0051: a booking source's commission
/** 1500 → "15", 1250 → "12.5" (basis points as a percentage, Latin digits). */
export const bpToPercent = (bp: number | null | undefined) => String(Number(((bp ?? 0) / 100).toFixed(2)));
/** "15" / "12.5" / "١٥" → 1500 / 1250; null when it is not a percentage 0–100 with at most two decimals. */
export function percentToBp(text: string): number | null {
  const t = text.trim().replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d))).replace("٫", ".").replace(/%$/, "").trim();
  if (!/^\d{1,3}(\.\d{1,2})?$/.test(t)) return null;
  const bp = Math.round(Number(t) * 100);
  return bp >= 0 && bp <= 10000 ? bp : null;
}
