// 0152 regression on the demo backend (mirror of the SQL guard). Synthetic.
import { describe, it, expect, beforeAll, beforeEach } from "vitest";
type Client = ReturnType<typeof import("../../src/demo/client")["createDemoClient"]>;
let client: Client; let resetDemo: () => void; let BRANCH: string; let CAT: string; let SRC: string; let _EXT: string;
const memStorage = () => { const m = new Map<string, string>(); return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, String(v)), removeItem: (k: string) => void m.delete(k), clear: () => m.clear(), key: () => null, length: 0 }; };
async function login(e: string) { await client.auth.signInWithPassword({ email: e, password: "demo" }); }
async function rpc(fn: string, args: any) { const { data, error } = await client.rpc(fn, args); if (error) throw new Error(error.message); return data as any; }
const fut = (n: number) => { const d = new Date(); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
beforeAll(async () => { (globalThis as any).window = globalThis; (globalThis as any).localStorage = memStorage(); (globalThis as any).sessionStorage = memStorage(); const mod = await import("../../src/demo/client"); client = mod.createDemoClient(); resetDemo = mod.resetDemo; });
beforeEach(async () => { resetDemo(); await login("owner@demo.sa");
  BRANCH = ((await client.from("branches").select("id").order("name_ar").limit(1).maybeSingle()).data as any).id;
  CAT = ((await client.from("room_categories").select("id").eq("branch_id", BRANCH).order("base_price_halalas").limit(1).maybeSingle()).data as any).id;
  const s = (await client.from("booking_sources").select("id, kind, external_reference_required").eq("is_active", true)).data as any[];
  SRC = (s.find((x) => !x.external_reference_required && x.kind !== "external") ?? s[0]).id; _EXT = (s.find((x) => x.kind === "external" && x.external_reference_required) ?? s.find((x) => x.kind === "external")).id; });
const mk = (o: any) => rpc("fn_staff_create_reservation", { p: { branch_id: o.branch ?? BRANCH, category_id: o.cat ?? CAT, source_id: SRC, check_in: fut(o.ci), check_out: fut(o.co), guest_name: o.name, guest_phone: o.phone, guest_profile_id: o.pid, adults: 1, companions: 0 } });
const fails = async (p: Promise<any>) => { try { await p; return "accepted"; } catch (e: any) { return String(e.message); } };
describe("0152 profile reuse respects the branch grant", () => {
  it("PB01-PB07 hidden id refused (same error as a nonexistent id), hidden phone makes a new profile, nothing leaks, visible and owner links still work", async () => {
    await login("owner@demo.sa");
    const bs = (await client.from("branches").select("id").order("name_ar")).data as any[]; const BB = bs.find((b: any) => b.id !== BRANCH).id;
    const cb = ((await client.from("room_categories").select("id").eq("branch_id", BB).order("base_price_halalas").limit(1).maybeSingle()).data as any).id;
    const ob = await mk({ branch: BB, cat: cb, ci: 200, co: 201, name: "سلمان", phone: "0500000061" });
    const own = await mk({ ci: 205, co: 206, name: "أحمد", phone: "0500000031" });
    await login("reception@demo.sa");
    const nonexistent = await fails(mk({ ci: 220, co: 221, name: "سعيد", pid: "00000000-0000-4000-8000-000000000000" }));
    const hiddenId = await fails(mk({ ci: 220, co: 221, name: "سلمان", pid: ob.guest_profile_id }));
    expect(hiddenId).toBe(nonexistent);                                   // PB01 no oracle for the existence of a hidden profile
    expect(hiddenId).toContain("guest_profile");
    const viaPhone = await mk({ ci: 230, co: 231, name: "عمر", phone: "0500000061" });
    expect(viaPhone.guest_profile_id).not.toBe(ob.guest_profile_id);       // PB02 a hidden profile is never linked by phone
    expect(Object.keys(viaPhone).join(",")).not.toMatch(/name|phone/);    // PB03 the response carries no identity
    { const mine = await rpc<any>("fn_guest_profile", { p_id: viaPhone.guest_profile_id }); expect(mine.duplicates ?? []).toEqual([]);   // PB08 no hidden name through the duplicates list
      const lst = await rpc<any>("fn_guest_profiles", { p: { q: "0500000061", limit: 20 } }); expect(lst.rows.every((x: any) => !x.duplicates)).toBe(true); }   // PB09
    expect(await fails(rpc("fn_guest_profile", { p_id: ob.guest_profile_id }))).toContain("NOT_FOUND");   // PB04 still hidden afterwards
    expect((await mk({ ci: 260, co: 261, name: "فيصل", pid: own.guest_profile_id })).ok).toBe(true);     // PB05 a visible profile still links by id
    await login("owner@demo.sa");
    const viaOwner = await mk({ ci: 270, co: 271, name: "كريم", phone: "0500000061" });
    expect(viaOwner.guest_profile_id).toBe(ob.guest_profile_id);           // PB06 the owner still links across branches
    expect(await fails(mk({ ci: 280, co: 281, name: "صالح", pid: ob.guest_profile_id }))).toBe("accepted");  // PB07 owner by id still works
  });
});
