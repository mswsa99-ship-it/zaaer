/**
 * Room AI, phase 1 (founding). Room AI only PROPOSES: a draft lives in the browser session and nothing is written
 * until the user confirms it, one item at a time or all together. It never touches money or finance actions and
 * reads only the active hotel's active branch.
 */
export type StepId = "policies" | "structure" | "categories" | "facilities" | "task_types";

export type FieldType = "text" | "textarea" | "number" | "check" | "select" | "money_sar";
export interface FieldSpec { key: string; label: string; type: FieldType; options?: Record<string, string>; hint?: string; ltr?: boolean; wide?: boolean; required?: boolean }

/** One proposed item. `values` is what the user sees and edits; `note` explains why it was suggested. */
export interface DraftItem { id: string; include: boolean; values: Record<string, string | number | boolean | null>; note?: string }

export type Severity = "risk" | "warn" | "note";
export interface Finding { id: string; severity: Severity; step: StepId | "general"; title: string; detail: string; to?: string }

/** The active branch's current data, read with hotel-scoped queries only. */
export interface Snapshot {
  branch: { id: string; name_ar: string; check_in_time?: string | null; check_out_time?: string | null } | null;
  policies: Array<{ topic: string; title: string; content_ar: string; is_public: boolean; archived_at: string | null }>;
  blocks: Array<{ id: string; name: string; archived_at: string | null }>;
  floors: Array<{ id: string; block_id: string; name: string; archived_at: string | null }>;
  categories: Array<{ id: string; name_ar: string; base_capacity: number; max_capacity: number; base_price_halalas: number | null; archived_at: string | null }>;
  rooms: Array<{ id: string; category_id: string; floor_id: string | null; archived_at: string | null }>;
  facilities: Array<{ name: string; archived_at: string | null }>;
  taskTypes: Array<{ name: string; code: string | null; archived_at: string | null }>;
}
export const emptySnapshot = (): Snapshot => ({ branch: null, policies: [], blocks: [], floors: [], categories: [], rooms: [], facilities: [], taskTypes: [] });

export interface ProposalContext { snapshot: Snapshot; /** user's answers to the step's questions */ answers: Record<string, string | number> }

/**
 * The pluggable seam. Phase 1 ships only the deterministic provider (templates, no network, no model).
 * A language-model provider would implement the same two methods and must return the same shapes; its output is
 * still only a draft that goes through the same confirm step. See docs/ROOM_AI.md.
 */
export interface RoomAiProvider {
  readonly id: string;
  propose(step: StepId, ctx: ProposalContext): Promise<DraftItem[]>;
  review(snapshot: Snapshot): Promise<Finding[]>;
}
