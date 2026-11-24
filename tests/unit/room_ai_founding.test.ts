import { describe, expect, it } from "vitest";
import { defaultPolicies, hasPlaceholder, STEP_ORDER } from "../../src/lib/roomAi/defaults";
import { alreadyExists, deterministicProvider, getRoomAiProvider, problems, reviewSnapshot } from "../../src/lib/roomAi/provider";
import { emptySnapshot, type Snapshot } from "../../src/lib/roomAi/types";
import { readFileSync } from "node:fs";
import { createOpGuard, runBatch, type Outcome } from "../../src/lib/roomAi/batch";
import type { DraftItem } from "../../src/lib/roomAi/types";

const snap = (p: Partial<Snapshot> = {}): Snapshot => ({ ...emptySnapshot(), branch: { id: "b1", name_ar: "فرع", check_in_time: "15:00:00", check_out_time: "12:00:00" }, ...p });

describe("Room AI phase 1 (RA)", () => {
  it("RA01 the shipped provider is the deterministic one", () => { expect(getRoomAiProvider()).toBe(deterministicProvider); });
  it("RA02 policy defaults take times from the branch and leave blanks for commercial terms", () => {
    const p = defaultPolicies(snap());
    expect(p.find((x) => x.values.topic === "checkin")!.values.content_ar).toContain("15:00");
    expect(hasPlaceholder(p.find((x) => x.values.topic === "cancellation")!.values.content_ar)).toBe(true);
  });
  it("RA03 an item with a blank cannot be confirmed", () => { const c = defaultPolicies(snap()).find((x) => x.values.topic === "cancellation")!; expect(problems("policies", c.values).length).toBeGreaterThan(0); });
  it("RA04 no default proposes any price or fee", async () => {
    for (const s of STEP_ORDER) for (const d of await deterministicProvider.propose(s, { snapshot: snap(), answers: { floors: 3 } })) {
      expect(d.values.price_sar ?? null).toBeNull();
      expect(JSON.stringify(d.values)).not.toMatch(/\d+\s*(ريال|SAR|%|٪)/);
    }
  });
  it("RA05 a category needs a price typed by the user", async () => {
    const [c] = await deterministicProvider.propose("categories", { snapshot: snap(), answers: {} });
    expect(problems("categories", c.values)).toContain("اكتب السعر الأساسي لليلة");
    expect(problems("categories", { ...c.values, price_sar: 250 })).toEqual([]);
  });
  it("RA06 existing items are not proposed again", async () => {
    const s = snap({ facilities: [{ name: "المصلى", archived_at: null }], policies: [{ topic: "wifi", title: "x", content_ar: "y", is_public: true, archived_at: null }] });
    expect((await deterministicProvider.propose("facilities", { snapshot: s, answers: {} })).map((d) => d.values.name)).not.toContain("المصلى");
    expect((await deterministicProvider.propose("policies", { snapshot: s, answers: {} })).some((d) => d.values.topic === "wifi")).toBe(false);
    expect(alreadyExists("facilities", { name: " المصلى " }, s)).toBe(true);
  });
  it("RA07 an archived item does not count as existing", () => { expect(alreadyExists("facilities", { name: "المصلى" }, snap({ facilities: [{ name: "المصلى", archived_at: "2026-01-01" }] }))).toBe(false); });
  it("RA08 structure: floor count answer drives the floors; existing floors are not duplicated", async () => {
    const [d] = await deterministicProvider.propose("structure", { snapshot: snap(), answers: { floors: 2 } });
    expect(String(d.values.floors).split("\n")).toEqual(["الأرضي", "الأول", "الثاني"]);
    const s = snap({ blocks: [{ id: "k", name: "المبنى الرئيسي", archived_at: null }], floors: ["الأرضي", "الأول", "الثاني"].map((n, i) => ({ id: "f" + i, block_id: "k", name: n, archived_at: null })) });
    expect(await deterministicProvider.propose("structure", { snapshot: s, answers: { floors: 2 } })).toEqual([]);
  });
  it("RA09 review: an empty hotel gets risks, in severity order", () => {
    const f = reviewSnapshot(snap());
    expect(f.map((x) => x.id)).toEqual(expect.arrayContaining(["no-policies", "no-cats", "no-blocks", "no-tt", "no-fac"]));
    const order = f.map((x) => ({ risk: 0, warn: 1, note: 2 })[x.severity]); expect(order).toEqual([...order].sort());
  });
  it("RA10 review: flags missing cancellation, unfilled blanks and an unpriced category", () => {
    const s = snap({ policies: [{ topic: "checkin", title: "الوصول", content_ar: "عدد [x]", is_public: true, archived_at: null }], categories: [{ id: "c", name_ar: "جناح", base_capacity: 2, max_capacity: 1, base_price_halalas: 0, archived_at: null }] });
    const ids = reviewSnapshot(s).map((x) => x.id);
    expect(ids).toEqual(expect.arrayContaining(["no-cancel", "placeholders", "price-c", "cap-c", "no-rooms"]));
  });
  it("RA11 review is read-only and a complete hotel has no risk", () => {
    const s = snap({
      policies: ["checkin", "cancellation", "stay", "children"].map((t) => ({ topic: t, title: t, content_ar: "نص", is_public: true, archived_at: null })),
      blocks: [{ id: "k", name: "ب", archived_at: null }], floors: [{ id: "f", block_id: "k", name: "ط", archived_at: null }],
      categories: [{ id: "c", name_ar: "مفردة", base_capacity: 1, max_capacity: 2, base_price_halalas: 10000, archived_at: null }], rooms: [{ id: "r", category_id: "c", floor_id: "f", archived_at: null }],
      facilities: [{ name: "المصلى", archived_at: null }], taskTypes: [{ name: "تنظيف", code: null, archived_at: null }],
    });
    expect(reviewSnapshot(s).filter((x) => x.severity !== "note")).toEqual([]);
  });
  it("RA12 source guard: no network/model calls, no finance tables or RPCs in Room AI files", () => {
    for (const f of ["defaults", "provider", "types", "write", "batch"]) {
      const src = readFileSync(`src/lib/roomAi/${f}.ts`, "utf8");
      expect(src).not.toMatch(/fetch\(|functions\.invoke|XMLHttpRequest|anthropic|openai/i);
      expect(src).not.toMatch(/voucher|invoice|cash_account|payment|ledger|refund|fn_ai_ops_execute/i);
    }
  });
  it("RA13 every write is scoped: writer filters by the active branch and reads only that branch", () => {
    const src = readFileSync("src/lib/roomAi/write.ts", "utf8");
    expect((src.match(/\.eq\("branch_id", id\)/g) ?? []).length).toBe(7);
    expect(src).toContain("branch_id: c.branchId");
  });

  const items = (n: number): DraftItem[] => Array.from({ length: n }, (_, i) => ({ id: "i" + i, include: true, values: { name: "n" + i } }));
  const mk = (over: Partial<Parameters<typeof runBatch>[0]> = {}) => {
    const out: Record<string, Outcome> = {}; const written: string[] = [];
    const o = { items: items(3), pinnedBranch: "A", currentBranch: () => "A" as string | null, lock: { busy: false }, refresh: async () => snap(), exists: () => false, write: async (d: DraftItem) => { written.push(d.id); }, onResult: (id: string, r: Outcome) => { out[id] = r; }, ...over };
    return { o, out, written };
  };
  it("RA14 batch: writes each item once, in order", async () => { const { o, out, written } = mk(); expect(await runBatch(o)).toBe("done"); expect(written).toEqual(["i0", "i1", "i2"]); expect(Object.values(out).every((r) => r.state === "ok")).toBe(true); expect(o.lock.busy).toBe(false); });
  it("RA15 branch switch mid-batch stops the rest and writes nothing for the new branch", async () => {
    let cur: string | null = "A"; const w: string[] = [];
    const { o, out } = mk({ currentBranch: () => cur, write: async (d) => { w.push(d.id); if (d.id === "i0") cur = "B"; } });
    expect(await runBatch(o)).toBe("branch-changed");
    expect(w).toEqual(["i0"]);
    expect(out.i1.state).toBe("stopped"); expect(out.i2.state).toBe("stopped");
  });
  it("RA16 a branch that is already different when the batch starts writes nothing", async () => {
    const { o, written, out } = mk({ currentBranch: () => "B" }); expect(await runBatch(o)).toBe("branch-changed"); expect(written).toEqual([]); expect(out.i0.state).toBe("stopped");
  });
  it("RA17 double click: the second start is refused while the first runs, and each item is written once", async () => {
    let release!: () => void; const gate = new Promise<void>((r) => (release = r));
    const lock = { busy: false }; const w: string[] = [];
    const a = mk({ lock, write: async (d) => { await gate; w.push(d.id); } });
    const p1 = runBatch(a.o);
    const second = await runBatch(mk({ lock }).o);
    expect(second).toBe("locked");
    release(); expect(await p1).toBe("done"); expect(w).toEqual(["i0", "i1", "i2"]); expect(lock.busy).toBe(false);
  });
  it("RA18 partial failure: the failed item is reported, the rest continues, and a retry skips what already exists", async () => {
    const have = new Set<string>(); const { o, out } = mk({ exists: (d) => have.has(d.id), write: async (d) => { if (d.id === "i1") throw new Error("boom"); have.add(d.id); } });
    await runBatch(o);
    expect(out.i0.state).toBe("ok"); expect(out.i1.state).toBe("failed"); expect(out.i2.state).toBe("ok");
    const retry = mk({ items: items(3), exists: (d) => have.has(d.id), write: async (d) => { have.add(d.id); } });
    await runBatch(retry.o);
    expect(retry.out.i0.state).toBe("skipped"); expect(retry.out.i1.state).toBe("ok"); expect(retry.out.i2.state).toBe("skipped");
  });
  it("RA19 a failed read before the batch writes nothing; a failed read mid-batch stops the rest", async () => {
    const a = mk({ refresh: async () => null }); expect(await runBatch(a.o)).toBe("no-snapshot"); expect(a.written).toEqual([]);
    let n = 0; const b = mk({ refresh: async () => (++n === 2 ? null : snap()) });
    expect(await runBatch(b.o)).toBe("no-snapshot"); expect(b.written).toEqual(["i0"]); expect(b.out.i1.state).toBe("stopped");
  });
  it("RA19b the latest-wins guard drops a slow answer from an older operation", async () => {
    const g = createOpGuard(); const applied: string[] = [];
    const slow = async () => { const t = g.next(); await new Promise((r) => setTimeout(r, 20)); if (g.isCurrent(t)) applied.push("slow"); };
    const fast = async () => { const t = g.next(); if (g.isCurrent(t)) applied.push("fast"); };
    await Promise.all([slow(), fast()]); expect(applied).toEqual(["fast"]);
  });
  it("RA19c the panel states plainly that it is fixed templates, not a model or a chat, and has the lock and the pinned branch", () => {
    const src = readFileSync("src/components/RoomAiFounding.tsx", "utf8");
    expect(src).toContain("قوالب جاهزة ثابتة"); expect(src).toContain("ليست محادثة ولا نموذج ذكاء اصطناعي");
    expect(src).toContain("lock"); expect(src).toContain("pinnedBranch"); expect(src).toContain("include: false");
  });
});
