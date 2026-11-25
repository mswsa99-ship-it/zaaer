import { beforeEach, describe, expect, it, vi } from "vitest";
const ctx = vi.hoisted(() => ({ key: "a", guest: true, rpc: vi.fn() }));
vi.mock("../../src/lib/guestScope", () => ({ guestScopeKey: () => ctx.key, currentGuestScope: () => ({ guest: ctx.guest }) }));
vi.mock("../../src/lib/supabase", () => ({ supabase: { rpc: ctx.rpc } }));
beforeEach(() => { vi.resetModules(); ctx.key = "a"; ctx.guest = true; ctx.rpc.mockReset(); });
describe("hotel identity cache", () => {
  it("does not reuse a completed response for another hotel", async () => {
    ctx.rpc.mockResolvedValueOnce({ data: { name_ar: "Hotel A" } }).mockResolvedValueOnce({ data: { name_ar: "Hotel B" } });
    const m = await import("../../src/lib/organization");
    await m.loadOrganization(); expect(m.organizationName()).toBe("Hotel A");
    ctx.key = "b"; expect(m.organizationName()).toBe(null);
    await m.loadOrganization(); expect(m.organizationName()).toBe("Hotel B");
  });
  it("late hotel A response cannot overwrite hotel B", async () => {
    let resolveA!: (v: unknown) => void;
    ctx.rpc.mockReturnValueOnce(new Promise(r => { resolveA = r; })).mockResolvedValueOnce({ data: { name_ar: "Hotel B" } });
    const m = await import("../../src/lib/organization");
    const a = m.loadOrganization(); ctx.key = "b";
    await m.loadOrganization(); resolveA({ data: { name_ar: "Hotel A" } }); await a;
    expect(m.organizationName()).toBe("Hotel B"); expect(ctx.rpc).toHaveBeenCalledTimes(2);
  });
  it("guest null identity cannot suppress staff identity", async () => {
    ctx.rpc.mockResolvedValueOnce({ data: null }).mockResolvedValueOnce({ data: { name_ar: "Staff hotel" } });
    const m = await import("../../src/lib/organization"); await m.loadOrganization();
    ctx.guest = false; await m.loadOrganization(); expect(m.organizationName()).toBe("Staff hotel");
  });
});
