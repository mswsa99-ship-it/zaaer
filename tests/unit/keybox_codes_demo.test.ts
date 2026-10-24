/**
 * «الرموز» in the in-browser demo — KD01–KD07. The demo must keep the same rules as the SQL functions of 0025
 * (tests/sql/keybox_codes_tests.sql), otherwise the walkthrough would show a screen the real system does not have:
 * red after a guest leaves, housekeeping never on a unit with a guest in house, the same code refused, no code in a
 * list or a query — only through the audited view.
 */
import { describe, it, expect, beforeAll, beforeEach } from "vitest";

type Demo = typeof import("../../src/demo/client");
let demo: Demo;
let client: ReturnType<Demo["createDemoClient"]>;
const BRANCH = "00000000-0000-0000-0000-000000000010";

const memStorage = () => {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, String(v)), removeItem: (k: string) => void m.delete(k), clear: () => m.clear(), key: () => null, length: 0 };
};
const login = (email: string) => client.auth.signInWithPassword({ email, password: "demo" });
async function rpc<T = any>(fn: string, args: Record<string, unknown>): Promise<T> { // eslint-disable-line @typescript-eslint/no-explicit-any
  const { data, error } = await client.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}
const fails = async (p: Promise<unknown>) => { try { await p; return ""; } catch (e) { return (e as Error).message; } };

interface Unit { room_id: string; room_number: string; state: string; guest_in_house: boolean; can_view: boolean; can_change: boolean; needs_change_since: string | null; has_code: boolean }
const board = () => rpc<Unit[]>("fn_keybox_board", { p_branch: BRANCH });
const alerts = () => rpc<{ count: number; rooms: string[]; oldest_since: string | null }>("fn_keybox_alerts", { p_branch: BRANCH });

beforeAll(async () => {
  (globalThis as any).window = globalThis; // eslint-disable-line @typescript-eslint/no-explicit-any
  (globalThis as any).localStorage = memStorage(); // eslint-disable-line @typescript-eslint/no-explicit-any
  (globalThis as any).sessionStorage = memStorage(); // eslint-disable-line @typescript-eslint/no-explicit-any
  demo = await import("../../src/demo/client");
  client = demo.createDemoClient();
});
beforeEach(async () => { demo.resetDemo(); await login("housekeeping@demo.sa"); });

describe("«الرموز» in the demo (same rules as 0025)", () => {
  it("KD01 the housekeeper sees the red units with their waiting time — the alert lists the same units — and never a code", async () => {
    const units = await board();
    const red = units.filter((u) => u.state === "change");
    expect(red.length).toBeGreaterThan(0);
    for (const u of red) expect(Date.parse(u.needs_change_since!)).toBeLessThanOrEqual(Date.now());
    const a = await alerts();
    expect(a.count).toBe(red.length);
    expect([...a.rooms].sort()).toEqual(red.map((u) => u.room_number).sort());
    expect(JSON.stringify(units)).not.toMatch(/"code"\s*:/);
    // the table itself never gives a code, whatever the query (as code_encrypted on the server)
    await login("reception@demo.sa");
    const { data } = await client.from("keyboxes").select("*").eq("branch_id", BRANCH);
    expect((data ?? []).length).toBeGreaterThan(0);
    for (const row of data ?? []) expect(row).not.toHaveProperty("code_plain");
  });

  it("KD02 a unit with a guest in house: housekeeping can neither see nor change its code; the supervisor can see it (audited)", async () => {
    const inHouse = (await board()).find((u) => u.guest_in_house)!;
    expect(inHouse).toBeTruthy();
    expect(inHouse.can_view || inHouse.can_change).toBe(false);
    expect(await fails(rpc("fn_keybox_reveal", { p_room: inHouse.room_id }))).toBe("GUEST_IN_HOUSE");
    expect(await fails(rpc("fn_staff_rotate_keybox_code", { p_room: inHouse.room_id, p_new_code: "4455", p_field_tested: true }))).toBe("GUEST_IN_HOUSE");
    expect(await fails(rpc("fn_staff_mark_keybox_tested", { p_room: inHouse.room_id }))).toBe("GUEST_IN_HOUSE");
    await login("reception@demo.sa");
    const r = await rpc<{ code: string }>("fn_keybox_reveal", { p_room: inHouse.room_id });
    expect(r.code).toMatch(/^\d{4,8}$/);
    const { data: audit } = await client.from("audit_events").select("action, entity_id, details").eq("action", "keybox.code_viewed");
    const entry = (audit ?? []).find((x) => x.entity_id === inHouse.room_id);
    expect(entry).toBeTruthy();
    expect(JSON.stringify(entry)).not.toContain(r.code);
  });

  it("KD03 a check-out turns the unit red at once and raises the alert", async () => {
    await login("owner@demo.sa");
    const { data } = await client.from("reservations").select("id, room_id, status").eq("branch_id", BRANCH).eq("status", "checked_in");
    const stay = (data ?? [])[0] as { id: string; room_id: string };
    const before = await alerts();
    const out = await rpc<{ ok: boolean }>("fn_staff_checkout", { p_reservation: stay.id, p_override_reason: "اختبار الرموز" });
    expect(out.ok).toBe(true);
    await login("housekeeping@demo.sa");
    const unit = (await board()).find((u) => u.room_id === stay.room_id)!;
    expect(unit.state).toBe("change");
    expect(unit.guest_in_house).toBe(false);
    expect(unit.can_view && unit.can_change).toBe(true);
    expect(Date.now() - Date.parse(unit.needs_change_since!)).toBeLessThan(60_000);
    const after = await alerts();
    expect(after.count).toBe(before.count + 1);
    expect(after.rooms).toContain(unit.room_number);
  });

  it("KD04 the same code is refused and the unit stays red; a code is 4 to 8 digits", async () => {
    const red = (await board()).find((u) => u.state === "change" && u.has_code && u.can_view)!;
    const { code } = await rpc<{ code: string }>("fn_keybox_reveal", { p_room: red.room_id });
    expect(await fails(rpc("fn_staff_rotate_keybox_code", { p_room: red.room_id, p_new_code: code, p_field_tested: true }))).toBe("CODE_MUST_DIFFER_FROM_PREVIOUS");
    for (const bad of ["12", "123456789", "12a4"]) {
      expect(await fails(rpc("fn_staff_rotate_keybox_code", { p_room: red.room_id, p_new_code: bad, p_field_tested: true }))).toBe("VALIDATION: code_must_be_4_to_8_digits");
    }
    expect((await board()).find((u) => u.room_id === red.room_id)!.state).toBe("change");
  });

  it("KD05 housekeeping saves a new tested code: green, the alert drops, the new code is the one shown and the old one is refused next time", async () => {
    const before = await alerts();
    const red = (await board()).find((u) => u.state === "change" && u.can_change)!;
    const { code: old } = await rpc<{ code: string }>("fn_keybox_reveal", { p_room: red.room_id });
    const fresh = old === "7391" ? "7392" : "7391";
    const r = await rpc<{ ok: boolean; code_version: number; room_status: string }>("fn_staff_rotate_keybox_code", { p_room: red.room_id, p_new_code: fresh, p_field_tested: true });
    expect(r.ok).toBe(true);
    const unit = (await board()).find((u) => u.room_id === red.room_id)!;
    expect(unit.state).toBe("ok");
    expect(unit.needs_change_since).toBeNull();
    expect((await alerts()).count).toBe(before.count - 1);
    expect((await rpc<{ code: string }>("fn_keybox_reveal", { p_room: red.room_id })).code).toBe(fresh);
    expect(await fails(rpc("fn_staff_rotate_keybox_code", { p_room: red.room_id, p_new_code: fresh, p_field_tested: true }))).toBe("CODE_MUST_DIFFER_FROM_PREVIOUS");
  });

  it("KD06 a code saved untested is amber until housekeeping confirms the test; testing a code that must change is refused", async () => {
    const units = await board();
    const ok = units.find((u) => u.state === "ok" && u.can_change)!;
    await rpc("fn_staff_rotate_keybox_code", { p_room: ok.room_id, p_new_code: "6060", p_field_tested: false });
    expect((await board()).find((u) => u.room_id === ok.room_id)!.state).toBe("untested");
    const t = await rpc<{ ok: boolean }>("fn_staff_mark_keybox_tested", { p_room: ok.room_id });
    expect(t.ok).toBe(true);
    expect((await board()).find((u) => u.room_id === ok.room_id)!.state).toBe("ok");
    const red = units.find((u) => u.state === "change" && u.has_code && u.can_change)!;
    expect(await fails(rpc("fn_staff_mark_keybox_tested", { p_room: red.room_id }))).toBe("CODE_NEEDS_CHANGE");
  });

  it("KD07 finance has no access to the codes", async () => {
    await login("finance@demo.sa");
    expect(await fails(board())).toMatch(/^FORBIDDEN/);
    expect(await fails(alerts())).toMatch(/^FORBIDDEN/);
  });
});
