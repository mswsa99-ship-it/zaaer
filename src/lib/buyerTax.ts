/**
 * Buyer data a ZATCA standard (B2B) tax invoice needs. Source: ZATCA Electronic Invoice XML Implementation Standard v1.2
 * (rules BR-10, BR-KSA-10, BR-KSA-63, BR-KSA-67, BR-KSA-81) and the E-invoicing Detailed Technical Guideline (VAT number
 * format; the FAQ: with no buyer VAT number an additional buyer ID is mandatory). A PO box is NOT in the required fields.
 * Pure checks only: this file does not claim an invoice is compliant, and nothing here talks to ZATCA.
 */
import { latinDigits } from "./validation";

export interface BuyerAddress { street: string; building_number: string; postal_code: string; city: string; district: string; country_code: string }

/** A KSA VAT registration number: 15 digits, the first and the last are 3. */
export function checkVatNumber(raw: string | null | undefined): void {
  const v = latinDigits(String(raw ?? "")).replace(/\s/g, "");
  if (!v) return; // optional: a buyer that is not VAT registered gives another ID instead
  if (!/^3\d{13}3$/.test(v)) throw new Error("VALIDATION: vat_number_format");
}

/** For a buyer in Saudi Arabia: street, building number (4 digits), postal code (5 digits), city and district are all required. */
export function checkBuyerAddress(a: Partial<BuyerAddress>): string[] {
  const miss: string[] = [];
  const t = (s?: string) => (s ?? "").trim();
  if (!t(a.street)) miss.push("street");
  if (!/^\d{4}$/.test(latinDigits(t(a.building_number)))) miss.push("building_number");
  if (!/^\d{5}$/.test(latinDigits(t(a.postal_code)))) miss.push("postal_code");
  if (!t(a.city)) miss.push("city");
  if (!t(a.district)) miss.push("district");
  return miss;
}

export const BUYER_ADDRESS_LABELS_AR: Record<string, string> = { street: "اسم الشارع", building_number: "رقم المبنى (4 أرقام)", postal_code: "الرمز البريدي (5 أرقام)", city: "المدينة", district: "الحي" };
