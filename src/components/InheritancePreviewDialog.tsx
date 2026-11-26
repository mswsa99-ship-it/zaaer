import { useState } from "react";
import { Modal } from "./forms";
import { AlertTriangle } from "lucide-react";
import { overwritableRows, type PlanRow } from "../lib/inheritanceView";

const EFFECT_TEXT: Record<PlanRow["effect"], string> = {
  updates: "سيتحدّث", creates: "ستُنشأ له نسخة", keeps_own: "يبقى نصه الخاص", linked: "يبقى كما هو ويُربط بالأساسي", unchanged: "بلا تغيير", skipped: "مؤرشف: يُتخطّى",
};

/**
 * Preview of a hotel-level change, exactly as the server planned it. Branches that keep their own text are never
 * selected by default; choosing one for overwrite is explicit and sent back to the server with the preview token.
 */
export function InheritancePreviewDialog({ open, title, rows, hiddenNote, onCancel, onConfirm }: {
  open: boolean; title: string; rows: PlanRow[]; hiddenNote?: string | null; onCancel: () => void; onConfirm: (overwriteBranchIds: string[]) => Promise<void>;
}) {
  const [overwrite, setOverwrite] = useState<Set<string>>(new Set());
  const [busy, setBusy] = useState(false);
  const choosable = overwritableRows(rows);
  const toggle = (id: string) => setOverwrite((s) => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n; });
  const close = () => { setOverwrite(new Set()); onCancel(); };
  return (
    <Modal open={open} title={title} onClose={close}>
      <div data-testid="inheritance-preview" className="space-y-4 text-sm">
        <div className="rai-notice rai-notice-warning" role="note"><AlertTriangle aria-hidden="true" /><p>هذا تعديل على مستوى الفندق. يُنسخ إلى الفروع التي لم تغيّر النص بنفسها، وما غيّره فرع بنفسه يبقى كما هو ما لم تختره.</p></div>
        <ul className="space-y-2" aria-label="أثر التعديل على الفروع">
          {rows.map((r) => (
            <li key={r.branchId} className="rounded-xl border border-rai-line p-3" data-testid={`plan-${r.branchId}`}>
              <p className="font-medium text-rai-ink">{r.name}</p>
              <p className={r.effect === "keeps_own" ? "text-rai-success" : "text-rai-ink-muted"}>{EFFECT_TEXT[r.effect]}{r.changed.length > 0 && `: ${r.changed.join("، ")}`}</p>
              {r.effect === "keeps_own" && r.overwritable.length > 0 && (
                <label className="mt-1 flex min-h-[44px] cursor-pointer items-start gap-2">
                  <input type="checkbox" className="mt-1 h-4 w-4" checked={overwrite.has(r.branchId)} onChange={() => toggle(r.branchId)} data-testid={`overwrite-${r.branchId}`} />
                  <span className={overwrite.has(r.branchId) ? "text-rai-warning" : "text-rai-ink"}>استبدال نص {r.name} ({r.overwritable.join("، ")}) بنص الفندق</span>
                </label>
              )}
            </li>
          ))}
          {rows.length === 0 && <li className="text-rai-ink-muted">لا توجد فروع تتأثر.</li>}
        </ul>
        {hiddenNote && <p className="text-rai-ink-muted" data-testid="plan-hidden">{hiddenNote}</p>}
        {choosable.length > 0 && <p className="text-rai-ink-muted">المحدَّد للاستبدال: {overwrite.size} من {choosable.length}</p>}
        <div className="flex flex-wrap justify-end gap-2">
          <button type="button" className="btn-outline min-h-[44px]" onClick={close}>إلغاء</button>
          <button type="button" className="btn-primary min-h-[44px]" disabled={busy} data-testid="inheritance-confirm"
            onClick={async () => { setBusy(true); try { await onConfirm([...overwrite]); setOverwrite(new Set()); } finally { setBusy(false); } }}>تطبيق على الفروع</button>
        </div>
      </div>
    </Modal>
  );
}
