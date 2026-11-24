/**
 * Exports and printing (decisions 14 and 43, control G25, test X09): every file and every printout states what it
 * holds — the branch, the period, the filters, and whether it is «كل النتائج» or «هذه الصفحة» — and holds exactly the
 * rows the screen's filters and the reader's permissions allow, read from the same server function page after page.
 */
import { buildXlsx, safeFileName, XLSX_MIME, type XlsxCell, type XlsxSheet } from "./xlsx";

export type ExportScope = { kind: "all"; count: number } | { kind: "page"; count: number; total: number };

export interface ExportStatement {
  /** what the file is: «الحجوزات», «دفتر السندات», «سجل الإجراءات», a report's name */
  title: string;
  branch: string | null;
  /** an ISO day or a range */
  period?: { from?: string | null; to?: string | null } | null;
  /** the active filters, already in the reader's words («الحالة: مؤكد») */
  filters: string[];
  scope: ExportScope;
  /** OWNER-17: a report (figures and breakdowns, not a list of rows): the scope line says so, with no row count */
  report?: boolean;
  /** the branch's day and time the export was made (shown as given) */
  generatedAt: string;
  /** who exported (a name, never an id) */
  by?: string | null;
}

export const scopeText = (s: ExportScope) => (s.kind === "all" ? `كل النتائج (${s.count})` : `هذه الصفحة فقط (${s.count} من ${s.total})`);
export const periodText = (p: ExportStatement["period"]) => {
  if (!p || (!p.from && !p.to)) return "كل الفترات";
  if (p.from && p.to) return p.from === p.to ? p.from : `${p.from} → ${p.to}`;
  return p.from ? `من ${p.from}` : `حتى ${p.to}`;
};

/** The lines at the top of a file or a printout. The same words in Excel, on paper and in the tests. */
export function statementLines(s: ExportStatement): string[] {
  return [
    s.title,
    `الفرع: ${s.branch ?? "—"}`,
    `الفترة: ${periodText(s.period)}`,
    `المرشحات: ${s.filters.length ? s.filters.join(" · ") : "بلا مرشحات"}`,
    `النطاق: ${s.report ? "التقرير كاملًا للفترة والمرشحات" : scopeText(s.scope)}`,
    `أُصدر: ${s.generatedAt}${s.by ? ` · بواسطة ${s.by}` : ""}`,
  ];
}

export function exportFileName(s: ExportStatement, ext: "xlsx" | "csv"): string {
  const period = s.period?.from || s.period?.to ? `${s.period?.from ?? ""}_${s.period?.to ?? ""}` : "all";
  return `${safeFileName(`${s.title}-${s.branch ?? ""}-${period}-${s.scope.kind === "all" ? "all" : "page"}-${s.scope.count}`)}.${ext}`;
}

export interface ExportTable { columns: string[]; rows: XlsxCell[][]; widths?: number[]; /** further sheets of the Excel file (breakdowns of a report); the printout shows the main table */ sheets?: XlsxSheet[]; /** the data rows, when `rows` also carries summary lines (a totals line) */ count?: number }

/** One sheet: the statement, a blank line, the column header (bold), the rows. */
export function sheetOf(s: ExportStatement, t: ExportTable, name = "البيانات"): XlsxSheet {
  const head = statementLines(s).map((l) => [l]);
  return { name, rows: [...head, [], t.columns, ...t.rows], headerRow: head.length + 1, widths: t.widths ?? t.columns.map((c) => Math.max(10, Math.min(40, c.length * 2))) };
}

export function xlsxBlob(sheets: XlsxSheet[]): Blob { return new Blob([buildXlsx(sheets) as BlobPart], { type: XLSX_MIME }); }

/** The browser's download of a blob (the app runs in a normal browser tab, not inside a sandbox). */
export function downloadBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a"); a.href = url; a.download = filename; a.rel = "noopener"; document.body.appendChild(a); a.click(); a.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

export function downloadXlsx(s: ExportStatement, t: ExportTable, extraSheets: XlsxSheet[] = []) {
  downloadBlob(xlsxBlob([sheetOf(s, t), ...(t.sheets ?? []), ...extraSheets]), exportFileName(s, "xlsx"));
}

const escHtml = (v: unknown) => String(v ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const cellText = (c: XlsxCell) => (c == null ? "" : typeof c === "object" ? (c.fmt === "money" ? c.v.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 }) : c.v.toLocaleString("en-US")) : String(c));

/**
 * 6.10 (U2 الطباعة): the print page is independent and divided into pages — the rows split into page-sized
 * sections, each its own table that repeats the column header and carries its page number, so a 5,000-row list
 * never makes the browser lay out one giant table.
 */
export const PRINT_ROWS_PER_PAGE = 40;

/** One page section: its own table with the repeated column header, then the page's number. */
function printPageSections(t: ExportTable, rowsPerPage: number, from: number, to: number, pageCount: number): string {
  const th = t.columns.map((c) => `<th>${escHtml(c)}</th>`).join("");
  const out: string[] = [];
  const pages = Math.max(1, Math.ceil(t.rows.length / rowsPerPage));
  for (let p = from; p < to && p < pages; p++) {
    const rows = t.rows.slice(p * rowsPerPage, (p + 1) * rowsPerPage);
    const body = rows.map((r) => `<tr>${t.columns.map((_, j) => `<td>${escHtml(cellText(r[j]))}</td>`).join("")}</tr>`).join("");
    out.push(`<table class="pg${p === pages - 1 ? " last" : ""}"><thead><tr>${th}</tr></thead><tbody>${body}</tbody></table><p class="pageno">صفحة ${p + 1} من ${pageCount}</p>`);
  }
  return out.join("");
}

function printShell(title: string, meta: string[], pages: string, s: ExportStatement, t: ExportTable): string {
  return `<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><title>${escHtml(title)}</title>
<style>
  body { font-family: "Segoe UI", Tahoma, Arial, sans-serif; color: #1b2430; margin: 16mm 12mm; font-size: 11px; }
  h1 { font-size: 16px; margin: 0 0 4px; }
  .meta { color: #4a5568; margin: 0 0 10px; line-height: 1.6; }
  .meta span { display: inline-block; margin-inline-end: 14px; }
  table { border-collapse: collapse; width: 100%; }
  th, td { border: 1px solid #cbd3df; padding: 3px 5px; text-align: right; vertical-align: top; }
  th { background: #eef2f7; font-weight: 600; }
  tr { break-inside: avoid; }
  thead { display: table-header-group; }
  tfoot { display: table-footer-group; }
  table.pg { break-after: page; }
  table.pg.last { break-after: auto; }
  .pageno { margin: 4px 0 0; color: #4a5568; font-size: 10px; text-align: center; }
  .foot { margin-top: 8px; color: #4a5568; }
  @page { size: A4 landscape; margin: 10mm; }
</style></head><body>
<h1>${escHtml(title)}</h1>
<p class="meta">${meta.map((m) => `<span>${escHtml(m)}</span>`).join("")}</p>
${pages}
${(t.sheets ?? []).map((sh) => sheetTable(sh)).join("\n")}
<p class="foot">${s.report ? "التقرير كاملًا" : `${escHtml(scopeText(s.scope))} · ${t.count ?? t.rows.length} صفًا في هذه الطباعة`}</p>
</body></html>`;
}

/**
 * The document that is printed (or saved as PDF from the print dialog): the statement as a header, then the table
 * divided into page sections, then (OWNER-17) each further sheet of a report as its own table under its name, so
 * the paper holds what the Excel file holds. Pure, so a test reads it.
 */
export function buildPrintDocument(s: ExportStatement, t: ExportTable): string {
  const [title, ...meta] = statementLines(s);
  const pages = Math.max(1, Math.ceil(t.rows.length / PRINT_ROWS_PER_PAGE));
  return printShell(title, meta, printPageSections(t, PRINT_ROWS_PER_PAGE, 0, pages, pages), s, t);
}

export interface PrintBuildOptions {
  /** rows per printed page section (default PRINT_ROWS_PER_PAGE) */
  rowsPerPage?: number;
  /** after this many page sections the builder yields to the event loop (default 5) */
  yieldEveryPages?: number;
  /** progress in page sections, for the button's busy line */
  onProgress?: (donePages: number, totalPages: number) => void;
}

const yieldToEventLoop = () => new Promise<void>((r) => setTimeout(r, 0));

/**
 * buildPrintDocument in chunks: between page sections the tab's event loop turns, so building the printout of a
 * 5,000-row list never freezes the tab (6.10/U2). The resulting document is identical to the synchronous one.
 */
export async function buildPrintDocumentAsync(s: ExportStatement, t: ExportTable, opts: PrintBuildOptions = {}): Promise<string> {
  const rowsPerPage = Math.max(1, opts.rowsPerPage ?? PRINT_ROWS_PER_PAGE);
  const every = Math.max(1, opts.yieldEveryPages ?? 5);
  const pages = Math.max(1, Math.ceil(t.rows.length / rowsPerPage));
  const parts: string[] = [];
  for (let p = 0; p < pages; p += every) {
    parts.push(printPageSections(t, rowsPerPage, p, Math.min(p + every, pages), pages));
    opts.onProgress?.(Math.min(p + every, pages), pages);
    if (p + every < pages) await yieldToEventLoop();
  }
  const [title, ...meta] = statementLines(s);
  return printShell(title, meta, parts.join(""), s, t);
}

/** A further sheet as a printed table: its header row as the table head, the rows after it as the body. */
function sheetTable(sh: XlsxSheet): string {
  const h = sh.headerRow ?? 0, head = sh.rows[h] ?? [], rows = sh.rows.slice(h + 1);
  if (!rows.length) return "";
  return `<h2 style="font-size:13px;margin:14px 0 4px">${escHtml(sh.name)}</h2><table><thead><tr>${head.map((c) => `<th>${escHtml(cellText(c))}</th>`).join("")}</tr></thead><tbody>${rows.map((r) => `<tr>${head.map((_, j) => `<td>${escHtml(cellText(r[j]))}</td>`).join("")}</tr>`).join("")}</tbody></table>`;
}

/** Prints through a hidden frame so the screen's own layout is untouched; the frame is removed afterwards. */
export function printDocument(html: string) {
  const frame = document.createElement("iframe");
  frame.setAttribute("aria-hidden", "true"); frame.style.position = "fixed"; frame.style.right = "0"; frame.style.bottom = "0"; frame.style.width = "0"; frame.style.height = "0"; frame.style.border = "0";
  document.body.appendChild(frame);
  const doc = frame.contentWindow?.document;
  if (!doc) { frame.remove(); return; }
  doc.open(); doc.write(html); doc.close();
  const done = () => window.setTimeout(() => frame.remove(), 1000);
  frame.contentWindow?.addEventListener("afterprint", done);
  window.setTimeout(() => { try { frame.contentWindow?.focus(); frame.contentWindow?.print(); } finally { window.setTimeout(done, 60_000); } }, 50);
}

/** CSV with a BOM (Excel opens it in UTF-8) — kept for readers who prefer it; the statement is its first lines. */
export function csvText(s: ExportStatement, t: ExportTable): string {
  const q = (c: unknown) => `"${String(c ?? "").replace(/"/g, '""')}"`;
  const lines = [...statementLines(s).map((l) => [l]), [], t.columns, ...t.rows.map((r) => r.map(cellText))];
  return "﻿" + lines.map((r) => r.map(q).join(",")).join("\n");
}

export const money = (halalas: number | null | undefined): XlsxCell => (halalas == null ? null : { v: halalas / 100, fmt: "money" });
