import { useEffect, useRef, useState, createContext, useContext, type ReactNode, type FormEvent } from "react";
import { X, Archive, Trash2, RotateCcw, AlertTriangle } from "lucide-react";
import { cn } from "../lib/utils";
import { ErrorBanner, Spinner } from "./ui";
import { opsApi, toArabicError, type DefinitionEntity } from "../lib/api";
import { formatMoneyInput, moneyTextToHalalas, sanitizeMoneyText } from "../lib/money";

/** Modal that never closes on its own after a failed save — the form keeps its values. */
export function Modal({ open, title, onClose, children, wide }: { open: boolean; title: string; onClose: () => void; children: ReactNode; wide?: boolean }) {
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, onClose]);
  if (!open) return null;
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-ink-900/50 p-0 sm:items-center sm:p-4" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className={cn("card max-h-[92vh] w-full overflow-y-auto p-5 sm:p-6", wide ? "sm:max-w-3xl" : "sm:max-w-lg")} role="dialog" aria-modal="true">
        <div className="mb-4 flex items-center justify-between">
          <h3 className="text-base font-semibold text-ink-800">{title}</h3>
          <button onClick={onClose} className="rounded-lg p-1 text-ink-400 hover:bg-ink-50 hover:text-ink-700" aria-label="إغلاق"><X className="h-4 w-4" /></button>
        </div>
        {children}
      </div>
    </div>
  );
}

export function Field({ label, children, hint, className, error }: { label: string; children: ReactNode; hint?: string; className?: string; error?: string | null }) {
  return (
    <div className={className}>
      <label className="label">{label}</label>
      {children}
      {error ? <p className="mt-1 text-xs text-danger-600" role="alert">{error}</p> : hint && <p className="mt-1 text-xs text-ink-400">{hint}</p>}
    </div>
  );
}

/** SAR input that yields integer halalas. */
/** The one money field of the system (design system «AmountInput»): starts empty, never rewrites what the user is typing. */
export function MoneyInput({ valueHalalas, onChange, min = 0, disabled, placeholder, label }: { valueHalalas: number | null; onChange: (h: number | null) => void; min?: number; disabled?: boolean; placeholder?: string; label?: string }) {
  const [text, setText] = useState(formatMoneyInput(valueHalalas));
  // the last value this field sent up: a different value arriving is set from outside (a suggestion, a reset) and shows
  // at once, even while the field has the focus; the field's own value never rewrites what the user is typing
  const sent = useRef<number | null>(valueHalalas);
  useEffect(() => { if (valueHalalas !== sent.current) { sent.current = valueHalalas; setText(formatMoneyInput(valueHalalas)); } }, [valueHalalas]);
  return (
    <div className="relative">
      <input type="text" inputMode="decimal" autoComplete="off" data-money="" value={text} disabled={disabled} placeholder={placeholder ?? "0"} aria-label={label}
        onBlur={() => setText(formatMoneyInput(moneyTextToHalalas(text)))}
        onChange={(e) => { const t = sanitizeMoneyText(e.target.value, min < 0); if (t == null) return; setText(t); const h = moneyTextToHalalas(t); sent.current = h; onChange(h); }}
        className="input pl-12 tabular-nums" dir="ltr" />
      <span className="pointer-events-none absolute inset-y-0 left-3 flex items-center text-xs text-ink-500">ر.س</span>
    </div>
  );
}

export function SubmitRow({ busy, label, onCancel, danger }: { busy: boolean; label: string; onCancel?: () => void; danger?: boolean }) {
  return (
    <div className="mt-5 flex gap-2">
      <button type="submit" disabled={busy} className={danger ? "btn-danger" : "btn-primary"}>{busy ? <Spinner className="h-4 w-4" /> : null} {label}</button>
      {onCancel && <button type="button" onClick={onCancel} className="btn-outline">إلغاء</button>}
    </div>
  );
}

/** Generic form wrapper: shows the error inline and never clears the inputs on failure (U01). */
export function ActionForm({ onSubmit, children, error }: { onSubmit: () => Promise<void>; children: ReactNode; error?: string | null }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const submit = async (e: FormEvent) => {
    e.preventDefault(); setBusy(true); setErr(null);
    try { await onSubmit(); } catch (ex) { setErr(toArabicError(ex)); } finally { setBusy(false); }
  };
  return (
    <form onSubmit={submit}>
      {(err || error) && <div className="mb-3"><ErrorBanner message={err ?? error ?? ""} /></div>}
      <FormBusy.Provider value={busy}>{children}</FormBusy.Provider>
    </form>
  );
}
const FormBusy = createContext(false);
export const useFormBusy = () => useContext(FormBusy);

export function Submit({ label, onCancel, danger }: { label: string; onCancel?: () => void; danger?: boolean }) {
  const busy = useFormBusy();
  return <SubmitRow busy={busy} label={label} onCancel={onCancel} danger={danger} />;
}

export function ReasonInput({ value, onChange, label = "السبب (إلزامي)", placeholder }: { value: string; onChange: (v: string) => void; label?: string; placeholder?: string }) {
  return (
    <Field label={label}>
      <textarea value={value} onChange={(e) => onChange(e.target.value)} className="input" rows={2} placeholder={placeholder ?? "يُسجَّل السبب في سجل العمليات"} />
    </Field>
  );
}

/**
 * Archive / restore / delete controls for a definition. Delete is only offered after the server
 * confirms there are no dependencies; otherwise the dependency list is shown and archiving is suggested.
 */
export function DefinitionLifecycle({ entity, id, archived, onDone, compact }: { entity: DefinitionEntity; id: string; archived: boolean; onDone: () => void; compact?: boolean }) {
  const [mode, setMode] = useState<"idle" | "archive" | "delete" | "restore">("idle");
  const [reason, setReason] = useState("");
  const [deps, setDeps] = useState<Record<string, number> | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const DEP_LABELS: Record<string, string> = { rooms: "وحدات", reservations: "حجوزات", staff: "موظفون", blocks: "بلوكات", floors: "طوابق", facilities: "مرافق", allocations: "تخصيصات", tasks: "مهام", keyboxes: "صناديق", services: "خدمات", charges: "بنود حجز" };

  const openDelete = async () => {
    setErr(null); setMode("delete"); setDeps(null);
    try { setDeps(await opsApi.dependencies(entity, id)); } catch (e) { setErr(toArabicError(e)); }
  };
  const run = async (fn: () => Promise<unknown>) => { setBusy(true); setErr(null); try { await fn(); setMode("idle"); setReason(""); onDone(); } catch (e) { setErr(toArabicError(e)); } finally { setBusy(false); } };
  const hasDeps = deps ? Object.values(deps).some((n) => n > 0) : true;

  return (
    <div className={compact ? "" : "mt-3 border-t border-ink-50 pt-3"}>
      <div className="flex flex-wrap gap-2">
        {!archived && <button type="button" onClick={() => { setMode("archive"); setErr(null); }} className="btn-outline text-xs"><Archive className="h-3.5 w-3.5" /> أرشفة</button>}
        {archived && <button type="button" onClick={() => run(() => opsApi.archiveDefinition(entity, id, "استعادة", false))} className="btn-outline text-xs"><RotateCcw className="h-3.5 w-3.5" /> استعادة</button>}
        <button type="button" onClick={openDelete} className="btn-ghost text-xs text-danger-600"><Trash2 className="h-3.5 w-3.5" /> حذف نهائي</button>
      </div>
      {err && <div className="mt-2"><ErrorBanner message={err} /></div>}
      {mode === "archive" && (
        <div className="mt-3 space-y-2 rounded-xl border border-ink-100 p-3">
          <ReasonInput value={reason} onChange={setReason} label="سبب الأرشفة (إلزامي)" />
          <p className="text-xs text-ink-400">الأرشفة تخفي العنصر من الاختيارات الجديدة وتبقي تاريخه كاملًا.</p>
          <div className="flex gap-2">
            <button type="button" disabled={busy || !reason.trim()} onClick={() => run(() => opsApi.archiveDefinition(entity, id, reason.trim(), true))} className="btn-primary text-xs">{busy ? <Spinner className="h-3.5 w-3.5" /> : <Archive className="h-3.5 w-3.5" />} تأكيد الأرشفة</button>
            <button type="button" onClick={() => setMode("idle")} className="btn-outline text-xs">إلغاء</button>
          </div>
        </div>
      )}
      {mode === "delete" && (
        <div className="mt-3 space-y-2 rounded-xl border border-danger-500/30 p-3">
          {deps === null && !err && <p className="text-xs text-ink-400">جارٍ فحص الارتباطات…</p>}
          {deps && hasDeps && (
            <div className="text-xs text-danger-600">
              <p className="flex items-center gap-1 font-medium"><AlertTriangle className="h-3.5 w-3.5" /> لا يمكن الحذف لارتباطه بـ:</p>
              <ul className="mt-1 space-y-0.5">{Object.entries(deps).filter(([, n]) => n > 0).map(([k, n]) => <li key={k}>• {n} {DEP_LABELS[k] ?? k}</li>)}</ul>
              <p className="mt-1 text-ink-500">يمكنك أرشفته بدلًا من الحذف.</p>
            </div>
          )}
          {deps && !hasDeps && <p className="text-xs text-ink-600">لا توجد ارتباطات. الحذف نهائي ويُسجَّل في سجل الإجراءات.</p>}
          <div className="flex gap-2">
            {deps && !hasDeps && <button type="button" disabled={busy} onClick={() => run(async () => { const r = await opsApi.deleteDefinition(entity, id); if (!r.ok) throw new Error(r.error ?? "HAS_DEPENDENCIES"); })} className="btn-danger text-xs">{busy ? <Spinner className="h-3.5 w-3.5" /> : <Trash2 className="h-3.5 w-3.5" />} تأكيد الحذف</button>}
            <button type="button" onClick={() => setMode("idle")} className="btn-outline text-xs">إغلاق</button>
          </div>
        </div>
      )}
    </div>
  );
}

export function ArchivedBadge({ archivedAt }: { archivedAt: string | null }) {
  if (!archivedAt) return null;
  return <span className="badge bg-ink-100 text-ink-500">مؤرشف</span>;
}

export function Toggle({ checked, onChange, label }: { checked: boolean; onChange: (v: boolean) => void; label: string }) {
  return (
    <label className="flex cursor-pointer items-center gap-2 text-sm text-ink-700">
      <input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} className="h-4 w-4 rounded border-ink-300 text-brand-600" />
      {label}
    </label>
  );
}
