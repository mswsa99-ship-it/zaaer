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

/** COPY-02: the Umm al-Qura calendar (the one Saudi Arabia uses) through Intl; the arithmetic estimate only where Intl lacks it. */
const UMALQURA = (() => {
  try { return new Intl.DateTimeFormat("en-u-ca-islamic-umalqura-nu-latn", { timeZone: "UTC", year: "numeric", month: "numeric", day: "numeric" }); } catch { return null; }
})();

export function gregorianToHijri(year: number, month: number, day: number) {
  if (UMALQURA) {
    const parts = UMALQURA.formatToParts(new Date(Date.UTC(year, month - 1, day)));
    const get = (t: string) => Number(parts.find((p) => p.type === t)?.value ?? NaN);
    const h = { year: get("year"), month: get("month"), day: get("day") };
    if (Number.isFinite(h.year) && Number.isFinite(h.month) && Number.isFinite(h.day)) return h;
  }
  return jdToHijri(gregorianToJD(year, month, day));
}

export function hijriToGregorian(year: number, month: number, day: number) {
  const jd = HIJRI_EPOCH_JD + (year - 1) * 354.367 + (month - 1) * 29.5 + day;
  const est = jdToGregorian(jd);
  // the estimate is within a few days: the Umm al-Qura day that matches exactly, when there is one
  const base = Date.UTC(est.year, est.month - 1, est.day);
  for (const off of [0, -1, 1, -2, 2, -3, 3, -4, 4, -5, 5]) {
    const d = new Date(base + off * 86_400_000);
    const h = gregorianToHijri(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate());
    if (h.year === year && h.month === month && h.day === day) return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate() };
  }
  return est;
}

export function formatGregorian(iso: string): string {
  if (!iso) return "";
  const d = new Date(iso);
  return d.toLocaleDateString("en-GB", { year: "numeric", month: "2-digit", day: "2-digit" });
}

export const HIJRI_MONTH_NAMES = ["محرم", "صفر", "ربيع الأول", "ربيع الآخر", "جمادى الأولى", "جمادى الآخرة", "رجب", "شعبان", "رمضان", "شوال", "ذو القعدة", "ذو الحجة"];
export const HIJRI_MONTH_NAMES_EN = ["Muharram", "Safar", "Rabi al-Awwal", "Rabi al-Thani", "Jumada al-Ula", "Jumada al-Akhirah", "Rajab", "Shaban", "Ramadan", "Shawwal", "Dhu al-Qadah", "Dhu al-Hijjah"];

export function formatHijri(iso: string, en = false): string {
  if (!iso) return "";
  const d = new Date(iso);
  const h = gregorianToHijri(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate());
  return en ? `${h.day} ${HIJRI_MONTH_NAMES_EN[h.month - 1] ?? h.month} ${h.year} AH` : `${h.day} ${HIJRI_MONTH_NAMES[h.month - 1] ?? h.month} ${h.year}هـ`;
}

/**
 * The interface's locale (the owner's decision, 30 Oct 2026; design system U2): Arabic words with Latin digits 0–9 and
 * the Gregorian calendar everywhere — amounts, dates and times read the same on every screen and every print.
 */
export const UI_LOCALE = "ar-SA-u-ca-gregory-nu-latn";

export function formatDateTime(iso: string): string {
  if (!iso) return "";
  return new Date(iso).toLocaleString(UI_LOCALE, {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

/**
 * Arabic count with the right word form, by the CLDR plural rules for Arabic (COPY-11): 1 → واحد, 2 → المثنى,
 * 3–10 (and 103–110 …) → الجمع, 11–99 (and 111–199 …) → المفرد المنصوب, 100, 101, 102, 200 … → المفرد المجرور.
 * 0 takes its own phrase when one is given («لا حجوزات»), else the genitive singular («0 حجز»).
 */
export function arabicCount(n: number, [one, two, few, many]: readonly [string, string, string, string], zero?: string): string {
  if (n === 0 && zero) return zero;
  if (n === 1) return one;
  if (n === 2) return two;
  const m = Math.abs(n) % 100;
  if (m >= 3 && m <= 10) return `${n} ${few}`;
  if (m >= 11 && m <= 99) return `${n} ${many}`;
  return `${n} ${many.replace(/ً?ا$|ً$/, "")}`;   // 0, 100–102, 200 …: «100 حجز»
}

/** U1 note 11: the counted nouns the screens show, so «1 مهمة» reads «مهمة واحدة» and «2 ليلة» reads «ليلتان». */
const W = (one: string, two: string, few: string, many: string, zero?: string) => (n: number) => arabicCount(n, [one, two, few, many], zero);
export const COUNT = {
  unit: W("وحدة واحدة", "وحدتان", "وحدات", "وحدة", "لا وحدات"),
  task: W("مهمة واحدة", "مهمتان", "مهام", "مهمة", "لا مهام"),
  night: W("ليلة واحدة", "ليلتان", "ليالٍ", "ليلة"),
  voucher: W("سند واحد", "سندان", "سندات", "سندًا", "لا سندات"),
  booking: W("حجز واحد", "حجزان", "حجوزات", "حجزًا", "لا حجوزات"),
  request: W("طلب واحد", "طلبان", "طلبات", "طلبًا", "لا طلبات"),
  guest: W("نزيل واحد", "نزيلان", "نزلاء", "نزيلًا", "لا نزلاء"),
  companion: W("مرافق واحد", "مرافقان", "مرافقين", "مرافقًا", "لا مرافقين"),
  floor: W("طابق واحد", "طابقان", "طوابق", "طابقًا", "لا طوابق"),
  facility: W("مرفق واحد", "مرفقان", "مرافق", "مرفقًا", "لا مرافق"),
  file: W("ملف واحد", "ملفان", "ملفات", "ملفًا", "لا ملفات"),
  child: W("طفل واحد", "طفلان", "أطفال", "طفلًا", "لا أطفال"),
  branch: W("فرع واحد", "فرعان", "فروع", "فرعًا", "لا فروع"),
  staff: W("موظف واحد", "موظفان", "موظفين", "موظفًا", "لا موظفين"),
  answer: W("إجابة واحدة", "إجابتان", "إجابات", "إجابة", "لا إجابات"),
  question: W("سؤال واحد", "سؤالان", "أسئلة", "سؤالًا", "لا أسئلة"),
  event: W("حدث واحد", "حدثان", "أحداث", "حدثًا", "لا أحداث"),
  day: W("يوم واحد", "يومان", "أيام", "يومًا"),
  week: W("أسبوع واحد", "أسبوعان", "أسابيع", "أسبوعًا"),
  hour: W("ساعة واحدة", "ساعتان", "ساعات", "ساعة"),
  discount: W("خصم واحد", "خصمان", "خصومات", "خصمًا", "لا خصومات"),
  payment: W("دفعة واحدة", "دفعتان", "دفعات", "دفعة", "لا دفعات"),
  conversation: W("محادثة واحدة", "محادثتان", "محادثات", "محادثة", "لا محادثات"),
  attempt: W("محاولة واحدة", "محاولتان", "محاولات", "محاولة"),
  person: W("شخص واحد", "شخصان", "أشخاص", "شخصًا"),
  alert: W("تنبيه واحد", "تنبيهان", "تنبيهات", "تنبيهًا", "لا تنبيهات"),
  record: W("سجل واحد", "سجلان", "سجلات", "سجلًا", "لا سجلات"),
  item: W("بند واحد", "بندان", "بنود", "بندًا", "لا بنود"),
  times: W("مرة واحدة", "مرتين", "مرات", "مرة", "لم تُستخدم بعد"),
  stay: W("إقامة واحدة", "إقامتان", "إقامات", "إقامة", "لا إقامات"),
  ticket: W("طلب تحويل واحد", "طلبا تحويل", "طلبات تحويل", "طلب تحويل", "لا طلبات تحويل"),
  message: W("رسالة واحدة", "رسالتان", "رسائل", "رسالة", "لا رسائل"),
} as const;

/** How long ago, in Arabic: «الآن», «منذ دقيقتين», «منذ 3 ساعات», «منذ 11 يومًا». */
export function sinceArabic(iso: string, now: number = Date.now()): string {
  const minutes = Math.max(0, Math.floor((now - Date.parse(iso)) / 60_000));
  if (!Number.isFinite(minutes)) return "";
  if (minutes < 1) return "الآن";
  if (minutes < 60) return "منذ " + arabicCount(minutes, ["دقيقة", "دقيقتين", "دقائق", "دقيقة"]);
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return "منذ " + arabicCount(hours, ["ساعة", "ساعتين", "ساعات", "ساعة"]);
  return "منذ " + arabicCount(Math.floor(hours / 24), ["يوم", "يومين", "أيام", "يومًا"]);
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
  if (!name || !name.trim() || name.trim() === "—") return "—";   // COPY-29: no «—•••»
  const parts = name.trim().split(/\s+/);
  if (parts.length < 2) return parts[0]?.[0] + "•••";
  return `${parts[0]} ${parts[1][0]}••`;
}

/**
 * GUEST-17: one way to say a time of day on the guest's pages — «4:00 عصرًا», «12:00 ظهرًا», «4:00 PM» — from the
 * branch's "16:00:00". Empty when the time is not set.
 */
export function formatClock(t: string | null | undefined, en = false): string {
  if (!t) return "";
  const [h, m] = t.split(":").map(Number);
  if (!Number.isFinite(h)) return "";
  const hh = h % 12 || 12, mm = String(m || 0).padStart(2, "0");
  if (en) return `${hh}:${mm} ${h >= 12 ? "PM" : "AM"}`;
  return `${hh}:${mm} ${h >= 12 ? (h >= 18 ? "مساءً" : h === 12 ? "ظهرًا" : "عصرًا") : "صباحًا"}`;
}

/** COPY-12: one money form on every screen and in the server's texts — «1,600.00 ر.س», grouped, no trailing period. */
const MONEY_NUMBER = new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
export function formatCurrency(amount: number): string {
  return `${MONEY_NUMBER.format(Number.isFinite(amount) ? amount : 0)} ر.س`;
}

/**
 * A11Y-13 (APG radio group): the arrow keys move between the options of a `role="radiogroup"` and choose the one
 * they land on; Tab reaches the group once (the chosen option holds tabIndex 0, the others -1).
 */
export function radioGroupKeys(e: { key: string; currentTarget: HTMLElement; preventDefault: () => void }) {
  const keys: Record<string, number> = { ArrowLeft: 1, ArrowDown: 1, ArrowRight: -1, ArrowUp: -1 };   // right-to-left: ← is next
  const step = keys[e.key];
  if (!step) return;
  const radios = Array.from(e.currentTarget.querySelectorAll<HTMLElement>('[role="radio"]:not([disabled])'));
  if (radios.length === 0) return;
  e.preventDefault();
  const at = radios.findIndex((r) => r === document.activeElement || r.getAttribute("aria-checked") === "true");
  const next = radios[(Math.max(at, 0) + step + radios.length) % radios.length];
  next.focus();
  next.click();
}
