import { useCallback, useEffect, useRef, useState, type DependencyList } from "react";
import { useBranch } from "./branch";
import { toArabicError } from "./api";

export const ROOM_AI_CHANGED = "roomai:changed";

export interface BranchQuery<T> {
  /** The result for the ACTIVE branch only — never a previous branch's data. */
  data: T;
  /** True until the first result for the active branch arrives (the screen shows "loading", not old data). */
  loading: boolean;
  /** A reload in progress while the current branch's data stays on screen. */
  refreshing: boolean;
  /** Why the load failed — shown as an error with "retry", never as an empty list (G23/U04). */
  error: string | null;
  /** The branch the data belongs to (null when the user has no authorised branch). */
  branchId: string | null;
  /** True when the owner chose «جميع الفروع» and this query merged every branch (a read-only view). */
  all: boolean;
  reload: () => void;
}

/**
 * One way for every branch-scoped screen to load its data (decision 40, control G24):
 *  - each request is tied to the branch it was made for; a response for another branch, or one that an
 *    newer request superseded, is dropped — a slow answer from the previous branch can never replace the
 *    current one;
 *  - switching the branch clears the screen at once (loading), so nothing of the previous branch stays visible;
 *  - no active branch → the empty value, never an unscoped query (fail closed);
 *  - a failed reload keeps the branch's current data and reports the error beside it.
 * `deps` are the loader's other inputs (filters, page…): a change reloads.
 */
export function useBranchQuery<T>(load: (branchId: string) => Promise<T>, deps: DependencyList, empty: T, opts?: { merge?: (parts: T[]) => T }): BranchQuery<T> {
  const { branchId, branches, allBranches, loading: branchLoading } = useBranch();
  // «جميع الفروع» (owner only): every authorised branch is loaded and merged; without a merge function the screen stays single-branch.
  const fan = allBranches && !!opts?.merge;
  const key = fan ? "all:" + branches.map((b) => b.id).join(",") : branchId;
  const mergeRef = useRef(opts?.merge);
  mergeRef.current = opts?.merge;
  const branchesRef = useRef(branches);
  branchesRef.current = branches;
  const emptyRef = useRef(empty);
  const loadRef = useRef(load);
  loadRef.current = load;
  const [state, setState] = useState<{ key: string | null; data: T; loading: boolean; refreshing: boolean; error: string | null }>(
    { key: null, data: empty, loading: true, refreshing: false, error: null });
  const reqRef = useRef(0);
  const [tick, setTick] = useState(0);

  useEffect(() => {
    const token = ++reqRef.current;
    if (branchLoading) return;
    if (!key) { setState({ key: null, data: emptyRef.current, loading: false, refreshing: false, error: null }); return; }
    setState((s) => (s.key === key
      ? { ...s, refreshing: true, error: null }
      : { key, data: emptyRef.current, loading: true, refreshing: false, error: null }));
    const run: Promise<T> = fan
      ? Promise.all(branchesRef.current.map((b) => loadRef.current(b.id))).then((parts) => mergeRef.current!(parts))
      : loadRef.current(key);
    run.then(
      (data) => { if (token === reqRef.current) setState({ key, data, loading: false, refreshing: false, error: null }); },
      (e) => {
        if (token !== reqRef.current) return;
        setState((s) => ({ key, data: s.key === key ? s.data : emptyRef.current, loading: false, refreshing: false, error: toArabicError(e) }));
      });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, branchLoading, tick, ...deps]);

  const reload = useCallback(() => setTick((t) => t + 1), []);
  // Room AI confirmed a write for this branch: the open page reloads its list (no other behaviour change)
  useEffect(() => {
    const onChanged = () => setTick((t) => t + 1);
    window.addEventListener(ROOM_AI_CHANGED, onChanged);
    return () => window.removeEventListener(ROOM_AI_CHANGED, onChanged);
  }, []);
  const current = state.key === key && key !== null;
  return {
    data: current ? state.data : emptyRef.current,
    loading: branchLoading || (key !== null && (!current || state.loading)),
    refreshing: current && state.refreshing,
    error: current ? state.error : null,
    branchId,
    all: fan,
    reload,
  };
}

/** A Supabase query result as a value, or a thrown error (so useBranchQuery reports it instead of showing "empty"). */
export function must<T>(res: { data: T | null; error: { message: string } | null }): T {
  if (res.error) throw new Error(res.error.message);
  return (res.data ?? ([] as unknown as T));
}
