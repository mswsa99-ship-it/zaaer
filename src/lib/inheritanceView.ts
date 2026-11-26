/**
 * Display mapping only for lane 7's server plans (src/lib/inheritance.ts). No inheritance rules live here:
 * the server preview decides who is updated and who keeps their own text; this turns it into rows for the dialog.
 */
import type { PolicyPreview, PolicyField, KnowledgePreview, KnowledgeField } from "./inheritance";

export type PlanEffect = "updates" | "creates" | "keeps_own" | "linked" | "unchanged" | "skipped";
export interface PlanRow { branchId: string; name: string; effect: PlanEffect; changed: string[]; overwritable: string[] }

export const FIELD_LABELS: Record<PolicyField | KnowledgeField, string> = {
  title: "العنوان", content_ar: "النص", content_en: "النص الإنجليزي", is_public: "الظهور للنزيل",
  question: "السؤال", answer: "الإجابة", answer_en: "الإجابة بالإنجليزية", category: "التصنيف", is_active: "التفعيل", priority: "الأولوية", keywords: "الكلمات المفتاحية",
};
const lbl = (f: string) => FIELD_LABELS[f as keyof typeof FIELD_LABELS] ?? f;

export function policyPlanRows(p: PolicyPreview): PlanRow[] {
  return p.branches.map((b) => ({
    branchId: b.branch_id, name: b.branch_name, changed: b.update_fields.map(lbl), overwritable: b.overwritable_fields.map(lbl),
    effect: b.action === "create" ? "creates" : b.action === "update" ? "updates" : b.action === "keep_override" ? "keeps_own" : b.action === "link_existing" ? "linked" : b.action === "skip_archived" ? "skipped" : "unchanged",
  }));
}
export function knowledgePlanRows(p: KnowledgePreview): PlanRow[] {
  return p.branches.map((b) => ({
    branchId: b.branch_id, name: b.branch_name, changed: b.changed_fields.map(lbl), overwritable: b.overwritable_fields.map(lbl),
    effect: b.action === "inherits" ? "updates" : b.action === "keep_override" ? "keeps_own" : "unchanged",
  }));
}
/** Which of the rows a person may choose to overwrite (server lists them as overwritable). */
export const overwritableRows = (rows: PlanRow[]) => rows.filter((r) => r.effect === "keeps_own" && r.overwritable.length > 0);

export type LoadState = "denied" | "error";
/** Permission refusals from the server are a state of their own, not a generic failure. */
export function classifyError(e: unknown): LoadState {
  const x = e as { code?: string; message?: string } | null;
  return x?.code === "42501" || /permission denied|not allowed|forbidden/i.test(x?.message ?? "") ? "denied" : "error";
}

/** Branches the caller may not see are only counted by the server (no names); shown as a plain note. */
export function hiddenBranchesNote(h: { inherits: number; keep_override: number } | undefined): string | null {
  if (!h || h.inherits + h.keep_override === 0) return null;
  const parts = [h.inherits ? `${h.inherits} ستتحدّث` : "", h.keep_override ? `${h.keep_override} تحتفظ بنصها الخاص` : ""].filter(Boolean).join("، ");
  return `فروع أخرى خارج صلاحيتك لرؤيتها: ${parts}.`;
}
