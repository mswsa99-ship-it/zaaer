// Regression for the aggregate-scope gap: list stays/last_check_in and duplicates[].stays must equal what the caller may see (detail view). Synthetic demo backend.
import { describe, it, expect, beforeAll, beforeEach } from "vitest";
type Client = ReturnType<typeof import("../../src/demo/client")["createDemoClient"]>;
let client: Client; let resetDemo: () => void; let BRANCH: string; let BB: string; let CAT: string; let CB: string; let SRC: string;
const memStorage = () => { const m = new Map<string, string>(); return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, String(v)), removeItem: (k: string) => void m.delete(k), clear: () => m.clear(), key: () => null, length: 0 }; };
const login = (e: string) => client.auth.signInWithPassword({ email: e, password: "demo" });
async function rpc(fn: string, args: any) { const { data, error } = await client.rpc(fn, args); if (error) throw new Error(error.message); return data as any; }
const fut = (n: number) => { const d = new Date(); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const mk = (o: any) => rpc("fn_staff_create_reservation", { p: { branch_id: o.branch ?? BRANCH, category_id: o.branch ? CB : CAT, source_id: SRC, check_in: fut(o.ci), check_out: fut(o.ci + 1), guest_name: o.name, guest_phone: o.phone, adults: 1, companions: 0 } });
beforeAll(async () => { (globalThis as any).window = globalThis; (globalThis as any).localStorage = memStorage(); (globalThis as any).sessionStorage = memStorage(); const mod = await import("../../src/demo/client"); client = mod.createDemoClient(); resetDemo = mod.resetDemo; });
beforeEach(async () => { resetDemo(); await login("owner@demo.sa");
  const bs = (await client.from("branches").select("id").order("name_ar")).data as any[]; BRANCH = bs[0].id; BB = bs[1].id;
  CAT = ((await client.from("room_categories").select("id").eq("branch_id", BRANCH).order("base_price_halalas").limit(1).maybeSingle()).data as any).id;
  CB = ((await client.from("room_categories").select("id").eq("branch_id", BB).order("base_price_halalas").limit(1).maybeSingle()).data as any).id;
  const s = (await client.from("booking_sources").select("id, kind, external_reference_required").eq("is_active", true)).data as any[]; SRC = (s.find((x) => !x.external_reference_required && x.kind !== "external") ?? s[0]).id; });
describe("profile aggregate scope", () => {
  it("SC01-SC05 mixed-branch profile: supervisor list = detail; owner sees all; hidden profiles never counted; later A stay makes it visible", async () => {
    const a = await mk({ ci: 10, name: "نواف", phone: "0500000081" }); await mk({ branch: BB, ci: 20, name: "نواف", phone: "0500000081" });
    await login("reception@demo.sa");
    const d = await rpc("fn_guest_profile", { p_id: a.guest_profile_id }); const l = (await rpc("fn_guest_profiles", { p: { q: "0500000081", limit: 5 } })).rows[0];
    expect(l.stays).toBe(d.stays.length);                                                          // SC01 list stays = visible stays
    expect(l.last_check_in).toBe(d.stays.map((x: any) => x.check_in).sort().pop());               // SC02 last arrival is within the caller's branches
    await login("owner@demo.sa");
    const ol = (await rpc("fn_guest_profiles", { p: { q: "0500000081", limit: 5 } })).rows[0]; expect(ol.stays).toBe(2); expect(ol.last_check_in).toBe(fut(20));   // SC03 owner sees both
    await mk({ branch: BB, ci: 30, name: "سلمان", phone: "0500000082" }); await login("reception@demo.sa");
    const mine = await mk({ ci: 40, name: "عمر", phone: "0500000082" });
    expect((await rpc("fn_guest_profile", { p_id: mine.guest_profile_id })).duplicates).toEqual([]);   // SC04 hidden never in duplicates
    await login("manager@demo.sa"); await mk({ ci: 50, name: "سلمان", phone: "0500000082" }); await login("reception@demo.sa");
    const dup = (await rpc("fn_guest_profile", { p_id: mine.guest_profile_id })).duplicates;
    expect(dup.length).toBe(1); const vis = await rpc("fn_guest_profile", { p_id: dup[0].id });
    expect(dup[0].stays).toBe(vis.stays.length);                                                   // SC05 duplicates[].stays = visible stays
  });
});
