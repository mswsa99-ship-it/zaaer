/**
 * B7 (the owner's note 8): the amount of a printed voucher or invoice in words, in Arabic, as Saudi documents write it:
 * «فقط ألف ومئتان وخمسون ريالًا وخمس وعشرون هللة لا غير». The riyal is masculine, the halala feminine; the counted noun
 * follows the number (1 ريال واحد، 2 ريالان، 3–10 ريالات، 11–99 ريالًا، 100… ريال).
 */

const ONES_M = ["", "واحد", "اثنان", "ثلاثة", "أربعة", "خمسة", "ستة", "سبعة", "ثمانية", "تسعة", "عشرة"];
const ONES_F = ["", "واحدة", "اثنتان", "ثلاث", "أربع", "خمس", "ست", "سبع", "ثماني", "تسع", "عشر"];
const TEENS_M = ["", "أحد عشر", "اثنا عشر", "ثلاثة عشر", "أربعة عشر", "خمسة عشر", "ستة عشر", "سبعة عشر", "ثمانية عشر", "تسعة عشر"];
const TEENS_F = ["", "إحدى عشرة", "اثنتا عشرة", "ثلاث عشرة", "أربع عشرة", "خمس عشرة", "ست عشرة", "سبع عشرة", "ثماني عشرة", "تسع عشرة"];
const TENS = ["", "عشرة", "عشرون", "ثلاثون", "أربعون", "خمسون", "ستون", "سبعون", "ثمانون", "تسعون"];
const HUNDREDS = ["", "مئة", "مئتان", "ثلاثمئة", "أربعمئة", "خمسمئة", "ستمئة", "سبعمئة", "ثمانمئة", "تسعمئة"];

/**
 * 1–999 in words; `fem` for a feminine counted noun (the halala); `construct` when the counted noun or a scale word
 * follows directly, which drops the dual's nūn («مئتا ريال»، «مئتا ألف»).
 */
function below1000(n: number, fem: boolean, construct = false): string {
  const parts: string[] = [];
  const h = Math.floor(n / 100), r = n % 100;
  if (h) parts.push(h === 2 && r === 0 && construct ? "مئتا" : HUNDREDS[h]);
  if (r) {
    const ones = fem ? ONES_F : ONES_M;
    if (r <= 10) parts.push(r === 10 ? (fem ? "عشر" : "عشرة") : ones[r]);
    else if (r < 20) parts.push((fem ? TEENS_F : TEENS_M)[r - 10]);
    else { const u = r % 10, t = Math.floor(r / 10); const unit = u === 1 && fem ? "إحدى" : ones[u]; parts.push(u ? `${unit} و${TENS[t]}` : TENS[t]); }
  }
  return parts.join(" و");
}

/** A count of thousands or millions with its scale word (ألف / ألفان / ألفا / آلاف / ألفًا). */
function scaled(count: number, one: string, two: string, few: string, many: string, last: boolean, construct: boolean): string {
  if (count === 1) return one;
  if (count === 2) return last && construct ? two.slice(0, -1) : two;   // «ألفا ريال»، «ألفان وخمسمئة»
  const r = count % 100;
  // «أحد عشر ألفًا وخمسمئة», but «أحد عشر ألف ريال» when the noun follows the scale word directly
  const word = r >= 3 && r <= 10 ? few : r >= 11 && !(last && construct) ? many : one;
  return `${below1000(count, false, true)} ${word}`;
}

/** A whole number (0 … 999,999,999,999) in words, masculine or feminine; `construct` when its noun follows directly. */
export function numberWords(n: number, fem = false, construct = false): string {
  if (!Number.isFinite(n) || n < 0 || n >= 1e12) throw new Error("VALIDATION: amount");
  n = Math.floor(n);
  if (n === 0) return "صفر";
  const parts: string[] = [];
  const billions = Math.floor(n / 1e9), millions = Math.floor((n % 1e9) / 1e6), thousands = Math.floor((n % 1e6) / 1e3), rest = n % 1e3;
  if (billions) parts.push(scaled(billions, "مليار", "ملياران", "مليارات", "مليارًا", !millions && !thousands && !rest, construct));
  if (millions) parts.push(scaled(millions, "مليون", "مليونان", "ملايين", "مليونًا", !thousands && !rest, construct));
  if (thousands) parts.push(scaled(thousands, "ألف", "ألفان", "آلاف", "ألفًا", !rest, construct));
  if (rest) parts.push(below1000(rest, fem, construct));
  return parts.join(" و");
}

/** The counted noun after a number (the tamyiz rules). */
function counted(n: number, one: string, two: string, few: string, many: string, single: string): string {
  if (n === 1) return single;
  if (n === 2) return two;
  const r = n % 100;
  const fem = few === "هللات";
  if (r >= 3 && r <= 10) return `${numberWords(n, fem)} ${few}`;
  if (r >= 11) return `${numberWords(n, fem)} ${many}`;
  return `${numberWords(n, fem, true)} ${one}`;   // a round number: the noun follows the number directly
}

/** Halalas (a signed integer) as «فقط … ريالًا و… هللة لا غير»; a negative amount reads «سالب …». */
export function amountInWords(halalas: number): string {
  if (!Number.isInteger(halalas)) throw new Error("VALIDATION: amount");
  const neg = halalas < 0; const abs = Math.abs(halalas);
  const sar = Math.floor(abs / 100), hal = abs % 100;
  const parts: string[] = [];
  if (sar > 0) parts.push(counted(sar, "ريال", "ريالان", "ريالات", "ريالًا", "ريال واحد"));
  if (hal > 0) parts.push(counted(hal, "هللة", "هللتان", "هللات", "هللة", "هللة واحدة"));
  if (parts.length === 0) parts.push("صفر ريال");
  return `فقط ${neg ? "سالب " : ""}${parts.join(" و")} لا غير`;
}
