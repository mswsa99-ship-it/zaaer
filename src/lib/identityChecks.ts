import { checkIdentityNumber, latinDigits } from "./validation";

/** Advisory only. A checksum is not proof that a document was issued or belongs to the guest.
 * Algorithm reference: https://github.com/alhazmy13/Saudi-ID-Validator/blob/master/validateSAID.py
 * Format errors remain the responsibility of checkIdentityNumber, never this warning.
 */
export function hasSaudiIdentityChecksumWarning(type: string, number: string): boolean {
  if (type !== "national_id" && type !== "iqama") return false;
  const value = latinDigits(number).replace(/\s/g, "");
  try { checkIdentityNumber(type, value); } catch { return false; }
  let sum = 0;
  for (let i = 0; i < value.length; i++) {
    const n = Number(value[i]) * (i % 2 === 0 ? 2 : 1);
    sum += n > 9 ? n - 9 : n;
  }
  return sum % 10 !== 0;
}

/** Existing fn_valid_iban / demo rule, extracted without changing its input semantics.
 * Reference: https://www.swift.com/sites/default/files/files/iban-registry-100.txt
 */
export function validIban(p: string | null | undefined): boolean {
  const s = String(p ?? "").replace(/\s/g, "").toUpperCase();
  if (!/^SA\d{2}[0-9A-Z]{20}$/.test(s)) return false;
  const moved = s.slice(4) + s.slice(0, 4);
  let r = 0; for (const ch of moved) { const d = /\d/.test(ch) ? ch : String(ch.charCodeAt(0) - 55); for (const x of d) r = (r * 10 + Number(x)) % 97; }
  return r === 1;
}

/** Input normalization matches the existing branch-guide save path. Empty is not an IBAN;
 * the optional input handles clearing separately. This does not verify account ownership.
 */
export function validSaudiIban(input: string): boolean {
  return validIban(latinDigits(input));
}
