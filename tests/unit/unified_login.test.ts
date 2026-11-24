import { readFileSync } from "node:fs";
import { describe, it, expect } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import { loginDestination, safeReturnPath } from "../../src/lib/loginRouting";
import { readLoginIdentity } from "../../src/lib/loginIdentity";
import { defaultPermissions } from "../../src/lib/permissionCatalog";
import type { StaffProfile } from "../../src/lib/auth";
const profile = (role = "owner") => ({ role, is_active: true } as StaffProfile);
const base = { loading: false, hasSession: true, error: null, operator: false, profile: profile(), allows: { can: () => true, canFull: () => true }, returnTo: null };

describe("unified sign-in routing", () => {
  it.each(["https://evil.test", "//evil.test", "/\\evil.test", "/staff/../admin/finance", "/staff/%2e%2e/admin/finance", "/staff/dashboard?next=https://evil.test", "/staff/dashboard#x", "/staff/login", "/booking/lookup", "/owner/setup", "/staff//dashboard", "/admin/missing", "/staff/dashboard\n"])("rejects unsafe or non-allowlisted return path %s", value => expect(safeReturnPath(value)).toBeNull());
  it("blocks operators from hotel entrance and staff from platform entrance", () => { expect(loginDestination({ ...base, operator: true })).toBeNull(); expect(loginDestination({ ...base, entry: "platform" })).toBeNull(); });
  it("keeps an authorized relative destination", () => expect(loginDestination({ ...base, returnTo: "/staff/reservations" })).toBe("/staff/reservations"));
  it("does not elevate a staff account to platform", () => expect(loginDestination({ ...base, returnTo: "/platform" })).toBe("/staff/dashboard"));
  it("operators only land from their separate entrance", () => expect(loginDestination({ ...base, entry: "platform", operator: true, profile: null, returnTo: "/admin/finance" })).toBe("/platform"));
  it.each(["owner", "manager", "supervisor", "finance", "housekeeping"])("uses allowed role default for %s", role => {
    const perms = defaultPermissions(role); const paths: Record<string,string> = { owner: "/staff/dashboard", manager: "/staff/dashboard", supervisor: "/staff/rooms", finance: "/admin/finance", housekeeping: "/staff/housekeeping" };
    expect(loginDestination({ ...base, profile: profile(role), allows: { can: c => perms.allowed.has(c), canFull: c => perms.full.has(c) } })).toBe(paths[role]);
  });
  it("denies a return page absent from permissions", () => expect(loginDestination({ ...base, profile: profile("housekeeping"), allows: { can: () => false, canFull: () => false }, returnTo: "/admin/finance" })).not.toBe("/admin/finance"));
  it("waits for loading and blocks errors rather than onboarding", () => {
    expect(loginDestination({ ...base, loading: true })).toBeNull();
    expect(loginDestination({ ...base, error: "failed", profile: null })).toBeNull();
    expect(loginDestination({ ...base, hasSession: false })).toBeNull();
    expect(loginDestination({ ...base, profile: { ...profile(), is_active: false } })).toBeNull();
    expect(loginDestination({ ...base, profile: profile("guest") })).toBeNull();
    expect(loginDestination({ ...base, profile: null })).toBe("/owner/setup");
  });
});

function client(options: { operatorError?: boolean; profileError?: boolean; claimError?: boolean; permissionError?: boolean; missing?: boolean; operator?: boolean; inactive?: boolean }) {
  return { rpc: async (name: string) => name === "fn_platform_operator_id" ? { data: options.operator ? "uid" : null, error: options.operatorError } : name === "fn_claim_staff_profile" ? { data: {}, error: options.claimError } : { data: { allowed: ["res.read"], full: [], sees_money: false }, error: options.permissionError }, from: () => ({ select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: options.missing ? null : { ...profile(), is_active: !options.inactive }, error: options.profileError }) }) }) }) } as unknown as SupabaseClient;
}
describe("server identity lookup fails closed", () => {
  it.each([{ operatorError: true }, { profileError: true }, { missing: true, claimError: true }, { permissionError: true }])("never treats failed lookup as an empty profile: %j", async options => { await expect(readLoginIdentity(client(options), "uid")).rejects.toThrow(); });
  it("allows confirmed empty profile to onboarding decision", async () => expect((await readLoginIdentity(client({ missing: true }), "uid")).profile).toBeNull());
  it("uses server permissions rather than client defaults", async () => expect([...(await readLoginIdentity(client({}), "uid")).permissions.allowed]).toEqual(["res.read"]));
  it("keeps inactive profile blocked with no permissions", async () => expect((await readLoginIdentity(client({ inactive: true }), "uid")).permissions.allowed.size).toBe(0));
});

it("staff creation excludes owner and registration entry is owner-only", () => {
 const staff = readFileSync(new URL("../../src/pages/admin/AdminStaff.tsx", import.meta.url), "utf8");
 expect(staff.match(/const INVITE_ROLES = \[(.*?)\]/)?.[1]).not.toContain("owner");
 const login = readFileSync(new URL("../../src/pages/staff/StaffLogin.tsx", import.meta.url), "utf8");
 expect(login).toContain("التسجيل الجديد فقط متاح للملاك أو مسؤول الفندق.");
 expect(login).toContain("<OwnerRegister embedded");
 expect(login).not.toContain("state: { email:");
});
