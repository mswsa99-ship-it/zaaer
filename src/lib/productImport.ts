/**
 * «استيراد قائمة» in «المنتجات» (W1): the owner's list, pasted once, read line by line before anything is saved.
 * Pure, so the page and its tests share it.
 */
import { moneyTextToHalalas, sanitizeMoneyText } from "./money";
/** One line of a pasted list: «الفئة، المنتج، السعر» and, optionally, «، الوصف». */
export interface ImportLine { n: number; category: string; name: string; price: number | null; description: string | null; problem: string | null; existing: boolean }
const chars = (s: string) => [...s].length;
/**
 * Reads a pasted list (one product per line). The parts are separated by «،» or a tab, «|» or «؛», or by plain commas
 * when none of those is on the line (the price then keeps its own commas: «1,250»). A name already in the catalogue, or
 * earlier in the list, is left as it is; up to 200 lines.
 */
export function parseProductList(text: string, existingNames: string[]): ImportLine[] {
  const seen = new Set(existingNames.map((x) => x.trim().toLowerCase()));
  return text.split(/\r?\n/).map((raw, i) => ({ raw: raw.trim(), n: i + 1 })).filter((x) => x.raw).slice(0, 200).map(({ raw, n }) => {
    // with plain commas only, the price keeps its own commas (1,250 or 2,50): category, name, price, the rest
    const plain = /[،\t|؛]/.test(raw) ? null : /^([^,]*),([^,]*),\s*([0-9٠-٩][0-9٠-٩.,٫]*(?:\s*(?:ر\.?\s?س\.?|ريال|SAR))?)\s*(?:,(.*))?$/i.exec(raw);
    const parts = (plain ? plain.slice(1).map((x) => x ?? "") : /[،\t|؛]/.test(raw) ? raw.split(/[،\t|؛]/) : raw.split(",")).map((x) => x.trim());
    const [category = "", name = "", priceText = "", ...rest] = parts;
    const description = rest.join("، ").trim() || null;
    const t = sanitizeMoneyText(priceText.replace(/ر\.?\s?س\.?|ريالًا|ريالات|ريال|SAR/gi, "").trim(), false);
    const price = t == null ? null : moneyTextToHalalas(t);
    let problem: string | null = null;
    if (!category || chars(category) > 40) problem = "اسم الفئة مطلوب، 40 حرفًا على الأكثر";
    else if (!name || chars(name) > 40) problem = "اسم المنتج مطلوب، 40 حرفًا على الأكثر";
    else if (price == null || price < 1 || price > 10_000_000) problem = "السعر غير مقروء (بالريال، مثل 2.50)";
    else if (description && chars(description) > 200) problem = "الوصف أطول من 200 حرف";
    const existing = !problem && seen.has(name.toLowerCase());
    if (!problem && !existing) seen.add(name.toLowerCase());
    return { n, category, name, price, description, problem, existing };
  });
}
