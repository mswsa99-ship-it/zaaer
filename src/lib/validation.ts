/**
 * The data rules of migration 0047 (correction batch 1: the owner's notes 1, 4 and 14; decisions 2 and 6), in one place
 * for the forms (to warn as the user types) and the demo backend (to refuse as the server does). The server is the
 * authority; these functions mirror it rule for rule and throw the same «VALIDATION: …» codes.
 */

const ARABIC_DIGITS = "٠١٢٣٤٥٦٧٨٩";
const PERSIAN_DIGITS = "۰۱۲۳۴۵۶۷۸۹";

/** Arabic-Indic and Persian digits as 0–9. */
export function latinDigits(s: string): string {
  return s.replace(/[٠-٩۰-۹]/g, (c) => String(ARABIC_DIGITS.includes(c) ? ARABIC_DIGITS.indexOf(c) : PERSIAN_DIGITS.indexOf(c)));
}

const NAME_ALLOWED = /^[A-Za-zÀ-ÖØ-öø-ɏء-غـ-ْٰ-ۓ '’.-]+$/;
const NAME_LETTER = /[A-Za-zÀ-ÖØ-öø-ɏء-غف-يٱ-ۓ]/g;

/** A person's name: letters (Arabic or Latin), spaces, hyphen, apostrophe, dot; at least two letters. Empty is left to «required». */
export function checkPersonName(name: string | null | undefined): void {
  const s = (name ?? "").trim();
  if (!s) return;
  if (!NAME_ALLOWED.test(s) || (s.match(NAME_LETTER) ?? []).length < 2) throw new Error("VALIDATION: name_letters_only");
}

/**
 * A phone as it is kept: 05XXXXXXXX for a Saudi mobile (also written 5…, 9665…, +9665…, 009665…),
 * +<digits> for another country (+ or 00, then 8–15 digits). Null when empty and not required.
 */
export function checkPhone(phone: string | null | undefined, required: boolean): string | null {
  let d = latinDigits(phone ?? "").replace(/[\s()-]/g, "");
  if (!d) {
    if (required) throw new Error("VALIDATION: phone_required");
    return null;
  }
  if (d.startsWith("+")) d = "00" + d.slice(1);
  if (!/^\d+$/.test(d)) throw new Error("VALIDATION: phone_format");
  if (/^05\d{8}$/.test(d)) return d;
  if (/^5\d{8}$/.test(d)) return "0" + d;
  if (/^(00)?9665\d{8}$/.test(d)) return "0" + d.slice(-9);
  if (/^00[1-9]\d{7,14}$/.test(d) && !d.startsWith("00966")) return "+" + d.slice(2);
  throw new Error("VALIDATION: phone_format");
}

/** No one younger than 15 on the day the data is entered (dates as YYYY-MM-DD). */
export function checkMinAge(birth: string | null | undefined, today: string): void {
  if (!birth) return;
  const [y, m, dd] = today.split("-").map(Number);
  const limit = `${String(y - 15).padStart(4, "0")}-${String(m).padStart(2, "0")}-${String(dd).padStart(2, "0")}`;
  if (birth > limit) throw new Error("VALIDATION: minimum_age_15");
}

/** The latest birth date the form may offer today: exactly 15 years ago. */
export function maxBirthDate(today: string): string {
  const [y, m, d] = today.split("-").map(Number);
  return `${String(y - 15).padStart(4, "0")}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

/** A national ID is 10 digits starting 1; an iqama 10 digits starting 2. */
export function checkIdentityNumber(type: string, number: string): void {
  if (type === "national_id" && !/^1\d{9}$/.test(number)) throw new Error("VALIDATION: identity_number_format");
  if (type === "iqama" && !/^2\d{9}$/.test(number)) throw new Error("VALIDATION: identity_number_format");
  if (type === "gcc_id" && !/^[A-Za-z0-9]{6,15}$/.test(number)) throw new Error("VALIDATION: identity_number_format");
  if (type === "passport" && !/^[A-Za-z0-9]{5,12}$/.test(number)) throw new Error("VALIDATION: identity_number_format");
}

/** The form's live hint: the Arabic message for the rule a value breaks, or null when it passes. */
export function fieldError(check: () => unknown, messages: Record<string, string>): string | null {
  try {
    check();
    return null;
  } catch (e) {
    const code = String((e as Error).message).replace(/^VALIDATION:\s*/, "");
    return messages[code] ?? null;
  }
}
