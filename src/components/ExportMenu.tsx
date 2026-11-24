import { useEffect, useRef, useState } from "react";
import { Download, Printer, ChevronDown } from "lucide-react";
import { toArabicError } from "../lib/api";
import { buildPrintDocumentAsync, downloadXlsx, printDocument, scopeText, type ExportScope, type ExportStatement, type ExportTable } from "../lib/exports";
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
  const [menuOpen, setMenuOpen] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [progress, setProgress] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open && !menuOpen) return;
    const onDown = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) { setOpen(null); setMenuOpen(false); } };
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") { setOpen(null); setMenuOpen(false); } };
    document.addEventListener("mousedown", onDown); window.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("mousedown", onDown); window.removeEventListener("keydown", onKey); };
  }, [open, menuOpen]);

  const scopes: ExportScope[] = allOnly ? [{ kind: "all", count: source.total }] : [{ kind: "all", count: source.total }, { kind: "page", count: source.pageCount, total: source.total }];
  const pick = (kind: "xlsx" | "print") => (allOnly ? run(kind, scopes[0]) : setOpen(open === kind ? null : kind));

  async function run(kind: "xlsx" | "print", scope: ExportScope) {
    setOpen(null); setMenuOpen(false); setError(null); setProgress(null); setBusy(`${kind}:${scope.kind}`);
    try {
      const table = await source.table(scope);
      // the statement counts what the file really holds (the set may have changed between the screen and the export)
      const n = table.count ?? table.rows.length;
      const actual: ExportScope = scope.kind === "all" ? { kind: "all", count: n } : { kind: "page", count: n, total: source.total };
      const statement = source.statement(actual);
      if (kind === "xlsx") downloadXlsx(statement, table); else {
        const html = await buildPrintDocumentAsync(statement, table, { onProgress: (done, total) => { if (total > 1) setProgress(`يُجهَّز للطباعة… صفحة ${done} من ${total}`); } });
        setProgress(null); printDocument(html);
      }
    } catch (e) { setError(toArabicError(e)); } finally { setBusy(null); setProgress(null); }
  }

  const empty = disabled || source.total === 0;
  const pending = !!busy;
  // 6.9 (U8): one named «تصدير ▾» button; its menu names the two formats, then the scope (unless a report has only one)
  const toggle = () => { setMenuOpen((o) => !o); setOpen(null); };
  return (
    <div className="relative" ref={ref} data-testid="export-menu">
      <button type="button" onClick={toggle} disabled={empty || pending} className="btn-outline text-sm" data-testid="export-trigger" aria-haspopup="menu" aria-expanded={menuOpen}
        title={empty ? "لا توجد صفوف للتصدير" : undefined}>
        {pending ? <Spinner className="h-4 w-4" /> : <Download className="h-4 w-4" />} تصدير <ChevronDown className="h-4 w-4" aria-hidden="true" />
      </button>
      {menuOpen && !open && (
        <div role="menu" aria-label="تصدير" className="absolute left-0 z-20 mt-1 w-64 rounded-xl border border-ink-100 bg-white p-1 text-sm shadow-lg" data-testid="export-format-menu">
          <button role="menuitem" type="button" onClick={() => { if (allOnly) { setMenuOpen(false); run("xlsx", scopes[0]); } else pick("xlsx"); }} className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-right hover:bg-ink-50" data-testid="export-xlsx" aria-haspopup={allOnly ? undefined : "menu"} aria-expanded={allOnly ? undefined : open === "xlsx"}>
            <Download className="h-4 w-4" /> ملف Excel
          </button>
          <button role="menuitem" type="button" onClick={() => { if (allOnly) { setMenuOpen(false); run("print", scopes[0]); } else pick("print"); }} className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-right hover:bg-ink-50" data-testid="export-print" aria-haspopup={allOnly ? undefined : "menu"} aria-expanded={allOnly ? undefined : open === "print"}>
            <Printer className="h-4 w-4" /> طباعة / PDF
          </button>
        </div>
      )}
      {menuOpen && open && (
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
      {progress && <p className="mt-1 text-xs text-ink-500" role="status" data-testid="export-print-progress">{progress}</p>}
      {error && <p className="mt-1 text-xs text-danger-600" role="alert">{error}</p>}
    </div>
  );
}
