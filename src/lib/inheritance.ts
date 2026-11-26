/**
 * Hotel-level policies and knowledge base inherited by branches (migration 0149).
 * The server decides everything: preview names the branches and fields a hotel-level change will touch, apply writes
 * exactly that preview (token), branches keep their own customised fields unless explicitly chosen to be overwritten,
 * revert gives a branch's own text back to the hotel-level one. This module only calls the RPCs; it holds no rules.
 */
import { supabase } from "./supabase";

export type PolicyTopic = "checkin" | "cancellation" | "wifi" | "parking" | "location" | "children" | "contact" | "stay" | "privacy" | "other";
export type PolicyField = "title" | "content_ar" | "content_en" | "is_public";

export interface PolicyMasterDraft {
  id?: string;                 // omit to create a new hotel-level policy
  version?: number;            // required when editing
  topic?: PolicyTopic;         // fixed once created
  topic_label?: string | null; // only for topic "other"
  title: string;
  content_ar: string;
  content_en?: string | null;
  is_public?: boolean;
  sort_order?: number;
}

/** What would happen in one branch. */
export type PolicyBranchAction =
  | "create"          // branch has no such policy: gets an inherited copy
  | "update"          // inherited fields are updated
  | "keep_override"   // branch changed these fields itself: kept (overwritable only when chosen)
  | "link_existing"   // branch already had a policy of this topic: kept as it is, now linked; differing fields count as its own
  | "unchanged"
  | "skip_archived";

export interface PolicyPlanBranch {
  branch_id: string;
  branch_name: string;
  policy_id: string | null;
  action: PolicyBranchAction;
  update_fields: PolicyField[];        // will change if applied
  kept_fields: PolicyField[];          // branch's own text, preserved
  overwritable_fields: PolicyField[];  // kept fields that differ and may be overwritten if this branch is chosen
}

export interface PolicyPreview {
  master: Omit<PolicyMasterDraft, "version"> & { id: string; topic: PolicyTopic };
  is_new: boolean;
  branches: PolicyPlanBranch[];
  token: string;                        // pass back to apply
}

export interface PolicyApplyResult { ok: true; id: string; version: number; created: number; updated: number; overwritten: number; kept_own: number }

export interface PolicyMasterRow {
  id: string; topic: PolicyTopic; topic_label: string | null; title: string; content_ar: string; content_en: string | null;
  is_public: boolean; sort_order: number; version: number;
  branches: { branch_id: string; policy_id: string; override_fields: PolicyField[]; master_version: number | null; archived: boolean }[];
}

export interface KnowledgeEdit {
  question?: string; answer?: string; answer_en?: string | null; keywords?: string[]; category?: string;
  is_public?: boolean; is_active?: boolean; priority?: number; version: number; reason?: string;
}
export type KnowledgeField = "question" | "answer" | "answer_en" | "category" | "is_public" | "is_active" | "priority" | "keywords";
export interface KnowledgePlanBranch {
  branch_id: string; branch_name: string;
  override_id: string | null;
  action: "inherits" | "keep_override" | "unchanged";
  changed_fields: KnowledgeField[];       // inherits: these change for the branch
  overwritable_fields: KnowledgeField[];  // keep_override: these would change if the branch is chosen
}
/** branches lists only the branches the caller may see; hidden_branches counts the others (no names, no entry ids). */
export interface KnowledgePreview { entry_id: string; version: number; changed_fields: KnowledgeField[]; branches: KnowledgePlanBranch[]; hidden_branches: { inherits: number; keep_override: number }; token: string }
export interface KnowledgeEffectiveRow {
  id: string; branch_id: string | null; origin: "hotel" | "branch_override" | "branch_only"; overrides_entry_id: string | null;
  category: string; question: string; keywords: string[]; answer: string; answer_en: string | null;
  is_public: boolean; is_active: boolean; priority: number; version: number;
}

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

export const inheritanceApi = {
  // ---- policies
  policyMasters: () => rpc<{ masters: PolicyMasterRow[] }>("fn_policy_masters_list", {}),
  policyPreview: (d: PolicyMasterDraft) => rpc<PolicyPreview>("fn_policy_master_preview", { p: d }),
  /** overwriteBranches: branch ids chosen explicitly; each must be a branch the preview lists with overwritable_fields. */
  policyApply: (d: PolicyMasterDraft, preview: PolicyPreview, overwriteBranches: string[] = [], reason?: string) =>
    rpc<PolicyApplyResult>("fn_policy_master_apply", { p: { ...d, id: d.id ?? preview.master.id, token: preview.token, overwrite_branches: overwriteBranches, reason } }),
  /** A branch follows the hotel-level text again (fields omitted = all of its own fields). */
  policyRevert: (policyId: string, fields?: PolicyField[], reason?: string) =>
    rpc<{ ok: boolean; reverted: PolicyField[] }>("fn_policy_branch_revert", { p_policy_id: policyId, p_fields: fields ?? null, p_reason: reason ?? null }),
  // ---- knowledge base
  knowledgePreview: (entryId: string, edit: KnowledgeEdit) => rpc<KnowledgePreview>("fn_knowledge_main_preview", { p_entry: entryId, p: edit }),
  knowledgeApply: (entryId: string, edit: KnowledgeEdit, preview: KnowledgePreview, overwriteBranches: string[] = []) =>
    rpc<{ ok: boolean; id: string; version: number; overwritten: number }>("fn_knowledge_main_apply", { p_entry: entryId, p: { ...edit, token: preview.token, overwrite_branches: overwriteBranches } }),
  /** A branch makes its own version of a shared entry (then edit it with knowledgeApi.upsert). */
  knowledgeOverride: (entryId: string, branchId: string, seed?: Partial<KnowledgeEdit>) =>
    rpc<{ ok: boolean; id: string; version: number; existing: boolean }>("fn_knowledge_branch_override", { p_entry: entryId, p_branch: branchId, p: seed ?? {} }),
  knowledgeRevert: (overrideId: string, reason?: string) => rpc<{ ok: boolean }>("fn_knowledge_revert_override", { p_override: overrideId, p_reason: reason ?? null }),
  knowledgeEffective: (branchId: string) => rpc<KnowledgeEffectiveRow[]>("fn_knowledge_effective", { p_branch: branchId }),
};
