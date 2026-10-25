/**
 * A small Excel (.xlsx) writer with no dependency (decision 14, 10.4: exports to Excel beside print/PDF).
 *
 * An .xlsx file is a zip of XML parts. This writes the parts a workbook needs (content types, the package relations,
 * the workbook, its relations, a styles part and one part per sheet) and stores them in a zip without compression,
 * with the CRC and sizes a reader checks. Text goes in as inline strings (no shared-string table), numbers as values,
 * so a cell is exactly what the screen showed: nothing is reinterpreted on the way. Sheets are right-to-left.
 *
 * Kept deliberately small: strings, numbers, a money format (two decimals), a bold row for the header, column widths.
 */
export type XlsxCell = string | number | null | undefined | { v: number; fmt: "money" | "int" };
export interface XlsxSheet {
  /** at most 31 characters, none of : \ / ? * [ ] */
  name: string;
  rows: XlsxCell[][];
  /** zero-based index of the row written in bold (the column header), if any */
  headerRow?: number;
  /** column widths in characters, by column index */
  widths?: number[];
}

// ---------------------------------------------------------------------------------------------------------------
// zip (stored entries)
// ---------------------------------------------------------------------------------------------------------------
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; }
  return t;
})();
export function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
const enc = new TextEncoder();
function dosDateTime(d: Date): { time: number; date: number } {
  const time = (d.getHours() << 11) | (d.getMinutes() << 5) | Math.floor(d.getSeconds() / 2);
  const date = ((Math.max(d.getFullYear(), 1980) - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate();
  return { time, date };
}
/** A zip of stored (uncompressed) entries, names UTF-8. */
export function zipStore(entries: Array<{ name: string; data: Uint8Array }>, now = new Date()): Uint8Array {
  const { time, date } = dosDateTime(now);
  const locals: Uint8Array[] = []; const centrals: Uint8Array[] = [];
  let offset = 0;
  for (const e of entries) {
    const name = enc.encode(e.name); const crc = crc32(e.data);
    const lh = new DataView(new ArrayBuffer(30 + name.length));
    lh.setUint32(0, 0x04034b50, true); lh.setUint16(4, 20, true); lh.setUint16(6, 0x0800, true); lh.setUint16(8, 0, true);
    lh.setUint16(10, time, true); lh.setUint16(12, date, true); lh.setUint32(14, crc, true); lh.setUint32(18, e.data.length, true); lh.setUint32(22, e.data.length, true);
    lh.setUint16(26, name.length, true); lh.setUint16(28, 0, true);
    new Uint8Array(lh.buffer).set(name, 30);
    const local = new Uint8Array(lh.buffer);
    const ch = new DataView(new ArrayBuffer(46 + name.length));
    ch.setUint32(0, 0x02014b50, true); ch.setUint16(4, 20, true); ch.setUint16(6, 20, true); ch.setUint16(8, 0x0800, true); ch.setUint16(10, 0, true);
    ch.setUint16(12, time, true); ch.setUint16(14, date, true); ch.setUint32(16, crc, true); ch.setUint32(20, e.data.length, true); ch.setUint32(24, e.data.length, true);
    ch.setUint16(28, name.length, true); ch.setUint16(30, 0, true); ch.setUint16(32, 0, true); ch.setUint16(34, 0, true); ch.setUint16(36, 0, true); ch.setUint32(38, 0, true); ch.setUint32(42, offset, true);
    new Uint8Array(ch.buffer).set(name, 46);
    locals.push(local, e.data); centrals.push(new Uint8Array(ch.buffer));
    offset += local.length + e.data.length;
  }
  const cdSize = centrals.reduce((s, c) => s + c.length, 0);
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, 0x06054b50, true); end.setUint16(4, 0, true); end.setUint16(6, 0, true); end.setUint16(8, entries.length, true); end.setUint16(10, entries.length, true);
  end.setUint32(12, cdSize, true); end.setUint32(16, offset, true); end.setUint16(20, 0, true);
  const total = offset + cdSize + 22; const out = new Uint8Array(total); let p = 0;
  for (const part of [...locals, ...centrals, new Uint8Array(end.buffer)]) { out.set(part, p); p += part.length; }
  return out;
}

// ---------------------------------------------------------------------------------------------------------------
// the workbook
// ---------------------------------------------------------------------------------------------------------------
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "");
export function columnName(i: number): string { let s = ""; let n = i + 1; while (n > 0) { const r = (n - 1) % 26; s = String.fromCharCode(65 + r) + s; n = Math.floor((n - 1) / 26); } return s; }
export function sheetName(name: string): string { const clean = name.replace(/[:\\/?*[\]]/g, " ").trim().slice(0, 31); return clean || "Sheet1"; }

// styles: 0 = default, 1 = bold (header), 2 = money #,##0.00, 3 = integer #,##0, 4 = bold title
const STYLES = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="3"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="13"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="5"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="4" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="3" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>`;

function cellXml(ref: string, c: XlsxCell, bold: boolean): string {
  if (c == null) return bold ? `<c r="${ref}" s="1"/>` : "";
  if (typeof c === "number") return Number.isFinite(c) ? `<c r="${ref}"${bold ? ' s="1"' : ""}><v>${c}</v></c>` : "";
  if (typeof c === "object") return Number.isFinite(c.v) ? `<c r="${ref}" s="${c.fmt === "money" ? 2 : 3}"><v>${c.v}</v></c>` : "";
  const s = String(c);
  const space = /^\s|\s$/.test(s) ? ' xml:space="preserve"' : "";
  return `<c r="${ref}" t="inlineStr"${bold ? ' s="1"' : ""}><is><t${space}>${esc(s)}</t></is></c>`;
}
function sheetXml(sheet: XlsxSheet): string {
  const rows = sheet.rows;
  const width = rows.reduce((m, r) => Math.max(m, r.length), 1);
  const cols = sheet.widths && sheet.widths.length ? `<cols>${sheet.widths.map((w, i) => `<col min="${i + 1}" max="${i + 1}" width="${Math.max(4, Math.min(120, w))}" customWidth="1"/>`).join("")}</cols>` : "";
  const body = rows.map((r, i) => {
    const bold = sheet.headerRow === i;
    const cells = r.map((c, j) => cellXml(`${columnName(j)}${i + 1}`, c, bold)).join("");
    return `<row r="${i + 1}">${cells}</row>`;
  }).join("");
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="A1:${columnName(width - 1)}${Math.max(rows.length, 1)}"/><sheetViews><sheetView rightToLeft="1" workbookViewId="0"/></sheetViews><sheetFormatPr defaultRowHeight="15"/>${cols}<sheetData>${body}</sheetData></worksheet>`;
}

/** The bytes of a workbook with these sheets. */
export function buildXlsx(sheets: XlsxSheet[], now = new Date()): Uint8Array {
  if (sheets.length === 0) throw new Error("xlsx: no sheets");
  const names = new Set<string>();
  const named = sheets.map((s, i) => { let n = sheetName(s.name); let k = 2; while (names.has(n)) n = `${n.slice(0, 28)} ${k++}`; names.add(n); return { ...s, name: n, id: i + 1 }; });
  const contentTypes = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>${named.map((s) => `<Override PartName="/xl/worksheets/sheet${s.id}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join("")}</Types>`;
  const rels = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>`;
  const workbook = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView xWindow="0" yWindow="0" windowWidth="20000" windowHeight="10000"/></bookViews><sheets>${named.map((s) => `<sheet name="${esc(s.name)}" sheetId="${s.id}" r:id="rId${s.id}"/>`).join("")}</sheets></workbook>`;
  const wbRels = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${named.map((s) => `<Relationship Id="rId${s.id}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${s.id}.xml"/>`).join("")}<Relationship Id="rId${named.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>`;
  const entries = [
    { name: "[Content_Types].xml", data: enc.encode(contentTypes) },
    { name: "_rels/.rels", data: enc.encode(rels) },
    { name: "xl/workbook.xml", data: enc.encode(workbook) },
    { name: "xl/_rels/workbook.xml.rels", data: enc.encode(wbRels) },
    { name: "xl/styles.xml", data: enc.encode(STYLES) },
    ...named.map((s) => ({ name: `xl/worksheets/sheet${s.id}.xml`, data: enc.encode(sheetXml(s)) })),
  ];
  return zipStore(entries, now);
}

export const XLSX_MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

/** A file name safe for every system: the title's letters, digits, dashes and underscores (Arabic kept), nothing else. */
export function safeFileName(s: string): string {
  return s.replace(/[\\/:*?"<>|\u0000-\u001f]/g, " ").replace(/\s+/g, " ").trim().replace(/ /g, "_").slice(0, 120) || "export";
}
