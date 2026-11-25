import { describe, expect, it } from "vitest";
import { hasSaudiIdentityChecksumWarning, validIban, validSaudiIban } from "../../src/lib/identityChecks";
import { validIban as demoValidIban } from "../../src/demo/phase2";
import { checkIdentityNumber, latinDigits } from "../../src/lib/validation";

// Algorithm reference (not identity verification):
// https://github.com/alhazmy13/Saudi-ID-Validator/blob/master/validateSAID.py
// IDs below are invented checksum fixtures, not people or issued-document claims.
// IBAN reference example: https://www.swift.com/sites/default/files/files/iban-registry-100.txt
const syntheticId = "1000000008";
const syntheticIqama = "2000000006";
const registryIban = "SA0380000000608010167519";

describe("identity checksum advisory", () => {
  it("accepts invented valid checksum fixtures for both document types", () => {
    expect(hasSaudiIdentityChecksumWarning("national_id", syntheticId)).toBe(false);
    expect(hasSaudiIdentityChecksumWarning("iqama", syntheticIqama)).toBe(false);
  });
  it("warns on an incorrect checksum without changing format acceptance", () => {
    for (const [type, number] of [["national_id", "1000000009"], ["iqama", "2000000007"]]) {
      expect(hasSaudiIdentityChecksumWarning(type, number)).toBe(true);
      expect(() => checkIdentityNumber(type, number)).not.toThrow();
    }
  });
  it("keeps existing malformed document rejection separate from the advisory", () => {
    for (const value of ["", "100", "2000000006", "100000000X", "10000000088"]) {
      expect(hasSaudiIdentityChecksumWarning("national_id", value)).toBe(false);
      expect(() => checkIdentityNumber("national_id", value)).toThrow("identity_number_format");
    }
  });
  it("never applies Saudi checksums to passports or GCC documents", () => {
    for (const type of ["passport", "gcc_id"]) expect(hasSaudiIdentityChecksumWarning(type, "1000000009")).toBe(false);
  });
  it("normalizes Arabic and Persian digits and spaces for advisory display", () => {
    expect(hasSaudiIdentityChecksumWarning("national_id", "١٠٠٠ ٠٠٠٠٠٩")).toBe(true);
    expect(hasSaudiIdentityChecksumWarning("iqama", "۲۰۰۰۰۰۰۰۰۶")).toBe(false);
  });
  it("detects each single digit substitution of an invented valid ID", () => {
    for (let i = 1; i < syntheticId.length; i++) {
      const mutated = syntheticId.slice(0, i) + ((Number(syntheticId[i]) + 1) % 10) + syntheticId.slice(i + 1);
      expect(hasSaudiIdentityChecksumWarning("national_id", mutated)).toBe(true);
    }
  });
});

describe("Saudi IBAN input checksum", () => {
  it("passes the published SWIFT example and accepts existing input normalization", () => {
    expect(validSaudiIban(registryIban)).toBe(true);
    expect(validSaudiIban("sa03 8000 0000 6080 1016 7519")).toBe(true);
    expect(validSaudiIban("SA٠٣٨٠٠٠٠٠٠٠٦٠٨٠١٠١٦٧٥١٩")).toBe(true);
    expect(validSaudiIban("SA۰۳۸۰۰۰۰۰۰۰۶۰۸۰۱۰۱۶۷۵۱۹")).toBe(true);
  });
  it("refuses checksum errors even when the shape is correct", () => {
    expect(validSaudiIban("SA0480000000608010167519")).toBe(false);
    for (let i = 2; i < registryIban.length; i++) {
      const mutated = registryIban.slice(0, i) + ((Number(registryIban[i]) + 1) % 10) + registryIban.slice(i + 1);
      expect(validSaudiIban(mutated)).toBe(false);
    }
  });
  it("retains the existing Saudi-only shape restriction", () => {
    for (const value of ["", "SA03", registryIban + "0", registryIban.slice(0, -1), "GB29NWBK60161331926819", "SA03-80000000608010167519", "SA038000000060801016751!"]) expect(validSaudiIban(value)).toBe(false);
  });
});

it("shares the exact demo checksum and preserves raw versus save-path digit normalization", () => {
  expect(demoValidIban).toBe(validIban);
  const inputs = [null, undefined, "", registryIban, "sa03 8000 0000 6080 1016 7519", "SA٠٣٨٠٠٠٠٠٠٠٦٠٨٠١٠١٦٧٥١٩", "SA۰۳۸۰۰۰۰۰۰۰۶۰۸۰۱۰۱۶۷۵۱۹", "SA0480000000608010167519"];
  for (const input of inputs) {
    expect(demoValidIban(input)).toBe(validIban(input));
    expect(validSaudiIban(input ?? "")).toBe(demoValidIban(latinDigits(input ?? "")));
  }
  expect(demoValidIban("SA٠٣٨٠٠٠٠٠٠٠٦٠٨٠١٠١٦٧٥١٩")).toBe(false);
});
