/** Staff-list branch_ids are the caller-visible subset, not a full assignment registry for nonowners. */
export const emptyStaffBranchesLabel = (isOwner: boolean) => isOwner ? "بلا فرع" : "لا توجد فروع ظاهرة ضمن صلاحياتك";
/** Never replace memberships with an unchanged partial display. The server validates all explicit changes. */
export function changedStaffBranches(initial: string[], next: string[]): { branch_ids?: string[] } {
  const a = new Set(initial), b = new Set(next);
  return a.size === b.size && [...a].every((id) => b.has(id)) ? {} : { branch_ids: [...b] };
}
