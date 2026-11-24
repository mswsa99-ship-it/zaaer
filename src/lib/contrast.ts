/**
 * Plan 3.2 — WCAG 2.x contrast math for the design-token gate. Pure functions, no DOM: the token file (to be
 * created after design approval 3.1) is checked by pairing each text token with its background token here.
 * Ratios follow https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio and #dfn-relative-luminance.
 */

export interface Rgb {
  r: number;
  g: number;
  b: number;
}

/** Parses #rgb, #rrggbb, #rrggbbaa (alpha ignored) or rgb(r, g, b). Returns null on anything else. */
export function parseColor(input: string): Rgb | null {
  const s = input.trim();
  const hex = s.match(/^#([0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/);
  if (hex) {
    const h = hex[1];
    if (h.length <= 4) {
      return { r: parseInt(h[0] + h[0], 16), g: parseInt(h[1] + h[1], 16), b: parseInt(h[2] + h[2], 16) };
    }
    return { r: parseInt(h.slice(0, 2), 16), g: parseInt(h.slice(2, 4), 16), b: parseInt(h.slice(4, 6), 16) };
  }
  const rgb = s.match(/^rgb\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*\)$/);
  if (rgb) {
    const c = { r: Number(rgb[1]), g: Number(rgb[2]), b: Number(rgb[3]) };
    return c.r <= 255 && c.g <= 255 && c.b <= 255 ? c : null;
  }
  return null;
}

function channel(v: number): number {
  const c = v / 255;
  return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

/** WCAG relative luminance, 0 (black) to 1 (white). */
export function relativeLuminance(c: Rgb): number {
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/** Contrast ratio of two colors, 1 to 21. Null when either color cannot be parsed. */
export function contrastRatio(a: string | Rgb, b: string | Rgb): number | null {
  const ca = typeof a === "string" ? parseColor(a) : a;
  const cb = typeof b === "string" ? parseColor(b) : b;
  if (!ca || !cb) return null;
  const la = relativeLuminance(ca);
  const lb = relativeLuminance(cb);
  const [hi, lo] = la >= lb ? [la, lb] : [lb, la];
  return (hi + 0.05) / (lo + 0.05);
}

/** AA thresholds: 4.5:1 for normal text, 3:1 for large text (WCAG 1.4.3). */
export const AA_NORMAL_TEXT = 4.5;
export const AA_LARGE_TEXT = 3;

export function meetsAA(a: string | Rgb, b: string | Rgb, largeText = false): boolean {
  const ratio = contrastRatio(a, b);
  return ratio !== null && ratio >= (largeText ? AA_LARGE_TEXT : AA_NORMAL_TEXT);
}

/** One declared text/background pair of the token file, e.g. «نص ثانوي على بطاقة». */
export interface TokenPair {
  label: string;
  text: string;
  background: string;
  largeText?: boolean;
}

export interface PairResult {
  label: string;
  ratio: number | null;
  required: number;
  pass: boolean;
}

/** Evaluates every pair of a token set; the 3.2 gate fails while any result has pass = false. */
export function checkPairs(pairs: TokenPair[]): PairResult[] {
  return pairs.map((p) => {
    const ratio = contrastRatio(p.text, p.background);
    const required = p.largeText ? AA_LARGE_TEXT : AA_NORMAL_TEXT;
    return { label: p.label, ratio, required, pass: ratio !== null && ratio >= required };
  });
}
