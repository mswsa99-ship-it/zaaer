/**
 * 0060 (OWNER-12): the same near-name rule as fn_name_closeness — hamza, alef maqsura, taa marbuta and diacritics
 * folded, then the best trigram overlap (0–1) between the query and the whole name, any word of it, or any two words
 * joined («عبد الله» against «عبدالله»). 0.3 or more is a near name.
 */
export function nameNorm(s: string | null | undefined): string {
  const from = "أإآٱىئؤة", to = "ااااييوه";
  return String(s ?? "").replace(/[أإآٱىئؤة]/g, (c) => to[from.indexOf(c)]).replace(/[ًٌٍَُِّْـ]/g, "").replace(/\s+/g, " ").toLowerCase();
}
function trigrams(s: string): Set<string> {
  const t = "  " + s + " ", out = new Set<string>();
  for (let i = 0; i < Math.max(t.length - 2, 1); i++) out.add(t.slice(i, i + 3));
  return out;
}
export function nameCloseness(name: string, q: string): number {
  const b = trigrams(nameNorm(q).replace(/ /g, ""));
  const ws = nameNorm(name).split(" ").filter(Boolean);
  const parts = [ws.join(""), ...ws, ...ws.slice(0, -1).map((w, i) => w + ws[i + 1])].filter(Boolean);
  let best = 0;
  for (const p of parts) {
    const a = trigrams(p);
    const inter = [...a].filter((x) => b.has(x)).length, uni = new Set([...a, ...b]).size;
    if (uni) best = Math.max(best, Math.round((inter / uni) * 1000) / 1000);
  }
  return best;
}
export const NEAR_NAME = 0.3;
