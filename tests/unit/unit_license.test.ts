/**
 * The unit's licence number (0075, plan item 1.8): the rule the form checks before the server does, the same rule
 * in the migration, and the demo's copy of the two functions — the owner, the manager and the supervisor read it,
 * nobody else; changed with «definitions»; the log keeps the last four characters only (UL20–UL27).
 */
import { describe, it, expect, beforeAll, beforeEach } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { normalizeUnitLicense } from "../../src/lib/validation";
import { readsUnitLicense, readsUnitLicenseFor, setsUnitLicenseOnCreate, UNIT_LICENSE_READERS } from "../../src/lib/unitLicenseRoles";

const m75 = readFileSync(join(__dirname, "..", "..", "supabase/migrations/20261123110000_0075_unit_license.sql"), "utf8");
const refused = (s: string) => { try { normalizeUnitLicense(s); return "accepted"; } catch (e) { return (e as Error).message; } };

describe("UL — the number's rule", () => {
  it("UL20 Arabic-Indic digits read as Latin, letters kept in capitals, spaces around trimmed; empty clears it", () => {
    expect(normalizeUnitLicense("  tl-٢٠٢٥/0101 ")).toBe("TL-2025/0101");
    expect(normalizeUnitLicense("۱۲۳abc")).toBe("123ABC");
    expect(normalizeUnitLicense("A".repeat(40))).toBe("A".repeat(40));
    expect(normalizeUnitLicense("")).toBeNull();
    expect(normalizeUnitLicense("   ")).toBeNull();
    expect(normalizeUnitLicense(null)).toBeNull();
  });

  it("UL21 Arabic letters, spaces inside, a leading «-» or «/», other symbols and more than 40 characters are refused", () => {
    for (const bad of ["ترخيص 12", "A B", "-ABC", "/12", "A_1", "A.1", "9".repeat(41), "ß1", "ı1"]) expect(refused(bad), bad).toBe("VALIDATION: room_license");
  });

  it("UL22 the migration checks the same characters, before capitals, and the same length", () => {
    expect(m75).toContain("v !~ '^[A-Za-z0-9][A-Za-z0-9/-]*$'");
    expect(m75).toContain("char_length(v) > 40");
    expect(m75.indexOf("v !~ '^[A-Za-z0-9]")).toBeLessThan(m75.indexOf("v := upper(v);"));
    expect(m75).toContain("fn_has_role('owner', 'manager', 'supervisor')");
    expect(m75).not.toMatch(/delet|drop|truncat/i);
  });

  it("UL23 the three reader roles, and no others", () => {
    expect([...UNIT_LICENSE_READERS].sort()).toEqual(["manager", "owner", "supervisor"]);
    for (const r of ["owner", "manager", "supervisor"]) expect(readsUnitLicense(r)).toBe(true);
    for (const r of ["finance", "housekeeping", "guest", "", null, undefined]) expect(readsUnitLicense(r as string | null | undefined)).toBe(false);
  });
});

// ---------------------------------------------------------------- the demo's copy (src/demo/client.ts)
type Client = ReturnType<typeof import("../../src/demo/client")["createDemoClient"]>;
let client: Client;
let resetDemo: () => void;
const memStorage = () => {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, String(v)), removeItem: (k: string) => void m.delete(k), clear: () => m.clear(), key: () => null, length: 0 };
};
const BRANCH_A = "00000000-0000-0000-0000-000000000010";
const BRANCH_B = "00000000-0000-0000-0000-000000000012";
async function login(email: string) { await client.auth.signInWithPassword({ email, password: "demo" }); }
async function rpc<T = any>(fn: string, args: Record<string, unknown> = {}): Promise<{ data: T; error: { message: string } | null }> {
  const { data, error } = await client.rpc(fn, args);
  return { data: data as T, error: error as { message: string } | null };
}
async function roomId(number: string): Promise<string> {
  const r = await client.from("rooms").select("id, room_number");
  return ((r.data as any[]) ?? []).find((x) => x.room_number === number).id;
}

beforeAll(async () => {
  (globalThis as any).window = globalThis;
  (globalThis as any).localStorage = memStorage();
  (globalThis as any).sessionStorage = memStorage();
  const mod = await import("../../src/demo/client");
  client = mod.createDemoClient();
  resetDemo = mod.resetDemo;
});
beforeEach(async () => { resetDemo(); await login("owner@demo.sa"); });

describe("UL — the demo keeps the same rules", () => {
  it("UL24 the owner reads the branch's licences and changes one; the stored number follows the rule", async () => {
    const r101 = await roomId("101"), r103 = await roomId("103");
    const list = (await rpc<any[]>("fn_room_licenses", { p_branch: BRANCH_A })).data;
    expect(list.map((l) => l.license_number)).toEqual(["DEMO-LIC-0101", "DEMO-LIC-0102"]);
    expect((await rpc("fn_admin_set_room_license", { p_room: r103, p_number: " tl-٢٠٢٥ " })).data).toEqual({ ok: true, license_number: "TL-2025" });
    expect((await rpc("fn_admin_set_room_license", { p_room: r101, p_number: "A B" })).error?.message).toBe("VALIDATION: room_license");
    expect((await rpc("fn_admin_set_room_license", { p_room: r103, p_number: "TL-2025" })).data).toEqual({ ok: true, unchanged: true, license_number: "TL-2025" });
    const after = (await rpc<any[]>("fn_room_licenses", { p_branch: BRANCH_A })).data;
    expect(after.find((l) => l.room_id === r103)?.license_number).toBe("TL-2025");
  });

  it("UL25 the manager changes it; the supervisor reads it but cannot change it; finance and housekeeping get neither", async () => {
    const r101 = await roomId("101");
    await login("manager@demo.sa");
    expect((await rpc("fn_admin_set_room_license", { p_room: r101, p_number: "MGR-1" })).data).toEqual({ ok: true, license_number: "MGR-1" });
    await login("reception@demo.sa");
    expect((await rpc<any[]>("fn_room_licenses", { p_branch: BRANCH_A })).data.map((l) => l.license_number)).toContain("MGR-1");
    expect((await rpc("fn_admin_set_room_license", { p_room: r101, p_number: "SUP-1" })).error?.message).toMatch(/^FORBIDDEN/);
    for (const who of ["finance@demo.sa", "housekeeping@demo.sa"]) {
      await login(who);
      expect((await rpc("fn_room_licenses", { p_branch: BRANCH_A })).error?.message, who).toMatch(/^FORBIDDEN/);
      expect((await rpc("fn_admin_set_room_license", { p_room: r101, p_number: "X-1" })).error?.message, who).toMatch(/^FORBIDDEN/);
    }
  });

  it("UL26 no role reads or writes the table directly — not even the owner", async () => {
    const rows = await client.from("room_licenses").select("*");
    expect(rows.data ?? []).toEqual([]);
    const ins = await client.from("room_licenses").insert({ room_id: await roomId("103"), branch_id: BRANCH_A, license_number: "SNEAK-1" });
    expect(ins.error?.message).toMatch(/row-level security/);
    expect((await rpc<any[]>("fn_room_licenses", { p_branch: BRANCH_A })).data.map((l) => l.license_number)).not.toContain("SNEAK-1");
  });

  it("UL27 the change is in the log as «room.license_set» with the last four characters only; clearing is logged too", async () => {
    const r101 = await roomId("101");
    await rpc("fn_admin_set_room_license", { p_room: r101, p_number: "NEW-77777" });
    await rpc("fn_admin_set_room_license", { p_room: r101, p_number: "" });
    const log = ((await client.from("audit_events").select("action, entity_id, details")).data as any[]).filter((a) => a.action === "room.license_set" && a.entity_id === r101);
    expect(log).toHaveLength(2);
    expect(log.map((a) => a.details)).toEqual([{ before: { license_number: "…7777" }, after: {} }, { before: { license_number: "…0101" }, after: { license_number: "…7777" } }].map((d) => JSON.parse(JSON.stringify(d))));
    expect(JSON.stringify(log)).not.toContain("NEW-77777");
    expect((await rpc<any[]>("fn_room_licenses", { p_branch: BRANCH_A })).data.some((l) => l.room_id === r101)).toBe(false);
    expect((await rpc<any[]>("fn_room_licenses", { p_branch: BRANCH_B })).data).toEqual([]);
  });
});

describe("UL28 individual accounts: the licence is read and edited by whoever may EDIT the rooms page, whatever the role", () => {
  const ind = (pages: Record<string, Record<string, boolean>>) => ({ mode: "individual" as const, revision: 1, pages, sensitive: [], homePage: null });
  it("edit on /admin/rooms reads whatever the role; the three roles keep their read; a view-only or add-only non-listed role, or edit on other pages, does not; legacy and owner keep the roles", () => {
    expect(readsUnitLicenseFor("housekeeping", ind({ "/admin/rooms": { view: true, edit: true } }))).toBe(true);
    expect(readsUnitLicenseFor("supervisor", ind({ "/admin/rooms": { view: true } }))).toBe(true); // existing read preserved
    expect(readsUnitLicenseFor("housekeeping", ind({ "/admin/rooms": { view: true } }))).toBe(false);
    expect(readsUnitLicenseFor("housekeeping", ind({ "/admin/rooms": { view: true, add: true } }))).toBe(false);
    expect(readsUnitLicenseFor("finance", ind({ "/admin/services": { view: true, edit: true } }))).toBe(false);
    expect(readsUnitLicenseFor("owner", ind({}))).toBe(true);
    expect(readsUnitLicenseFor("manager", { mode: "legacy", revision: 0, pages: {}, sensitive: [], homePage: null })).toBe(true);
    expect(readsUnitLicenseFor("housekeeping", { mode: "legacy", revision: 0, pages: {}, sensitive: [], homePage: null })).toBe(false);
    expect(readsUnitLicenseFor("manager", undefined)).toBe(true);
  });
});

describe("UL29 item 6 (user 2026-11-25 06:19): the licence is saved together with the unit, in one call", () => {
  async function cat(): Promise<string> { const c = await client.from("room_categories").select("id, branch_id"); return ((c.data as any[]) ?? []).find((x) => x.branch_id === BRANCH_A).id; }
  const count = async (n: string) => (((await client.from("rooms").select("id, room_number")).data as any[]) ?? []).filter((x) => x.room_number === n).length;
  it("UL29a a new unit with a licence saves both; the log has room.created and room.license_set", async () => {
    const res = await rpc<any>("fn_admin_upsert_room", { p: { branch_id: BRANCH_A, category_id: await cat(), room_number: "901", license: " nl-٧٧ " } });
    expect(res.error).toBeNull();
    expect((await rpc<any[]>("fn_room_licenses", { p_branch: BRANCH_A })).data.find((l) => l.room_id === res.data.id)?.license_number).toBe("NL-77");
    const log = await client.from("audit_events").select("action, entity_id");
    const acts = ((log.data as any[]) ?? []).filter((e) => e.entity_id === res.data.id).map((e) => e.action).sort();
    expect(acts).toEqual(["room.created", "room.license_set"]);
  });
  it("UL29b an invalid licence on a new unit refuses the whole save: no unit, no licence", async () => {
    const before = (await rpc<any[]>("fn_room_licenses", { p_branch: BRANCH_A })).data.length;
    const res = await rpc("fn_admin_upsert_room", { p: { branch_id: BRANCH_A, category_id: await cat(), room_number: "902", license: "A B" } });
    expect(res.error?.message).toBe("VALIDATION: room_license");
    expect(await count("902")).toBe(0);
    expect((await rpc<any[]>("fn_room_licenses", { p_branch: BRANCH_A })).data.length).toBe(before);
  });
  it("UL29c a blank licence on create is not sent: unit saved, no licence row; an edit with an invalid licence changes nothing", async () => {
    const c = await cat();
    const made = await rpc<any>("fn_admin_upsert_room", { p: { branch_id: BRANCH_A, category_id: c, room_number: "903", license: "" } });
    expect(made.error).toBeNull();
    expect((await rpc<any[]>("fn_room_licenses", { p_branch: BRANCH_A })).data.some((l) => l.room_id === made.data.id)).toBe(false);
    const bad = await rpc("fn_admin_upsert_room", { p: { id: made.data.id, category_id: c, notes: "لا يُحفظ", license: "A B", version: made.data.version } });
    expect(bad.error?.message).toBe("VALIDATION: room_license");
    const row = ((await client.from("rooms").select("id, notes, version")).data as any[]).find((x) => x.id === made.data.id);
    expect(row.notes ?? null).toBeNull();
    expect(row.version).toBe(made.data.version);
  });
  it("UL29d setsUnitLicenseOnCreate: Add alone is enough for an individual account; view-only is not; legacy and owner as before", () => {
    const ind = (pages: Record<string, Record<string, boolean>>) => ({ mode: "individual" as const, revision: 1, pages, sensitive: [], homePage: null });
    expect(setsUnitLicenseOnCreate("housekeeping", ind({ "/admin/rooms": { view: true, add: true } }))).toBe(true);
    expect(setsUnitLicenseOnCreate("housekeeping", ind({ "/admin/rooms": { view: true } }))).toBe(false);
    expect(readsUnitLicenseFor("housekeeping", ind({ "/admin/rooms": { view: true, add: true } }))).toBe(false); // Add alone never reads existing numbers
    expect(setsUnitLicenseOnCreate("owner", undefined)).toBe(true);
    expect(setsUnitLicenseOnCreate("finance", undefined)).toBe(false);
  });
});
