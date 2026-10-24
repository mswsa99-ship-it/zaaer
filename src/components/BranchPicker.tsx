import { useBranch, NO_BRANCH_MESSAGE } from "../lib/branch";
import { useAuth } from "../lib/auth";
import { Building2, AlertTriangle } from "lucide-react";

/**
 * Branch scope selector shared by operational and admin screens. The selection lives in BranchProvider, so changing
 * it here refreshes every branch-scoped list/request/form on the open page (U02/G24). A signed-in user with no
 * authorised branch sees the fail-closed message instead of a picker (GAP02).
 */
export function BranchPicker({ className }: { className?: string }) {
  const { branchId, branches, setBranchId, loading } = useBranch();
  const { session } = useAuth();
  if (loading) return null;
  if (branches.length === 0) {
    if (!session) return null;
    return <span className={"inline-flex items-center gap-1.5 text-sm text-danger-600 " + (className ?? "")}><AlertTriangle className="h-4 w-4" /> {NO_BRANCH_MESSAGE}</span>;
  }
  if (branches.length === 1) return <span className={"inline-flex items-center gap-1.5 text-sm text-ink-500 " + (className ?? "")}><Building2 className="h-4 w-4" /> {branches[0].name_ar}</span>;
  return (
    <label className={"inline-flex items-center gap-2 text-sm " + (className ?? "")}>
      <Building2 className="h-4 w-4 text-ink-400" />
      <select value={branchId ?? ""} onChange={(e) => setBranchId(e.target.value)} className="input w-auto py-1.5" aria-label="الفرع النشط">
        {branches.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
      </select>
    </label>
  );
}
