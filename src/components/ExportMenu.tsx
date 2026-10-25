import { useEffect, useRef, useState } from "react";
import { Download, Printer, ChevronDown } from "lucide-react";
import { toArabicError } from "../lib/api";
import { buildPrintDocument, downloadXlsx, printDocument, scopeText, type ExportScope, type ExportStatement, type ExportTable } from "../lib/exports";
import { Spinner } from "./ui";

export interface ExportSource {
  /** the file's statement for a scope (title, branch, period, filters in words, who) */
  statement: (scope: ExportScope) => ExportStatement;
  /** the rows of a scope: the page as shown, or every page of the same filters (decision 43) */
  table: (scope: ExportScope) => Promise<ExportTable>;
  /** rows on the screen now, and the exact total the server reported */
  pageCount: number;
  total: number;
}

/**
 * «تصدير Excel» and «طباعة / PDF» with the scope said out loud (decision 14, 10.4; G25; X09): the reader picks
 * «كل النتائج» (every page of the same filters) or «هذه الصفحة», and the file's first lines repeat the choice.
 */
export function ExportMenu({ source, disabled, allOnly }: { source: ExportSource; disabled?: boolean; /** a report has no pages: export its whole result at once */ allOnly?: boolean }) {
  const [open, setOpen] = useState<null | "xlsx" | "print">(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setOpen(null); };
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(null); };
    document.addEventListener("mousedown", onDown); window.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("mousedown", onDown); window.removeEventListener("keydown", onKey); };
  }, [open]);

  const scopes: ExportScope[] = allOnly ? [{ kind: "all", count: source.total }] : [{ kind: "all", count: source.total }, { kind: "page", count: source.pageCount, total: source.total }];
  const pick = (kind: "xlsx" | "print") => (allOnly ? run(kind, scopes[0]) : setOpen(open === kind ? null : kind));

  async function run(kind: "xlsx" | "print", scope: ExportScope) {
    setOpen(null); setError(null); setBusy(`${kind}:${scope.kind}`);
    try {
      const table = await source.table(scope);
      // the statement counts what the file really holds (the set may have changed between the screen and the export)
      const n = table.count ?? table.rows.length;
      const actual: ExportScope = scope.kind === "all" ? { kind: "all", count: n } : { kind: "page", count: n, total: source.total };
      const statement = source.statement(actual);
      if (kind === "xlsx") downloadXlsx(statement, table); else printDocument(buildPrintDocument(statement, table));
    } catch (e) { setError(toArabicError(e)); } finally { setBusy(null); }
  }

  const empty = disabled || source.total === 0;
  return (
    <div className="relative" ref={ref} data-testid="export-menu">
      <div className="flex items-center gap-1">
        <button type="button" onClick={() => pick("xlsx")} disabled={empty || !!busy} className="btn-outline text-sm" data-testid="export-xlsx" aria-haspopup={allOnly ? undefined : "menu"} aria-expanded={allOnly ? undefined : open === "xlsx"}>
          {busy?.startsWith("xlsx") ? <Spinner className="h-4 w-4" /> : <Download className="h-4 w-4" />} تصدير Excel {!allOnly && <ChevronDown className="h-3 w-3" />}
        </button>
        <button type="button" onClick={() => pick("print")} disabled={empty || !!busy} className="btn-outline text-sm" data-testid="export-print" aria-haspopup={allOnly ? undefined : "menu"} aria-expanded={allOnly ? undefined : open === "print"}>
          {busy?.startsWith("print") ? <Spinner className="h-4 w-4" /> : <Printer className="h-4 w-4" />} طباعة / PDF {!allOnly && <ChevronDown className="h-3 w-3" />}
        </button>
      </div>
      {open && (
        <div role="menu" className="absolute left-0 z-20 mt-1 w-64 rounded-xl border border-ink-100 bg-white p-1 text-sm shadow-lg" data-testid="export-scope-menu">
          <p className="px-3 py-1.5 text-[11px] text-ink-400">{open === "xlsx" ? "ملف Excel يذكر في أوله الفرع والفترة والمرشحات والنطاق" : "صفحة للطباعة أو الحفظ PDF، بعنوان يذكر الفرع والفترة والمرشحات والنطاق"}</p>
          {scopes.map((s) => (
            <button key={s.kind} role="menuitem" type="button" onClick={() => run(open, s)} disabled={s.count === 0} className="block w-full rounded-lg px-3 py-2 text-right hover:bg-ink-50 disabled:opacity-50" data-testid={`export-scope-${s.kind}`}>
              {scopeText(s)}
              <span className="block text-[11px] text-ink-400">{s.kind === "all" ? "يُقرأ من الخادم صفحةً صفحة بالمرشحات نفسها" : "الصفوف المعروضة الآن فقط"}</span>
            </button>
          ))}
        </div>
      )}
      {error && <p className="mt-1 text-xs text-danger-600" role="alert">{error}</p>}
    </div>
  );
}
