/**
 * GUEST-10 (owner decision, 31 Oct review): the guest pages a foreign guest must complete — «حجوزاتي», the booking
 * status, the guests' registration and the key-box code — read in Arabic or English. The guest picks the language
 * with the button in the header (or a link with ?lang=en); the choice is kept on this device. Strings are written
 * as pairs where they are used (t("…", "…")), so a page never shows a key instead of a sentence. Data the property
 * writes in Arabic (policies, the branch guide, the stay summary) is shown as written.
 */
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { toArabicError } from "./api";

export type GuestLang = "ar" | "en";
const KEY = "guest_lang";

/** ?lang=en in the address (also after the # of the demo's hash routes) */
function langInUrl(): string | null {
  const h = window.location.hash, i = h.indexOf("?");
  return new URLSearchParams(window.location.search).get("lang") ?? (i >= 0 ? new URLSearchParams(h.slice(i + 1)).get("lang") : null);
}

function initialLang(): GuestLang {
  try {
    const q = langInUrl();
    if (q === "en" || q === "ar") return q;
    const s = localStorage.getItem(KEY);
    if (s === "en" || s === "ar") return s;
  } catch { /* storage blocked or no window */ }
  return "ar";
}

const Ctx = createContext<{ lang: GuestLang; setLang: (l: GuestLang) => void }>({ lang: "ar", setLang: () => undefined });

/** `active`: the page reads in both languages; the others stay Arabic whatever was chosen (the choice is kept). */
export function GuestLangProvider({ children, active = true }: { children: ReactNode; active?: boolean }) {
  const [lang, setLangState] = useState<GuestLang>(initialLang);
  const setLang = useCallback((l: GuestLang) => {
    setLangState(l);
    try { localStorage.setItem(KEY, l); } catch { /* ignore */ }
  }, []);
  useEffect(() => { try { if (langInUrl()) localStorage.setItem(KEY, lang); } catch { /* ignore */ } }, [lang]);
  const value = useMemo(() => ({ lang: active ? lang : "ar" as GuestLang, setLang }), [lang, setLang, active]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useGuestLang() {
  const { lang, setLang } = useContext(Ctx);
  const en = lang === "en";
  const t = useCallback((ar: string, english: string) => (en ? english : ar), [en]);
  return { lang, en, t, setLang, dir: (en ? "ltr" : "rtl") as "ltr" | "rtl" };
}

// ---------------------------------------------------------------------------------------------------------------
// Labels and formats
// ---------------------------------------------------------------------------------------------------------------
export const STATUS_EN: Record<string, string> = {
  draft: "Draft", pending_verification: "Awaiting verification", confirmed: "Confirmed", checked_in: "Checked in",
  checked_out: "Checked out", closed: "Closed", cancelled: "Cancelled", rejected: "Rejected", no_show: "No-show",
};
export const PAYMENT_EN: Record<string, string> = {
  pending: "Awaiting payment", processing: "Processing", paid: "Paid", failed: "Failed", partially_paid: "Partly paid", refunded: "Refunded", overpaid: "Overpaid",
};
export const VERIFICATION_EN: Record<string, string> = {
  not_started: "Not started", data_submitted: "Details submitted", pending_supervisor: "Awaiting the reception", verified: "Verified", rejected: "Rejected",
};
export const IDENTITY_TYPE_EN: Record<string, string> = { national_id: "Saudi national ID", iqama: "Iqama (residence permit)", passport: "Passport", gcc_id: "GCC ID" };

/** «1 night», «3 nights» */
export const countEn = (n: number, one: string, many = one + "s") => `${n} ${n === 1 ? one : many}`;
/** SAR 1,250.00 — the English page's money */
export const moneyEn = (sar: number) => new Intl.NumberFormat("en-US", { style: "currency", currency: "SAR", minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(sar);

// ---------------------------------------------------------------------------------------------------------------
// The server's reasons and errors, in English. Anything not known here is shown as the server wrote it.
// ---------------------------------------------------------------------------------------------------------------
const AMOUNT = /([\d,٬.]+)\s*(?:ر\.س\.?|ريال)/;
const sarIn = (s: string) => { const m = s.match(AMOUNT); return m ? `SAR ${m[1].replace(/٬/g, ",")}` : ""; };

const REASONS_EN: Array<[RegExp, (ar: string) => string]> = [
  [/^الحجز غير مؤكد$/, () => "The booking is not confirmed yet"],
  [/^لم تُسجَّل بيانات النزلاء$/, () => "The guests' details have not been registered"],
  [/^بيانات أحد النزلاء ناقصة$/, () => "One guest's details are incomplete"],
  [/^عدد النزلاء المسجلين أقل من عدد الحجز$/, () => "Fewer guests are registered than the booking holds"],
  [/^لم تُعتمد مطابقة الهوية لجميع النزلاء$/, () => "The reception has not yet checked every guest's ID"],
  [/^لم تُخصَّص وحدة$/, () => "No unit has been assigned yet"],
  [/^الوحدة غير نظيفة$/, () => "The unit is being cleaned"],
  [/^الوحدة تحت الصيانة$/, () => "The unit is under maintenance"],
  [/^الوحدة موقوفة عن العمل$/, () => "The unit is out of service"],
  [/^الوحدة محجوزة لحجز آخر في هذه الفترة$/, () => "The unit is held for another booking in this period"],
  [/^في الوحدة نزيل لم تُسجَّل مغادرته$/, () => "The previous guest has not checked out yet"],
  [/^لم يُسجَّل النزلاء في شموس$/, () => "Guest registration with the authorities (Shomoos) is pending"],
  [/^لم يُؤكَّد قبول شموس للتسجيل$/, () => "Guest registration with the authorities (Shomoos) is pending"],
  [/^تغيّر عدد النزلاء بعد تسجيل شموس/, () => "The number of guests changed; the reception will update the registration"],
  [/^لم يُسجَّل الوصول بعد$/, () => "Check-in at the reception is not done yet"],
  [/^يُسجَّل الوصول في الاستقبال ثم يُسلَّم الرمز$/, () => "Check in at the reception first; the code follows"],
  [/^لم يُعيَّن رمز الصندوق$/, () => "The key-box code is not set yet"],
  [/^رمز الصندوق يحتاج إلى تغيير$|^الرمز الحالي سُلِّم لحجز آخر/, () => "The key-box code is being changed"],
  [/^لم يُجرَّب رمز الصندوق على الصندوق$/, () => "The reception is testing the key-box code"],
  [/^الوحدة بلا صندوق مفتاح/, () => "This unit has no key box; the key is handed over at the reception"],
  [/^انتهى موعد المغادرة$|^انتهت فترة الإقامة$|^الإقامة غير قائمة$/, () => "The stay has ended"],
  [/^لم يحن تاريخ الوصول/, (ar) => `It is not the arrival date yet${(ar.match(/\((\d{4}-\d{2}-\d{2})\)/) ?? [])[1] ? ` (${(ar.match(/\((\d{4}-\d{2}-\d{2})\)/) ?? [])[1]})` : ""}`],
  [/^سُجِّل وصول هذا الحجز مسبقًا$/, () => "This booking is already checked in"],
  [/^الليلة الأولى غير مدفوعة كاملة/, (ar) => `The first night is not fully paid${sarIn(ar) ? `: ${sarIn(ar)} left` : ""}`],
  [/^التأمين لم يُستلم كاملًا/, (ar) => `The security deposit is not fully received${sarIn(ar) ? `: ${sarIn(ar)} required` : ""}`],
  [/^مبلغ مستحق/, (ar) => `Amount due${sarIn(ar) ? `: ${sarIn(ar)}` : ""}`],
  [/^يرجى مراجعة الاستقبال$/, () => "Please see the reception"],
  [/^لم يُسلَّم الرمز بعد$|^لم يتم تسليم الرمز بعد$/, () => "The code has not been released yet"],
  [/^الرمز غير مخصص لهذا الحجز$/, () => "The code is not assigned to this booking"],
  [/^الحجز غير موجود$/, () => "Booking not found"],
];
export function reasonEn(ar: string): string {
  for (const [re, f] of REASONS_EN) if (re.test(ar)) return f(ar);
  return ar;
}

const VALIDATION_EN: Record<string, string> = {
  full_name_three_parts: "Enter the full name as on the ID (first, father's and family name).",
  full_name_two_parts: "Enter the name as on the passport or GCC ID (at least first and family name).",
  name_letters_only: "Use letters only (Arabic or English), without numbers or symbols.",
  identity_number_format: "The ID number is not valid: a Saudi ID is 10 digits starting with 1, an iqama 10 digits starting with 2.",
  identity_number_format_passport: "The passport number is 5 to 12 English letters and digits.",
  identity_number_format_gcc: "The GCC ID number is 6 to 15 English letters and digits.",
  identity_type: "The document type is not valid.",
  nationality: "Nationality is required.",
  birth_date: "The date of birth is not valid.", birth_date_range: "The date of birth is out of range.",
  minimum_age_15: "Guests under 15 are not registered with a document; add them under «Children under 15».",
  consent_required: "Please confirm the details are correct.",
  acknowledgement_required: "Please accept the stay summary first.",
  phone_required_primary: "A mobile number is required for the main guest.", phone_required: "A mobile number is required for the main guest.",
  phone_format: "Mobile number: a Saudi number starts with 05 and has 10 digits; an international one starts with + and the country code.",
  phone: "The phone number is not valid.",
  child_age: "A child's age is a number from 0 to 14.", children: "The children's list is not valid.",
  children_registered: "More guests are registered with a document than remain after the children; ask the reception to remove one.",
};
const ERROR_EN: Record<string, string> = {
  TOKEN_INVALID: "This link is not valid or has expired.",
  TOKEN_EXPIRED: "This link has expired.",
  RESERVATION_NOT_FOUND: "Booking not found.",
  GUEST_NOT_FOUND: "Guest record not found.",
  GUEST_LIMIT_REACHED: "All the booking's guests are already registered.",
  DUPLICATE_GUEST: "This document is already registered on this booking.",
  GUEST_ALREADY_VERIFIED: "This guest is already verified; the details cannot be changed.",
  RESERVATION_NOT_EDITABLE: "This booking can no longer be changed.",
  RATE_LIMITED: "Too many attempts. Please wait a little and try again.",
};

/** The guest's error in the page's language; the English page keeps the trace code for the reception. */
export function guestError(e: unknown, en: boolean): string {
  if (!en) return toArabicError(e);
  const msg = (e as { message?: string })?.message ?? String(e);
  const trace = (e as { traceId?: string })?.traceId;
  const v = msg.match(/VALIDATION:\s*([a-z_0-9]+)/i);
  let text = v ? VALIDATION_EN[v[1]] : undefined;
  if (!text) for (const k of Object.keys(ERROR_EN)) if (msg.includes(k)) { text = ERROR_EN[k]; break; }
  text ??= "Something went wrong. Please try again, or contact the reception.";
  return trace ? `${text} (trace: ${trace})` : text;
}

/** The form's live hint in English (the same rules as fieldError with VALIDATION_AR). */
export function validationMessages(en: boolean, ar: Record<string, string>): Record<string, string> {
  return en ? { ...ar, ...VALIDATION_EN } : ar;
}
