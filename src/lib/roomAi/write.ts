import { opsApi } from "../api";
import { supabase } from "../supabase";
import { floorLines } from "./provider";
import type { DraftItem, Snapshot, StepId } from "./types";

export interface WriteCtx { branchId: string; organizationId: string; userId: string; snapshot: Snapshot }
const must = (r: { error: { message: string } | null }) => { if (r.error) throw new Error(r.error.message); };

/**
 * Applies ONE confirmed item through the same calls the regular admin pages use (the server enforces role and
 * branch). Money fields are never written here except the base nightly price the user typed himself.
 * Never called unless the user pressed confirm.
 */
export async function writeItem(step: StepId, d: DraftItem, c: WriteCtx): Promise<void> {
  const v = d.values;
  if (step === "policies") {
    must(await supabase.from("property_policies").insert({
      branch_id: c.branchId, organization_id: c.organizationId, topic: String(v.topic), topic_label: null,
      title: String(v.title).trim(), content_ar: String(v.content_ar).trim(), is_public: !!v.is_public,
      sort_order: c.snapshot.policies.length + 1, updated_by: c.userId, updated_at: new Date().toISOString(),
    }));
  } else if (step === "structure") {
    const name = String(v.name).trim();
    let blockId = c.snapshot.blocks.find((b) => !b.archived_at && b.name.trim() === name)?.id;
    if (!blockId) blockId = (await opsApi.upsertBlock({ branch_id: c.branchId, name, description: null, sort_order: c.snapshot.blocks.length + 1, is_active: true })).id;
    const have = new Set(c.snapshot.floors.filter((f) => f.block_id === blockId && !f.archived_at).map((f) => f.name.trim()));
    let order = c.snapshot.floors.filter((f) => f.block_id === blockId).length;
    for (const f of floorLines(v)) { if (have.has(f)) continue; await opsApi.upsertFloor({ block_id: blockId, name: f, sort_order: ++order, is_active: true }); }
  } else if (step === "categories") {
    await opsApi.upsertRoomCategory({
      branch_id: c.branchId, name_ar: String(v.name_ar).trim(), name_en: String(v.name_en ?? "").trim() || null, description: String(v.description ?? "").trim() || null,
      base_capacity: Number(v.base_capacity), max_capacity: Number(v.max_capacity), base_price_halalas: Math.round(Number(v.price_sar) * 100),
      weekly_price_halalas: null, monthly_price_halalas: null, min_nightly_halalas: null, price_mode: "unified", amenities: [], is_public: true, is_active: true, sort_order: c.snapshot.categories.length + 1,
    });
  } else if (step === "facilities") {
    await opsApi.upsertFacility({ branch_id: c.branchId, name: String(v.name).trim(), description: String(v.description ?? "").trim() || null, block_id: null, floor_id: null, is_active: true });
  } else {
    await opsApi.upsertTaskType({ branch_id: c.branchId, name: String(v.name).trim(), description: String(v.description ?? "").trim() || null, is_active: true });
  }
}

/** Read-only, hotel-scoped: every query filters on the active branch (the server's row rules also scope to the hotel). */
export async function loadSnapshot(branch: Snapshot["branch"]): Promise<Snapshot> {
  if (!branch) return { branch: null, policies: [], blocks: [], floors: [], categories: [], rooms: [], facilities: [], taskTypes: [] };
  const id = branch.id;
  const [p, b, f, c, r, fa, t] = await Promise.all([
    supabase.from("property_policies").select("topic, title, content_ar, is_public, archived_at").eq("branch_id", id),
    supabase.from("blocks").select("id, name, archived_at").eq("branch_id", id),
    supabase.from("floors").select("id, block_id, name, archived_at").eq("branch_id", id),
    supabase.from("room_categories").select("id, name_ar, base_capacity, max_capacity, base_price_halalas, archived_at").eq("branch_id", id),
    supabase.from("rooms").select("id, category_id, floor_id, archived_at").eq("branch_id", id),
    supabase.from("facilities").select("name, archived_at").eq("branch_id", id),
    supabase.from("task_types").select("name, code, archived_at").eq("branch_id", id),
  ]);
  for (const x of [p, b, f, c, r, fa, t]) if (x.error) throw new Error(x.error.message);
  return { branch, policies: p.data ?? [], blocks: b.data ?? [], floors: f.data ?? [], categories: c.data ?? [], rooms: r.data ?? [], facilities: fa.data ?? [], taskTypes: t.data ?? [] } as Snapshot;
}
