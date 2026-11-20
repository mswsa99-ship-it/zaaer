/**
 * A clock time as the guest reads it, and the free hour's window from the branch's own times — the check-out time and
 * the free hour's end (0070's fn_ar_hm, fn_ar_period, fn_ar_window, fn_ar_range; the WhatsApp flow keeps its own copy):
 * «بين 12 و1 ظهرًا», «12–1»; "between 12 and 1 PM", "12–1".
 */
/** "HH:MM[:SS]" → minutes since midnight ("24:00" is 1440) */
export const toMin = (t: string | null | undefined) => { const m = /^(\d{1,2}):(\d{2})/.exec(String(t ?? "")); return m ? Number(m[1]) * 60 + Number(m[2]) : 0; };
const clock12 = (min: number) => { const h = Math.floor(min / 60), m = min % 60; return String(((h + 11) % 12) + 1) + (m > 0 ? ":" + String(m).padStart(2, "0") : ""); };
export const arPeriod = (min: number) => (min === 0 || min >= 1440 ? "منتصف الليل" : min < 720 ? "صباحًا" : min < 900 ? "ظهرًا" : min < 1080 ? "عصرًا" : "مساءً");
const enPeriod = (min: number) => (min === 0 || min >= 1440 ? "midnight" : min < 720 ? "AM" : "PM");
export const arWindow = (a: number, b: number) =>
  arPeriod(a) === arPeriod(b) ? `بين ${clock12(a)} و${clock12(b)} ${arPeriod(b)}` : `بين ${clock12(a)} ${arPeriod(a)} و${clock12(b)} ${arPeriod(b)}`;
export const enWindow = (a: number, b: number) =>
  enPeriod(a) === enPeriod(b) ? `between ${clock12(a)} and ${clock12(b)} ${enPeriod(b)}` : `between ${clock12(a)} ${enPeriod(a)} and ${clock12(b)} ${enPeriod(b)}`;
export const clockRange = (a: number, b: number) => `${clock12(a)}–${clock12(b)}`;
