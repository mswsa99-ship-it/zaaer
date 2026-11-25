// Uncommitted screenshot harness for AdminBackup (deleted before delivery): renders the presentational
// BackupStatusView with synthetic status data, no backend. Scenarios: ?case=ok | empty | failed
import React from "react";
import { MemoryRouter } from "react-router-dom";
import ReactDOM from "react-dom/client";
import "../src/index.css";
import { BackupStatusView } from "../src/pages/admin/AdminBackup";
import type { BackupStatus } from "../src/lib/useBackupStatus";

const ok: BackupStatus = {
  last_success: {
    finished_at: "2026-11-23T03:17:00+03:00",
    run_ref: "backup-20261123-031700-scheduled.tar.gpg",
    size_bytes: 2411724,
    sha256: "d06f39e87e97aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    tables_count: 102,
    rows_total: 48213,
    reason: "scheduled",
    verification: "manifest+sha256; uploaded",
  },
  last_run: { started_at: "2026-11-23T03:15:00+03:00", finished_at: "2026-11-23T03:17:00+03:00", status: "success", reason: "scheduled", error: null },
  last_restore_drill: { started_at: "2026-11-01T04:00:00+03:00", finished_at: "2026-11-01T04:03:00+03:00", status: "success", verification: "restore:counts+hashes identical", error: null },
  failures_since_last_success: 0,
};
const failed: BackupStatus = {
  ...ok,
  last_run: { started_at: "2026-11-24T03:15:00+03:00", finished_at: "2026-11-24T03:15:40+03:00", status: "failed", reason: "scheduled", error: "upload failed" },
  failures_since_last_success: 1,
};
const empty: BackupStatus = { last_success: null, last_run: null, last_restore_drill: null, failures_since_last_success: 0 };

const scenario = new URLSearchParams(location.search).get("case") ?? "ok";
const status = scenario === "empty" ? empty : scenario === "failed" ? failed : ok;

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode><MemoryRouter>
    <div dir="rtl" className="mx-auto max-w-5xl p-4">
      <BackupStatusView status={status} loading={false} error={null} reload={() => undefined} />
    </div>
  </MemoryRouter></React.StrictMode>,
);
