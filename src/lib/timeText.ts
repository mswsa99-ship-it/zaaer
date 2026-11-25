/**
 * Time as two scroll wheels (owner request, 25 Nov): the hours wheel lists all 24 hours as 12, 1 … 11 (صباحًا) and then
 * 12, 1 … 11 (مساءً), so passing the first 12 switches to the evening on its own; the minutes wheel lists 00 … 59.
 * The stored value stays «HH:MM» (24 h) or "" (blank = the screen's own default). Pure helpers, unit-tested.
 */
export const HOURS_24 = Array.from({ length: 24 }, (_, h) => h);
export const MINUTES = Array.from({ length: 60 }, (_, m) => m);

/** The number shown for a 24-hour hour: 0 → 12, 13 → 1, 12 → 12. */
export const hourLabel = (h24: number) => String(h24 % 12 === 0 ? 12 : h24 % 12);
export const periodOf = (h24: number): "صباحًا" | "مساءً" => (h24 >= 12 ? "مساءً" : "صباحًا");
export const pad2 = (n: number) => String(n).padStart(2, "0");

export function parseHHMM(v: string): { h: number; m: number } | null {
  const x = /^(\d{2}):(\d{2})/.exec(v ?? "");
  if (!x) return null;
  const h = Number(x[1]), m = Number(x[2]);
  return h <= 23 && m <= 59 ? { h, m } : null;
}
export const toHHMM = (h: number, m: number) => `${pad2(h)}:${pad2(m)}`;

/** «4:30 مساءً» for display; "" when there is no time. */
export function describeTime(v: string): string {
  const t = parseHHMM(v);
  return t ? `${hourLabel(t.h)}:${pad2(t.m)} ${periodOf(t.h)}` : "";
}

/** Wheel position (item index) for a scroll offset, clamped to the list. */
export function wheelIndex(scrollTop: number, itemHeight: number, count: number): number {
  return Math.max(0, Math.min(count - 1, Math.round(scrollTop / itemHeight)));
}
