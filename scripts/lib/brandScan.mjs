/**
 * Plan 3.4 — the automated scan of staff-facing texts (فحص آلي لنصوص الموظف). Today it inventories where the
 * product name and hotel name appear and which surface each serves; after the design approval (3.1) the same
 * scan is the gate: every staff surface names RoomAI, and the hotel name appears only as hotel data.
 */

/** Surfaces a file path serves: the guest sees his hotel's name; the staff must see RoomAI (3.4). */
export function classifySurface(path) {
  const p = String(path).split("\\").join("/");
  if (/src\/pages\/guest\/|src\/components\/Guest|src\/layouts\/GuestLayout|\/guest/i.test(p)) return "guest";
  if (/src\/pages\/(staff|admin)\/|src\/layouts\/(Staff|Admin)Layout|src\/components\//.test(p)) return "staff";
  return "shared"; // index.html, src/lib, src/demo … — judged case by case
}

/**
 * Every occurrence of a brand string in one source text.
 * @param {string} source
 * @param {string[]} brands
 * @param {string} [file]
 * @returns {Array<{file:string,line:number,brand:string,context:string}>}
 */
export function findBrandOccurrences(source, brands, file = "<text>") {
  const out = [];
  const lines = String(source).split("\n");
  for (let i = 0; i < lines.length; i++) {
    for (const brand of brands) {
      if (brand && lines[i].includes(brand)) out.push({ file, line: i + 1, brand, context: lines[i].trim() });
    }
  }
  return out;
}

/** Browser-tab titles: the static <title> and every dynamic document.title assignment (3.4 e2e checks these). */
export function findTitleAssignments(source, file = "<text>") {
  const out = [];
  const lines = String(source).split("\n");
  for (let i = 0; i < lines.length; i++) {
    const html = lines[i].match(/<title>([^<]*)<\/title>/);
    if (html) out.push({ file, line: i + 1, kind: "html", value: html[1].trim() });
    const dyn = lines[i].match(/document\.title\s*=\s*(.+?);?\s*$/);
    if (dyn) out.push({ file, line: i + 1, kind: "dynamic", value: dyn[1].trim() });
  }
  return out;
}
