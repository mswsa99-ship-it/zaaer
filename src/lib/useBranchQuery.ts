import { useCallback, useEffect, useRef, useState, type DependencyList } from "react";
import { useBranch } from "./branch";
import { toArabicError } from "./api";

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
export function useBranchQuery<T>(load: (branchId: string) => Promise<T>, deps: DependencyList, empty: T): BranchQuery<T> {
  const { branchId, loading: branchLoading } = useBranch();
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
    if (!branchId) { setState({ key: null, data: emptyRef.current, loading: false, refreshing: false, error: null }); return; }
    setState((s) => (s.key === branchId
      ? { ...s, refreshing: true, error: null }
      : { key: branchId, data: emptyRef.current, loading: true, refreshing: false, error: null }));
    loadRef.current(branchId).then(
      (data) => { if (token === reqRef.current) setState({ key: branchId, data, loading: false, refreshing: false, error: null }); },
      (e) => {
        if (token !== reqRef.current) return;
        setState((s) => ({ key: branchId, data: s.key === branchId ? s.data : emptyRef.current, loading: false, refreshing: false, error: toArabicError(e) }));
      });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [branchId, branchLoading, tick, ...deps]);

  const reload = useCallback(() => setTick((t) => t + 1), []);
  const current = state.key === branchId && branchId !== null;
  return {
    data: current ? state.data : emptyRef.current,
    loading: branchLoading || (branchId !== null && (!current || state.loading)),
    refreshing: current && state.refreshing,
    error: current ? state.error : null,
    branchId,
    reload,
  };
}

/** A Supabase query result as a value, or a thrown error (so useBranchQuery reports it instead of showing "empty"). */
export function must<T>(res: { data: T | null; error: { message: string } | null }): T {
  if (res.error) throw new Error(res.error.message);
  return (res.data ?? ([] as unknown as T));
}
