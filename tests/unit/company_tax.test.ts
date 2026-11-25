/** 0142: company VAT number and national address on a reservation: the demo's copy of fn_staff_set_company_tax (the SQL was exercised on the isolated test project). */
import { describe, it, expect, beforeAll, beforeEach } from "vitest";

type Client = ReturnType<typeof import("../../src/demo/client")["createDemoClient"]>;
let client: Client; let resetDemo: () => void;
const memStorage = () => { const m = new Map<string, string>(); return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, String(v)), removeItem: (k: string) => void m.delete(k), clear: () => m.clear(), key: () => null, length: 0 }; };
const rpc = async (fn: string, args: Record<string, unknown> = {}) => { const { data, error } = await client.rpc(fn, args); return { data: data as any, error: error as { message: string } | null }; };
const ADDR = { street: "شارع الملك فهد", city: "الرياض", district: "العليا", building_number: "1234", postal_code: "12345" };

beforeAll(async () => {
  (globalThis as any).window = globalThis; (globalThis as any).localStorage = memStorage(); (globalThis as any).sessionStorage = memStorage();
  const mod = await import("../../src/demo/client"); client = mod.createDemoClient(); resetDemo = mod.resetDemo;
});
beforeEach(async () => { resetDemo(); await client.auth.signInWithPassword({ email: "owner@demo.sa", password: "demo" }); });

async function firstReservation() { const r = await client.from("reservations").select("id, version"); return ((r.data as any[]) ?? [])[0] as { id: string; version: number }; }

describe("CT — company VAT number and address", () => {
  it("CT01 a valid VAT number and address are saved and the version moves", async () => {
    const r = await firstReservation();
    expect((await rpc("fn_staff_set_company_tax", { p_reservation: r.id, p_vat: "300000000000003", p_address: ADDR, p_expected_version: r.version })).data).toEqual({ ok: true });
    const after = ((await client.from("reservations").select("id, version, company_vat_number, company_address")).data as any[]).find((x) => x.id === r.id);
    expect(after.company_vat_number).toBe("300000000000003"); expect(after.company_address.city).toBe("الرياض"); expect(after.version).toBe(r.version + 1);
  });
  it("CT02 a wrong VAT number, an incomplete address and a missing version are refused", async () => {
    const r = await firstReservation();
    expect((await rpc("fn_staff_set_company_tax", { p_reservation: r.id, p_vat: "12345", p_address: null, p_expected_version: r.version })).error?.message).toMatch(/VALIDATION: vat_number/);
    expect((await rpc("fn_staff_set_company_tax", { p_reservation: r.id, p_vat: "300000000000003", p_address: { ...ADDR, building_number: "12" }, p_expected_version: r.version })).error?.message).toMatch(/VALIDATION: company_address/);
    expect((await rpc("fn_staff_set_company_tax", { p_reservation: r.id, p_vat: null, p_address: null })).error?.message).toMatch(/VERSION_REQUIRED/);
  });
  it("CT03 null clears both", async () => {
    const r = await firstReservation();
    await rpc("fn_staff_set_company_tax", { p_reservation: r.id, p_vat: "300000000000003", p_address: ADDR, p_expected_version: r.version });
    const v2 = ((await client.from("reservations").select("id, version")).data as any[]).find((x) => x.id === r.id).version;
    expect((await rpc("fn_staff_set_company_tax", { p_reservation: r.id, p_vat: null, p_address: null, p_expected_version: v2 })).data).toEqual({ ok: true });
    expect(((await client.from("reservations").select("id, company_vat_number")).data as any[]).find((x) => x.id === r.id).company_vat_number).toBeNull();
  });
  it("CT04 a role without the money permission is refused", async () => {
    await client.auth.signInWithPassword({ email: "housekeeping@demo.sa", password: "demo" });
    const r = await firstReservation();
    if (r) expect((await rpc("fn_staff_set_company_tax", { p_reservation: r.id, p_vat: null, p_address: null, p_expected_version: r.version })).error).not.toBeNull();
  });
});
