import { describe, it, expect } from "vitest";
import { policyPlanRows, knowledgePlanRows, overwritableRows, classifyError } from "../../src/lib/inheritanceView";
import type { PolicyPreview, KnowledgePreview } from "../../src/lib/inheritance";

const pp = { master: { id: "m", topic: "checkin", title: "t", content_ar: "c" }, is_new: false, token: "x", branches: [
  { branch_id: "b1", branch_name: "بريدة", policy_id: "p1", action: "update", update_fields: ["content_ar"], kept_fields: [], overwritable_fields: [] },
  { branch_id: "b2", branch_name: "عنيزة", policy_id: "p2", action: "keep_override", update_fields: [], kept_fields: ["content_ar"], overwritable_fields: ["content_ar"] },
  { branch_id: "b3", branch_name: "الرس", policy_id: null, action: "create", update_fields: ["title", "content_ar"], kept_fields: [], overwritable_fields: [] },
  { branch_id: "b4", branch_name: "ضرماء", policy_id: "p4", action: "link_existing", update_fields: [], kept_fields: ["title"], overwritable_fields: [] },
  { branch_id: "b5", branch_name: "قديم", policy_id: "p5", action: "skip_archived", update_fields: [], kept_fields: [], overwritable_fields: [] },
] } as PolicyPreview;

describe("inheritance view mapping", () => {
  it("maps the server policy plan without recomputing it", () => {
    const rows = policyPlanRows(pp);
    expect(rows.map((r) => r.effect)).toEqual(["updates", "keeps_own", "creates", "linked", "skipped"]);
    expect(rows[1].overwritable).toEqual(["النص"]);
    expect(rows[2].changed).toEqual(["العنوان", "النص"]);
  });
  it("only branches the server marks overwritable can be chosen", () => {
    expect(overwritableRows(policyPlanRows(pp)).map((r) => r.branchId)).toEqual(["b2"]);
  });
  it("maps knowledge plan", () => {
    const kp = { entry_id: "e", version: 1, changed_fields: ["answer"], token: "t", branches: [
      { branch_id: "b1", branch_name: "أ", override_id: null, action: "inherits", changed_fields: ["answer"], overwritable_fields: [] },
      { branch_id: "b2", branch_name: "ب", override_id: "o", action: "keep_override", changed_fields: [], overwritable_fields: ["answer"] },
      { branch_id: "b3", branch_name: "ج", override_id: null, action: "unchanged", changed_fields: [], overwritable_fields: [] }] } as KnowledgePreview;
    expect(knowledgePlanRows(kp).map((r) => r.effect)).toEqual(["updates", "keeps_own", "unchanged"]);
  });
  it("classifies permission refusal separately from other errors", () => {
    expect(classifyError({ code: "42501", message: "x" })).toBe("denied");
    expect(classifyError({ message: "permission denied for function" })).toBe("denied");
    expect(classifyError({ message: "network" })).toBe("error");
    expect(classifyError(null)).toBe("error");
  });
});

import { hiddenBranchesNote } from "../../src/lib/inheritanceView";
describe("hidden branches note", () => {
  it("is empty when nothing is hidden and counts without names otherwise", () => {
    expect(hiddenBranchesNote(undefined)).toBeNull();
    expect(hiddenBranchesNote({ inherits: 0, keep_override: 0 })).toBeNull();
    expect(hiddenBranchesNote({ inherits: 2, keep_override: 1 })).toBe("فروع أخرى خارج صلاحيتك لرؤيتها: 2 ستتحدّث، 1 تحتفظ بنصها الخاص.");
  });
});
