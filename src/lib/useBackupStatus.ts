import { useCallback, useEffect, useState } from "react";
import { supabase } from "./supabase";
import { toArabicError } from "./api";

/**
 * Item 7.1 (O4/T6): the recorded backup state behind «النسخ الاحتياطي». The server enforces owner-only read
 * (fn_backup_status, migration 0103); this hook only presents it. No key, passphrase or destination ever
 * reaches the client — the status rows carry references and proofs, never secrets.
 */
export type BackupRunSummary = {
  started_at: string;
  finished_at: string | null;
  status: "running" | "success" | "failed";
  reason: "scheduled" | "pre-deploy" | "manual" | "drill";
  error: string | null;
};

export type BackupStatus = {
  last_success: {
    finished_at: string;
    run_ref: string;
    size_bytes: number | null;
    sha256: string | null;
    tables_count: number | null;
    rows_total: number | null;
    reason: string;
    verification: string | null;
  } | null;
  last_run: BackupRunSummary | null;
  last_restore_drill: { started_at: string; finished_at: string | null; status: string; verification: string | null; error: string | null } | null;
  failures_since_last_success: number;
};

export function useBackupStatus() {
  const [status, setStatus] = useState<BackupStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const { data, error: rpcError } = await supabase.rpc("fn_backup_status");
      if (rpcError) throw rpcError;
      setStatus((data as unknown as BackupStatus) ?? null);
    } catch (e) {
      setError(toArabicError(e));
      setStatus(null);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void reload();
  }, [reload]);

  return { status, loading, error, reload };
}
