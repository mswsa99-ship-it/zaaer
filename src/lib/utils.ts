import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

const HIJRI_EPOCH_JD = 1948439.5; // Julian Day of 1 Muharram 1 AH

function gregorianToJD(year: number, month: number, day: number): number {
  const a = Math.floor((14 - month) / 12);
  const y = year + 4800 - a;
  const m = month + 12 * a - 3;
  return day + Math.floor((153 * m + 2) / 5) + 365 * y + Math.floor(y / 4) - Math.floor(y / 100) + Math.floor(y / 400) - 32045;
}

function jdToGregorian(jd: number): { year: number; month: number; day: number } {
  const z = Math.floor(jd + 0.5);
  const a = z + 32044;
  const b = Math.floor((4 * a + 3) / 146097);
  const c = a - Math.floor((146097 * b) / 4);
  const d = Math.floor((4 * c + 3) / 1461);
  const e = c - Math.floor((1461 * d) / 4);
  const m = Math.floor((5 * e + 2) / 153);
  const day = e - Math.floor((153 * m + 2) / 5) + 1;
  const month = m + 3 - 12 * Math.floor(m / 10);
  const year = 100 * b + d - 4800 + Math.floor(m / 10);
  return { year, month, day };
}

function jdToHijri(jd: number): { year: number; month: number; day: number } {
  const days = Math.floor(jd - HIJRI_EPOCH_JD);
  const years = Math.floor(days / 354.367);
  let remaining = Math.round(days - years * 354.367);
  const monthLengths = [30, 29, 30, 29, 30, 29, 30, 29, 30, 29, 30, 29];
  let month = 0;
  let day = 0;
  for (let i = 0; i < 12; i++) {
    if (remaining <= monthLengths[i]) {
      month = i + 1;
      day = remaining;
      break;
    }
    remaining -= monthLengths[i];
  }
  if (month === 0) {
    return { year: years + 1, month: 1, day: 1 };
  }
  return { year: years + 1, month, day };
}

export function gregorianToHijri(year: number, month: number, day: number) {
  return jdToHijri(gregorianToJD(year, month, day));
}

export function hijriToGregorian(year: number, month: number, day: number) {
  const jd = HIJRI_EPOCH_JD + (year - 1) * 354.367 + (month - 1) * 29.5 + day;
  return jdToGregorian(jd);
}

export function formatGregorian(iso: string): string {
  if (!iso) return "";
  const d = new Date(iso);
  return d.toLocaleDateString("en-GB", { year: "numeric", month: "2-digit", day: "2-digit" });
}

export function formatHijri(iso: string): string {
  if (!iso) return "";
  const d = new Date(iso);
  const h = gregorianToHijri(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate());
  return `${h.day}/${String(h.month).padStart(2, "0")}/${h.year}هـ`;
}

export function formatDateTime(iso: string): string {
  if (!iso) return "";
  return new Date(iso).toLocaleString("ar-SA", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

/**
 * Business dates ("today", arrivals, report days) are the PROPERTY's dates, not UTC's and not the browser's:
 * between 00:00 and 03:00 in Riyadh the UTC date is still yesterday. Same rule as fn_branch_today() in SQL
 * (branches.timezone, default Asia/Riyadh).
 */
export const PROPERTY_TIME_ZONE = "Asia/Riyadh";

/** YYYY-MM-DD of an instant in the property's time zone (en-CA formats dates as ISO). */
export function isoDateIn(d: Date, timeZone: string = PROPERTY_TIME_ZONE): string {
  try { return d.toLocaleDateString("en-CA", { timeZone }); } catch { return d.toLocaleDateString("en-CA", { timeZone: PROPERTY_TIME_ZONE }); }
}

/** Today in the property's time zone (pass a branch's own zone when it is known). */
export function todayISO(timeZone?: string): string {
  return isoDateIn(new Date(), timeZone);
}

/** Calendar arithmetic on YYYY-MM-DD strings (no time zone involved). */
export function addDaysISO(iso: string, days: number): string {
  const d = new Date(iso + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export function nightsBetween(checkIn: string, checkOut: string): number {
  const a = new Date(checkIn).getTime();
  const b = new Date(checkOut).getTime();
  return Math.max(0, Math.round((b - a) / 86400000));
}

export function maskId(last4: string | undefined): string {
  if (!last4) return "••••";
  return `•••••${last4}`;
}

export function maskName(name: string | undefined): string {
  if (!name) return "—";
  const parts = name.trim().split(/\s+/);
  if (parts.length < 2) return parts[0]?.[0] + "•••";
  return `${parts[0]} ${parts[1][0]}••`;
}

export function formatCurrency(amount: number): string {
  return new Intl.NumberFormat("ar-SA", { style: "currency", currency: "SAR", maximumFractionDigits: 2 }).format(amount);
}
