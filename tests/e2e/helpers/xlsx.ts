/**
 * A reader for the zips our Excel writer produces (stored entries only), used by the unit tests of the writer and by
 * the end-to-end export tests to open a downloaded file and count its rows. Not a general zip reader.
 */
export interface ZipEntry { name: string; crc: number; data: Uint8Array }

export function readZip(bytes: Uint8Array): Map<string, ZipEntry> {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const out = new Map<string, ZipEntry>();
  let p = 0;
  while (p + 30 <= bytes.length && dv.getUint32(p, true) === 0x04034b50) {
    const method = dv.getUint16(p + 8, true); const crc = dv.getUint32(p + 14, true); const size = dv.getUint32(p + 18, true);
    const nameLen = dv.getUint16(p + 26, true); const extraLen = dv.getUint16(p + 28, true);
    if (method !== 0) throw new Error("readZip: only stored entries are supported");
    const name = new TextDecoder().decode(bytes.subarray(p + 30, p + 30 + nameLen));
    const start = p + 30 + nameLen + extraLen;
    out.set(name, { name, crc, data: bytes.subarray(start, start + size) });
    p = start + size;
  }
  return out;
}

/** The sheet's rows as text: inline strings and values, in column order (empty cells left out). */
export function sheetCells(sheetXml: string): string[][] {
  const rows: string[][] = [];
  for (const row of sheetXml.matchAll(/<row r="\d+">([\s\S]*?)<\/row>/g)) {
    const cells: string[] = [];
    for (const c of row[1].matchAll(/<c [^>]*?(?:\/>|>([\s\S]*?)<\/c>)/g)) {
      const inner = c[1] ?? "";
      const t = inner.match(/<t(?: [^>]*)?>([\s\S]*?)<\/t>/); const v = inner.match(/<v>([\s\S]*?)<\/v>/);
      cells.push(unescape(t ? t[1] : v ? v[1] : ""));
    }
    rows.push(cells);
  }
  return rows;
}
const unescape = (s: string) => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&amp;/g, "&");

/** The first sheet of a workbook's bytes as rows of text. */
export function firstSheetRows(bytes: Uint8Array): string[][] {
  const z = readZip(bytes);
  const sheet = z.get("xl/worksheets/sheet1.xml");
  if (!sheet) throw new Error("no first sheet");
  return sheetCells(new TextDecoder().decode(sheet.data));
}
