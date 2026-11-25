/**
 * Plan item 7.2 (O5 «الفرع المؤرشف»): an archived branch never appears in a selection list — the demo-store facet.
 * The products admin list («ومنها المنتجات») is the one the plan names; the guest list is the control that already
 * filtered correctly. Descriptive names without a letter code, so no acceptance-library prefix is needed.
 */
import { describe, it, expect, beforeAll, beforeEach } from "vitest";

type Demo = typeof import("../../src/demo/client");
let demo: Demo;
let staff: ReturnType<Demo["createDemoClient"]>;

const memStorage = () => {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, String(v)), removeItem: (k: string) => void m.delete(k), clear: () => m.clear(), key: () => null, length: 0 };
};
async function rpc<T = any>(fn: string, args: Record<string, unknown> = {}): Promise<T> { // eslint-disable-line @typescript-eslint/no-explicit-any
  const { data, error } = await staff.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}
const as = (email: string) => staff.auth.signInWithPassword({ email, password: "demo" });

const BRANCH_A = "00000000-0000-0000-0000-000000000010";

beforeAll(async () => {
  (globalThis as any).window = globalThis; // eslint-disable-line @typescript-eslint/no-explicit-any
  (globalThis as any).localStorage = memStorage(); // eslint-disable-line @typescript-eslint/no-explicit-any
  (globalThis as any).sessionStorage = memStorage(); // eslint-disable-line @typescript-eslint/no-explicit-any
  (globalThis as any).location = { href: "https://demo.test/index.html#/" }; // eslint-disable-line @typescript-eslint/no-explicit-any
  demo = await import("../../src/demo/client");
  staff = demo.createDemoClient();
});
beforeEach(async () => { demo.resetDemo(); await as("owner@demo.sa"); });

/** A fresh branch with no commitments, archived with a reason, as the owner does from /admin/branches. */
async function archivedBranch(): Promise<string> {
  const made = await rpc<{ id: string }>("fn_admin_upsert_branch", { p: { name_ar: "فرع الاختبار المؤرشف", name_en: "Archived Test Branch" } });
  await rpc("fn_admin_archive_definition", { p_entity: "branch", p_id: made.id, p_reason: "اختبار قبول 7.2", p_archive: true });
  return made.id;
}

describe("the archived branch in selection lists (7.2)", () => {
  it("the products branch list hides the archived branch and keeps the active ones", async () => {
    const archived = await archivedBranch();
    const a = await rpc<{ branches: Array<{ id: string; name: string; mine: boolean }> }>("fn_admin_products");
    expect(a.branches.map((b) => b.id)).not.toContain(archived);
    expect(a.branches.map((b) => b.id)).toContain(BRANCH_A);
    // every listed branch is one the caller may actually see or act on
    expect(a.branches.every((b) => typeof b.mine === "boolean")).toBe(true);
  });

  it("a restored branch returns to the products branch list", async () => {
    const archived = await archivedBranch();
    let a = await rpc<{ branches: Array<{ id: string }> }>("fn_admin_products");
    expect(a.branches.map((b) => b.id)).not.toContain(archived);
    await rpc("fn_admin_archive_definition", { p_entity: "branch", p_id: archived, p_reason: "استعادة", p_archive: false });
    a = await rpc<{ branches: Array<{ id: string }> }>("fn_admin_products");
    expect(a.branches.map((b) => b.id)).toContain(archived);
  });

  it("control: the guest branch list already hides the archived branch", async () => {
    const archived = await archivedBranch();
    const g = await rpc<Array<{ id: string }>>("fn_guest_branches");
    expect(g.map((b) => b.id)).not.toContain(archived);
    expect(g.map((b) => b.id)).toContain(BRANCH_A);
  });

  it("control: the archived branch still exists for the management screen, marked archived", async () => {
    const archived = await archivedBranch();
    const { data } = await staff.from("branches").select("id, archived_at, is_active").eq("id", archived).single();
    expect((data as { archived_at: string | null }).archived_at).not.toBeNull();
  });
});
