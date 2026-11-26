/** LOCAL TEST HARNESS ONLY. Mounts the REAL InheritancePreviewDialog with MOCKED plan rows (no backend, no RPC). It proves layout/reachability, not server behaviour. */
import ReactDOM from "react-dom/client";
import { useState } from "react";
import "../../../src/index.css";
import "../../../src/themeIdentity.css";
import { InheritancePreviewDialog } from "../../../src/components/InheritancePreviewDialog";
import type { PlanRow } from "../../../src/lib/inheritanceView";

const n = Number(new URLSearchParams(location.search).get("rows") ?? 12);
const rows: PlanRow[] = Array.from({ length: n }, (_, i) => ({
  branchId: `b${i}`, name: `فرع تجريبي ${i + 1}`,
  effect: i % 3 === 0 ? "keeps_own" : i % 3 === 1 ? "updates" : "creates",
  changed: i % 3 === 1 ? ["العنوان", "النص"] : [], overwritable: i % 3 === 0 ? ["النص"] : [],
}));
function App() {
  const [open, setOpen] = useState(true);
  const [log, setLog] = useState("");
  return (<div className="p-4">
    <button className="btn-primary min-h-[44px]" onClick={() => setOpen(true)}>فتح المعاينة</button>
    <p data-testid="log">{log}</p>
    <InheritancePreviewDialog open={open} title="معاينة تعديل سياسة الفندق" rows={rows} onCancel={() => { setOpen(false); setLog("cancelled"); }}
      onConfirm={async (ids) => { setOpen(false); setLog("confirmed:" + ids.join(",")); }} />
  </div>);
}
ReactDOM.createRoot(document.getElementById("root")!).render(<App />);
