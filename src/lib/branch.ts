/**
 * Active-branch scope, shared by every screen through one React context (GAP01).
 *
 *  - Staff: the list is exactly what `fn_user_branch_ids` returns (SECURITY DEFINER; owner → all branches of the
 *    organisation, others → memberships). No memberships or a failed query → EMPTY list, no active branch, and the
 *    guard / BranchPicker show "لا يوجد فرع مخوّل لحسابك — تواصل مع المدير" instead of data (GAP02, fail closed).
 *  - Guest screens (no session): VITE_DEFAULT_BRANCH_ID or the first active branch (branches are publicly readable:
 *    name, times and the tax setting that prices are quoted against).
 *  - The selection is persisted per user (localStorage key scoped by the signed-in user id) and changing it
 *    re-renders every consumer of `useBranch()`, so each page's branch-keyed effects refetch. Out-of-order
 *    responses are dropped with a request token.
 */
import { createContext, createElement, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { supabase } from "./supabase";
import { useAuth } from "./auth";

export interface BranchLite { id: string; name_ar: string; name_en?: string | null; check_in_time?: string; check_out_time?: string; tax_rate_bp?: number; prices_include_tax?: boolean; map_url?: string | null; booking_platform_url?: string | null; default_language?: "ar" | "en" }

/** What a quoted price means for tax (decision 68): nothing to say at zero tax, otherwise before or including it. */
export function priceTaxNote(b: BranchLite | null | undefined): string | null {
  if (!b || !b.tax_rate_bp) return null;
  return b.prices_include_tax ? "شامل الضريبة" : "قبل الضريبة";
}

export const NO_BRANCH_MESSAGE = "لا يوجد فرع مخوّل لحسابك — تواصل مع المدير";

const DEFAULT_BRANCH = (import.meta.env.VITE_DEFAULT_BRANCH_ID as string | undefined) ?? null;
const BRANCH_COLUMNS = "id, name_ar, name_en, check_in_time, check_out_time, tax_rate_bp, prices_include_tax, map_url, booking_platform_url, default_language";

interface BranchContextValue {
  branches: BranchLite[];
  /** True until the list for the current principal (staff user or guest) has been resolved. */
  loading: boolean;
  /** Message when the authorised-branch query failed (the list is empty in that case). */
  error: string | null;
  branchId: string | null;
  branch: BranchLite | null;
  setBranchId: (id: string) => void;
  /** Re-run the authorised-branch query (e.g. after the manager fixed the memberships). */
  reload: () => void;
}

const BranchContext = createContext<BranchContextValue | undefined>(undefined);
const EMPTY: BranchLite[] = [];

// ---------------------------------------------------------------------------
// persistence (per user; best effort — storage may be unavailable)
// ---------------------------------------------------------------------------
const storageKey = (scope: string) => `zaaer.branch.${scope}`;
function readStored(scope: string | null): string | null {
  if (!scope) return null;
  try { return (scope === "guest" ? sessionStorage : localStorage).getItem(storageKey(scope)); } catch { return null; }
}
function writeStored(scope: string | null, id: string) {
  if (!scope) return;
  try { (scope === "guest" ? sessionStorage : localStorage).setItem(storageKey(scope), id); } catch { /* ignore */ }
}

// ---------------------------------------------------------------------------
// data
// ---------------------------------------------------------------------------
type Loaded = { branches: BranchLite[]; error: string | null };

async function loadGuestBranches(): Promise<Loaded> {
  const { data, error } = await supabase.from("branches").select(BRANCH_COLUMNS).eq("is_active", true).order("created_at");
  if (error) return { branches: [], error: error.message };
  return { branches: (data as BranchLite[]) ?? [], error: null };
}

/** Staff: only branches the server says this user may act on. Empty or failed → empty (never the public list). */
async function loadStaffBranches(): Promise<Loaded> {
  const { data: ids, error } = await supabase.rpc("fn_user_branch_ids");
  if (error) return { branches: [], error: error.message };
  const allowed = new Set(
    (Array.isArray(ids) ? (ids as Array<{ fn_user_branch_ids: string } | string>) : [])
      .map((x) => (typeof x === "string" ? x : x?.fn_user_branch_ids))
      .filter((x): x is string => typeof x === "string" && x.length > 0)
  );
  if (allowed.size === 0) return { branches: [], error: null };
  const { data, error: e2 } = await supabase.from("branches").select(BRANCH_COLUMNS).eq("is_active", true).order("created_at");
  if (e2) return { branches: [], error: e2.message };
  return { branches: ((data as BranchLite[]) ?? []).filter((b) => allowed.has(b.id)), error: null };
}

// ---------------------------------------------------------------------------
// provider
// ---------------------------------------------------------------------------
export function BranchProvider({ children }: { children: ReactNode }) {
  const { session, loading: authLoading } = useAuth();
  const userId = session?.user?.id ?? null;
  // Persistence scope: the signed-in user (1:1 with the staff profile) or the shared guest scope.
  const scope = authLoading ? null : userId ?? "guest";

  const [state, setState] = useState<{ scope: string | null; branches: BranchLite[]; loading: boolean; error: string | null }>({ scope: null, branches: [], loading: true, error: null });
  const [override, setOverride] = useState<{ scope: string; id: string } | null>(null);
  const reqRef = useRef(0);
  const [reloadTick, setReloadTick] = useState(0);

  useEffect(() => {
    if (!scope) return;
    const token = ++reqRef.current;
    setState((s) => ({ ...s, loading: true, error: null }));
    (userId ? loadStaffBranches() : loadGuestBranches()).then((r) => {
      if (token !== reqRef.current) return; // a newer request (sign-in/out, reload) superseded this one
      setState({ scope, branches: r.branches, loading: false, error: r.error });
    });
  }, [scope, userId, reloadTick]);

  const branches = state.scope === scope ? state.branches : EMPTY;
  const loading = !scope || state.scope !== scope || state.loading;
  const error = state.scope === scope ? state.error : null;

  const stored = useMemo(() => readStored(scope), [scope]);
  const chosen = override && override.scope === scope ? override.id : stored;
  const branch = useMemo(() => {
    if (branches.length === 0) return null;
    return branches.find((b) => b.id === chosen) ?? branches.find((b) => b.id === DEFAULT_BRANCH) ?? branches[0];
  }, [branches, chosen]);

  const setBranchId = useCallback((id: string) => {
    if (!scope) return;
    setOverride({ scope, id });
    writeStored(scope, id);
  }, [scope]);
  const reload = useCallback(() => setReloadTick((t) => t + 1), []);

  const value = useMemo<BranchContextValue>(() => ({ branches, loading, error, branchId: branch?.id ?? null, branch, setBranchId, reload }), [branches, loading, error, branch, setBranchId, reload]);
  return createElement(BranchContext.Provider, { value }, children);
}

function useBranchContext(): BranchContextValue {
  const ctx = useContext(BranchContext);
  if (!ctx) throw new Error("useBranch must be used within BranchProvider");
  return ctx;
}

/** Authorised branches of the current principal (never the public list for a signed-in user). */
export function useBranches() {
  const { branches, loading, error } = useBranchContext();
  return { branches, loading, error };
}

/** The active branch shared by the whole app; `setBranchId` switches it for every open list/request/form. */
export function useBranch() {
  return useBranchContext();
}
